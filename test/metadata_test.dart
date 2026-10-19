import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:atode/sharing.dart';

void main() {
  test(
    'extracts relative and fallback images and rejects unsupported schemes',
    () {
      final base = Uri.parse('https://example.com/articles/page');
      expect(
        parsePageMetadata(
          '<meta property="og:image" content="../photo.jpg">',
          base,
        ).image,
        'https://example.com/photo.jpg',
      );
      expect(
        parsePageMetadata(
          '<meta property="og:image" content="javascript:bad"><meta name="twitter:image" content="//cdn.example.com/a.png">',
          base,
        ).image,
        'https://cdn.example.com/a.png',
      );
      expect(parsePageMetadata('<title>画像なし</title>', base).image, isNull);
    },
  );
  test('uses redirect destination to resolve image paths', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      if (r.uri.path == '/start') {
        await r.response.redirect(Uri.parse('/nested/page'));
      } else {
        r.response.headers.contentType = ContentType.html;
        r.response.write(
          '<meta property="og:image" content="image.png"><title>Preview</title>',
        );
        await r.response.close();
      }
    });
    try {
      final result = await fetchPageMetadata(
        'http://127.0.0.1:${server.port}/start',
      );
      expect(result?.title, 'Preview');
      expect(result?.image, 'http://127.0.0.1:${server.port}/nested/image.png');
    } finally {
      await server.close(force: true);
    }
  });
  test(
    'fetches page title and handles HTTP failure and missing title',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/error') {
          request.response.statusCode = 403;
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            request.uri.path == '/empty'
                ? '<p>no title</p>'
                : '<title>カフェ &amp; 公園</title>',
          );
        }
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      try {
        expect(await fetchPageTitle('$base/title'), 'カフェ & 公園');
        expect(await fetchPageTitle('$base/error'), isNull);
        expect(await fetchPageTitle('$base/empty'), isNull);
      } finally {
        await server.close(force: true);
      }
    },
  );
}
