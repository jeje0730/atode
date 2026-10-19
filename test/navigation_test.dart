import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atode/main.dart';
import 'package:atode/data.dart';
import 'backup_test.dart' show MemoryRestoreRepository;

void main() {
  testWidgets(
    'search and scroll survive tab changes, swipes keep navigation in sync',
    (tester) async {
      final repo = MemoryRestoreRepository();
      for (var n = 0; n < 30; n++) {
        await repo.save(
          Item(
            id: '$n',
            title: 'カフェ $n',
            url: 'https://example.com/$n',
            category: '行きたい店',
            created: DateTime(2026, 10, n + 1),
          ),
        );
      }
      await tester.pumpWidget(AtodeApp(repository: repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存一覧'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'カフェ');
      await tester.pumpAndSettle();
      final search = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      final list = find.byKey(const PageStorageKey('library-list'));
      final scroll = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      await tester.drag(list, const Offset(0, -650));
      await tester.pumpAndSettle();
      final offset = tester.state<ScrollableState>(scroll).position.pixels;
      expect(offset, greaterThan(0));
      await tester.tap(find.text('今日どうする？'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存一覧'));
      await tester.pumpAndSettle();
      expect(search.text, 'カフェ');
      expect(
        tester.state<ScrollableState>(scroll).position.pixels,
        closeTo(offset, 1),
      );
      await tester.drag(find.byType(PageView), const Offset(-650, 0));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );
      await tester.tap(find.text('完了履歴'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.text('ホーム'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(find.text('「いつか」を、今日に。'), findsOneWidget);
    },
  );
}
