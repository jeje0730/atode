import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;
import 'data.dart';

class SharedLink {
  const SharedLink(this.url, this.title, this.note);
  final String url, title, note;
  static List<SharedLink> parse(String text, [String subject = '']) {
    final matches = RegExp(
      r'''https?://[^\s<>"「」『』]+''',
      caseSensitive: false,
    ).allMatches(text);
    final urls = matches
        .map((m) => m.group(0)!.replaceFirst(RegExp(r'[)\]。、，,！!？?]+$'), ''))
        .where(validUrl)
        .toSet();
    return urls
        .map(
          (url) => SharedLink(
            url,
            validUrl(subject.trim()) ? '' : subject.trim(),
            text.trim() == url ? '' : text.trim(),
          ),
        )
        .toList();
  }
}

String normalizedUrl(String value) {
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

class AndroidShareReceiver {
  static const channel = MethodChannel('jp.atode/share');
  static AndroidShareReceiver? active;
  Future<void> start(void Function(List<SharedLink>) receive) async {
    if (!Platform.isAndroid) return;
    active = this;
    Future<void> drain() async {
      final batch =
          await channel.invokeListMethod<dynamic>('takePending') ?? [];
      if (batch.isEmpty) return;
      receive(
        batch
            .expand(
              (m) => SharedLink.parse(
                m['text'] as String,
                m['subject'] as String? ?? '',
              ),
            )
            .toList(),
      );
    }

    channel.setMethodCallHandler((call) async {
      if (call.method == 'available') await drain();
    });
    await drain();
  }

  void dispose() {
    if (Platform.isAndroid && identical(active, this)) {
      active = null;
      channel.setMethodCallHandler(null);
    }
  }
}

String? parsePageTitle(String source) {
  final doc = html.parse(source);
  final value =
      doc.querySelector('meta[property="og:title"]')?.attributes['content'] ??
      doc.querySelector('title')?.text;
  final clean = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean == null || clean.isEmpty
      ? null
      : clean.substring(0, clean.length > 300 ? 300 : clean.length);
}

class PageMetadata {
  const PageMetadata({this.title, this.image});
  final String? title, image;
}

PageMetadata parsePageMetadata(String source, Uri page) {
  final doc = html.parse(source);
  String? image;
  for (final selector in [
    'meta[property="og:image:secure_url"]',
    'meta[property="og:image"]',
    'meta[property="og:image:url"]',
    'meta[name="twitter:image"]',
    'meta[property="twitter:image"]',
  ]) {
    final raw = doc.querySelector(selector)?.attributes['content']?.trim();
    if (raw == null || raw.isEmpty) continue;
    final parsed = Uri.tryParse(raw);
    if (parsed == null) continue;
    final resolved = page.resolveUri(parsed).toString();
    if (validUrl(resolved)) {
      image = resolved;
      break;
    }
  }
  return PageMetadata(title: parsePageTitle(source), image: image);
}

Future<String?> fetchPageTitle(String url) async =>
    (await fetchPageMetadata(url))?.title;

Future<PageMetadata?> fetchPageMetadata(String url) async {
  if (!validUrl(url)) return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    return await (() async {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.acceptHeader, 'text/html');
      final response = await request.close();
      if (response.statusCode != 200 ||
          !(response.headers.contentType?.mimeType.contains('html') ?? false)) {
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        final remaining = 512 * 1024 - bytes.length;
        bytes.addAll(chunk.take(remaining));
        if (bytes.length >= 512 * 1024) break;
      }
      final encoding =
          Encoding.getByName(
            response.headers.contentType?.charset ?? 'utf-8',
          ) ??
          utf8;
      var finalPage = Uri.parse(url);
      for (final redirect in response.redirects) {
        finalPage = finalPage.resolveUri(redirect.location);
      }
      return parsePageMetadata(
        encoding == utf8
            ? utf8.decode(bytes, allowMalformed: true)
            : encoding.decode(bytes),
        finalPage,
      );
    })().timeout(const Duration(seconds: 8));
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
