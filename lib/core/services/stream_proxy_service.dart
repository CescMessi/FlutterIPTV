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
    required this.extension,
  });

  /// 代理 token（用于回收会话与生成 URL）。
  final String token;

  /// 可直接交给外部播放器的本地地址，例如
  /// `http://127.0.0.1:52341/p/AbCdEf/stream.m3u8`。
  ///
  /// 末尾的扩展名很重要：PotPlayer / VLC 这类播放器会按扩展名选择分离器，
  /// 没有扩展名的 `http://127.0.0.1:port/p/token/stream` 会被直接忽略（表现为
  /// 播放器窗口打开但一直不取流）。
  final String url;

  /// 入口地址的扩展名（m3u8 / ts / mp4 / flv / mkv）。
  final String extension;
}

class _ProxyTarget {
  _ProxyTarget({
    required this.token,
    required this.upstreamUrl,
    required this.headers,
    this.reload,
  });

  final String token;

  /// 当前上游地址（遇到 403/404/410 时会刷新）。
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
///   * `GET /p/<token>/stream.<ext>` —— 入口（直播流 / 点播文件 / HLS 清单）
///   * `GET /p/<token>/s/<base64url>.<ext>` —— HLS 分片、密钥、子清单
///
/// 所有 URL 都带真实扩展名（`.m3u8` / `.ts` / `.mp4` / `.key` ...），
/// 否则 PotPlayer 会按“未知类型”直接放弃。
///
/// HLS 清单会被重写：分片 / 密钥 / 子清单地址都替换成本代理地址。
class StreamProxyService {
  StreamProxyService();

  static const Duration _sessionIdleTimeout = Duration(hours: 2);
  static const Duration _sniffTimeout = Duration(milliseconds: 1500);

  HttpServer? _server;
  Timer? _cleanupTimer;
  final Map<String, _ProxyTarget> _targets = {};

  /// 最近若干条代理请求（排障用：外部播放器到底有没有来取流、上游返回了什么）。
  final List<String> _recentRequests = [];
  List<String> get recentRequests => List.unmodifiable(_recentRequests);
  int get requestCount => _requestCount;
  int _requestCount = 0;

  void _record(String line) {
    _requestCount++;
    _recentRequests.add('${DateTime.now().toIso8601String()} $line');
    if (_recentRequests.length > 60) _recentRequests.removeAt(0);
  }

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
  /// [reload] 用于上游 403/404/410 时重新解析防盗链地址（例如 302 跳转后的临时 token）。
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

    final extension = await _resolveEntryExtension(url, headers);
    final proxyUrl = 'http://127.0.0.1:$port/p/$token/stream.$extension';
    _log('注册代理会话: ext=$extension url=$proxyUrl -> $url');
    return StreamProxySession(
      token: token,
      url: proxyUrl,
      extension: extension,
    );
  }

