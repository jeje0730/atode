import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:atode/auth.dart';
import 'package:atode/account_screen.dart';
import 'package:atode/main.dart';
import 'package:atode/data.dart';
import 'backup_test.dart' show MemoryRestoreRepository;

class MemoryPkceStorage extends GotrueAsyncStorage {
  final values = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => values[key];
  @override
  Future<void> setItem({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    values.remove(key);
  }
}

class FakeAccountAuth extends AccountAuth {
  AuthIdentity? current;
  bool recovery = false;
  int logins = 0, signups = 0, resets = 0, updates = 0;
  String? failure;
  @override
  bool get configured => true;
  @override
  String get project => 'https://test.supabase.co';
  @override
  String? get unavailableMessage => null;
  @override
  AuthIdentity? get identity => current;
  @override
  bool get recovering => recovery;
  @override
  String? get eventError => null;
  void enter(String id) {
    current = AuthIdentity(id, '$id@example.com');
    notifyListeners();
  }

  @override
  Future<void> signIn(String email, String password) async {
    logins++;
    if (failure != null) throw LoginFailure(failure!);
    enter('a');
  }

  @override
  Future<bool> signUp(String email, String password) async {
    signups++;
    return true;
  }

  @override
  Future<void> sendReset(String email) async {
    resets++;
  }

