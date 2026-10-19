import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const authRedirect = 'jp.atode.atode://auth-callback/';
String accountDatabaseName(String project, String userId) =>
    'atode-user-${sha256.convert(utf8.encode('$project::$userId'))}.db';
String? validateEmail(String? value) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value?.trim() ?? '')
    ? null
    : 'メールアドレスを入力してください';
String? validateNewPassword(String? value) =>
    (value ?? '').length >= 8 ? null : 'パスワードは8文字以上で入力してください';

class AuthIdentity {
  const AuthIdentity(this.id, this.email);
  final String id, email;
}

class LoginFailure implements Exception {
  const LoginFailure(this.message);
  final String message;
}

abstract class AccountAuth extends ChangeNotifier {
  bool get configured;
  String get project;
  String? get unavailableMessage;
  AuthIdentity? get identity;
  bool get recovering;
  String? get eventError;
  Future<void> signIn(String email, String password);
  Future<bool> signUp(String email, String password);
  Future<void> sendReset(String email);
  Future<void> changePassword(String password);
  Future<void> signOut();
}

class UnavailableAuth extends AccountAuth {
  UnavailableAuth([
    this.unavailableMessage =
        'ログインを有効にするには、認証サービスの接続設定が必要です。ゲストとしては引き続き利用できます。',
  ]);
  @override
  final String unavailableMessage;
  @override
  bool get configured => false;
  @override
  String get project => '';
  @override
  AuthIdentity? get identity => null;
  @override
  bool get recovering => false;
  @override
  String? get eventError => null;
  Never fail() => throw LoginFailure(unavailableMessage);
  @override
  Future<void> signIn(String email, String password) async => fail();
  @override
  Future<bool> signUp(String email, String password) async => fail();
  @override
  Future<void> sendReset(String email) async => fail();
  @override
  Future<void> changePassword(String password) async => fail();
  @override
  Future<void> signOut() async => fail();
}

class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage(this.key);
  final String key;
  static const storage = FlutterSecureStorage();
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() => storage.containsKey(key: key);
  @override
  Future<String?> accessToken() => storage.read(key: key);
  @override
  Future<void> persistSession(String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> removePersistedSession() => storage.delete(key: key);
}

class SecurePkceStorage extends GotrueAsyncStorage {
  SecurePkceStorage(this.prefix);
  final String prefix;
  static const storage = FlutterSecureStorage();
  @override
  Future<String?> getItem({required String key}) =>
      storage.read(key: '$prefix:$key');
  @override
  Future<void> setItem({required String key, required String value}) =>
      storage.write(key: '$prefix:$key', value: value);
  @override
  Future<void> removeItem({required String key}) =>
      storage.delete(key: '$prefix:$key');
}

bool validAuthConfiguration(String url, String key) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !['', '/'].contains(uri.path)) {
    return false;
  }
  if (key.startsWith('sb_publishable_')) return key.length > 20;
  try {
    final parts = key.split('.');
    if (parts.length != 3) return false;
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    return payload is Map && payload['role'] == 'anon';
  } catch (_) {
    return false;
  }
}

Future<AccountAuth> initializeAccountAuth() async {
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: String.fromEnvironment('SUPABASE_ANON_KEY'),
  );
  if (url.isEmpty || key.isEmpty) return UnavailableAuth();
  if (!validAuthConfiguration(url, key)) {
    return UnavailableAuth('認証サービスのURLまたは公開キーの設定が正しくありません。管理者に確認してください。');
  }
  final project = Uri.parse(url).replace(path: '').toString();
  final projectKey = sha256.convert(utf8.encode(project)).toString();
  try {
    await Supabase.initialize(
      url: project,
      publishableKey: key,
      debug: false,
      authOptions: FlutterAuthClientOptions(
        localStorage: SecureSessionStorage('atode-session-$projectKey'),
        pkceAsyncStorage: SecurePkceStorage('atode-pkce-$projectKey'),
        detectSessionInUriPredicate: (uri) =>
            uri.scheme == 'jp.atode.atode' && uri.host == 'auth-callback',
      ),
    );
    return SupabaseAccountAuth(Supabase.instance.client, project);
  } catch (_) {
    return UnavailableAuth('ログインの初期化に失敗しました。アプリを再起動してください。ゲストとしては利用できます。');
  }
}

String authErrorMessage(Object error) {
  if (error is LoginFailure) return error.message;
  if (error is AuthException) {
    return switch (error.code) {
      'invalid_credentials' => 'メールアドレスまたはパスワードが違います。',
      'email_not_confirmed' => '確認メールのリンクを開いてからログインしてください。',
      'weak_password' => 'より強いパスワードを設定してください。',
      'user_already_exists' ||
      'email_exists' => '登録済みのメールアドレスです。ログインまたはパスワード再設定をお試しください。',
      'over_email_send_rate_limit' ||
      'over_request_rate_limit' => '操作が続いています。時間をおいて再度お試しください。',
      'otp_expired' ||
      'flow_state_expired' ||
      'flow_state_not_found' => 'リンクが無効か期限切れです。メールを再送してお試しください。',
      'same_password' => '現在と異なるパスワードを入力してください。',
      _ => '認証できませんでした。入力内容と通信状態を確認してください。',
    };
  }
  return '通信に失敗しました。接続を確認して再度お試しください。';
}

class SupabaseAccountAuth extends AccountAuth {
  SupabaseAccountAuth(this.client, this.project) {
    subscription = client.auth.onAuthStateChange.listen(
      (event) {
        _eventError = null;
        if (event.event == AuthChangeEvent.passwordRecovery) _recovering = true;
        if (event.event == AuthChangeEvent.signedOut) _recovering = false;
        notifyListeners();
      },
      onError: (Object error) {
        _eventError = authErrorMessage(error);
        notifyListeners();
      },
    );
  }
  final SupabaseClient client;
  late final StreamSubscription<AuthState> subscription;
  bool _recovering = false;
  String? _eventError;
  @override
  bool get configured => true;
  @override
  final String project;
  @override
  String? get unavailableMessage => null;
  @override
  AuthIdentity? get identity {
    final user = client.auth.currentUser;
    return user == null ? null : AuthIdentity(user.id, user.email ?? '');
  }

  @override
  bool get recovering => _recovering;
  @override
  String? get eventError => _eventError;
  @override
  Future<void> signIn(String email, String password) async {
    await client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  }

  @override
  Future<bool> signUp(String email, String password) async {
    final response = await client.auth.signUp(
      email: email.trim(),
      password: password,
      emailRedirectTo: authRedirect,
    );
    return response.session == null;
  }

  @override
  Future<void> sendReset(String email) =>
      client.auth.resetPasswordForEmail(email.trim(), redirectTo: authRedirect);
  @override
  Future<void> changePassword(String password) async {
    if (!_recovering || identity == null) {
      throw const LoginFailure('再設定メールのリンクを開き直してください。');
    }
    await client.auth.updateUser(UserAttributes(password: password));
    _recovering = false;
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    await client.auth.signOut(scope: SignOutScope.local);
  }

  @override
  void dispose() {
    subscription.cancel();
    super.dispose();
  }
}
