import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'data.dart';
import 'sharing.dart';
import 'backup_screen.dart';
import 'auth.dart';
import 'account_screen.dart';
import 'dart:async';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final auth = await initializeAccountAuth();
  runApp(AtodeApp(auth: auth));
}

const green = Color(0xFF42664F), ink = Color(0xFF263D35);
const moods = ['指定なし', 'のんびり', 'わくわく', '学びたい'];
const companions = ['指定なし', 'ひとり', '友人', '恋人', '家族'];

class AtodeApp extends StatefulWidget {
  const AtodeApp({super.key, this.repository, this.auth, this.repositoryFor});
  final Repository? repository;
  final AccountAuth? auth;
  final Repository Function(String? userId)? repositoryFor;
  @override
  State<AtodeApp> createState() => _AtodeAppState();
}

class _AtodeAppState extends State<AtodeApp> {
  final navigator = GlobalKey<NavigatorState>();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  late final AccountAuth auth;
  late final Repository guest;
  final accounts = <String, Repository>{};
  late String scope;
  String get currentScope =>
      '${auth.project}:${auth.identity?.id ?? 'guest'}:${auth.recovering}';
  Repository get repository {
    final id = auth.identity?.id;
    if (id == null) return guest;
    return accounts.putIfAbsent(
      '${auth.project}:$id',
      () =>
          widget.repositoryFor?.call(id) ??
          SqliteRepository(databaseName: accountDatabaseName(auth.project, id)),
    );
  }

  @override
  void initState() {
    super.initState();
    auth = widget.auth ?? UnavailableAuth();
    guest =
        widget.repository ??
        widget.repositoryFor?.call(null) ??
        SqliteRepository();
    scope = currentScope;
    auth.addListener(changed);
  }

  void changed() {
    if (!mounted) return;
    if (scope != currentScope) {
      messenger.currentState?.clearSnackBars();
      navigator.currentState?.popUntil((route) => route.isFirst);
      scope = currentScope;
    }
    setState(() {});
  }

  @override
  void dispose() {
    auth.removeListener(changed);
    if (widget.auth == null) auth.dispose();
    super.dispose();
  }

  Future<void> openAccount() async {
    await navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) =>
            AccountScreen(auth: auth, guest: guest, repository: repository),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigator,
    scaffoldMessengerKey: messenger,
    title: 'あとで。',
    debugShowCheckedModeBanner: false,
    scrollBehavior: const MaterialScrollBehavior().copyWith(
      overscroll: false,
      physics: const ClampingScrollPhysics(),
    ),
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: green,
        surface: const Color(0xFFFAF9F5),
      ),
      scaffoldBackgroundColor: const Color(0xFFFAF9F5),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    ),
    home: auth.recovering
        ? PasswordUpdateScreen(auth: auth)
        : Home(
            key: ValueKey(scope),
            repository: repository,
            accountAction: openAccount,
            accountEmail: auth.identity?.email,
          ),
  );
}

class Home extends StatefulWidget {
  const Home({
    super.key,
    required this.repository,
    this.accountAction,
    this.accountEmail,
  });
  final Repository repository;
  final Future<void> Function()? accountAction;
  final String? accountEmail;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final receiver = AndroidShareReceiver();
  final shareQueue = <SharedLink>[];
  bool editorOpen = false;
  bool backupOpen = false;
  bool accountOpen = false;
  List<Item> items = [];
  int tab = 0;
  final pages = PageController();
  final search = TextEditingController();
  int navigationRequest = 0;
  bool navigating = false;

  void switchTab(int index) {
    if (loading || error != null || !pages.hasClients) return;
    FocusScope.of(context).unfocus();
    final request = ++navigationRequest;
    navigating = true;
    setState(() => tab = index);
    if (MediaQuery.disableAnimationsOf(context)) {
      pages.jumpToPage(index);
      navigating = false;
      return;
    }
    unawaited(
      pages
          .animateToPage(
            index,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeInOutCubic,
          )
          .whenComplete(() {
            if (!mounted || request != navigationRequest) return;
            navigating = false;
            if (pages.hasClients) setState(() => tab = pages.page!.round());
          }),
    );
  }

