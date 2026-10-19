import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:atode/data.dart';

void main() {
  test('v2 upgrade keeps old completion without inventing a date', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('atode_v2_');
    final path = '${dir.path}/items.db';
    final oldItem = Item(
      id: 'done',
      title: '以前に行った店',
      url: 'https://example.com',
      category: '行きたい店',
      created: DateTime(2026),
      status: '行った',
      favorite: true,
    );
    final values = oldItem.toMap()..remove('completedAt');
    final legacy = await openDatabase(
      path,
      version: 2,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE items (${values.entries.map((e) => '${e.key} ${e.key == 'id'
              ? 'TEXT PRIMARY KEY'
              : ['budget', 'minutes', 'favorite'].contains(e.key)
              ? 'INTEGER'
              : 'TEXT'}').join(',')})',
        );
      },
    );
    await legacy.insert('items', values);
    await legacy.close();
    final repo = SqliteRepository(databasePath: path);
    try {
      final result = (await repo.load()).single;
      expect(result.toMap(), oldItem.toMap());
      expect(completionHistory([result]), [result]);
      expect(result.completedAt, isNull);
      final time = DateTime(2026, 10, 19, 12);
      await repo.save(
        result.changeStatus('未完了').changeStatus('行った', now: time),
      );
      await repo.close();
      expect((await repo.load()).single.completedAt, time);
      expect((await repo.load()).single.favorite, isTrue);
    } finally {
      await repo.close();
      await dir.delete(recursive: true);
    }
  });
  test(
    'v1 upgrade preserves saved items and favorite persists after reopen',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = await Directory.systemTemp.createTemp('atode_migration_');
      final path = '${dir.path}/items.db';
      final item = Item(
        id: 'legacy',
        title: '以前の保存',
        url: 'https://example.com',
        category: categories.first,
        created: DateTime(2026),
        image: 'https://example.com/image.jpg',
      );
      final legacy = await openDatabase(
        path,
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE items(id TEXT PRIMARY KEY,title TEXT NOT NULL,url TEXT NOT NULL,category TEXT NOT NULL,created TEXT NOT NULL,note TEXT NOT NULL,image TEXT NOT NULL,status TEXT NOT NULL,budget INTEGER,minutes INTEGER,mood TEXT NOT NULL,companion TEXT NOT NULL,viewed TEXT)',
          );
        },
      );
      await legacy.insert(
        'items',
        item.toMap()
          ..remove('favorite')
          ..remove('completedAt'),
      );
      await legacy.close();
      final repo = SqliteRepository(databasePath: path);
      try {
        final migrated = (await repo.load()).single;
        expect(migrated.toMap(), item.toMap());
        await repo.save(migrated.update(favorite: true));
        await repo.close();
        expect((await repo.load()).single.favorite, isTrue);
        expect((await repo.load()).single.image, item.image);
      } finally {
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test('SQLite retains records across reopen, updates and deletes', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('atode_test_');
    final repo = SqliteRepository(databasePath: '${dir.path}/items.db');
    try {
      final item = Item(
        id: '1',
        title: '週末のカフェ',
        url: 'https://example.com',
        category: categories.first,
        created: DateTime(2026),
        budget: 1000,
        minutes: 30,
        note: '窓際の席',
      );
      await repo.save(item);
      await repo.close();
      expect((await repo.load()).single.toMap(), item.toMap());
      await repo.save(item.update(status: '行った'));
      expect((await repo.load()).single.status, '行った');
      await repo.delete(item.id);
      expect(await repo.load(), isEmpty);
    } finally {
      await repo.close();
      await dir.delete(recursive: true);
    }
  });
}
