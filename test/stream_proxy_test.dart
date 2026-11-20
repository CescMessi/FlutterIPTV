import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_iptv/core/services/stream_proxy_service.dart';

void main() {
  test('HLS 清单被重写、分片与密钥经代理透传、请求头被注入', () async {
    final seenUserAgent = <String>[];
    final segmentBytes = List<int>.generate(64, (index) => index);
    final keyBytes = <int>[9, 8, 7, 6];

    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamPort = upstream.port;

    upstream.listen((request) async {
      final userAgent = request.headers.value('user-agent');
      if (userAgent != null) seenUserAgent.add(userAgent);

      switch (request.uri.path) {
        case '/live.m3u8':
          request.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          request.response.write(
            '#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:4\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
            '#EXTINF:4.0,\n'
            'seg1.ts\n'
            '#EXTINF:4.0,\n'
            'http://127.0.0.1:$upstreamPort/seg2.ts\n'
            '#EXT-X-ENDLIST\n',
          );
          break;
        case '/seg1.ts':
        case '/seg2.ts':
          request.response.headers.contentType = ContentType('video', 'mp2t');
          request.response.add(segmentBytes);
          break;
        case '/key.bin':
          request.response.add(keyBytes);
          break;
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final proxy = StreamProxyService();
    final session = await proxy.register(
      url: 'http://127.0.0.1:$upstreamPort/live.m3u8',
      headers: {'User-Agent': 'test-agent/1.0'},
    );
    final proxyPort = proxy.port;
    final client = HttpClient();

    try {
      // 入口地址必须带扩展名，否则 PotPlayer 会直接忽略（不取流）
      expect(session.url, endsWith('/stream.m3u8'));

      final playlistResponse =
          await (await client.getUrl(Uri.parse(session.url))).close();
      final playlist = await playlistResponse.transform(utf8.decoder).join();

      expect(playlist, contains('#EXTM3U'));
      expect(playlist, contains('127.0.0.1:$proxyPort/p/${session.token}/s/'));

      final keyLine = playlist
          .split('\n')
          .firstWhere((line) => line.startsWith('#EXT-X-KEY'));
      expect(keyLine, contains('127.0.0.1:$proxyPort/p/${session.token}/s/'));
      expect(keyLine, contains('.key"'));

      final mediaLines = playlist
          .split('\n')
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .toList();
      expect(mediaLines, hasLength(2));
      for (final line in mediaLines) {
        expect(line, startsWith('http://127.0.0.1:$proxyPort/p/'));
        expect(line, endsWith('.ts'));
      }

      final firstSegment =
          await (await client.getUrl(Uri.parse(mediaLines.first))).close();
      final firstBytes =
          await firstSegment.fold<List<int>>(<int>[], (buffer, chunk) {
        buffer.addAll(chunk);
        return buffer;
      });
      expect(firstBytes, segmentBytes);
      expect(seenUserAgent, contains('test-agent/1.0'));
    } finally {
      client.close(force: true);
      await proxy.release(session.token);
      await proxy.dispose();
      await upstream.close(force: true);
    }
  });
}