  @override
  Future<void> changePassword(String password) async {
    updates++;
    recovery = false;
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    current = null;
    recovery = false;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'config rejects secret keys and validates credentials and DB isolation',
    () {
      expect(
        validAuthConfiguration(
          'https://test.supabase.co',
          'sb_publishable_123456789012345',
        ),
        isTrue,
      );
      expect(
        validAuthConfiguration(
          'http://test.supabase.co',
          'sb_publishable_123456789012345',
        ),
        isFalse,
      );
      expect(
        validAuthConfiguration(
          'https://test.supabase.co',
          'sb_secret_dangerous',
        ),
        isFalse,
      );
      final jwt =
          'header.${base64Url.encode(utf8.encode(jsonEncode({'role': 'service_role'})))}.signature';
      expect(validAuthConfiguration('https://test.supabase.co', jwt), isFalse);
      expect(validateEmail('name@example.com'), isNull);
      expect(validateEmail('broken'), isNotNull);
      expect(validateNewPassword('short'), isNotNull);
      expect(
        accountDatabaseName('project', 'a'),
        isNot(accountDatabaseName('project', 'b')),
      );
      expect(
        accountDatabaseName('project', 'a'),
        isNot(accountDatabaseName('other', 'a')),
      );
    },
  );
  test(
    'secure session storage persists and removes only its own session',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = SecureSessionStorage('test-project');
      final other = SecureSessionStorage('other-project');
      await storage.initialize();
      expect(await storage.hasAccessToken(), isFalse);
      await storage.persistSession('test-session');
      await other.persistSession('other-session');
      expect(await storage.accessToken(), 'test-session');
      await storage.removePersistedSession();
      expect(await storage.hasAccessToken(), isFalse);
      expect(await other.accessToken(), 'other-session');
      final pkce = SecurePkceStorage('test-pkce');
      await pkce.setItem(key: 'verifier', value: 'test-verifier');
      expect(await pkce.getItem(key: 'verifier'), 'test-verifier');
      await pkce.removeItem(key: 'verifier');
      expect(await pkce.getItem(key: 'verifier'), isNull);
    },
  );
  test(
    'Supabase adapter uses password auth and logout, handles confirmation response',
    () async {
      final user = {
        'id': 'user-a',
        'aud': 'authenticated',
        'role': 'authenticated',
        'email': 'a@example.com',
        'created_at': '2026-10-19T00:00:00Z',
        'app_metadata': <String, dynamic>{},
        'user_metadata': <String, dynamic>{},
      };
      final expiry =
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
          1000;
      final token =
          'eyJhbGciOiJIUzI1NiJ9.${base64Url.encode(utf8.encode(jsonEncode({'sub': 'user-a', 'exp': expiry, 'role': 'authenticated'}))).replaceAll('=', '')}.signature';
      final calls = <String>[];
      final client = SupabaseClient(
        'https://test.supabase.co',
        'test-public-key',
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          pkceAsyncStorage: MemoryPkceStorage(),
        ),
        httpClient: MockClient((request) async {
          calls.add(request.url.path);
          if (request.url.path.endsWith('/token')) {
            expect(request.url.queryParameters['grant_type'], 'password');
            expect(jsonDecode(request.body)['email'], 'a@example.com');
            return http.Response(
              jsonEncode({
                'access_token': token,
                'refresh_token': 'test-refresh',
                'token_type': 'bearer',
                'expires_in': 3600,
                'user': user,
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/signup')) {
            expect(jsonDecode(request.body)['email'], 'new@example.com');
            return http.Response(jsonEncode(user), 200);
          }
          return http.Response('{}', 200);
        }),
      );
      final auth = SupabaseAccountAuth(client, 'https://test.supabase.co');
      try {
        await auth.signIn(' a@example.com ', 'password-test');
        await Future<void>.delayed(Duration.zero);
        expect(auth.identity?.id, 'user-a');
        await auth.signOut();
        await Future<void>.delayed(Duration.zero);
        expect(auth.identity, isNull);
        expect(await auth.signUp('new@example.com', 'password-test'), isTrue);
        expect(calls, contains('/auth/v1/logout'));
      } finally {
        auth.dispose();
        await client.dispose();
      }
    },
  );
  testWidgets('login validates and displays errors without signing in', (
    tester,
  ) async {
    final auth = FakeAccountAuth()..failure = '認証情報が違います';
    final repo = MemoryRestoreRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: AccountScreen(auth: auth, guest: repo, repository: repo),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'ログイン'));
    await tester.pumpAndSettle();
    expect(auth.logins, 0);
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'user@example.com',
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'password-test');
    await tester.tap(find.widgetWithText(FilledButton, 'ログイン'));
    await tester.pumpAndSettle();
    expect(auth.logins, 1);
    expect(find.text('認証情報が違います'), findsOneWidget);
    expect(auth.identity, isNull);
  });
  testWidgets('signup requires password confirmation; reset sends only email', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final auth = FakeAccountAuth();
    final repo = MemoryRestoreRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: AccountScreen(auth: auth, guest: repo, repository: repo),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('新規登録'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'new@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'password-test');
    await tester.enterText(find.byType(TextFormField).at(2), 'mismatch');
    await tester.tap(find.widgetWithText(FilledButton, '新規登録'));
    await tester.pumpAndSettle();
    expect(auth.signups, 0);
    await tester.enterText(find.byType(TextFormField).at(2), 'password-test');
    await tester.tap(find.widgetWithText(FilledButton, '新規登録'));
    await tester.pumpAndSettle();
    expect(auth.signups, 1);
    expect(find.textContaining('確認メールを送信しました'), findsOneWidget);
    await tester.tap(find.text('パスワード再設定'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'new@example.com');
    await tester.tap(find.text('再設定メールを送信'));
    await tester.pumpAndSettle();
    expect(auth.resets, 1);
  });
  testWidgets(
    'accounts isolate data, guest import is explicit and logout closes private routes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = FakeAccountAuth();
      final guest = MemoryRestoreRepository();
      final a = MemoryRestoreRepository();
      final b = MemoryRestoreRepository();
      await guest.save(
        Item(
          id: 'guest',
          title: 'ゲストのカフェ',
          url: 'https://example.com',
          category: '行きたい店',
          created: DateTime(2026),
        ),
      );
      await tester.pumpWidget(
        AtodeApp(
          auth: auth,
          repository: guest,
          repositoryFor: (id) => id == 'a' ? a : b,
        ),
      );
      await tester.pumpAndSettle();
      auth.enter('a');
      await tester.pumpAndSettle();
      expect(a.records, isEmpty);
      expect(find.text('ゲストのカフェ'), findsNothing);
      await tester.tap(find.byIcon(Icons.account_circle));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ゲストの保存を引き継ぐ'));
      await tester.pumpAndSettle();
      expect(a.records, isEmpty);
      await tester.tap(find.text('追加する'));
      await tester.pumpAndSettle();
      expect(a.records.length, 1);
      expect(guest.records.length, 1);
      await tester.tap(find.text('ログアウト'));
      await tester.pumpAndSettle();
      expect(find.text('ログイン中'), findsNothing);
      expect(find.text('ゲストのカフェ'), findsWidgets);
      auth.enter('b');
      await tester.pumpAndSettle();
      expect(find.text('ゲストのカフェ'), findsNothing);
      expect(b.records, isEmpty);
      auth.enter('a');
      await tester.pumpAndSettle();
      expect(find.text('ゲストのカフェ'), findsWidgets);
    },
  );
  testWidgets('password recovery displays update screen and returns to app', (
    tester,
  ) async {
    final auth = FakeAccountAuth()
      ..current = const AuthIdentity('a', 'a@example.com')
      ..recovery = true;
    final repo = MemoryRestoreRepository();
    await tester.pumpWidget(
      AtodeApp(auth: auth, repository: repo, repositoryFor: (_) => repo),
    );
    await tester.pumpAndSettle();
    expect(find.text('新しいパスワード'), findsWidgets);
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'updated-password',
    );
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'updated-password',
    );
    await tester.tap(find.text('パスワードを更新'));
    await tester.pumpAndSettle();
    expect(auth.updates, 1);
    expect(find.text('あとで。'), findsOneWidget);
  });
  testWidgets('unconfigured auth explains setup without pretending to log in', (
    tester,
  ) async {
    final repo = MemoryRestoreRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: AccountScreen(
          auth: UnavailableAuth(),
          guest: repo,
          repository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('接続設定が必要'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'ログイン'))
          .onPressed,
      isNull,
    );
  });
}
