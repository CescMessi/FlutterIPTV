import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'service_locator.dart';

/// 注册到代理里的一个播放会话。
class StreamProxySession {
  const StreamProxySession({
    required this.token,
    required this.url,
  });

  /// 代理 token（用于回收会话与生成 URL）。
  final String token;

  /// 可直接交给外部播放器的本地地址，例如
  /// `http://127.0.0.1:52341/p/AbCdEf/stream`。
  final String url;
}

class _ProxyTarget {
  _ProxyTarget({
    required this.token,
    required this.upstreamUrl,
    required this.headers,
    this.reload,
  });

  final String token;

  /// 当前上游地址（遇到 403/410 时会刷新）。
  String upstreamUrl;

  /// 需要注入到上游请求里的头（User-Agent / Referer / Cookie ...）。
  final Map<String, String> headers;

  /// 上游签名过期时，用来重新解析真实地址的回调。
  final Future<String?> Function()? reload;

  DateTime lastAccess = DateTime.now();
}

/// 本地回环流代理。
///
/// 场景：IPTV 源普遍要求特定的 `User-Agent` / `Referer` / `Cookie`，
/// 或者用了短时效的防盗链签名。PotPlayer / VLC 这类播放器无法注入这些头，
/// 直接把地址丢过去就会 403。
///
/// 这里由 App 自己发起上游请求，再通过 `127.0.0.1` 上的 HTTP 服务把数据转发给
/// 外部播放器：
///   * `GET /p/<token>/stream`  —— 直播流 / 点播文件（透传 Range）
///   * `GET /p/<token>/seg?u=…` —— HLS 分片、密钥、子清单（base64url 编码的真实地址）
///
/// HLS 清单会被重写：所有分片 / 密钥 / 子清单地址都替换成本代理地址，
/// 这样外部播放器只需要认 127.0.0.1 即可。
class StreamProxyService {
  StreamProxyService();

  static const Duration _sessionIdleTimeout = Duration(hours: 2);

  HttpServer? _server;
  Timer? _cleanupTimer;
  final Map<String, _ProxyTarget> _targets = {};

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..autoUncompress = false
    ..idleTimeout = const Duration(seconds: 30);

  bool get isRunning => _server != null;
  int get port => _server?.port ?? 0;

