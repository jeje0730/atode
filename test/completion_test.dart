import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atode/data.dart';
import 'package:atode/main.dart';
import 'library_test.dart' show TestRepository;

class FailingCompletionRepository extends TestRepository {
  @override
  Future<void> save(Item item) async {
    if (item.isCompleted) throw Exception('disk unavailable');
    await super.save(item);
  }
}

void main() {
  final item = Item(
    id: '1',
    title: '週末のカフェ',
    url: 'https://example.com/cafe',
    category: '行きたい店',
    created: DateTime(2026),
  );
  testWidgets('failed completion keeps item unfinished and allows retry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = FailingCompletionRepository();
    await repo.save(item);
    await tester.pumpWidget(AtodeApp(repository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存一覧'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item.title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('「行った」を記録'));
    await tester.pumpAndSettle();
    expect(repo.items[item.id]!.status, '未完了');
    expect(repo.items[item.id]!.completedAt, isNull);
    expect(find.text('状態を保存できませんでした'), findsOneWidget);
    expect(find.text('「行った」を記録'), findsOneWidget);
  });
  test(
    'category actions and completion transitions preserve or clear dates',
    () {
      expect(categories.map(completionStatus), [
        '行った',
        '行った',
        '買った',
        '観た',
        '読んだ',
        '完了',
      ]);
      final first = DateTime(2026, 10, 19, 12);
      final done = item.changeStatus('行った', now: first);
      expect(done.completedAt, first);
      expect(done.isCompleted, isTrue);
      expect(done.update(favorite: true).completedAt, first);
      expect(done.changeStatus('観た', now: DateTime(2027)).completedAt, first);
      expect(done.changeStatus('未完了').completedAt, isNull);
      expect(done.changeStatus('興味なし').isCompleted, isFalse);
      expect(
        done
            .changeStatus('未完了')
            .changeStatus('行った', now: DateTime(2027))
            .completedAt,
        DateTime(2027),
      );
    },
  );
  test(
    'history excludes unfinished and dismissed, sorts by completion and keeps unknown dates',
    () {
      final early = item.changeStatus('行った', now: DateTime(2026, 10, 18));
      final late = Item.fromMap({
        ...early.toMap(),
        'id': '2',
        'completedAt': DateTime(2026, 10, 19).toIso8601String(),
      });
      final legacy = Item.fromMap({
        ...early.toMap(),
        'id': '3',
        'completedAt': null,
      });
      expect(
        completionHistory([
          item,
          early,
          legacy,
          late,
          item.changeStatus('興味なし'),
        ]),
        [late, early, legacy],
      );
      expect(legacy.update(favorite: true).completedAt, isNull);
    },
  );
  testWidgets('complete from rediscovery, undo, and reopen history', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = TestRepository();
    await repo.save(item);
    await tester.pumpWidget(AtodeApp(repository: repo));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('忘れていた「いつか」'),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('home-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.scrollUntilVisible(
      find.text('週末のカフェ').last,
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('home-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('週末のカフェ').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('「行った」を記録'));
    await tester.pumpAndSettle();
    expect(repo.items['1']!.completedAt, isNotNull);
    expect(recommend(repo.items.values.toList()), isEmpty);
    await tester.tap(find.text('元に戻す'));
    await tester.pumpAndSettle();
    expect(repo.items['1']!.status, '未完了');
    expect(repo.items['1']!.completedAt, isNull);
    await tester.tap(find.text('保存一覧'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('週末のカフェ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('「行った」を記録'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完了履歴'));
    await tester.pumpAndSettle();
    expect(find.text('週末のカフェ'), findsOneWidget);
    expect(find.text('できたことの記録'), findsOneWidget);
    await tester.tap(find.text('週末のカフェ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未完了に戻す'));
    await tester.pumpAndSettle();
    expect(repo.items['1']!.completedAt, isNull);
    expect(find.textContaining('完了した保存はまだありません'), findsOneWidget);
  });
}
