import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

const categories = ['行きたい店', '行きたい場所', '欲しいもの', '観たいもの', '読みたいもの', 'その他'];
const statuses = ['未完了', '行った', '観た', '買った', '読んだ', '完了', '興味なし'];
bool isCompletedStatus(String status) =>
    !['未完了', '興味なし'].contains(status) && statuses.contains(status);
String completionStatus(String category) => switch (category) {
  '行きたい店' || '行きたい場所' => '行った',
  '欲しいもの' => '買った',
  '観たいもの' => '観た',
  '読みたいもの' => '読んだ',
  _ => '完了',
};
bool validUrl(String s) {
  final u = Uri.tryParse(s);
  return u != null &&
      ['http', 'https'].contains(u.scheme) &&
      u.host.isNotEmpty &&
      !s.contains(RegExp(r'\s'));
}

class Item {
  Item({
    required this.id,
    required this.title,
    required this.url,
    required this.category,
    required this.created,
    this.note = '',
    this.image = '',
    this.status = '未完了',
    this.budget,
    this.minutes,
    this.mood = '指定なし',
    this.companion = '指定なし',
    this.viewed,
    this.favorite = false,
    this.completedAt,
  });
  final String id, title, url, category, note, image, status, mood, companion;
  final int? budget, minutes;
  final DateTime created;
  final DateTime? viewed;
  final bool favorite;
  final DateTime? completedAt;
  bool get isCompleted => isCompletedStatus(status);
  Item changeStatus(String value, {DateTime? now}) {
    if (!statuses.contains(value)) throw ArgumentError.value(value, 'status');
    return Item.fromMap({
      ...toMap(),
      'status': value,
      'completedAt': isCompletedStatus(value)
          ? (isCompleted
                ? completedAt?.toIso8601String()
                : (now ?? DateTime.now()).toIso8601String())
          : null,
    });
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'url': url,
    'category': category,
    'created': created.toIso8601String(),
    'note': note,
    'image': image,
    'status': status,
    'budget': budget,
    'minutes': minutes,
    'mood': mood,
    'companion': companion,
    'viewed': viewed?.toIso8601String(),
    'favorite': favorite ? 1 : 0,
    'completedAt': completedAt?.toIso8601String(),
  };
  factory Item.fromMap(Map<String, Object?> m) => Item(
    id: m['id'] as String,
    title: m['title'] as String,
    url: m['url'] as String,
    category: m['category'] as String,
    created: DateTime.parse(m['created'] as String),
    note: m['note'] as String,
    image: m['image'] as String,
    status: m['status'] as String,
    budget: m['budget'] as int?,
    minutes: m['minutes'] as int?,
    mood: m['mood'] as String,
    companion: m['companion'] as String,
    viewed: m['viewed'] == null ? null : DateTime.parse(m['viewed'] as String),
    favorite: m['favorite'] == 1,
    completedAt: m['completedAt'] == null
        ? null
        : DateTime.parse(m['completedAt'] as String),
  );
  Item update({String? status, DateTime? viewed, bool? favorite}) {
    final item = Item.fromMap({
      ...toMap(),
      if (viewed != null) 'viewed': viewed.toIso8601String(),
      if (favorite != null) 'favorite': favorite ? 1 : 0,
    });
    return status == null ? item : item.changeStatus(status);
  }
}

abstract class Repository {
  Future<List<Item>> load();
  Future<void> save(Item item);
  Future<void> delete(String id);
}

abstract class RestorableRepository implements Repository {
  Future<RestorePlan> restoreMissing(List<Item> incoming);
}

String itemUrlKey(String value) {
  final uri = Uri.parse(value.trim());
  final params = Map<String, List<String>>.from(uri.queryParametersAll)
    ..removeWhere(
      (key, _) =>
          key.startsWith('utm_') ||
          ['igsh', 'igshid', 'fbclid', 'gclid'].contains(key),
    );
  final keys = params.keys.toList()..sort();
  return uri
      .replace(
        host: uri.host.toLowerCase(),
        fragment: '',
        queryParameters: {for (final key in keys) key: params[key]!},
      )
      .toString()
      .replaceFirst(RegExp(r'\?$'), '');
}

class RestorePlan {
  const RestorePlan(this.additions, this.skipped);
  final List<Item> additions;
  final int skipped;
}

RestorePlan planRestore(List<Item> existing, List<Item> incoming) {
  final ids = existing.map((i) => i.id).toSet();
  final urls = existing.map((i) => itemUrlKey(i.url)).toSet();
  final additions = <Item>[];
  for (final item in incoming) {
    final key = itemUrlKey(item.url);
    if (ids.contains(item.id) || urls.contains(key)) continue;
    ids.add(item.id);
    urls.add(key);
    additions.add(item);
  }
  return RestorePlan(
    List.unmodifiable(additions),
    incoming.length - additions.length,
  );
}