  /// 预检：确认上游在超时内能返回响应头，避免把死链丢给外部播放器后静默卡住。
  Future<bool> probe({
    required String url,
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 4),
  }) async {
    HttpClientRequest? request;
    try {
      request = await _client.getUrl(Uri.parse(url)).timeout(timeout);
      headers.forEach((name, value) {
        if (name.isNotEmpty && value.isNotEmpty) {
          request!.headers.set(name, value);
        }
      });
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(timeout);
      final ok = response.statusCode >= 200 && response.statusCode < 400;
      // 只读响应头，立刻断开（直播流不 drain，避免挂住）
      final subscription = response.listen(null);
      await subscription.cancel();
      return ok;
    } catch (e) {
      _record('  probe failed: $e');
      try {
        request?.abort();
      } catch (_) {}
      return false;
    }
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

  // ==================== 扩展名判定 ====================

  /// 决定入口 URL 的扩展名：先看原始路径，再看首字节是否为 HLS 清单。
  Future<String> _resolveEntryExtension(
    String url,
    Map<String, String> headers,
  ) async {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in const ['m3u8', 'm3u']) {
      if (path.endsWith('.$ext')) return 'm3u8';
    }
    for (final ext in const ['mp4', 'flv', 'mkv', 'ts', 'm4s', 'mpd']) {
      if (path.endsWith('.$ext')) return ext;
    }
    // 无扩展名（udpxy / rtp / 带 token 的 CDN）：嗅探首字节
    return _sniffExtension(url, headers);
  }

  Future<String> _sniffExtension(
    String url,
    Map<String, String> headers,
  ) async {
    try {
      final request =
          await _client.getUrl(Uri.parse(url)).timeout(_sniffTimeout);
      headers.forEach((name, value) {
        if (name.isNotEmpty && value.isNotEmpty) {
          request.headers.set(name, value);
        }
      });
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-31');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(_sniffTimeout);
      final head = <int>[];
      await for (final chunk in response) {
        head.addAll(chunk);
        if (head.length >= 8) break;
      }
      final text = String.fromCharCodes(head.take(8));
      if (text.startsWith('#EXTM3U')) return 'm3u8';
      return 'ts';
    } catch (_) {
      return 'ts';
    }
  }

  String _extensionFor(String resolvedUrl, {String? forced}) {
    if (forced != null) return forced;
    final path = Uri.tryParse(resolvedUrl)?.path.toLowerCase() ?? '';
    const known = {
      'm3u8': 'm3u8',
      'm3u': 'm3u8',
      'ts': 'ts',
      'mp4': 'mp4',
      'm4s': 'mp4',
      'm4v': 'mp4',
      'aac': 'aac',
      'vtt': 'vtt',
      'webvtt': 'vtt',
      'key': 'key',
      'flv': 'flv',
      'mkv': 'mkv',
      'jpg': 'jpg',
      'png': 'png',
    };
    for (final entry in known.entries) {
      if (path.endsWith('.${entry.key}')) return entry.value;
    }
    return 'ts';
  }

  // ==================== HTTP 处理 ====================

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      // 只服务本机：避免同网段的人拿这个端口白嫖源地址
      final remote = request.connectionInfo?.remoteAddress;
      if (remote == null || !remote.isLoopback) {
        _log('拒绝非本机代理请求: ${remote?.address}', warn: true);
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
        _log('代理 token 不存在: ${segments[1]}', warn: true);
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

      final rest = segments.sublist(2).join('/');
      _record('${request.method} $rest');

      Uri upstream;
      if (rest == 'stream' || rest.startsWith('stream.')) {
        upstream = Uri.parse(target.upstreamUrl);
      } else if (rest.startsWith('s/')) {
        var name = rest.substring(2);
        final dot = name.lastIndexOf('.');
        if (dot > 0) name = name.substring(0, dot);
        final decoded = _decodeUrl(name);
        if (decoded == null) {
          response.statusCode = HttpStatus.badRequest;
          await response.close();
          return;
        }
        upstream = Uri.parse(decoded);
      } else if (segments[2] == 'seg') {
        // 兼容旧版（1.5.32）生成的清单
        final encoded = request.uri.queryParameters['u'];
        final decoded = encoded == null ? null : _decodeUrl(encoded);
        if (decoded == null) {
          response.statusCode = HttpStatus.badRequest;
          await response.close();
          return;
        }
        upstream = Uri.parse(decoded);
      } else {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      await _relay(request, response, target, upstream);
    } catch (e) {
      _record('  !! $e');
      _log('代理转发失败: $e', warn: true);
      try {
        response.statusCode = e is TimeoutException
            ? HttpStatus.gatewayTimeout
            : HttpStatus.badGateway;
        response.headers.contentType = ContentType.text;
        response.write('proxy error: $e');
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
      _record('  .. open ${uri.host}${uri.path}');
      final outbound = await _client.openUrl(request.method, uri);
      target.headers.forEach((name, value) {
        if (name.isNotEmpty && value.isNotEmpty) {
          outbound.headers.set(name, value);
        }
      });
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) outbound.headers.set(HttpHeaders.rangeHeader, range);
      outbound.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

      final current = await () async {
        try {
          return await outbound.close().timeout(const Duration(seconds: 8));
        } on TimeoutException {
          // 上游接了 TCP 却不回响应头：必须主动断开，否则播放器会一直干等
          try {
            outbound.abort();
          } catch (_) {}
          _record('  !! upstream 8s 无响应头，已中止');
          rethrow;
        }
      }();

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

    _record('  ↳ upstream ${upstreamResponse.statusCode} ${uri.path}');
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
    // 上游长时间不吐数据时主动断开，让播放器走自己的重连而不是永远干等
    var lastData = DateTime.now();
    final watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (DateTime.now().difference(lastData) > const Duration(seconds: 20)) {
        _record('  !! upstream 20s 无数据，主动断开');
        try {
          response.close();
        } catch (_) {}
      }
    });
    try {
      await for (final chunk in upstreamResponse) {
        lastData = DateTime.now();
        response.add(chunk);
      }
    } catch (e) {
      _log('代理流中断: $e', warn: true);
    } finally {
      watchdog.cancel();
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
    final bytes = utf8.encode(rewritten);

    response.statusCode = HttpStatus.ok;
    response.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    response.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
    if (request.method == 'HEAD') {
      await response.close();
      return true;
    }
    response.add(bytes);
    await response.close();
    return true;
  }

  String _rewriteHls(String text, Uri base, _ProxyTarget target) {
    final proxyBase = 'http://127.0.0.1:$port/p/${target.token}/s/';

    String toProxy(String raw, {String? forcedExtension}) {
      final resolved = base.resolve(raw.trim());
      final extension = _extensionFor(resolved.toString(), forced: forcedExtension);
      final encoded = base64Url
          .encode(utf8.encode(resolved.toString()))
          .replaceAll('=', '');
      return '$proxyBase$encoded.$extension';
    }

    final output = <String>[];
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trimRight();
      if (line.isEmpty) {
        output.add(line);
        continue;
      }
      if (line.startsWith('#')) {
        if (line.contains('URI="')) {
          final isKey = line.startsWith('#EXT-X-KEY');
          final isMap = line.startsWith('#EXT-X-MAP') ||
              line.startsWith('#EXT-X-PART') ||
              line.startsWith('#EXT-X-PRELOAD-HINT');
          final forced = isKey ? 'key' : (isMap ? 'mp4' : null);
          output.add(line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (match) => 'URI="${toProxy(match.group(1)!, forcedExtension: forced)}"',
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

  void _logDebug(String message) {
    try {
      ServiceLocator.log.d(message, tag: 'StreamProxy');
    } catch (_) {
      // ignore
    }
  }
}