  bool loading = true;
  String? error;
  String query = '',
      category = 'すべて',
      status = '未完了',
      mood = '指定なし',
      companion = '指定なし';
  int? budget, minutes;
  List<Item>? suggestions;
  bool favoritesOnly = false;
  String sortOrder = '新しい順';
  final favoritePending = <String>{};

  Future<void> toggleFavorite(Item item) async {
    if (favoritePending.contains(item.id)) return;
    setState(() => favoritePending.add(item.id));
    try {
      final current = items.firstWhere((i) => i.id == item.id);
      await widget.repository.save(current.update(favorite: !current.favorite));
      final fresh = await widget.repository.load();
      if (mounted) {
        setState(() {
          items = fresh;
          suggestions = suggestions
              ?.map(
                (old) =>
                    fresh.firstWhere((i) => i.id == old.id, orElse: () => old),
              )
              .toList();
        });
      }
    } catch (_) {
      message('お気に入りを保存できませんでした');
    } finally {
      if (mounted) setState(() => favoritePending.remove(item.id));
    }
  }

  @override
  void initState() {
    super.initState();
    reload();
    receiver
        .start((links) {
          if (!mounted) return;
          if (links.isEmpty) {
            message('共有された内容にURLがありません。リンクを共有してください。');
            return;
          }
          shareQueue.addAll(links);
          openNextShare();
        })
        .catchError((Object _) {
          message('共有データを読み込めませんでした');
        });
  }

  @override
  void dispose() {
    receiver.dispose();
    pages.dispose();
    search.dispose();
    super.dispose();
  }

  void openNextShare() {
    if (!mounted ||
        loading ||
        error != null ||
        editorOpen ||
        backupOpen ||
        accountOpen ||
        shareQueue.isEmpty) {
      return;
    }
    final link = shareQueue.removeAt(0);
    unawaited(edit(null, link));
  }

