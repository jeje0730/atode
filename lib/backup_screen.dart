import 'package:flutter/material.dart';
import 'backup.dart';
import 'data.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.repository, this.files});
  final RestorableRepository repository;
  final BackupFiles? files;
  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool busy = false;
  bool confirming = false;
  String? result;
  late final files = widget.files ?? DeviceBackupFiles();
  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      result = null;
    });
    try {
      await action();
    } on FormatException catch (e) {
      if (mounted) setState(() => result = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => result = '処理できませんでした。ファイルの保存先や空き容量を確認し、再度お試しください。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> export() => run(() async {
    final items = await widget.repository.load();
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final saved = await files.write(
      encodeBackup(items, now: now),
      'atode-backup-$stamp.json',
    );
    if (mounted) {
      setState(
        () =>
            result = saved ? '${items.length}件のバックアップを保存しました' : '保存をキャンセルしました',
      );
    }
  });
  Future<void> restore() => run(() async {
    final bytes = await files.read();
    if (bytes == null) {
      if (mounted) setState(() => result = 'ファイル選択をキャンセルしました');
      return;
    }
    final document = decodeBackup(bytes);
    final existing = await widget.repository.load();
    final plan = planRestore(existing, document.items);
    if (!mounted) return;
    setState(() => confirming = true);
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('復元内容の確認'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '作成日：${document.exportedAt.toLocal().toString().split('.').first}\nファイル内：${document.items.length}件\n追加予定：${plan.additions.length}件\n重複・IDの一致：${plan.skipped}件（スキップ）',
              ),
              const SizedBox(height: 12),
              const Text('現在のデータは削除・上書きしません。同じURLやIDのアイテムは現在の内容を優先します。'),
              if (plan.additions.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('追加する保存（先頭5件）'),
                ...plan.additions
                    .take(5)
                    .map((i) => Text('・${i.title}（${i.category}／${i.status}）')),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: plan.additions.isEmpty
                ? null
                : () => Navigator.pop(c, true),
            child: const Text('追加して復元'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => confirming = false);
    if (yes != true) {
      setState(() => result = '復元をキャンセルしました');
      return;
    }
    final restored = await widget.repository.restoreMissing(document.items);
    if (mounted) {
      setState(
        () => result =
            '${restored.additions.length}件を復元しました（${restored.skipped}件はスキップ）',
      );
    }
  });
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('バックアップ・復元'),
        automaticallyImplyLeading: !busy,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Icon(Icons.backup_outlined, size: 48),
              const SizedBox(height: 20),
              const Text(
                '大切な「あとで」を持ち運ぶ',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                '保存内容・メモ・お気に入り・完了日を1つのファイルに保存できます。機種変更後は、このファイルを選んで復元してください。',
              ),
              const SizedBox(height: 12),
              const Text(
                '画像はURLを保存します。画像ファイルやログイン情報は含みません。バックアップは暗号化されないため、保存先と共有相手にご注意ください。',
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: busy ? null : export,
                icon: const Icon(Icons.file_upload_outlined),
                label: const Text('バックアップを保存'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: busy ? null : restore,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('ファイルから復元'),
              ),
              const SizedBox(height: 12),
              const Text('復元は10MB・10,000件まで。現在の保存を残し、重複しないアイテムだけ追加します。'),
              if (busy && !confirming)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: LinearProgressIndicator(),
                ),
              if (result != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text(
                    result!,
                    semanticsLabel: result,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
