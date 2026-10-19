import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'data.dart';

const maxBackupBytes = 10 * 1024 * 1024;
const maxBackupItems = 10000;

class BackupDocument {
  const BackupDocument(this.items, this.exportedAt);
  final List<Item> items;
  final DateTime exportedAt;
}

Uint8List encodeBackup(List<Item> items, {DateTime? now}) {
  if (items.length > maxBackupItems) {
    throw const FormatException('バックアップは10,000件までです');
  }
  final bytes = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'app': 'atode',
        'version': 1,
        'exportedAt': (now ?? DateTime.now()).toIso8601String(),
        'items': items.map((i) => i.toMap()).toList(),
      }),
    ),
  );
  if (bytes.length > maxBackupBytes) {
    throw const FormatException('バックアップは10MBまでです');
  }
  return bytes;
}

BackupDocument decodeBackup(List<int> bytes) {
  if (bytes.length > maxBackupBytes) {
    throw const FormatException('ファイルは10MBまでです');
  }
  try {
    final source = utf8.decode(bytes);
    final root = jsonDecode(
      source.startsWith('\uFEFF') ? source.substring(1) : source,
    );
    if (root is! Map ||
        root['app'] != 'atode' ||
        root['version'] is! int ||
        root['version'] != 1 ||
        root['items'] is! List) {
      throw const FormatException('対応する「あとで。」のバックアップではありません');
    }
    final exported = _date(root['exportedAt']);
    final raw = root['items'] as List;
    if (raw.length > maxBackupItems) {
      throw const FormatException('復元は10,000件までです');
    }
    final ids = <String>{};
    final items = <Item>[];
    for (final record in raw) {
      if (record is! Map) throw const FormatException('保存データの形式が不正です');
      final m = Map<String, Object?>.from(record);
      for (final key in [
        'id',
        'title',
        'url',
        'category',
        'note',
        'image',
        'status',
        'mood',
        'companion',
      ]) {
        if (m[key] is! String) {
          throw const FormatException('保存データの文字列が不正です');
        }
      }
      if ((m['id'] as String).trim().isEmpty ||
          (m['title'] as String).trim().isEmpty ||
          !ids.add(m['id'] as String)) {
        throw const FormatException('ID・タイトルが空か、IDが重複しています');
      }
      if (!validUrl(m['url'] as String) ||
          ((m['image'] as String).isNotEmpty &&
              !validUrl(m['image'] as String))) {
        throw const FormatException('URLの形式が不正です');
      }
      if (!categories.contains(m['category']) ||
          !statuses.contains(m['status']) ||
          !['指定なし', 'のんびり', 'わくわく', '学びたい'].contains(m['mood']) ||
          !['指定なし', 'ひとり', '友人', '恋人', '家族'].contains(m['companion'])) {
        throw const FormatException('カテゴリー・状態・提案条件が不正です');
      }
      for (final key in ['budget', 'minutes']) {
        if (m[key] != null &&
            (m[key] is! int ||
                (m[key] as int) < 0 ||
                (m[key] as int) > 9223372036854775807)) {
          throw const FormatException('予算・時間が不正です');
        }
      }
      if (m['favorite'] is! int || ![0, 1].contains(m['favorite'])) {
        throw const FormatException('お気に入りの形式が不正です');
      }
      _date(m['created']);
      for (final key in ['viewed', 'completedAt']) {
        if (m[key] != null) _date(m[key]);
      }
      if (!isCompletedStatus(m['status'] as String) &&
          m['completedAt'] != null) {
        throw const FormatException('完了日と状態が一致していません');
      }
      // Ignore unknown keys rather than passing them into SQLite later.
      items.add(Item.fromMap(m));
    }
    return BackupDocument(List.unmodifiable(items), exported);
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('バックアップの形式が不正です');
  }
}

DateTime _date(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})?$',
      ).hasMatch(value)) {
    throw const FormatException('日付の形式が不正です');
  }
  final date = DateTime.tryParse(value);
  final day = DateTime.tryParse(value.substring(0, 10));
  if (date == null ||
      day == null ||
      int.parse(value.substring(11, 13)) > 23 ||
      int.parse(value.substring(14, 16)) > 59 ||
      int.parse(value.substring(17, 19)) > 59 ||
      day.toIso8601String().substring(0, 10) != value.substring(0, 10)) {
    throw const FormatException('日付が不正です');
  }
  return date;
}

abstract class BackupFiles {
  Future<bool> write(Uint8List bytes, String name);
  Future<Uint8List?> read();
}

class DeviceBackupFiles implements BackupFiles {
  @override
  Future<bool> write(Uint8List bytes, String name) async =>
      await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        mimeType: 'application/json',
        dialogTitle: 'バックアップを保存',
      ) !=
      null;
  @override
  Future<Uint8List?> read() async {
    final file = await FilePicker.pickFile(
      type: FileType.any,
      dialogTitle: '「あとで。」のバックアップを選択',
    );
    if (file == null) return null;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > maxBackupBytes) {
        throw const FormatException('ファイルは10MBまでです');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}