  Future<void> reload() async {
    try {
      final data = await widget.repository.load();
      if (mounted) {
        setState(() {
          items = data;
          loading = false;
          error = null;
          suggestions = null;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => openNextShare());
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = 'データを読み込めませんでした';
        });
      }
    }
  }

  void message(String s) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
    }
  }

  Future<void> save(Item i) async {
    await widget.repository.save(i);
    await reload();
  }

  Future<void> edit([Item? i, SharedLink? shared]) async {
    if (editorOpen) return;
    editorOpen = true;
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => Editor(
          item: i,
          shared: shared,
          defaultCategory: items.isEmpty ? 'その他' : items.first.category,
          onSave: save,
          findDuplicate: (url, id) async {
            final fresh = await widget.repository.load();
            for (final item in fresh) {
              if (item.id != id &&
                  normalizedUrl(item.url) == normalizedUrl(url)) {
                return item;
              }
            }
            return null;
          },
        ),
      ),
    );
    editorOpen = false;
    if (!mounted) return;
    if (result == true) {
      message('保存しました');
    }
    openNextShare();
  }

  Future<void> openBackup() async {
    final repository = widget.repository;
    if (backupOpen || repository is! RestorableRepository) return;
    backupOpen = true;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => BackupScreen(repository: repository)),
    );
    backupOpen = false;
    if (mounted) await reload();
  }

  Future<void> openAccount() async {
    if (accountOpen || widget.accountAction == null) return;
    accountOpen = true;
    await widget.accountAction!();
    accountOpen = false;
    if (mounted) await reload();
  }

  Future<void> detail(Item original) async {
    final i = original.update(viewed: DateTime.now());
    try {
      await save(i);
    } catch (_) {
      message('閲覧日時を保存できませんでした');
    }
    if (!mounted) {
      return;
    }
    bool changing = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheetState) {
          Future<void> change(String value) async {
            if (changing || value == i.status) return;
            setSheetState(() => changing = true);
            final changed = i.changeStatus(value);
            try {
              await save(changed);
              if (sheet.mounted) Navigator.pop(sheet);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    value == '未完了' ? '未完了に戻しました' : '「$value」を記録しました',
                  ),
                  action: SnackBarAction(
                    label: '元に戻す',
                    onPressed: () async {
                      try {
                        final latest = (await widget.repository.load())
                            .firstWhere((item) => item.id == i.id);
                        if (latest.status != changed.status ||
                            latest.completedAt != changed.completedAt) {
                          message('状態が変更されているため取り消せません');
                          return;
                        }
                        await save(
                          Item.fromMap({
                            ...latest.toMap(),
                            'status': i.status,
                            'completedAt': i.completedAt?.toIso8601String(),
                          }),
                        );
                      } catch (_) {
                        message('元に戻せませんでした');
                      }
                    },
                  ),
                ),
              );
            } catch (_) {
              if (sheet.mounted) setSheetState(() => changing = false);
              message('状態を保存できませんでした');
            }
          }

          return PopScope(
            canPop: !changing,
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(i.category, style: const TextStyle(color: green)),
                    const SizedBox(height: 8),
                    Text(
                      i.title,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(i.url),
                    Text('保存日 ${date(i.created)}'),
                    if (i.isCompleted)
                      Text(
                        i.completedAt == null
                            ? '完了日：記録なし'
                            : '完了日 ${date(i.completedAt!.toLocal())}',
                      ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: changing
                          ? null
                          : () => change(
                              i.isCompleted
                                  ? '未完了'
                                  : completionStatus(i.category),
                            ),
                      icon: Icon(
                        i.isCompleted ? Icons.undo : Icons.check_circle_outline,
                      ),
                      label: Text(
                        changing
                            ? '記録中…'
                            : i.isCompleted
                            ? '未完了に戻す'
                            : '「${completionStatus(i.category)}」を記録',
                      ),
                    ),
                    if (i.image.isNotEmpty) picture(i.image, large: true),
                    const SizedBox(height: 16),
                    Text(i.note.isEmpty ? 'メモはまだありません' : i.note),
                    const SizedBox(height: 16),
                    Text(
                      '予算：${i.budget == null ? '未登録' : '${i.budget}円'}　時間：${i.minutes == null ? '未登録' : '${i.minutes}分'}',
                    ),
                    Text('気分：${i.mood}　同行者：${i.companion}'),
                    const SizedBox(height: 20),
                    if (changing)
                      const LinearProgressIndicator()
                    else
                      select('状態', statuses, i.status, change),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () async {
                        try {
                          if (!await launchUrl(
                            Uri.parse(i.url),
                            mode: LaunchMode.externalApplication,
                          )) {
                            message('リンクを開けませんでした');
                          }
                        } catch (_) {
                          message('リンクを開けませんでした');
                        }
                      },
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('保存元を開く'),
                    ),
                    OutlinedButton(
                      onPressed: changing
                          ? null
                          : () {
                              Navigator.pop(sheet);
                              edit(i);
                            },
                      child: const Text('内容を編集'),
                    ),
                    TextButton(
                      onPressed: changing
                          ? null
                          : () async {
                              final yes = await showDialog<bool>(
                                context: sheet,
                                builder: (c) => AlertDialog(
                                  title: const Text('この保存を削除しますか？'),
                                  content: const Text('削除すると元に戻せません。'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(c, false),
                                      child: const Text('キャンセル'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(c, true),
                                      child: const Text('削除'),
                                    ),
                                  ],
                                ),
                              );
                              if (yes != true) {
                                return;
                              }
                              try {
                                await widget.repository.delete(i.id);
                                await reload();
                                if (sheet.mounted) {
                                  Navigator.pop(sheet);
                                }
                              } catch (_) {
                                message('削除できませんでした');
                              }
                            },
                      child: const Text(
                        '削除する',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget tile(Item i, {String? hint}) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.all(14),
          leading: i.image.isNotEmpty
              ? picture(i.image)
              : Container(
                  width: 52,
                  height: 60,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F1E9),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.bookmark_outline, color: green),
                ),
          title: Text(
            i.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${i.category} · ${Uri.parse(i.url).host}\n${i.status} · ${date(i.created)}',
            style: const TextStyle(fontSize: 12),
          ),
          isThreeLine: true,
          trailing: IconButton(
            tooltip: i.favorite ? 'お気に入りを解除' : 'お気に入りに追加',
            onPressed: favoritePending.contains(i.id)
                ? null
                : () => toggleFavorite(i),
            icon: Icon(
              i.favorite ? Icons.star : Icons.star_border,
              color: i.favorite ? const Color(0xFFAA7722) : green,
            ),
          ),
          onTap: () => detail(i),
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              hint,
              style: const TextStyle(fontSize: 13, color: green),
            ),
          ),
      ],
    ),
  );
  Widget empty(String s) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28),
    child: Center(
      child: Column(
        children: [
          const Icon(Icons.bookmarks_outlined, size: 44, color: green),
          const SizedBox(height: 12),
          Text(s, textAlign: TextAlign.center),
          TextButton(onPressed: () => edit(), child: const Text('URLを保存する')),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'あとで。',
        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: ink),
      ),
      actions: [
        Center(child: Text('${items.length} 件の「いつか」')),
        IconButton(
          tooltip: widget.accountEmail == null
              ? 'ログイン・アカウント'
              : 'アカウント：${widget.accountEmail}',
          onPressed: loading || error != null ? null : openAccount,
          icon: Icon(
            widget.accountEmail == null
                ? Icons.person_outline
                : Icons.account_circle,
          ),
        ),
        IconButton(
          tooltip: 'バックアップ・復元',
          onPressed: loading || error != null ? null : openBackup,
          icon: const Icon(Icons.backup_outlined),
        ),
        const SizedBox(width: 20),
      ],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error!),
                TextButton(onPressed: reload, child: const Text('再試行')),
              ],
            ),
          )
        : Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: PageView(
                key: const PageStorageKey('main-tabs'),
                controller: pages,
                onPageChanged: (index) {
                  if (!navigating) setState(() => tab = index);
                },
                children: [
                  home(),
                  library(),
                  propose(),
                  history(),
                ].map((page) => _RetainedTab(child: page)).toList(),
              ),
            ),
          ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: loading || error != null ? null : () => edit(),
      backgroundColor: green,
      foregroundColor: Colors.white,
      icon: const Icon(Icons.add),
      label: const Text('保存する'),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: switchTab,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home_outlined), label: 'ホーム'),
        NavigationDestination(
          icon: Icon(Icons.bookmarks_outlined),
          label: '保存一覧',
        ),
        NavigationDestination(
          icon: Icon(Icons.auto_awesome_outlined),
          label: '今日どうする？',
        ),
        NavigationDestination(icon: Icon(Icons.task_alt), label: '完了履歴'),
      ],
    ),
  );
  Widget home() {
    final old = items
        .where(
          (i) =>
              i.status == '未完了' &&
              DateTime.now().difference(i.viewed ?? i.created).inDays >= 7,
        )
        .toList();
    return ListView(
      key: const PageStorageKey('home-list'),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
      children: [
        const Text(
          '「いつか」を、今日に。',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: ink,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '気になるものを集めて、小さな楽しみを見つけよう。',
          style: TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: ink,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.wb_sunny_outlined,
                color: Color(0xFFE0C78E),
                size: 32,
              ),
              const SizedBox(height: 18),
              const Text(
                '今日は、何をしよう？',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '保存した「やりたい」から、今日の候補を。',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => switchTab(2),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE6D7AF),
                  foregroundColor: ink,
                ),
                child: const Text('候補を見つける →'),
              ),
            ],
          ),
        ),
        heading('気になることから探す'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: categories
              .map(
                (c) => ActionChip(
                  label: Text(
                    '$c  ${items.where((i) => i.category == c && i.status == '未完了').length}',
                  ),
                  onPressed: () {
                    setState(() {
                      category = c;
                      status = '未完了';
                    });
                    switchTab(1);
                  },
                ),
              )
              .toList(),
        ),
        heading('最近の保存'),
        if (items.isEmpty)
          empty('最初の「あとで」を保存してみましょう。')
        else
          ...items.take(3).map((i) => tile(i)),
        heading('忘れていた「いつか」'),
        const Text('7日以上見返していない、未完了の保存'),
        const Text(
          '気になる候補を開いて、「行った」「買った」などを記録しましょう。',
          style: TextStyle(fontSize: 12, color: green),
        ),
        const SizedBox(height: 12),
        if (old.isEmpty)
          const Text(
            'しばらく見返していない保存はありません。',
            style: TextStyle(color: Colors.black54),
          )
        else
          ...old.take(3).map((i) => tile(i)),
      ],
    );
  }

  Widget history() {
    final completed = completionHistory(items);
    String? previousDay;
    final rows = <Widget>[
      heading('できたことの記録'),
      Text('${completed.length} 件の「いつか」が、思い出に。'),
      const SizedBox(height: 12),
    ];
    if (completed.isEmpty) {
      rows.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Text(
            '完了した保存はまだありません。\n保存の詳細から「行った」「買った」などを記録できます。',
            textAlign: TextAlign.center,
          ),
        ),
      );
      rows.add(
        OutlinedButton(
          onPressed: () => switchTab(1),
          child: const Text('保存一覧を見る'),
        ),
      );
    }
    for (final item in completed) {
      final day = item.completedAt == null
          ? '完了日の記録なし'
          : date(item.completedAt!.toLocal());
      if (day != previousDay) {
        rows.add(heading(day));
        previousDay = day;
      }
      rows.add(
        tile(
          item,
          hint:
              '${item.status} · ${item.completedAt == null ? '以前の完了記録です' : '完了 ${date(item.completedAt!.toLocal())}'}',
        ),
      );
    }
    return ListView(
      key: const PageStorageKey('history-list'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
      children: rows,
    );
  }

  Widget library() {
    final filtered = sortItems(
      items.where(
        (i) =>
            (category == 'すべて' || i.category == category) &&
            (status == 'すべて' || i.status == status) &&
            (!favoritesOnly || i.favorite) &&
            '${i.title} ${i.note} ${i.url}'.toLowerCase().contains(
              query.toLowerCase(),
            ),
      ),
      oldestFirst: sortOrder == '古い順',
    );
    return ListView(
      key: const PageStorageKey('library-list'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
      children: [
        heading('あなたの「あとで」'),
        TextField(
          controller: search,
          decoration: const InputDecoration(
            hintText: 'タイトル・メモ・URLで検索',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (s) => setState(() => query = s),
        ),
        const SizedBox(height: 16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: ['すべて', ...categories]
                .map(
                  (c) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(c),
                      selected: category == c,
                      onSelected: (_) => setState(() => category = c),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 16),
        select(
          '状態',
          ['すべて', ...statuses],
          status,
          (v) => setState(() => status = v),
        ),
        const SizedBox(height: 16),
        Text('${filtered.length} 件'),
        const SizedBox(height: 12),
        select(
          '並び替え',
          ['新しい順', '古い順'],
          sortOrder,
          (v) => setState(() => sortOrder = v),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilterChip(
            avatar: const Icon(Icons.star_border, size: 18),
            label: const Text('お気に入りのみ'),
            selected: favoritesOnly,
            onSelected: (v) => setState(() => favoritesOnly = v),
          ),
        ),
        const SizedBox(height: 12),
        if (filtered.isEmpty)
          empty('条件に合う保存がありません。')
        else
          ...filtered.map((i) => tile(i)),
      ],
    );
  }

  Widget propose() => ListView(
    key: const PageStorageKey('proposal-list'),
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
    children: [
      heading('今日どうする？'),
      const Text('今の気分に合わせて、保存をひとつ行動に。'),
      const SizedBox(height: 24),
      DropdownButtonFormField<int>(
        initialValue: budget ?? -1,
        decoration: const InputDecoration(labelText: '予算'),
        items: const [
          DropdownMenuItem(value: -1, child: Text('指定なし')),
          DropdownMenuItem(value: 1000, child: Text('1,000円以内')),
          DropdownMenuItem(value: 3000, child: Text('3,000円以内')),
          DropdownMenuItem(value: 10000, child: Text('10,000円以内')),
        ],
        onChanged: (v) => setState(() {
          budget = v == -1 ? null : v;
          suggestions = null;
        }),
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<int>(
        initialValue: minutes ?? -1,
        decoration: const InputDecoration(labelText: '使える時間'),
        items: const [
          DropdownMenuItem(value: -1, child: Text('指定なし')),
          DropdownMenuItem(value: 30, child: Text('30分')),
          DropdownMenuItem(value: 60, child: Text('1時間')),
          DropdownMenuItem(value: 180, child: Text('3時間')),
        ],
        onChanged: (v) => setState(() {
          minutes = v == -1 ? null : v;
          suggestions = null;
        }),
      ),
      const SizedBox(height: 16),
      select(
        '気分',
        moods,
        mood,
        (v) => setState(() {
          mood = v;
          suggestions = null;
        }),
      ),
      const SizedBox(height: 16),
      select(
        '同行者',
        companions,
        companion,
        (v) => setState(() {
          companion = v;
          suggestions = null;
        }),
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: () => setState(() {
          suggestions = recommend(
            items,
            budget: budget,
            minutes: minutes,
            mood: mood,
            companion: companion,
          )..shuffle();
        }),
        icon: const Icon(Icons.auto_awesome),
        label: Text(suggestions == null ? '保存から候補を探す' : '別の候補を表示'),
      ),
      const SizedBox(height: 12),
      const Text(
        '未登録の条件は適合と断定せず、確認が必要な候補として表示します。',
        style: TextStyle(fontSize: 12, color: Colors.black54),
      ),
      if (suggestions != null) ...[
        heading('今日の候補'),
        if (suggestions!.isEmpty)
          empty('条件に合う候補がありません。\n条件をゆるめて試してください。')
        else
          ...suggestions!.take(3).map((i) {
            return tile(
              i,
              hint: recommendationReason(
                i,
                budget: budget,
                minutes: minutes,
                mood: mood,
                companion: companion,
              ),
            );
          }),
      ],
    ],
  );
}

class _RetainedTab extends StatefulWidget {
  const _RetainedTab({required this.child});
  final Widget child;
  @override
  State<_RetainedTab> createState() => _RetainedTabState();
}

class _RetainedTabState extends State<_RetainedTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

Widget heading(String s) => Padding(
  padding: const EdgeInsets.only(top: 24, bottom: 12),
  child: Text(
    s,
    style: const TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.bold,
      color: ink,
    ),
  ),
);
Widget select(
  String label,
  List<String> options,
  String value,
  ValueChanged<String> changed,
) => DropdownButtonFormField<String>(
  key: ValueKey('$label$value'),
  initialValue: value,
  decoration: InputDecoration(labelText: label),
  items: options
      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
      .toList(),
  onChanged: (v) {
    if (v != null) {
      changed(v);
    }
  },
);
String date(DateTime d) => '${d.year}/${d.month}/${d.day}';
Widget picture(String url, {bool large = false}) => ClipRRect(
  borderRadius: BorderRadius.circular(14),
  child: Image.network(
    url,
    width: large ? double.infinity : 56,
    height: large ? 180 : 60,
    fit: BoxFit.cover,
    errorBuilder: (_, e, s) => SizedBox(
      width: 56,
      height: 60,
      child: const Icon(Icons.image_not_supported_outlined),
    ),
  ),
);

class Editor extends StatefulWidget {
  const Editor({
    super.key,
    this.item,
    this.shared,
    this.defaultCategory = 'その他',
    this.findDuplicate,
    required this.onSave,
  });
  final Item? item;
  final SharedLink? shared;
  final String defaultCategory;
  final Future<Item?> Function(String url, String? id)? findDuplicate;
  final Future<void> Function(Item) onSave;
  @override
  State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  final form = GlobalKey<FormState>();
  late final TextEditingController url, title, note, image, budget, minutes;
  late String category, mood, companion;
  bool busy = false;
  bool fetching = false;
  String? metadataMessage;
  @override
  void initState() {
    super.initState();
    final i = widget.item;
    url = TextEditingController(text: i?.url ?? widget.shared?.url);
    title = TextEditingController(text: i?.title ?? widget.shared?.title);
    note = TextEditingController(text: i?.note ?? widget.shared?.note);
    image = TextEditingController(text: i?.image);
    budget = TextEditingController(text: i?.budget?.toString());
    minutes = TextEditingController(text: i?.minutes?.toString());
    category = i?.category ?? widget.defaultCategory;
    mood = i?.mood ?? '指定なし';
    companion = i?.companion ?? '指定なし';
    if (widget.shared != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) loadTitle(automatic: true);
      });
    }
  }

  Future<void> loadTitle({bool automatic = false}) async {
    final target = url.text.trim();
    if (!validUrl(target)) {
      setState(() => metadataMessage = '先にURLを入力してください');
      return;
    }
    final previous = title.text;
    final previousImage = image.text;
    setState(() {
      fetching = true;
      metadataMessage = null;
    });
    final fetched = await fetchPageMetadata(target);
    if (!mounted) return;
    setState(() {
      fetching = false;
      if (url.text.trim() != target || busy) return;
      final updated = <String>[];
      if (fetched?.title != null &&
          title.text == previous &&
          (!automatic || previous.isEmpty)) {
        title.text = fetched!.title!;
        updated.add('タイトル');
      }
      if (fetched?.image != null &&
          image.text == previousImage &&
          (!automatic || previousImage.isEmpty)) {
        image.text = fetched!.image!;
        updated.add('画像');
      }
      metadataMessage = updated.isEmpty
          ? '情報を取得できなかったか、入力済みの内容を保持しました。手入力でも保存できます。'
          : '${updated.join('・')}を取得しました。内容を確認してください。';
    });
  }

  @override
  void dispose() {
    for (final c in [url, title, note, image, budget, minutes]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget field(
    TextEditingController c,
    String label, {
    bool required = false,
    bool isUrl = false,
    bool numeric = false,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: c,
      maxLines: lines,
      keyboardType: numeric
          ? TextInputType.number
          : isUrl
          ? TextInputType.url
          : TextInputType.text,
      decoration: InputDecoration(labelText: label),
      validator: (v) {
        final s = (v ?? '').trim();
        if (required && s.isEmpty) {
          return '入力してください';
        }
        if (isUrl && s.isNotEmpty && !validUrl(s)) {
          return 'http / httpsのURLを入力してください';
        }
        if (numeric &&
            s.isNotEmpty &&
            (int.tryParse(s) == null || int.parse(s) < 0)) {
          return '0以上の整数を入力してください';
        }
        return null;
      },
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.item == null ? '新しい「あとで」' : '保存を編集')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                '気になった瞬間を、ここに。',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: ink,
                ),
              ),
              const SizedBox(height: 8),
              const Text('URLとタイトルを入力して保存できます。'),
              const SizedBox(height: 24),
              field(url, '保存元のURL *', required: true, isUrl: true),
              OutlinedButton.icon(
                onPressed: fetching || busy ? null : () => loadTitle(),
                icon: const Icon(Icons.download_outlined),
                label: Text(fetching ? '情報を取得中…' : 'URLからタイトル・画像を取得'),
              ),
              if (metadataMessage != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(metadataMessage!),
                ),
              field(title, 'タイトル *', required: true),
              select('カテゴリー', categories, category, (v) => category = v),
              const SizedBox(height: 16),
              field(note, 'メモ', lines: 3),
              field(image, '画像URL（任意）', isUrl: true),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: image,
                builder: (_, value, _) => value.text.trim().isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: picture(value.text.trim(), large: true),
                      ),
              ),
              const Text(
                '提案をより自分に合わせる（任意）',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              field(budget, '目安の予算（円）', numeric: true),
              field(minutes, '目安の所要時間（分）', numeric: true),
              select('気分', moods, mood, (v) => mood = v),
              const SizedBox(height: 16),
              select('同行者', companions, companion, (v) => companion = v),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: busy ? null : submit,
                child: Text(busy ? '保存中…' : '保存する'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    ),
  );
  Future<void> submit() async {
    if (!form.currentState!.validate()) {
      return;
    }
    setState(() => busy = true);
    try {
      final duplicate = await widget.findDuplicate?.call(
        url.text.trim(),
        widget.item?.id,
      );
      if (!mounted) return;
      if (duplicate != null) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('同じURLが保存されています'),
            content: Text('「${duplicate.title}」\n別のアイテムとして保存しますか？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('戻る'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('別に保存'),
              ),
            ],
          ),
        );
        if (proceed != true) {
          if (mounted) setState(() => busy = false);
          return;
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('重複を確認できませんでした。再度お試しください。')),
        );
      }
      return;
    }
    if (!mounted) return;
    final old = widget.item;
    final now = DateTime.now();
    final i = Item(
      id: old?.id ?? now.microsecondsSinceEpoch.toString(),
      title: title.text.trim(),
      url: url.text.trim(),
      category: category,
      created: old?.created ?? now,
      note: note.text.trim(),
      image: image.text.trim(),
      status: old?.status ?? '未完了',
      viewed: old?.viewed,
      favorite: old?.favorite ?? false,
      completedAt: old?.completedAt,
      budget: int.tryParse(budget.text.trim()),
      minutes: int.tryParse(minutes.text.trim()),
      mood: mood,
      companion: companion,
    );
    try {
      await widget.onSave(i);
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存できませんでした。再度お試しください。')));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }
}
