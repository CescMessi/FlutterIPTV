import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math' as math;

import '../../../core/models/channel.dart';
import '../../../core/platform/platform_detector.dart';
import '../../../core/services/service_locator.dart';
import '../../../core/services/channel_test_service.dart';
import '../../../core/services/log_service.dart';

enum PlayerState {
  idle,
  loading,
  playing,
  paused,
  error,
  buffering,
}

/// 缓冲强度档位 → libmpv 直播调优参数。
///
/// 旧实现只把档位换算成 `demuxer-max-bytes`（媒体缓存上限），
/// 而真正决定「能不能扛住网络抖动」的是 `demuxer-readahead-secs`、
/// `cache-secs` 与 `stream-buffer-size`，所以三档在实机上几乎没有区别。
class _MpvTuning {
  const _MpvTuning({
    required this.demuxerMaxBytes,
    required this.readaheadSecs,
    required this.cacheSecs,
    required this.streamBufferBytes,
    required this.networkTimeoutSecs,
  });

  /// 解码缓存上限（mpv: demuxer-max-bytes）
  final int demuxerMaxBytes;

  /// demuxer 预读窗口（mpv: demuxer-readahead-secs，默认 1s）
  final int readaheadSecs;

  /// 流缓存秒数（mpv: cache-secs）
  final int cacheSecs;

  /// 网络读缓冲（mpv: stream-buffer-size，默认 128KiB）
  final int streamBufferBytes;

  /// 单次网络操作超时（mpv: network-timeout，media_kit 默认 5s）
  final int networkTimeoutSecs;

  static const Map<String, _MpvTuning> _profiles = {
    // 换台优先：预读 2s，刚好覆盖一次 CDN 抖动
    'fast': _MpvTuning(
      demuxerMaxBytes: 32 * 1024 * 1024,
      readaheadSecs: 2,
      cacheSecs: 10,
      streamBufferBytes: 1 * 1024 * 1024,
      networkTimeoutSecs: 15,
    ),
    // 平衡：预读 4s
    'balanced': _MpvTuning(
      demuxerMaxBytes: 64 * 1024 * 1024,
      readaheadSecs: 4,
      cacheSecs: 15,
      streamBufferBytes: 2 * 1024 * 1024,
      networkTimeoutSecs: 20,
    ),
    // 稳定优先：预读 8s / 缓存 30s，容忍明显抖动
    'stable': _MpvTuning(
      demuxerMaxBytes: 128 * 1024 * 1024,
      readaheadSecs: 8,
      cacheSecs: 30,
      streamBufferBytes: 4 * 1024 * 1024,
      networkTimeoutSecs: 30,
    ),
    // 低延迟（未在设置页暴露）：预读 1s
    'low_latency': _MpvTuning(
      demuxerMaxBytes: 16 * 1024 * 1024,
      readaheadSecs: 1,
      cacheSecs: 3,
      streamBufferBytes: 512 * 1024,
      networkTimeoutSecs: 10,
    ),
  };

  static _MpvTuning of(String? strength) =>
      _profiles[strength] ?? _profiles['fast']!;
}

/// Unified player provider that uses:
/// - Native Android Activity (via MethodChannel) on Android TV for best 4K performance
/// - media_kit on all other platforms (Windows, Android phone/tablet, etc.)
class PlayerProvider extends ChangeNotifier {
  // media_kit player (for all platforms except Android TV)
  Player? _mediaKitPlayer;
  VideoController? _videoController;

  // Common state
  Channel? _currentChannel;
  PlayerState _state = PlayerState.idle;
  String? _error;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  bool _isMuted = false;
  double _playbackSpeed = 1.0;
  bool _isFullscreen = false;
  bool _controlsVisible = true;
  int _volumeBoostDb = 0;
  List<AudioTrack> _audioTracks = [];
  int _currentAudioTrack = -1;
  bool _audioPassthrough = false;
  String _audioCodec = '';

  int _retryCount = 0;
  static const int _maxRetries = 2;  // 改为重试2次
  Timer? _retryTimer;
  bool _isAutoSwitching = false; // 标记是否正在自动切换源
  bool _isAutoDetecting = false; // 标记是否正在自动检测源
  bool _isSoftwareDecoding = false;
  bool _noVideoFallbackAttempted = false;
  bool _softwareFallbackUsed = false;
  bool _allowSoftwareFallback = true;
  String _windowsHwdecMode = 'auto-safe';
  bool _isDisposed = false;
  String _videoOutput = 'auto';
  String _vo = 'unknown';
  String _configuredVo = 'auto';

  // ===== 播放统计（读取 mpv 属性，用于真实掉帧 / 缓存观测） =====
  int _droppedFrames = 0; // container/解码链累计丢帧（mpv: frame-drop-count）
  int _decoderDroppedFrames = 0; // 解码器丢帧（mpv: decoder-frame-drop-count）
  double _cacheSeconds = 0; // 已缓存时长（mpv: demuxer-cache-time）
  double _liveFps = 0; // 实际输出帧率（mpv: estimated-vf-fps）
  String _statsSignature = '';

  // ===== 通知节流（避免 position 流把 UI 线程刷成每秒几十次重建） =====
  DateTime _lastPositionNotify = DateTime.fromMillisecondsSinceEpoch(0);

  // ===== mpv 日志节流（debug 级别下 mpv 每秒可吐上百行） =====
  DateTime? _mpvLogWindowStart;
  int _mpvLogWindowCount = 0;

  // ===== 临时性流错误的软重载（不重建播放器，不触发换源） =====
  Timer? _softReloadTimer;
  int _softReloadCount = 0;
  DateTime? _lastSoftReloadAt;

  // On Android TV, we use native player via Activity, so don't init any Flutter player
  // On Android phone/tablet and other platforms, use media_kit
  bool get _useNativePlayer => Platform.isAndroid && PlatformDetector.isTV;

  // Getters
  Player? get player => _mediaKitPlayer;
  VideoController? get videoController => _videoController;

  Channel? get currentChannel => _currentChannel;
  PlayerState get state => _state;
  String? get error => _error;
  Duration get position => _position;
  Duration get duration => _duration;
  double get volume => _volume;
  bool get isMuted => _isMuted;
  double get playbackSpeed => _playbackSpeed;
  bool get isFullscreen => _isFullscreen;
  bool get controlsVisible => _controlsVisible;

  List<AudioTrack> get audioTracks => _audioTracks;
  int get currentAudioTrack => _currentAudioTrack;
  bool get audioPassthrough => _audioPassthrough;
  String get audioCodec => _audioCodec;

  bool get isPlaying => _state == PlayerState.playing;
  bool get isLoading => _state == PlayerState.loading || _state == PlayerState.buffering;
  bool get hasError => _state == PlayerState.error && _error != null;

  /// Check if current content is seekable (VOD or replay)
  bool get isSeekable {
    // 1. 检查直播类型（如果明确是直播，不可拖动）
    if (_currentChannel?.isLive == true) return false;
    
    // 2. 检查直播类型（如果是点播或回放，可拖动）
    if (_currentChannel?.isSeekable == true) {
      // 但还需要检查 duration 是否有效
      if (_duration.inSeconds > 0 && _duration.inSeconds <= 86400) {
        return true;
      }
    }
    
    // 3. 检查 duration（点播内容有明确时长）
    // 直播流通常 duration 为 0 或超大值
    if (_duration.inSeconds > 0 && _duration.inSeconds <= 86400) {
      // 有效时长（1秒到24小时），但要排除直播流
      if (_currentChannel?.isLive != true) {
        return true;
      }
    }
    
    // 4. 默认不可拖动（安全起见）
    return false;
  }
  
  /// Check if should show progress bar based on settings and content
  bool shouldShowProgressBar(String progressBarMode) {
    if (progressBarMode == 'never') return false;
    if (progressBarMode == 'always') return _duration.inSeconds > 0;
    // auto mode: only show for seekable content
    return isSeekable && _duration.inSeconds > 0;
  }
  
  /// Check if current content is live stream
  bool get isLiveStream => !isSeekable;

  // 清除错误状态（用于显示错误后防止重复显示）
  void clearError() {
    _error = null;
    _errorDisplayed = true; // 标记错误已被显示，防止重复触发
    // 重置状态为 idle，避免 hasError 一直为 true
    if (_state == PlayerState.error) {
      _state = PlayerState.idle;
    }
    notifyListeners();
  }

