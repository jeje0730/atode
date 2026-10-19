import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atode/data.dart';
import 'package:atode/main.dart';

class TestRepository implements Repository {
  final items = <String, Item>{};
  @override
  Future<List<Item>> load() async => sortItems(items.values);
  @override
  Future<void> save(Item item) async {
    items[item.id] = item;
  }

  @override
  Future<void> delete(String id) async {
    items.remove(id);
  }
}

void main() {
  final older = Item(
    id: 'old',
    title: '古い保存',
    url: 'https://example.com/old',
    category: 'その他',
    created: DateTime(2026),
    budget: 500,
    minutes: 20,
    mood: 'のんびり',
  );
  final newer = Item(
    id: 'new',
    title: '新しい保存',
    url: 'https://example.com/new',
    category: 'その他',
    created: DateTime(2026, 2),
  );
  test('sorts both ways without mutating source', () {
    final source = [older, newer];
    expect(sortItems(source), [newer, older]);
    expect(sortItems(source, oldestFirst: true), [older, newer]);
    expect(source, [older, newer]);
  });
  test('reason distinguishes matching and missing conditions', () {
    final reason = recommendationReason(
      older,
      budget: 1000,
      minutes: 30,
      mood: 'のんびり',
      companion: '友人',
    );
    expect(reason, contains('予算500円（1000円以内）'));
    expect(reason, contains('所要20分（30分以内）'));
    expect(reason, contains('気分「のんびり」に一致'));
    expect(reason, contains('同行者は確認が必要'));
    expect(recommendationReason(newer), '未完了の保存から提案');
    expect(recommendationReason(newer, budget: 1000), isNot(contains('以内')));
  });
  testWidgets('favorite toggle persists and filter works; sorting updates UI', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = TestRepository();
    await repo.save(older);
    await repo.save(newer);
    await tester.pumpWidget(AtodeApp(repository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存一覧'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('新しい保存')).dy,
      lessThan(tester.getTopLeft(find.text('古い保存')).dy),
    );
    await tester.tap(find.text('新しい順'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('古い順').last);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('古い保存')).dy,
      lessThan(tester.getTopLeft(find.text('新しい保存')).dy),
    );
    await tester.tap(find.byTooltip('お気に入りに追加').first);
    await tester.pumpAndSettle();
    expect(repo.items['old']!.favorite, isTrue);
    await tester.tap(find.text('お気に入りのみ'));
    await tester.pumpAndSettle();
    expect(find.text('古い保存'), findsOneWidget);
    expect(find.text('新しい保存'), findsNothing);
    await tester.tap(find.byTooltip('お気に入りを解除'));
    await tester.pumpAndSettle();
    expect(repo.items['old']!.favorite, isFalse);
    expect(find.text('条件に合う保存がありません。'), findsOneWidget);
  });
}
