import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atode/main.dart';
import 'package:atode/data.dart';

class MemoryRepository implements Repository {
  final Map<String, Item> items = {};
  @override
  Future<List<Item>> load() async => items.values.toList();
  @override
  Future<void> save(Item i) async {
    items[i.id] = i;
  }

  @override
  Future<void> delete(String id) async {
    items.remove(id);
  }
}

void main() {
  test('validate safe HTTP URLs', () {
    expect(validUrl('https://example.com/post'), isTrue);
    for (final s in [
      'javascript:alert(1)',
      'example.com',
      'https://',
      'https://example.com/a b',
    ]) {
      expect(validUrl(s), isFalse);
    }
  });
  test(
    'recommendations exclude completed and known mismatches; missing fields are explicit',
    () {
      final i = Item(
        id: '1',
        title: 'カフェ',
        url: 'https://example.com',
        category: '行きたい店',
        created: DateTime(2026),
      );
      final expensive = Item.fromMap({...i.toMap(), 'id': '2', 'budget': 5000});
      expect(recommend([i, expensive, i.update(status: '行った')], budget: 1000), [
        i,
      ]);
      expect(
        missing(i, budget: 1000, minutes: 30, mood: 'のんびり', companion: '友人'),
        ['予算', '時間', '気分', '同行者'],
      );
      expect(Item.fromMap(i.toMap()).toMap(), i.toMap());
    },
  );
  testWidgets('save and reload item through UI', (tester) async {
    final repo = MemoryRepository();
    await tester.pumpWidget(AtodeApp(repository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存する').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'https://example.com/cafe',
    );
    await tester.enterText(find.byType(TextFormField).at(1), '週末のカフェ');
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '保存する'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(Editor),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存する'));
    await tester.pumpAndSettle();
    expect(repo.items.values.single.title, '週末のカフェ');
    await tester.tap(find.text('保存一覧'));
    await tester.pumpAndSettle();
    expect(find.text('週末のカフェ'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(AtodeApp(repository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存一覧'));
    await tester.pumpAndSettle();
    expect(find.text('週末のカフェ'), findsOneWidget);
  });
}