  // 错误防抖：记录上次错误时间，避免短时间内重复触发
  DateTime? _lastErrorTime;
  String? _lastErrorMessage;
  bool _errorDisplayed = false; // 标记错误是否已被显示

  void _setError(String error) {
    ServiceLocator.log.d('PlayerProvider: _setError 被调用 - 当前重试次数: $_retryCount/$_maxRetries, 错误: $error');
    
    // 忽略 seek 相关的错误（直播流不支持 seek）
    if (error.contains('seekable') || 
        error.contains('Cannot seek') || 
        error.contains('seek in this stream')) {
      ServiceLocator.log.d('PlayerProvider: 忽略 seek 错误（直播流不支持拖动）');
      return;
    }
    
    // 忽略音频解码警告（如果还能播放声音，这只是警告）
    if (error.contains('Error decoding audio') || 
        error.contains('audio decoder') ||
        error.contains('Audio decoding')) {
      ServiceLocator.log.d('PlayerProvider: Ignore audio decode warning (likely partial frame decode failure)');
      return;
    }
    
    // 尝试自动重试（重试阶段不受防护限制）
    if (_retryCount < _maxRetries && _currentChannel != null) {
      _retryCount++;
      ServiceLocator.log.d('PlayerProvider: 播放错误，尝试重试($_retryCount/$_maxRetries): $error');
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(milliseconds: 500), () {
        if (_currentChannel != null) {
          _retryPlayback();
        }
      });
      return;
    }
    
    // 超过重试次数，检查是否有下一个源
    if (_currentChannel != null && _currentChannel!.hasMultipleSources) {
      final currentSourceIndex = _currentChannel!.currentSourceIndex;
      final totalSources = _currentChannel!.sourceCount;
      
      ServiceLocator.log.d('PlayerProvider: 当前源索引: $currentSourceIndex, 总源数: $totalSources');
      
      // 计算下一个源索引（不使用取模运算，避免循环）
      int nextIndex = currentSourceIndex + 1;
      
      // 检查下一个源是否存在
      if (nextIndex < totalSources) {
        // 下一个源存在，先检测再尝试
        ServiceLocator.log.d('PlayerProvider: 当前源(${currentSourceIndex + 1}/$totalSources) 重试失败，检测源 ${nextIndex + 1}');
        
        // 标记开始自动检测
        _isAutoDetecting = true;
        // 异步检测下一个源
        _checkAndSwitchToNextSource(nextIndex, error);
        return;
      } else {
        ServiceLocator.log.d('PlayerProvider: 已到最后一个源 (${currentSourceIndex + 1}/$totalSources), 停止尝试');
      }
    }
    
    // 没有更多源或所有源都失败，显示错误（此时才应用防抖）
    final now = DateTime.now();
    // 如果错误已经被显示过，不再设置
    if (_errorDisplayed) {
      return;
    }
    // 相同错误在30秒内不重复设置
    if (_lastErrorMessage == error && _lastErrorTime != null && now.difference(_lastErrorTime!).inSeconds < 30) {
      return;
    }
    _lastErrorMessage = error;
    _lastErrorTime = now;
    
