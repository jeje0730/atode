import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:atode/data.dart';
import 'package:atode/backup.dart';
import 'package:atode/backup_screen.dart';

class MemoryRestoreRepository implements RestorableRepository {
  final records = <String, Item>{};
  int restores = 0;
  @override
  Future<List<Item>> load() async => records.values.toList();
  @override
  Future<void> save(Item i) async {
    records[i.id] = i;
  }

  @override
  Future<void> delete(String id) async {
    records.remove(id);
  }

  @override
  Future<RestorePlan> restoreMissing(List<Item> incoming) async {
    restores++;
    final plan = planRestore(await load(), incoming);
    for (final i in plan.additions) {
      records[i.id] = i;
    }
    return plan;
  }
}

class MemoryBackupFiles implements BackupFiles {
  Uint8List? selected, written;
  bool cancelled = false;
  @override
  Future<bool> write(Uint8List bytes, String name) async {
    if (cancelled) return false;
    written = bytes;
    return true;
  }

  @override
  Future<Uint8List?> read() async => selected;
}

void main() {
  final item = Item(
    id: '1',
    title: 'カフェ',
    url: 'https://example.com/cafe',
    category: '行きたい店',
    created: DateTime(2026, 10, 1),
    note: '窓際',
    image: 'https://example.com/photo.jpg',
    budget: 1000,
    minutes: 60,
    mood: 'のんびり',
    companion: '友人',
    favorite: true,
    viewed: DateTime(2026, 10, 18),
  ).changeStatus('行った', now: DateTime(2026, 10, 19));
  test('backup roundtrip preserves all fields and Japanese text', () {
    final now = DateTime(2026, 10, 19);
    final document = decodeBackup(encodeBackup([item], now: now));
    expect(document.items.single.toMap(), item.toMap());
    expect(document.exportedAt, now);
    expect(decodeBackup(encodeBackup([])).items, isEmpty);
  });
  test(
    'invalid schemas, fields, dates, duplicate IDs and oversized input are rejected',
    () {
      final base =
          jsonDecode(utf8.decode(encodeBackup([item]))) as Map<String, dynamic>;
      for (final entry in <String, Object?>{
        'title': '',
        'url': 'javascript:bad',
        'category': 'unknown',
        'favorite': true,
        'budget': -1,
        'minutes': 1.5,
        'created': '2026-02-30T10:00:00.000',
        'viewed': '2026-10-19T25:00:00',
        'status': '未完了',
      }.entries) {
        final bad = {
          ...base,
          'items': [
            {...item.toMap(), entry.key: entry.value},
          ],
        };
        expect(
          () => decodeBackup(utf8.encode(jsonEncode(bad))),
          throwsFormatException,
          reason: entry.key,
        );
      }
      expect(
        () => decodeBackup(utf8.encode(jsonEncode({...base, 'version': 999}))),
        throwsFormatException,
      );
      expect(
        () => decodeBackup(
          utf8.encode(
            jsonEncode({
              ...base,
              'items': [item.toMap(), item.toMap()],
            }),
          ),
        ),
        throwsFormatException,
      );
      expect(() => decodeBackup([0xff, 0xff]), throwsFormatException);
      expect(
        () => decodeBackup(Uint8List(maxBackupBytes + 1)),
        throwsFormatException,
      );
    },
  );
  test(
    'merge preserves local records and skips duplicate URLs and ID collisions',
    () {
      final duplicate = Item.fromMap({
        ...item.toMap(),
        'id': 'duplicate',
        'url': 'https://example.com/cafe?utm_source=share',
      });
      final collision = Item.fromMap({
        ...item.toMap(),
        'url': 'https://example.com/different',
      });
      final unique = Item.fromMap({
        ...item.toMap(),
        'id': 'new',
        'url': 'https://example.com/new',
      });
      final plan = planRestore([item], [duplicate, collision, unique, unique]);
      expect(plan.additions, [unique]);
      expect(plan.skipped, 3);
    },
  );
  test(
    'SQLite restores atomically, retains original data, and is repeatable',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = await Directory.systemTemp.createTemp('atode_restore_');
      final repo = SqliteRepository(databasePath: '${dir.path}/test.db');
      try {
        await repo.save(item);
        final good = Item.fromMap({
          ...item.toMap(),
          'id': 'new',
          'url': 'https://example.com/new',
        });
        final fail = Item.fromMap({
          ...item.toMap(),
          'id': 'fail',
          'url': 'https://example.com/fail',
        });
        await (await repo.db).execute(
          "CREATE TRIGGER fail_restore BEFORE INSERT ON items WHEN NEW.id = 'fail' BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END",
        );
        await expectLater(
          repo.restoreMissing([good, fail]),
          throwsA(isA<DatabaseException>()),
        );
        expect((await repo.load()).map((i) => i.id), ['1']);
        final plan = await repo.restoreMissing(
          decodeBackup(encodeBackup([item, good])).items,
        );
        expect(plan.additions.length, 1);
        expect(plan.skipped, 1);
        await repo.close();
        expect((await repo.load()).length, 2);
        expect(
          (await repo.load()).firstWhere((i) => i.id == 'new').toMap(),
          good.toMap(),
        );
        expect((await repo.restoreMissing([item, good])).additions, isEmpty);
      } finally {
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );
  testWidgets('export, restore preview, cancel and confirm through UI', (
    tester,
  ) async {
    final repo = MemoryRestoreRepository();
    final files = MemoryBackupFiles();
    await repo.save(item);
    await tester.pumpWidget(
      MaterialApp(
        home: BackupScreen(repository: repo, files: files),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('バックアップを保存'));
    await tester.pumpAndSettle();
    expect(decodeBackup(files.written!).items.single.toMap(), item.toMap());
    final unique = Item.fromMap({
      ...item.toMap(),
      'id': 'new',
      'url': 'https://example.com/new',
      'title': '追加する店',
    });
    files.selected = encodeBackup([item, unique]);
    await tester.tap(find.text('ファイルから復元'));
    await tester.pumpAndSettle();
    expect(find.text('復元内容の確認'), findsOneWidget);
    expect(repo.restores, 0);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(repo.records.length, 1);
    await tester.tap(find.text('ファイルから復元'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('追加して復元'));
    await tester.pumpAndSettle();
    expect(repo.records.length, 2);
    expect(repo.records['1']!.toMap(), item.toMap());
  });
  testWidgets('cancelled file selection and corrupt input do not modify data', (
    tester,
  ) async {
    final repo = MemoryRestoreRepository();
    final files = MemoryBackupFiles();
    await repo.save(item);
    await tester.pumpWidget(
      MaterialApp(
        home: BackupScreen(repository: repo, files: files),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ファイルから復元'));
    await tester.pumpAndSettle();
    expect(find.text('ファイル選択をキャンセルしました'), findsOneWidget);
    files.selected = Uint8List.fromList(utf8.encode('{}'));
    await tester.tap(find.text('ファイルから復元'));
    await tester.pumpAndSettle();
    expect(repo.restores, 0);
    expect(repo.records.length, 1);
    expect(find.text('復元内容の確認'), findsNothing);
  });
}