  /// 确保本地代理服务已启动，返回端口。
  Future<int> ensureStarted() async {
    final existing = _server;
    if (existing != null) return existing.port;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.idleTimeout = const Duration(minutes: 2);
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object e) => _log('代理服务错误: $e', warn: true),
    );
    _server = server;

    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      final now = DateTime.now();
      _targets.removeWhere((_, target) =>
          now.difference(target.lastAccess) > _sessionIdleTimeout);
    });

    _log('本地流代理已启动: 127.0.0.1:${server.port}');
    return server.port;
  }

  /// 注册一个播放会话，返回可交给外部播放器的本地地址。
  ///
  /// [reload] 用于上游 403/410 时重新解析防盗链地址（例如 302 跳转后的临时 token）。
  Future<StreamProxySession> register({
    required String url,
    Map<String, String> headers = const {},
    Future<String?> Function()? reload,
  }) async {
    final port = await ensureStarted();
    final token = _newToken();
    _targets[token] = _ProxyTarget(
      token: token,
      upstreamUrl: url,
      headers: Map<String, String>.from(headers),
      reload: reload,
    );
    return StreamProxySession(
      token: token,
      url: 'http://127.0.0.1:$port/p/$token/stream',
    );
  }

  /// 回收会话（外部播放器退出 / 用户停止播放时调用）。
  Future<void> release(String? token) async {
    if (token == null) return;
    _targets.remove(token);
  }

  Future<void> dispose() async {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _targets.clear();
    await _server?.close(force: true);
    _server = null;
    _client.close(force: true);
  }

  // ==================== HTTP 处理 ====================

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      // 只服务本机：避免同网段的人拿这个端口白嫖源地址
      final remote = request.connectionInfo?.remoteAddress;
      if (remote == null || !remote.isLoopback) {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }

      final segments = request.uri.pathSegments;
      if (segments.length < 3 || segments[0] != 'p') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final target = _targets[segments[1]];
      if (target == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      target.lastAccess = DateTime.now();

      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }

      final action = segments[2];
      Uri upstream;
      if (action == 'seg') {
        final encoded = request.uri.queryParameters['u'];
        final decoded = encoded == null ? null : _decodeUrl(encoded);
        if (decoded == null) {
          response.statusCode = HttpStatus.badRequest;
          await response.close();
          return;
        }
        upstream = Uri.parse(decoded);
      } else {
        upstream = Uri.parse(target.upstreamUrl);
      }

      await _relay(request, response, target, upstream);
    } catch (e) {
      _log('代理转发失败: $e', warn: true);
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {
        // 客户端可能已经断开
      }
    }
  }

  Future<void> _relay(
    HttpRequest request,
    HttpResponse response,
    _ProxyTarget target,
    Uri upstream,
  ) async {
    var uri = upstream;
    HttpClientResponse? upstreamResponse;

    for (var attempt = 0; attempt < 2; attempt++) {
      final outbound = await _client.openUrl(request.method, uri);
      target.headers.forEach((name, value) {
        if (name.isNotEmpty && value.isNotEmpty) {
          outbound.headers.set(name, value);
        }
      });
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) outbound.headers.set(HttpHeaders.rangeHeader, range);
      outbound.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

      final current = await outbound.close();

      // 防盗链 token 过期：重新解析一次真实地址再试
      final isStale = attempt == 0 &&
          target.reload != null &&
          (current.statusCode == HttpStatus.forbidden ||
              current.statusCode == HttpStatus.notFound ||
              current.statusCode == HttpStatus.gone);
      if (isStale) {
        await current.drain<void>();
        final fresh = await target.reload!();
        if (fresh != null && fresh.isNotEmpty && fresh != uri.toString()) {
          _log('代理上游地址已刷新: $fresh');
          target.upstreamUrl = fresh;
          uri = Uri.parse(fresh);
          continue;
        }
      }

      upstreamResponse = current;
      break;
    }

    if (upstreamResponse == null) {
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }

    await _pump(request, response, target, uri, upstreamResponse);
  }

  Future<void> _pump(
    HttpRequest request,
    HttpResponse response,
    _ProxyTarget target,
    Uri upstream,
    HttpClientResponse upstreamResponse,
  ) async {
    if (await _maybeRewritePlaylist(
        request, response, target, upstream, upstreamResponse)) {
      return;
    }

    response.statusCode = upstreamResponse.statusCode;
    for (final name in const [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.cacheControlHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.etagHeader,
    ]) {
      final value = upstreamResponse.headers.value(name);
      if (value != null) response.headers.set(name, value);
    }

    if (request.method == 'HEAD') {
      await response.close();
      return;
    }

    response.bufferOutput = false;
    try {
      await for (final chunk in upstreamResponse) {
        response.add(chunk);
      }
    } catch (e) {
      _log('代理流中断: $e', warn: true);
    }
    await response.close();
  }

  /// HLS 清单：读出来重写所有 URI，再返回给播放器。
  Future<bool> _maybeRewritePlaylist(
    HttpRequest request,
    HttpResponse response,
    _ProxyTarget target,
    Uri upstream,
    HttpClientResponse upstreamResponse,
  ) async {
    final mime = upstreamResponse.headers.contentType?.mimeType ?? '';
    final looksLikeHls = mime.contains('mpegurl') ||
        upstream.path.toLowerCase().endsWith('.m3u8') ||
        upstream.path.toLowerCase().endsWith('.m3u');
    if (!looksLikeHls) return false;

    final body = await utf8.decodeStream(upstreamResponse);
    if (!body.contains('#EXTM3U')) return false;

    final rewritten = _rewriteHls(body, upstream, target);
    response.statusCode = HttpStatus.ok;
    response.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    response.write(rewritten);
    await response.close();
    return true;
  }

  String _rewriteHls(String text, Uri base, _ProxyTarget target) {
    final proxyBase = 'http://127.0.0.1:$port/p/${target.token}/seg?u=';

    String toProxy(String raw) {
      final resolved = base.resolve(raw.trim());
      final encoded =
          base64Url.encode(utf8.encode(resolved.toString())).replaceAll('=', '');
      return '$proxyBase$encoded';
    }

    final output = <String>[];
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trimRight();
      if (line.isEmpty) {
        output.add(line);
        continue;
      }
      if (line.startsWith('#')) {
        // 仅改写带 URI="..." 的标签：EXT-X-KEY / EXT-X-MAP / EXT-X-MEDIA / EXT-X-I-FRAME-STREAM-INF
        if (line.contains('URI="')) {
          output.add(line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (match) => 'URI="${toProxy(match.group(1)!)}"',
          ));
        } else {
          output.add(line);
        }
        continue;
      }
      output.add(toProxy(line));
    }
    return output.join('\n');
  }

  void _log(String message, {bool warn = false}) {
    try {
      if (warn) {
        ServiceLocator.log.w(message, tag: 'StreamProxy');
      } else {
        ServiceLocator.log.i(message, tag: 'StreamProxy');
      }
    } catch (_) {
      // 单元测试或早期启动时 ServiceLocator 可能尚未初始化
    }
  }

  String _newToken() {
    const alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List.generate(
      24,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  String? _decodeUrl(String encoded) {
    try {
      final normalized = base64Url.normalize(encoded);
      return utf8.decode(base64Url.decode(normalized));
    } catch (_) {
      return null;
    }
  }
}