    ServiceLocator.log.d('PlayerProvider: Playback failed, show error');
    _state = PlayerState.error;
    _error = error;
    notifyListeners();
  }
  
  
  /// 检测并切换到下一个源（用于自动切换）
  Future<void> _checkAndSwitchToNextSource(int nextIndex, String originalError) async {
    if (_currentChannel == null || !_isAutoDetecting) return; // 如果检测被取消，停止
    
    // 更新UI显示正在检测的源
    _currentChannel!.currentSourceIndex = nextIndex;
    _state = PlayerState.loading;
    notifyListeners();
    
    ServiceLocator.log.d('PlayerProvider: 检测源 ${nextIndex + 1}/${_currentChannel!.sourceCount}');
    
    final testService = ChannelTestService();
    final tempChannel = Channel(
      id: _currentChannel!.id,
      name: _currentChannel!.name,
      url: _currentChannel!.sources[nextIndex],
      groupName: _currentChannel!.groupName,
      logoUrl: _currentChannel!.logoUrl,
      sources: [_currentChannel!.sources[nextIndex]],
      playlistId: _currentChannel!.playlistId,
    );
    
    final result = await testService.testChannel(tempChannel);
    
    if (!_isAutoDetecting) return; // 检测完成后再次检查是否被取消
    
    if (!result.isAvailable) {
      ServiceLocator.log.d('PlayerProvider: 源 ${nextIndex + 1} 不可用: ${result.error}，继续尝试下一个源');
      
      // 检查是否还有更多源
      final totalSources = _currentChannel!.sourceCount;
      final nextNextIndex = nextIndex + 1;
      
      if (nextNextIndex < totalSources) {
        // 继续检测下一个源
        _checkAndSwitchToNextSource(nextNextIndex, originalError);
      } else {
        // 已到最后一个源，显示错误
        ServiceLocator.log.d('PlayerProvider: 已到最后一个源，所有源都不可用');
        _isAutoDetecting = false;
        _state = PlayerState.error;
        _error = '所有 $totalSources 个源都不可用';
        notifyListeners();
      }
      return;
    }
    
    ServiceLocator.log.d('PlayerProvider: Source ${nextIndex + 1} is available (${result.responseTime}ms), switching');
    _isAutoDetecting = false;
    _retryCount = 0; // 重置重试计数
    _isAutoSwitching = true; // 标记为自动切换
    _lastErrorMessage = null; // 重置错误消息，允许新源的错误被处理
    _playCurrentSource();
    _isAutoSwitching = false; // 重置标记
  }

  /// 重试播放当前频道
  Future<void> _retryPlayback() async {
    if (_currentChannel == null) return;
    
    ServiceLocator.log.d('PlayerProvider: 正在重试播放 ${_currentChannel!.name}, 当前源索引: ${_currentChannel!.currentSourceIndex}, 重试计数: $_retryCount');
    final startTime = DateTime.now();
    
    _state = PlayerState.loading;
    _error = null;
    notifyListeners();
    
    // 使用 currentUrl 而不是 url，以使用当前选择的源
    final url = _currentChannel!.currentUrl;
    ServiceLocator.log.d('PlayerProvider: 重试URL: $url');
    
    try {
      if (!_useNativePlayer) {
        ServiceLocator.log.i('>>> Retry: start resolving redirect', tag: 'PlayerProvider');
        // 解析真实播放地址（处理 302 重定向）
        final redirectStartTime = DateTime.now();
        
        final realUrl = await ServiceLocator.redirectCache.resolveRealPlayUrl(url);
        
        final redirectTime = DateTime.now().difference(redirectStartTime).inMilliseconds;
        ServiceLocator.log.i('>>> 重试: 302重定向解析完成，耗时: ${redirectTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log.d('>>> 重试: 使用播放地址: $realUrl', tag: 'PlayerProvider');
        
        final playStartTime = DateTime.now();
        await _mediaKitPlayer?.open(
          Media(
            realUrl,
            httpHeaders: {
              if (ServiceLocator.userAgent.userAgent != null)
                'User-Agent': ServiceLocator.userAgent.userAgent!,
            },
          ),
        );
        
        final playTime = DateTime.now().difference(playStartTime).inMilliseconds;
        final totalTime = DateTime.now().difference(startTime).inMilliseconds;
        ServiceLocator.log.i('>>> 重试: 播放器初始化完成，耗时: ${playTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log.i('>>> 重试: 总耗时: ${totalTime}ms', tag: 'PlayerProvider');
        
        _state = PlayerState.playing;
      }
      // 注意：不在这里重置 _retryCount，因为播放器可能还会异步报错
      // 重试计数会在播放真正稳定后（playing 状态持续一段时间）或切换频道时重置
      ServiceLocator.log.d('PlayerProvider: Retry command sent');
    } catch (e) {
      final totalTime = DateTime.now().difference(startTime).inMilliseconds;
      ServiceLocator.log.d('PlayerProvider: 重试失败 (${totalTime}ms): $e');
      // 重试失败，继续尝试或显示错误
      _setError('Failed to play channel: $e');
    }
    notifyListeners();
  }

  String _hwdecMode = 'unknown';
  String _videoCodec = '';
  double _fps = 0;
  
  // 保存初始化时的 hwdec 配置
  String _configuredHwdec = 'unknown';
  
  // FPS 显示
  double _currentFps = 0;
  
  // 视频信息
  int _videoWidth = 0;
  int _videoHeight = 0;
  double _downloadSpeed = 0; // bytes per second

  double get currentFps => _currentFps;
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;
  double get downloadSpeed => _downloadSpeed;
  int get droppedFrames => _droppedFrames;
  int get decoderDroppedFrames => _decoderDroppedFrames;
  double get cacheSeconds => _cacheSeconds;

  String get videoInfo {
    if (_mediaKitPlayer == null) return '';
    final w = _mediaKitPlayer!.state.width;
    final h = _mediaKitPlayer!.state.height;
    if (w == 0 || h == 0) return '';
    final parts = <String>['${w}x$h'];
    if (_videoCodec.isNotEmpty) parts.add(_videoCodec);
    if (_fps > 0) parts.add('${_fps.toStringAsFixed(1)} fps');
    final hwdecInfo = _formatHwdecInfo();
    if (hwdecInfo.isNotEmpty) {
      parts.add('hwdec: $hwdecInfo');
    }
    final voInfo = _formatVoInfo();
    if (voInfo.isNotEmpty) {
      parts.add('vo: $voInfo');
    }
    if (_droppedFrames > 0 || _decoderDroppedFrames > 0) {
      parts.add('drop: $_droppedFrames/$_decoderDroppedFrames');
    }
    if (_cacheSeconds > 0) {
      parts.add('cache: ${_cacheSeconds.toStringAsFixed(1)}s');
    }
    return parts.join(' | ');
  }

  double get progress {
    if (_duration.inMilliseconds == 0) return 0;
    return _position.inMilliseconds / _duration.inMilliseconds;
  }

  PlayerProvider() {
    _initPlayer();
  }

  void _initPlayer({bool useSoftwareDecoding = false}) {
    // On Android TV, we use native player - don't initialize any Flutter player
    if (_useNativePlayer) {
      return;
    }

    // 其他平台（包括 Android 手机）都使用 media_kit
    _initMediaKitPlayer(useSoftwareDecoding: useSoftwareDecoding);
  }
  
  /// 预热播放器 - 在应用启动时调用,提前初始化播放器资源
  /// 这样首次进入播放页面时就不会卡顿
  Future<void> warmup() async {
    if (_useNativePlayer) {
      return; // 原生播放器不需要预热
    }
    
    if (_mediaKitPlayer == null) {
      ServiceLocator.log.d('PlayerProvider: 预热播放器 - 初始化 media_kit', tag: 'PlayerProvider');
      _initMediaKitPlayer();
    }
    
    // 使用空 Media 预热会触发错误回调，可能导致首次播放黑屏/蓝屏
    // 目前只做实例初始化，不做无效流程预加载
  }

  void _initMediaKitPlayer(
      {bool useSoftwareDecoding = false, String? bufferStrength}) {
    _mediaKitPlayer?.dispose();
    _debugInfoTimer?.cancel();
    // Load decoding settings (overridden by explicit useSoftwareDecoding)
    final prefs = ServiceLocator.prefs;
    final decodingMode = prefs.getString('decoding_mode') ?? 'auto';
    _windowsHwdecMode = prefs.getString('windows_hwdec_mode') ?? 'auto-safe';
    _allowSoftwareFallback = prefs.getBool('allow_software_fallback') ?? true;
    _videoOutput = prefs.getString('video_output') ?? 'auto';
    final effectiveSoftware = useSoftwareDecoding || decodingMode == 'software';
    _isSoftwareDecoding = effectiveSoftware;

    // 启动时必须使用用户保存的缓冲强度；此前只有从设置页切换时才会传入，
    // 导致「稳定优先(128MB)」重启后又变回 fast(32MB)。
    final resolvedStrength =
        bufferStrength ?? prefs.getString('buffer_strength') ?? 'fast';
    final tuning = _MpvTuning.of(resolvedStrength);

    ServiceLocator.log.i('========== 初始化播放器 ==========', tag: 'PlayerProvider');
    ServiceLocator.log.i('平台: ${Platform.operatingSystem}', tag: 'PlayerProvider');
    ServiceLocator.log.i('软解码模式: $useSoftwareDecoding', tag: 'PlayerProvider');
    ServiceLocator.log.i('缓冲强度: $resolvedStrength', tag: 'PlayerProvider');

    final bufferSize = tuning.demuxerMaxBytes;

    String? vo;
    switch (_videoOutput) {
      case 'gpu':
        vo = 'gpu';
        break;
      case 'libmpv':
        vo = 'libmpv';
        break;
      case 'auto':
      default:
        vo = null;
        break;
    }
    _configuredVo = _videoOutput;

    _mediaKitPlayer = Player(
      configuration: PlayerConfiguration(
        bufferSize: bufferSize,
        vo: vo,
        // 设置网络超时（可选）
        // timeout: 3 秒连接最长超时
        // 根据日志级别启用 mpv 日志
        logLevel: ServiceLocator.log.currentLevel == LogLevel.debug
            ? MPVLogLevel.debug
            : (ServiceLocator.log.currentLevel == LogLevel.off
                ? MPVLogLevel.error
                : MPVLogLevel.info),
      ),
    );

    // 确畾确欢视ｇ爜妯″紡
    String? hwdecMode;
    if (Platform.isAndroid) {
      hwdecMode = effectiveSoftware ? 'no' : 'mediacodec';
    } else if (Platform.isWindows) {
      if (effectiveSoftware) {
        hwdecMode = 'no';
      } else {
        switch (_windowsHwdecMode) {
          case 'auto-copy':
            hwdecMode = 'auto-copy';
            break;
          case 'd3d11va':
            hwdecMode = 'd3d11va';
            break;
          case 'dxva2':
            hwdecMode = 'dxva2';
            break;
          case 'auto-safe':
          default:
            hwdecMode = 'auto-safe';
            break;
        }
      }
    }

    _configuredHwdec = hwdecMode ?? 'default';
    ServiceLocator.log.i('硬件解码模式: ${hwdecMode ?? "默认"}', tag: 'PlayerProvider');
    ServiceLocator.log.i('确欢加犻€? ${!effectiveSoftware}', tag: 'PlayerProvider');

    VideoControllerConfiguration config = VideoControllerConfiguration(
      hwdec: hwdecMode,
      enableHardwareAcceleration: !effectiveSoftware,
    );

    // 默认显示为配置值，后续可被实际运行时覆盖
    _hwdecMode = effectiveSoftware ? 'no' : _configuredHwdec;
    _vo = vo ?? 'auto';

    _videoController = VideoController(_mediaKitPlayer!, configuration: config);
    _setupMediaKitListeners();

    // IPTV 直播流缓存 / 超时 / 重连参数：media_kit 的默认值对直播偏激进
    // （network-timeout=5s、仅 1s 预读、开启磁盘缓存）。
    unawaited(_applyStreamTuning(tuning));

    // Force audio to stereo for multi-channel streams (e.g. E-AC-3 5.1).
    // Two-level approach:
    // 1. ad-lavc-downmix=yes: forces FFmpeg decoder-level downmix (bypasses
    //    audio chain bugs on some Android devices with OpenSL ES).
    // 2. audio-channels=stereo: tells mpv's audio chain to output stereo
    //    (safety net in case decoder-level downmix doesn't apply).
    // 3. audio-format=s16: forces 16-bit PCM output compatible with all
    //    Android audio drivers.
    if (Platform.isAndroid) {
      final player = _mediaKitPlayer!;
      Future(() async {
        try {
          await (player.platform as dynamic)
              .setProperty('ad-lavc-downmix', 'yes');
          ServiceLocator.log.i('ad-lavc-downmix=yes 已设置', tag: 'PlayerProvider');
        } catch (e) {
          ServiceLocator.log.d('设置 ad-lavc-downmix 失败: $e', tag: 'PlayerProvider');
        }
        try {
          await (player.platform as dynamic)
              .setProperty('audio-channels', 'stereo');
          ServiceLocator.log.i('audio-channels=stereo 已设置', tag: 'PlayerProvider');
        } catch (e) {
          ServiceLocator.log.d('设置 audio-channels 失败: $e', tag: 'PlayerProvider');
        }
        try {
          await (player.platform as dynamic)
              .setProperty('audio-format', 's16');
          ServiceLocator.log.i('audio-format=s16 已设置', tag: 'PlayerProvider');
        } catch (e) {
          ServiceLocator.log.d('设置 audio-format 失败: $e', tag: 'PlayerProvider');
        }
      });
    }

    _updateDebugInfo();

    ServiceLocator.log.i('播放器初始化完成', tag: 'PlayerProvider');
  }

  /// 给 libmpv 下发直播流相关的缓存 / 超时参数。
  ///
  /// media_kit 在创建播放器时会写入一组固定值：
  ///   cache=yes, cache-on-disk=yes, network-timeout=5,
  ///   demuxer-max-bytes=<bufferSize>, demuxer-max-back-bytes=<bufferSize>
  /// 其中磁盘缓存失败后（"Failed to create file cache."）会退化成 128KiB 流缓冲，
  /// 而 5s 网络超时对抖动较大的 IPTV 源过于激进，因此这里逐项覆盖。
  Future<void> _applyStreamTuning(_MpvTuning tuning) async {
    final player = _mediaKitPlayer;
    if (player == null) return;

    final properties = <String, String>{
      // 直播不需要磁盘缓存：磁盘 I/O 抖动 + 创建失败后会丢失缓存能力
      'cache-on-disk': 'no',
      // 只保留少量回退缓存，避免 128MB × 2 的内存占用
      'demuxer-max-back-bytes': '${tuning.demuxerMaxBytes ~/ 4}',
      // 真正的预读窗口（demuxer-max-bytes 只是上限，不设这里仍然只有 1s）
      'demuxer-readahead-secs': '${tuning.readaheadSecs}',
      'cache-secs': '${tuning.cacheSecs}',
      // 默认流缓冲 128KiB，突然的 CDN/组播抖动就会直接饿死
      'stream-buffer-size': '${tuning.streamBufferBytes}',
      'network-timeout': '${tuning.networkTimeoutSecs}',
      // 说明：http/https 的断流重连交给应用层软重载处理
      // （_scheduleSoftReload）。这里不写 stream-lavf-o，
      // 避免把 http 专用选项传给 udp/rtp/rtsp 源导致打开失败。
    };

    for (final entry in properties.entries) {
      try {
        await (player.platform as dynamic)
            .setProperty(entry.key, entry.value);
        ServiceLocator.log.d('mpv 参数: ${entry.key}=${entry.value}',
            tag: 'PlayerProvider');
      } catch (e) {
        ServiceLocator.log.d('mpv 参数设置失败 ${entry.key}=${entry.value}: $e',
            tag: 'PlayerProvider');
      }
    }
  }

  void _setupMediaKitListeners() {
    ServiceLocator.log.d('设置播放器监听器', tag: 'PlayerProvider');
    
    // 只有在日志关闭时才完成 mpv 日志
      if (ServiceLocator.log.currentLevel != LogLevel.off) {
        _mediaKitPlayer!.stream.log.listen((log) {
          final message = log.text.toLowerCase();
          final isError = log.level == 'error';
          final isWarn = log.level == 'warn';

          // 1) 限速：debug 级别下 mpv 每秒可输出上百行，逐行转发 + 落盘会拖慢主 isolate
          final now = DateTime.now();
          if (_mpvLogWindowStart == null ||
              now.difference(_mpvLogWindowStart!) >=
                  const Duration(seconds: 1)) {
            _mpvLogWindowStart = now;
            _mpvLogWindowCount = 0;
          }
          _mpvLogWindowCount++;

          // 2) 超长行（GL 扩展列表、解码器 GUID 列表）截断，避免反复写几 KB
          final text = log.text.length > 400
              ? '${log.text.substring(0, 400)}…'
              : log.text;

          if (!isError && !isWarn && _mpvLogWindowCount > 30) {
            return; // 超出窗口配额的普通日志直接丢弃
          }

          ServiceLocator.log.d('MPV log: $text', tag: 'PlayerProvider');

          // 3) 只在真正相关的行上做识别，避免每行跑 4 条 contains 链
          if (message.contains('using hardware decoding')) {
            _updateHwdecFromLog(message);
            ServiceLocator.log.i('使用硬件解码: $text', tag: 'PlayerProvider');
          } else if (message.contains('vo:') ||
              message.contains('video output')) {
            _updateVoFromLog(message);
          } else if (message.contains('software decoding')) {
            _updateHwdecFromLog(message);
          }

          // 记录错误和警告
          if (isError) {
            ServiceLocator.log.e('MPV错误: $text', tag: 'PlayerProvider');
          } else if (isWarn) {
            ServiceLocator.log.w('MPV警告: $text', tag: 'PlayerProvider');
          }
        });
      }
    
    _mediaKitPlayer!.stream.playing.listen((playing) {
      ServiceLocator.log.d('播放状态变化: playing=$playing', tag: 'PlayerProvider');
      if (playing) {
        _state = PlayerState.playing;
        // 只有在播放稳定后才重置重试计数
        // 使用延迟确保播放真正开始，而不是短暂的状态变化
        Future.delayed(const Duration(seconds: 3), () {
          if (_state == PlayerState.playing && _currentChannel != null) {
            ServiceLocator.log.d('PlayerProvider: Playback stable, reset retry count');
            _retryCount = 0;
            _softReloadCount = 0; // 连续稳定 3s 后重置软重载配额
          }
        });
      } else if (_state == PlayerState.playing) {
        _state = PlayerState.paused;
      }
      notifyListeners();
    });

    _mediaKitPlayer!.stream.buffering.listen((buffering) {
      ServiceLocator.log.d('缓冲状态: buffering=$buffering', tag: 'PlayerProvider');
      if (buffering && _state != PlayerState.idle && _state != PlayerState.error) {
        _state = PlayerState.buffering;
      } else if (!buffering && _state == PlayerState.buffering) {
        _state = _mediaKitPlayer!.state.playing ? PlayerState.playing : PlayerState.paused;
      }
      notifyListeners();
    });

    _mediaKitPlayer!.stream.position.listen((pos) {
      if (pos == _position) return;
      final previous = _position;
      _position = pos;
      final now = DateTime.now();
      // 进度条 250ms 粒度足够；seek / 换源造成的跳变立即通知
      final isJump = (pos - previous).abs() > const Duration(seconds: 2);
      if (isJump ||
          now.difference(_lastPositionNotify) >=
              const Duration(milliseconds: 250)) {
        _lastPositionNotify = now;
        notifyListeners();
      }
    });

    _mediaKitPlayer!.stream.duration.listen((dur) {
      if (dur == _duration) return;
      _duration = dur;
      notifyListeners();
    });
    
    _mediaKitPlayer!.stream.tracks.listen((tracks) {
      ServiceLocator.log.d('轨道信息更新: 视频轨${tracks.video.length}, 音频轨${tracks.audio.length}', tag: 'PlayerProvider');
      
      for (final track in tracks.video) {
        if (track.codec != null) {
          _videoCodec = track.codec!;
          ServiceLocator.log.i('视频编码: ${track.codec}', tag: 'PlayerProvider');
        }
        if (track.fps != null) {
          _fps = track.fps!;
          ServiceLocator.log.i('视频帧率: ${track.fps} fps', tag: 'PlayerProvider');
        }
        if (track.w != null && track.h != null) {
          ServiceLocator.log.i('视频分辨率: ${track.w}x${track.h}', tag: 'PlayerProvider');
        }
      }
      
      _audioTracks = tracks.audio;
      if (tracks.audio.isNotEmpty && _currentAudioTrack < 0) {
        _currentAudioTrack = 0;
      }
      for (final track in tracks.audio) {
        if (track.codec != null) {
          _audioCodec = track.codec!;
          ServiceLocator.log.i('音频编码: ${track.codec}', tag: 'PlayerProvider');
        }
      }
      
      notifyListeners();
    });
    
    _mediaKitPlayer!.stream.volume.listen((vol) {
      final nextVolume = vol / 100;
      if ((nextVolume - _volume).abs() < 0.005) return;
      _volume = nextVolume;
      notifyListeners();
    });
    
    _mediaKitPlayer!.stream.error.listen((err) {
      if (err.isNotEmpty) {
        // 临时性网络 / 缓存错误：软重载同一个 URL，不重建播放器、不换源、不弹错误。
        // 旧逻辑会走 _setError → 重试 2 次 → 换源 → 重建播放器，
        // 一次 1s 的网络抖动会被放大成数秒黑屏。
        if (_isTransientStreamError(err)) {
          ServiceLocator.log.w('检测到临时性流错误，软重载当前源: $err',
              tag: 'PlayerProvider');
          _scheduleSoftReload(err);
          return;
        }
        ServiceLocator.log.e('播放器错误: $err', tag: 'PlayerProvider');
        
        // 分析错误类型
        if (err.toLowerCase().contains('decode') || err.toLowerCase().contains('decoder')) {
          ServiceLocator.log.e('>>> 解码错误: $err', tag: 'PlayerProvider');
        } else if (err.toLowerCase().contains('render') || err.toLowerCase().contains('display')) {
          ServiceLocator.log.e('>>> 网络错误: $err', tag: 'PlayerProvider');
        } else if (err.toLowerCase().contains('hwdec') || err.toLowerCase().contains('hardware')) {
          ServiceLocator.log.e('>>> 确欢加犻€熼敊璇? $err', tag: 'PlayerProvider');
        } else if (err.toLowerCase().contains('codec')) {
          ServiceLocator.log.e('>>> 解码器错误: $err', tag: 'PlayerProvider');
        }
        
        if (_shouldTrySoftwareFallback(err)) {
          ServiceLocator.log.w('宽濊瘯轨В素佸洖退', tag: 'PlayerProvider');
          _attemptSoftwareFallback();
        } else {
          _setError(err);
        }
      }
    });
    
    _mediaKitPlayer!.stream.width.listen((width) {
      final nextWidth = width ?? 0;
      if (nextWidth == _videoWidth) return;
      _videoWidth = nextWidth;
      if (width != null && width > 0) {
        ServiceLocator.log.d('视嗛瀹藉害: $width', tag: 'PlayerProvider');
      }
      notifyListeners();
    });
    
    _mediaKitPlayer!.stream.height.listen((height) {
      final nextHeight = height ?? 0;
      if (nextHeight == _videoHeight) return;
      _videoHeight = nextHeight;
      if (height != null && height > 0) {
        ServiceLocator.log.d('视嗛高樺害: $height', tag: 'PlayerProvider');
      }
      notifyListeners();
    });
  }

  Timer? _debugInfoTimer;
  
  void _updateDebugInfo() {
    _debugInfoTimer?.cancel();
    
    _debugInfoTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_mediaKitPlayer == null) return;

      // 读取 mpv 的真实统计（掉帧 / 缓存 / 实际输出帧率），
      // 让「卡顿」可以被量化，而不是只看容器帧率。
      await _refreshMpvStats();
      
      // 如果线程未开启或尚未解析到实际值，使用配置值兜底
      if (ServiceLocator.log.currentLevel == LogLevel.off &&
          (_hwdecMode == 'unknown' || _hwdecMode.isEmpty)) {
        _hwdecMode = _configuredHwdec;
      }
      
      // 更存柊视嗛宽哄
      final newWidth = _mediaKitPlayer!.state.width ?? 0;
      final newHeight = _mediaKitPlayer!.state.height ?? 0;
      
      // 检测视频尺寸变化（可能表示解码成功）
      if (newWidth != _videoWidth || newHeight != _videoHeight) {
        if (newWidth > 0 && newHeight > 0) {
          ServiceLocator.log.i('鉁?视嗛视ｇ爜鎴愬姛: ${newWidth}x${newHeight}', tag: 'PlayerProvider');
        } else if (_videoWidth > 0 && newWidth == 0) {
          ServiceLocator.log.w('鉁?视嗛视ｇ爜个㈠け', tag: 'PlayerProvider');
        }
      }
      
      _videoWidth = newWidth;
      _videoHeight = newHeight;
      
      // Windows 端直接使用 track 中的 fps 信息
      // media_kit (mpv) 的勬覆查撳抚率囧熀帧瓑浜庤棰戞簮甯х巼
      if (_state == PlayerState.playing) {
        // 优先使用 mpv 的实际输出帧率（estimated-vf-fps），没有统计值时退回容器帧率
        _currentFps = _liveFps > 0 ? _liveFps : _fps;
      } else {
        _currentFps = 0;
      }
      
      // 预扮畻个嬭浇閫熷害 - 鍩轰簬视嗛分嗚鲸率囧拰甯х巼
      // media_kit 没有直接的下载速度 API，使用视频参数估算
      if (_state == PlayerState.playing && _videoWidth > 0 && _videoHeight > 0) {
        final pixels = _videoWidth * _videoHeight;
        final fps = _fps > 0 ? _fps : 25.0;
        // 预扮畻全紡锛氬儚绱犳暟 * 甯х巼 * 压嬬缉绯绘暟 (H.264/H.265 全稿瀷压嬬缉姣?
        // 1080p@30fps 绾?3-8 Mbps, 4K@30fps 绾?15-25 Mbps
        double compressionFactor;
        if (pixels >= 3840 * 2160) {
          compressionFactor = 0.04; // 4K
        } else if (pixels >= 1920 * 1080) {
          compressionFactor = 0.06; // 1080p
        } else if (pixels >= 1280 * 720) {
          compressionFactor = 0.08; // 720p
        } else {
          compressionFactor = 0.10; // SD
        }
        final estimatedBitrate = pixels * fps * compressionFactor; // bits per second
        _downloadSpeed = estimatedBitrate / 8.0; // bytes per second
      } else {
        _downloadSpeed = 0;
      }
      
      // 只在统计值真的变化时通知，避免每秒无条件重建一次 UI
      final signature = '${_videoWidth}x$_videoHeight|$_videoCodec|$_fps|'
          '${_liveFps.toStringAsFixed(1)}|$_droppedFrames|'
          '$_decoderDroppedFrames|${_cacheSeconds.toStringAsFixed(1)}|'
          '${_hwdecMode}|${_vo}|${_state.index}';
      if (signature != _statsSignature) {
        _statsSignature = signature;
        notifyListeners();
      }
    });
  }

  /// 读取 mpv 真实统计属性；失败时静默保留旧值。
  Future<void> _refreshMpvStats() async {
    final player = _mediaKitPlayer;
    if (player == null) return;
    final dynamic platform = player.platform;

    Future<double?> readDouble(String property) async {
      try {
        final raw = (await platform.getProperty(property)).toString();
        if (raw.isEmpty || raw == 'no' || raw == 'nan') return null;
        return double.tryParse(raw);
      } catch (_) {
        return null;
      }
    }

    final vfFps = await readDouble('estimated-vf-fps');
    if (vfFps != null) _liveFps = vfFps;

    final dropped = await readDouble('frame-drop-count');
    if (dropped != null) _droppedFrames = dropped.round();

    final decoderDropped = await readDouble('decoder-frame-drop-count');
    if (decoderDropped != null) _decoderDroppedFrames = decoderDropped.round();

    final cache = await readDouble('demuxer-cache-time');
    _cacheSeconds = cache ?? 0;
  }

  void _updateHwdecFromLog(String lowerMessage) {
    String? detected;

    // e.g. "Using hardware decoding (d3d11va-copy)"
    final hwdecMatch =
        RegExp(r'using hardware decoding\s*\(([^)]+)\)').firstMatch(lowerMessage);
    if (hwdecMatch != null) {
      detected = hwdecMatch.group(1);
    }

    // e.g. "hwdec=auto", "hwdec: d3d11va"
    final hwdecKeyMatch =
        RegExp(r'hwdec(?:-current)?\s*[:=]\s*([\w\-]+)')
            .firstMatch(lowerMessage);
    if (detected == null && hwdecKeyMatch != null) {
      detected = hwdecKeyMatch.group(1);
    }

    if (detected == null && lowerMessage.contains('software decoding')) {
      detected = 'no';
    }

    if (detected != null && detected.isNotEmpty && detected != _hwdecMode) {
      _hwdecMode = detected;
      notifyListeners();
    }
  }

  void _updateVoFromLog(String lowerMessage) {
    String? detected;

    // e.g. "VO: [gpu] 1920x1080"
    final voMatch = RegExp(r'vo:\s*\[?([a-z0-9_\-]+)\]?').firstMatch(lowerMessage);
    if (voMatch != null) {
      detected = voMatch.group(1);
    }

    // e.g. "Using video output driver: gpu"
    final driverMatch =
        RegExp(r'video output driver:\s*([a-z0-9_\-]+)').firstMatch(lowerMessage);
    if (detected == null && driverMatch != null) {
      detected = driverMatch.group(1);
    }

    if (detected != null && detected.isNotEmpty && detected != _vo) {
      _vo = detected;
      notifyListeners();
    }
  }

  String _formatHwdecInfo() {
    final configured = _configuredHwdec.trim();
    final actual = _hwdecMode.trim();
    if (configured.isEmpty || configured == 'unknown') {
      return actual == 'unknown' ? '' : actual;
    }
    if (actual.isEmpty || actual == 'unknown' || actual == configured) {
      return configured;
    }
    return '$configured -> $actual';
  }

  String _formatVoInfo() {
    final configured = _configuredVo.trim();
    final actual = _vo.trim();
    if (configured.isEmpty || configured == 'unknown') {
      return actual == 'unknown' ? '' : actual;
    }
    if (actual.isEmpty || actual == 'unknown' || actual == configured) {
      return configured;
    }
    return '$configured -> $actual';
  }

  bool _shouldTrySoftwareFallback(String error) {
    final lowerError = error.toLowerCase();
    if (!_allowSoftwareFallback) return false;
    return (lowerError.contains('codec') ||
            lowerError.contains('decoder') ||
            lowerError.contains('hwdec') ||
            lowerError.contains('mediacodec')) &&
        _retryCount < _maxRetries;
  }

  void _attemptSoftwareFallback() {
    if (!_allowSoftwareFallback) return;
    if (_isDisposed) return;
    if (_softwareFallbackUsed) return; // 一次播放只回退一次，避免反复重建播放器
    _softwareFallbackUsed = true;
    _softReloadTimer?.cancel();
    _retryCount++;
    final channelToPlay = _currentChannel;
    _initMediaKitPlayer(useSoftwareDecoding: true);
    if (channelToPlay != null) playChannel(channelToPlay);
  }

  /// 是否是「等一下重连就能好」的临时性错误（网络抖动、取流超时、缓存饿死）。
  /// 这类错误不应该触发换源 / 重建播放器。
  bool _isTransientStreamError(String message) {
    final m = message.toLowerCase();
    const fatalMarkers = [
      '404',
      '403',
      '401',
      'not found',
      'forbidden',
      'unsupported',
      'no video',
      'invalid data',
      'unknown format',
    ];
    if (fatalMarkers.any(m.contains)) return false;
    const transientMarkers = [
      'timed out',
      'timeout',
      'connection',
      'reset by peer',
      'network',
      'cache',
      'stalled',
      'i/o error',
      'end of file',
      'http error 5',
    ];
    return transientMarkers.any(m.contains);
  }

  /// 软重载：保留播放器实例与渲染管线，只重新打开当前 URL。
  void _scheduleSoftReload(String reason) {
    if (_isDisposed || _currentChannel == null) return;
    if (_softReloadTimer?.isActive == true) return;

    final now = DateTime.now();
    final tooMany = _softReloadCount >= 3 &&
        _lastSoftReloadAt != null &&
        now.difference(_lastSoftReloadAt!).inSeconds < 60;
    if (tooMany) {
      // 60s 内已软重载 3 次，交给硬错误链路（重试 / 换源 / 提示）
      _softReloadCount = 0;
      ServiceLocator.log.w('软重载过于频繁，转入硬错误处理: $reason',
          tag: 'PlayerProvider');
      _setError(reason);
      return;
    }

    _softReloadCount++;
    _lastSoftReloadAt = now;
    _state = PlayerState.buffering;
    notifyListeners();

    _softReloadTimer = Timer(const Duration(milliseconds: 1500), () async {
      final channel = _currentChannel;
      if (_isDisposed || channel == null) return;
      try {
        final realUrl = await ServiceLocator.redirectCache
            .resolveRealPlayUrl(channel.currentUrl);
        await _mediaKitPlayer?.open(
          Media(
            realUrl,
            httpHeaders: {
              if (ServiceLocator.userAgent.userAgent != null)
                'User-Agent': ServiceLocator.userAgent.userAgent!,
            },
          ),
        );
        ServiceLocator.log.i('软重载完成: $realUrl', tag: 'PlayerProvider');
      } catch (e) {
        ServiceLocator.log.w('软重载失败: $e', tag: 'PlayerProvider');
        _setError('软重载失败: $e');
      }
    });
  }

  // ============ Public API ============

  Future<void> playChannel(Channel channel, {bool preserveCurrentSource = false}) async {
    ServiceLocator.log.i('========== 开始嬫挱设鹃道==========', tag: 'PlayerProvider');
    ServiceLocator.log.i('棰戦亾: ${channel.name} (ID: ${channel.id})', tag: 'PlayerProvider');
    ServiceLocator.log.d('URL: ${channel.url}', tag: 'PlayerProvider');
    ServiceLocator.log.d('源数量 ${channel.sourceCount}', tag: 'PlayerProvider');
    final playStartTime = DateTime.now();
    
    _currentChannel = channel;
    _state = PlayerState.loading;
    _error = null;
    _lastErrorMessage = null; // 重置错误防抖
    _errorDisplayed = false; // 重置错误显示标记
    _retryCount = 0; // 重置重试计数
    _retryTimer?.cancel(); // 取消任何正在进行的重试
    _isAutoDetecting = false; // 取消任何正在进行的自动检测
    _noVideoFallbackAttempted = false;
    _softwareFallbackUsed = false;
    _softReloadTimer?.cancel();
    _softReloadTimer = null;
    _softReloadCount = 0;
    _statsSignature = '';
    loadVolumeSettings(); // Apply volume boost settings
    notifyListeners();

    // 如果有多个源，先检测找到第一个可用的源
    if (channel.hasMultipleSources && !preserveCurrentSource) {
      ServiceLocator.log.i('频道有 ${channel.sourceCount} 个源，开始检测可用源', tag: 'PlayerProvider');
      final detectStartTime = DateTime.now();

      final availableSourceIndex = await _findFirstAvailableSource(channel);

      final detectTime = DateTime.now().difference(detectStartTime).inMilliseconds;

      if (availableSourceIndex != null) {
        channel.currentSourceIndex = availableSourceIndex;
        ServiceLocator.log.i('找到可用源 ${availableSourceIndex + 1}/${channel.sourceCount}，检测耗时: ${detectTime}ms', tag: 'PlayerProvider');
      } else {
        ServiceLocator.log.e('所有 ${channel.sourceCount} 个源都不可用，检测耗时: ${detectTime}ms', tag: 'PlayerProvider');
        _setError('所有 ${channel.sourceCount} 个源均不可用');
        return;
      }
    } else if (channel.hasMultipleSources) {
      channel.currentSourceIndex =
          channel.currentSourceIndex.clamp(0, channel.sourceCount - 1);
      ServiceLocator.log.d('PlayerProvider: preserveCurrentSource=true, using source ${channel.currentSourceIndex + 1}/${channel.sourceCount}');
    }

    final playUrl = channel.currentUrl;
    ServiceLocator.log.d('准备播放URL: $playUrl', tag: 'PlayerProvider');

    try {
      final playerInitStartTime = DateTime.now();
      
      // Android TV 使用原生播放器，通过 MethodChannel 处理
      // 其他平台（包括 Android 手机）都使用 media_kit
      if (!_useNativePlayer) {
        // 解析真实播放地址（处理 302 重定向）
        ServiceLocator.log.i('>>> Start resolving redirect', tag: 'PlayerProvider');
        final redirectStartTime = DateTime.now();
        
        final realUrl = await ServiceLocator.redirectCache.resolveRealPlayUrl(playUrl);
        
        final redirectTime = DateTime.now().difference(redirectStartTime).inMilliseconds;
        ServiceLocator.log.i('>>> 302重定向解析完成，耗时: ${redirectTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log.d('>>> 使用播放地址: $realUrl', tag: 'PlayerProvider');
        
        // 开始播放
        ServiceLocator.log.i('>>> Start initializing player', tag: 'PlayerProvider');
        final playStartTime = DateTime.now();

        await _mediaKitPlayer?.open(
          Media(
            realUrl,
            httpHeaders: {
              if (ServiceLocator.userAgent.userAgent != null)
                'User-Agent': ServiceLocator.userAgent.userAgent!,
            },
          ),
        );

        final playTime = DateTime.now().difference(playStartTime).inMilliseconds;
        ServiceLocator.log.i('>>> 播放器初始化完成，耗时: ${playTime}ms', tag: 'PlayerProvider');
        
        _state = PlayerState.playing;
        notifyListeners();
        _scheduleNoVideoFallbackIfNeeded();
      }
      
      // 记录观看历史
      final channelId = channel.id;
      final playlistId = channel.playlistId;
      if (channelId != null && playlistId != null) {
        await ServiceLocator.watchHistory.addWatchHistory(channelId, playlistId);
      }
      
      final playerInitTime = DateTime.now().difference(playerInitStartTime).inMilliseconds;
      final totalTime = DateTime.now().difference(playStartTime).inMilliseconds;
      ServiceLocator.log.i('>>> 播放流程总耗时: ${totalTime}ms (播放器初始化: ${playerInitTime}ms)', tag: 'PlayerProvider');
      ServiceLocator.log.i('========== 频道播放总耗时: ${totalTime}ms ==========', tag: 'PlayerProvider');
    } catch (e) {
      ServiceLocator.log.e('播放频道失败', tag: 'PlayerProvider', error: e);
      _setError('Failed to play channel: $e');
      return;
    }
  }

  Future<void> reinitializePlayer({required String bufferStrength}) async {
    if (_useNativePlayer) return;
    final channelToPlay = _currentChannel;
    _state = PlayerState.loading;
    notifyListeners();
    _initMediaKitPlayer(bufferStrength: bufferStrength);
    if (channelToPlay != null) {
      await playChannel(channelToPlay);
    }
  }

  /// 查找第一个可用的源
  Future<int?> _findFirstAvailableSource(Channel channel) async {
    ServiceLocator.log.d('开始检测第${channel.sourceCount} 个源', tag: 'PlayerProvider');
    final testService = ChannelTestService();
    
    for (int i = 0; i < channel.sourceCount; i++) {
      // 更新UI显示当前检测的源
      channel.currentSourceIndex = i;
      notifyListeners();
      
      // 创建临时频道对象用于测试
      final tempChannel = Channel(
        id: channel.id,
        name: channel.name,
        url: channel.sources[i],
        groupName: channel.groupName,
        logoUrl: channel.logoUrl,
        sources: [channel.sources[i]], // 只测试当前源
        playlistId: channel.playlistId,
      );
      
      ServiceLocator.log.d('检测源 ${i + 1}/${channel.sourceCount}', tag: 'PlayerProvider');
      final testStartTime = DateTime.now();
      
      final result = await testService.testChannel(tempChannel);
      final testTime = DateTime.now().difference(testStartTime).inMilliseconds;
      
      if (result.isAvailable) {
        ServiceLocator.log.i('源${i + 1} 可用，响应时间: ${result.responseTime}ms，检测耗时: ${testTime}ms', tag: 'PlayerProvider');
        return i;
      } else {
        ServiceLocator.log.w('✗ 源 ${i + 1} 不可用: ${result.error}，检测耗时: ${testTime}ms', tag: 'PlayerProvider');
      }
    }
    
    ServiceLocator.log.e('所有${channel.sourceCount} 个源都不可用', tag: 'PlayerProvider');
    return null; // 所有源都不可用
  }

  Future<void> playUrl(String url, {String? name}) async {
    // Android TV 使用原生播放器，不支持此方法
    if (_useNativePlayer) {
      ServiceLocator.log.w('playUrl: Android TV 使用原生播放器，不支持此方法', tag: 'PlayerProvider');
      return;
    }
    
    final startTime = DateTime.now();
    _state = PlayerState.loading;
    _error = null;
    _lastErrorMessage = null; // 重置错误防抖
    _errorDisplayed = false; // 重置错误显示标记
    _noVideoFallbackAttempted = false;
    _softwareFallbackUsed = false;
    _softReloadTimer?.cancel();
    _softReloadTimer = null;
    _softReloadCount = 0;
    _statsSignature = '';
    loadVolumeSettings(); // Apply volume boost settings
    notifyListeners();

    try {
      // 解析真实播放地址（处理 302 重定向）
      ServiceLocator.log.i('>>> Start resolving redirect', tag: 'PlayerProvider');
      final redirectStartTime = DateTime.now();
      
      final realUrl = await ServiceLocator.redirectCache.resolveRealPlayUrl(url);
      
      final redirectTime = DateTime.now().difference(redirectStartTime).inMilliseconds;
      ServiceLocator.log.i('>>> 302重定向解析完成，耗时: ${redirectTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log.d('>>> 使用播放地址: $realUrl', tag: 'PlayerProvider');
      
      // 开始播放
      ServiceLocator.log.i('>>> Start initializing player', tag: 'PlayerProvider');
      final playStartTime = DateTime.now();

      await _mediaKitPlayer?.open(
        Media(
          realUrl,
          httpHeaders: {
            if (ServiceLocator.userAgent.userAgent != null)
              'User-Agent': ServiceLocator.userAgent.userAgent!,
          },
        ),
      );

      final playTime = DateTime.now().difference(playStartTime).inMilliseconds;
      final totalTime = DateTime.now().difference(startTime).inMilliseconds;
        ServiceLocator.log.i('>>> 播放器初始化完成，耗时: ${playTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log.i('>>> 播放流程总耗时: ${totalTime}ms', tag: 'PlayerProvider');
      
      _state = PlayerState.playing;
      _scheduleNoVideoFallbackIfNeeded();
    } catch (e) {
      final totalTime = DateTime.now().difference(startTime).inMilliseconds;
      ServiceLocator.log.e('>>> 播放失败 (${totalTime}ms): $e', tag: 'PlayerProvider');
      _setError('Failed to play: $e');
      return;
    }
    notifyListeners();
  }

  void togglePlayPause() {
    if (_useNativePlayer) return; // TV 端由原生播放器处理
    _mediaKitPlayer?.playOrPause();
  }

  void pause() {
    if (_useNativePlayer) return; // TV 端由原生播放器处理
    _mediaKitPlayer?.pause();
  }

  void play() {
    if (_useNativePlayer) return; // TV 端由原生播放器处理
    _mediaKitPlayer?.play();
  }

  Future<void> stop({bool silent = false}) async {
    // 清除错误状态和定时器
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryCount = 0;
    _error = null;
    _errorDisplayed = false;
    _lastErrorMessage = null;
    _lastErrorTime = null;
    _isAutoSwitching = false;
    _isAutoDetecting = false;
    _audioTracks = [];
    _currentAudioTrack = -1;
    _audioCodec = '';
    
    if (!_useNativePlayer) {
      _mediaKitPlayer?.stop();
    }
    _state = PlayerState.idle;
    _currentChannel = null;
    
    if (!silent) {
      notifyListeners();
    }
  }

  void seek(Duration position) {
    if (_useNativePlayer) return; // TV 端由原生播放器处理
    _mediaKitPlayer?.seek(position);
  }

  void seekForward(int seconds) {
    seek(_position + Duration(seconds: seconds));
  }

  void seekBackward(int seconds) {
    final newPos = _position - Duration(seconds: seconds);
    seek(newPos.isNegative ? Duration.zero : newPos);
  }

  void setVolume(double volume) {
    _volume = volume.clamp(0.0, 1.0);
    _applyVolume();
    if (_volume > 0) _isMuted = false;
    notifyListeners();
  }

  double _volumeBeforeMute = 1.0; // 淇濆瓨闈欓煶鍓嶇殑音抽噺

  void toggleMute() {
    if (!_isMuted) {
      // 静音前保存当前音量
      _volumeBeforeMute = _volume > 0 ? _volume : 1.0;
    }
    _isMuted = !_isMuted;
    if (!_isMuted && _volume == 0) {
      // 取消静音时如果音量为0，恢复到之前的音量
      _volume = _volumeBeforeMute;
    }
    _applyVolume();
    notifyListeners();
  }

  void switchAudioTrack(int index) {
    if (_useNativePlayer || _mediaKitPlayer == null) return;
    if (index < 0 || index >= _audioTracks.length) return;
    _currentAudioTrack = index;
    _mediaKitPlayer?.setAudioTrack(_audioTracks[index]);
    notifyListeners();
  }

  void toggleAudioPassthrough() {
    _audioPassthrough = !_audioPassthrough;
    notifyListeners();
  }

  void setAudioPassthrough(bool enabled) {
    _audioPassthrough = enabled;
    notifyListeners();
  }

  /// Apply volume boost from settings (in dB)
  void setVolumeBoost(int db) {
    _volumeBoostDb = db.clamp(-20, 20);
    _applyVolume();
    notifyListeners();
  }

  /// Load volume settings from preferences
  void loadVolumeSettings() {
    final prefs = ServiceLocator.prefs;
    // 音量增强独立于音量标准化，最终加载
    _volumeBoostDb = prefs.getInt('volume_boost') ?? 0;
    _applyVolume();
  }

  /// Calculate and apply the effective volume with boost
  void _applyVolume() {
    if (_useNativePlayer) return; // TV 端由原生播放器处理
    
    if (_isMuted) {
      _mediaKitPlayer?.setVolume(0);
      return;
    }

    // Convert dB to linear multiplier: multiplier = 10^(dB/20)
    final multiplier = math.pow(10, _volumeBoostDb / 20.0);
    final effectiveVolume = (_volume * multiplier).clamp(0.0, 2.0); // Allow up to 2x volume

    // media_kit uses 0-100 scale, but can go higher for boost
    _mediaKitPlayer?.setVolume(effectiveVolume * 100);
  }

  void setPlaybackSpeed(double speed) {
    if (_useNativePlayer) return; // TV 端由原生播放器处理
    _playbackSpeed = speed;
    _mediaKitPlayer?.setRate(speed);
    notifyListeners();
  }

  void toggleFullscreen() {
    _isFullscreen = !_isFullscreen;
    notifyListeners();
  }

  void setFullscreen(bool fullscreen) {
    _isFullscreen = fullscreen;
    notifyListeners();
  }

  void setControlsVisible(bool visible) {
    _controlsVisible = visible;
    notifyListeners();
  }

  void toggleControls() {
    _controlsVisible = !_controlsVisible;
    notifyListeners();
  }

  void playNext(List<Channel> channels) {
    if (_currentChannel == null || channels.isEmpty) return;
    final idx = channels.indexWhere((c) => c.id == _currentChannel!.id);
    if (idx == -1 || idx >= channels.length - 1) return;
    playChannel(channels[idx + 1]);
  }

  void playPrevious(List<Channel> channels) {
    if (_currentChannel == null || channels.isEmpty) return;
    final idx = channels.indexWhere((c) => c.id == _currentChannel!.id);
    if (idx <= 0) return;
    playChannel(channels[idx - 1]);
  }

  /// Switch to next source for current channel (if has multiple sources)
  void switchToNextSource() {
    if (_currentChannel == null || !_currentChannel!.hasMultipleSources) return;
    
    // 取消任何正在进行的自动检测
    _isAutoDetecting = false;
    _retryTimer?.cancel();
    
    final newIndex = (_currentChannel!.currentSourceIndex + 1) % _currentChannel!.sourceCount;
    _currentChannel!.currentSourceIndex = newIndex;
    
    ServiceLocator.log.d('PlayerProvider: 手动切换到源 ${newIndex + 1}/${_currentChannel!.sourceCount}');
    
    // 只有在非自动切换时才重置（手动切换时重置）
    if (!_isAutoSwitching) {
      _retryCount = 0;
      ServiceLocator.log.d('PlayerProvider: Manual source switch, reset retry state');
    }
    
    // Play the new source
    _playCurrentSource();
  }

  /// Switch to previous source for current channel (if has multiple sources)
  void switchToPreviousSource() {
    if (_currentChannel == null || !_currentChannel!.hasMultipleSources) return;
    
    // 取消任何正在进行的自动检测
    _isAutoDetecting = false;
    _retryTimer?.cancel();
    
    final newIndex = (_currentChannel!.currentSourceIndex - 1 + _currentChannel!.sourceCount) % _currentChannel!.sourceCount;
    _currentChannel!.currentSourceIndex = newIndex;
    
    ServiceLocator.log.d('PlayerProvider: 手动切换到源 ${newIndex + 1}/${_currentChannel!.sourceCount}');
    
    // 只有在非自动切换时才重置（手动切换时重置）
    if (!_isAutoSwitching) {
      _retryCount = 0;
      ServiceLocator.log.d('PlayerProvider: Manual source switch, reset retry state');
    }
    
    // Play the new source
    _playCurrentSource();
  }

  /// Play the current source of the current channel
  Future<void> _playCurrentSource() async {
    if (_currentChannel == null) return;
    
    // 记录初始配置
    ServiceLocator.log.d('开始嬫挱设鹃道源', tag: 'PlayerProvider');
    ServiceLocator.log.d('频道: ${_currentChannel!.name}, 源索引 ${_currentChannel!.currentSourceIndex}/${_currentChannel!.sourceCount}', tag: 'PlayerProvider');
    
    // 检测当前源是否可用
    final testService = ChannelTestService();
    final tempChannel = Channel(
      id: _currentChannel!.id,
      name: _currentChannel!.name,
      url: _currentChannel!.currentUrl,
      groupName: _currentChannel!.groupName,
      logoUrl: _currentChannel!.logoUrl,
      sources: [_currentChannel!.currentUrl],
      playlistId: _currentChannel!.playlistId,
    );
    
    ServiceLocator.log.i('检测源可用性: ${_currentChannel!.currentUrl}', tag: 'PlayerProvider');
    
    final result = await testService.testChannel(tempChannel);
    
    if (!result.isAvailable) {
      ServiceLocator.log.w('源不可用: ${result.error}', tag: 'PlayerProvider');
      _setError('源不可用: ${result.error}');
      return;
    }
    
    ServiceLocator.log.i('源可用，响应时间: ${result.responseTime}ms', tag: 'PlayerProvider');
    
    final url = _currentChannel!.currentUrl;
    final startTime = DateTime.now();
    
    _state = PlayerState.loading;
    _error = null;
    _lastErrorMessage = null;
    _errorDisplayed = false;
    _noVideoFallbackAttempted = false;
    notifyListeners();

    try {
      if (!_useNativePlayer) {
        // 解析真实播放地址（处理 302 重定向）
        ServiceLocator.log.i('>>> Source switch: start resolving redirect', tag: 'PlayerProvider');
        final redirectStartTime = DateTime.now();
        
        final realUrl = await ServiceLocator.redirectCache.resolveRealPlayUrl(url);
        
        final redirectTime = DateTime.now().difference(redirectStartTime).inMilliseconds;
        ServiceLocator.log.i('>>> 切换源: 302重定向解析完成，耗时: ${redirectTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log.d('>>> 切换源: 使用播放地址: $realUrl', tag: 'PlayerProvider');
        
        final playStartTime = DateTime.now();
        await _mediaKitPlayer?.open(
          Media(
            realUrl,
            httpHeaders: {
              if (ServiceLocator.userAgent.userAgent != null)
                'User-Agent': ServiceLocator.userAgent.userAgent!,
            },
          ),
        );
        
        final playTime = DateTime.now().difference(playStartTime).inMilliseconds;
        final totalTime = DateTime.now().difference(startTime).inMilliseconds;
        ServiceLocator.log.i('>>> 切换源: 播放器初始化完成，耗时: ${playTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log.i('>>> 切换源: 总昏€楁时: ${totalTime}ms', tag: 'PlayerProvider');
        
        _state = PlayerState.playing;
        _scheduleNoVideoFallbackIfNeeded();
      }
      ServiceLocator.log.i('播放成功', tag: 'PlayerProvider');
    } catch (e) {
      final totalTime = DateTime.now().difference(startTime).inMilliseconds;
      ServiceLocator.log.e('播放失败 (${totalTime}ms)', tag: 'PlayerProvider', error: e);
      _setError('Failed to play source: $e');
      return;
    }
    notifyListeners();
  }

  /// Get current source index (1-based for display)
  int get currentSourceIndex => (_currentChannel?.currentSourceIndex ?? 0) + 1;

  /// Get total source count
  int get sourceCount => _currentChannel?.sourceCount ?? 1;

  /// Set current channel without starting playback (for native player coordination)
  void setCurrentChannelOnly(Channel channel) {
    _currentChannel = channel;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _debugInfoTimer?.cancel();
    _retryTimer?.cancel();
    _softReloadTimer?.cancel();
    _mediaKitPlayer?.dispose();
    super.dispose();
  }

  void _scheduleNoVideoFallbackIfNeeded() {
    if (_useNativePlayer) return;
    if (!Platform.isWindows) return;
    if (_isSoftwareDecoding) return;
    if (!_allowSoftwareFallback) return;
    if (_noVideoFallbackAttempted) return;

    _noVideoFallbackAttempted = true;
    Future.delayed(const Duration(seconds: 3), () {
      if (_isDisposed) return;
      // 若已播放但仍无画面（宽度为0），尝试解码回调
      if (_state == PlayerState.playing && _videoWidth == 0 && _videoHeight == 0) {
        ServiceLocator.log.w('PlayerProvider: 音抽帧変絾时犵敾闈紝宽濊瘯轨В鍥為€€', tag: 'PlayerProvider');
        _attemptSoftwareFallback();
      }
    });
  }
}