class SqliteRepository implements RestorableRepository {
  SqliteRepository({this.databasePath, this.databaseName = 'atode.db'});
  final String? databasePath;
  final String databaseName;
  Database? _db;
  Future<Database> get db async => _db ??= await openDatabase(
    databasePath ?? p.join(await getDatabasesPath(), databaseName),
    version: 3,
    onCreate: (db, _) async {
      await db.execute(
        'CREATE TABLE items(id TEXT PRIMARY KEY,title TEXT NOT NULL,url TEXT NOT NULL,category TEXT NOT NULL,created TEXT NOT NULL,note TEXT NOT NULL,image TEXT NOT NULL,status TEXT NOT NULL,budget INTEGER,minutes INTEGER,mood TEXT NOT NULL,companion TEXT NOT NULL,viewed TEXT,favorite INTEGER NOT NULL DEFAULT 0,completedAt TEXT)',
      );
    },
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) {
        await db.execute(
          'ALTER TABLE items ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (oldVersion < 3) {
        await db.execute('ALTER TABLE items ADD COLUMN completedAt TEXT');
      }
    },
  );
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  @override
  Future<List<Item>> load() async => (await (await db).query(
    'items',
    orderBy: 'created DESC',
  )).map(Item.fromMap).toList();
  @override
  Future<void> save(Item item) async {
    await (await db).insert(
      'items',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(String id) async {
    await (await db).delete('items', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<RestorePlan> restoreMissing(List<Item> incoming) async =>
      (await db).transaction((txn) async {
        final existing = (await txn.query('items')).map(Item.fromMap).toList();
        final plan = planRestore(existing, incoming);
        final batch = txn.batch();
        for (final item in plan.additions) {
          batch.insert('items', item.toMap());
        }
        await batch.commit(noResult: true);
        return plan;
      });
}

List<Item> completionHistory(Iterable<Item> items) =>
    items.where((i) => i.isCompleted).toList()..sort((a, b) {
      if (a.completedAt == null && b.completedAt == null) {
        return b.created.compareTo(a.created);
      }
      if (a.completedAt == null) return 1;
      if (b.completedAt == null) return -1;
      return b.completedAt!.compareTo(a.completedAt!);
    });

List<Item> sortItems(Iterable<Item> items, {bool oldestFirst = false}) {
  final result = items.toList()
    ..sort((a, b) {
      final order = a.created.compareTo(b.created);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
  return oldestFirst ? result : result.reversed.toList();
}

String recommendationReason(
  Item i, {
  int? budget,
  int? minutes,
  String mood = '指定なし',
  String companion = '指定なし',
}) {
  final reasons = <String>[
    if (budget != null && i.budget != null && i.budget! <= budget)
      '予算${i.budget}円（$budget円以内）',
    if (minutes != null && i.minutes != null && i.minutes! <= minutes)
      '所要${i.minutes}分（$minutes分以内）',
    if (mood != '指定なし' && i.mood == mood) '気分「$mood」に一致',
    if (companion != '指定なし' && i.companion == companion) '同行者「$companion」に一致',
  ];
  final unknown = missing(
    i,
    budget: budget,
    minutes: minutes,
    mood: mood,
    companion: companion,
  );
  if (reasons.isEmpty) {
    reasons.add(unknown.isEmpty ? '未完了の保存から提案' : '条件が未登録の候補');
  }
  if (unknown.isNotEmpty) reasons.add('${unknown.join('・')}は確認が必要');
  return reasons.join('\n');
}

List<String> missing(
  Item i, {
  int? budget,
  int? minutes,
  String mood = '指定なし',
  String companion = '指定なし',
}) => [
  if (budget != null && i.budget == null) '予算',
  if (minutes != null && i.minutes == null) '時間',
  if (mood != '指定なし' && i.mood == '指定なし') '気分',
  if (companion != '指定なし' && i.companion == '指定なし') '同行者',
];
List<Item> recommend(
  List<Item> items, {
  int? budget,
  int? minutes,
  String mood = '指定なし',
  String companion = '指定なし',
}) => items
    .where(
      (i) =>
          i.status == '未完了' &&
          (budget == null || i.budget == null || i.budget! <= budget) &&
          (minutes == null || i.minutes == null || i.minutes! <= minutes) &&
          (mood == '指定なし' || i.mood == '指定なし' || i.mood == mood) &&
          (companion == '指定なし' ||
              i.companion == '指定なし' ||
              i.companion == companion),
    )
    .toList();
