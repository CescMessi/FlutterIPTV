import 'dart:io';

/// 外部播放器（PotPlayer / mpv / VLC / 自定义）的探测与启动。
///
/// 只负责「找到可执行文件」和「拼参数」，播放本身由代理服务
/// [StreamProxyService] 提供的 127.0.0.1 地址完成。
class ExternalPlayerService {
  static const String builtin = 'builtin';
  static const String mpv = 'mpv';
  static const String potPlayer = 'potplayer';
  static const String vlc = 'vlc';
  static const String custom = 'custom';

  static const List<String> supportedKinds = [
    builtin,
    mpv,
    potPlayer,
    vlc,
    custom,
  ];

  /// 解析外部播放器可执行文件路径；找不到返回 null。
  static Future<String?> resolveExecutable(
    String kind,
    String? customPath,
  ) async {
    if (!Platform.isWindows) return null;
    switch (kind) {
      case custom:
        final path = (customPath ?? '').trim();
        if (path.isEmpty) return null;
        return File(path).existsSync() ? path : null;
      case mpv:
        return _findInPath('mpv.exe');
      case potPlayer:
        return _potPlayerExecutable();
      case vlc:
        return _vlcExecutable();
      default:
        return null;
    }
  }

  /// 拼装启动参数。`{url}` 会被替换成代理地址。
  static List<String> buildArguments(
    String kind,
    String url, {
    String? argsTemplate,
  }) {
    switch (kind) {
      case mpv:
        return [
          '--force-window=yes',
          '--keep-open=no',
          '--terminal=no',
          url,
        ];
      case vlc:
        return ['--no-video-title-show', url];
      case potPlayer:
        return [url];
      case custom:
        final template = (argsTemplate ?? '').trim();
        if (template.isEmpty) return [url];
        return template
            .split(RegExp(r'\s+'))
            .map((part) => part.replaceAll('{url}', url))
            .where((part) => part.isNotEmpty)
            .toList();
      default:
        return [url];
    }
  }

  // ==================== 探测 ====================

  static Future<String?> _potPlayerExecutable() async {
    const keys = [
      r'HKCU\Software\DAUM\PotPlayer64',
      r'HKLM\SOFTWARE\DAUM\PotPlayer64',
      r'HKCU\Software\DAUM\PotPlayer',
      r'HKLM\SOFTWARE\DAUM\PotPlayer',
    ];
    for (final key in keys) {
      final dir = await _regValue(key, 'InstallPath');
      if (dir == null) continue;
      for (final exe in const ['PotPlayerMini64.exe', 'PotPlayerMini.exe']) {
        final path = '$dir\\$exe';
        if (File(path).existsSync()) return path;
      }
    }
    for (final candidate in const [
      r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
      r'C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini.exe',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static Future<String?> _vlcExecutable() async {
    for (final key in const [
      r'HKLM\SOFTWARE\VideoLAN\VLC',
      r'HKLM\SOFTWARE\WOW6432Node\VideoLAN\VLC',
      r'HKCU\Software\VideoLAN\VLC',
    ]) {
      final dir = await _regValue(key, 'InstallDir');
      if (dir == null) continue;
      final path = '$dir\\vlc.exe';
      if (File(path).existsSync()) return path;
    }
    for (final candidate in const [
      r'C:\Program Files\VideoLAN\VLC\vlc.exe',
      r'C:\Program Files (x86)\VideoLAN\VLC\vlc.exe',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static Future<String?> _findInPath(String executable) async {
    final pathVar = Platform.environment['PATH'] ?? '';
    for (final dir in pathVar.split(';')) {
      final trimmed = dir.trim();
      if (trimmed.isEmpty) continue;
      final candidate = '$trimmed\\$executable';
      if (File(candidate).existsSync()) return candidate;
    }
    try {
      final result = await Process.run('where', [executable]);
      if (result.exitCode == 0) {
        final first = result.stdout
            .toString()
            .split(RegExp(r'\r?\n'))
            .map((line) => line.trim())
            .firstWhere((line) => line.isNotEmpty, orElse: () => '');
        if (first.isNotEmpty && File(first).existsSync()) return first;
      }
    } catch (_) {
      // ignore
    }
    return null;
  }

  static Future<String?> _regValue(String key, String valueName) async {
    try {
      final result = await Process.run('reg', ['query', key, '/v', valueName]);
      if (result.exitCode != 0) return null;
      final text = result.stdout.toString();
      final match = RegExp(
        '$valueName\\s+REG_(?:SZ|EXPAND_SZ)\\s+(.+)',
        caseSensitive: false,
      ).firstMatch(text);
      final value = match?.group(1)?.trim();
      if (value == null || value.isEmpty) return null;
      return value;
    } catch (_) {
      return null;
    }
  }
}
