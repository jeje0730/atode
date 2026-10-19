import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atode/main.dart';
import 'package:atode/data.dart';
import 'package:atode/sharing.dart';

void main() {
  test(
    'extracts SNS links from mixed text, removes punctuation and duplicates',
    () {
      final links = SharedLink.parse(
        'おすすめ！ https://vm.tiktok.com/ABC/\nhttps://vm.tiktok.com/ABC/ https://www.instagram.com/reel/XYZ/。',
        '週末に観たい',
      );
      expect(links.map((i) => i.url), [
        'https://vm.tiktok.com/ABC/',
        'https://www.instagram.com/reel/XYZ/',
      ]);
      expect(links.first.title, '週末に観たい');
      expect(links.first.note, contains('おすすめ'));
      expect(SharedLink.parse('URLなし javascript:alert(1)'), isEmpty);
    },
  );
  test('duplicate comparison removes tracking, preserves meaningful query', () {
    expect(
      normalizedUrl(
        'https://www.instagram.com/reel/ABC/?igsh=123&utm_source=share#top',
      ),
      normalizedUrl('https://www.instagram.com/reel/ABC/'),
    );
    expect(
      normalizedUrl('https://example.com/?id=1'),
      isNot(normalizedUrl('https://example.com/?id=2')),
    );
  });
  test('HTML title prefers OpenGraph and decodes entities', () {
    expect(
      parsePageTitle(
        '<title>Fallback</title><meta content="カフェ &amp; 公園" property="og:title">',
      ),
      'カフェ & 公園',
    );
    expect(parsePageTitle('<title> Hello\n world </title>'), 'Hello world');
    expect(parsePageTitle('<html>no title</html>'), isNull);
  });
  testWidgets('shared draft is prefilled and duplicate requires confirmation', (
    tester,
  ) async {
    final existing = Item(
      id: '1',
      title: '既存',
      url: 'https://example.com/post',
      category: '観たいもの',
      created: DateTime(2026),
    );
    Item? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Editor(
          shared: const SharedLink('https://example.com/post', '共有タイトル', '本文'),
          defaultCategory: '観たいもの',
          findDuplicate: (url, id) async => existing,
          onSave: (i) async {
            saved = i;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('https://example.com/post'), findsOneWidget);
    expect(find.text('共有タイトル'), findsOneWidget);
    expect(find.text('観たいもの'), findsOneWidget);
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
    expect(find.text('同じURLが保存されています'), findsOneWidget);
    expect(saved, isNull);
    await tester.tap(find.text('戻る'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    await tester.tap(find.widgetWithText(FilledButton, '保存する'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('別に保存'));
    await tester.pumpAndSettle();
    expect(saved?.title, '共有タイトル');
    expect(saved?.category, '観たいもの');
  });
}
