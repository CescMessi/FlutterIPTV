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

  int _retryCount = 0;
  static const int _maxRetries = 2;  // 鏀逛负閲嶈瘯2娆?
  Timer? _retryTimer;
  bool _isAutoSwitching = false; // 鏍囪鏄惁姝ｅ湪鑷姩鍒囨崲婧?
  bool _isAutoDetecting = false; // 鏍囪鏄惁姝ｅ湪鑷姩妫€娴嬫簮
  bool _isSoftwareDecoding = false;
  bool _noVideoFallbackAttempted = false;
  bool _allowSoftwareFallback = true;
  String _windowsHwdecMode = 'auto-safe';
  bool _isDisposed = false;
  String _videoOutput = 'auto';
  String _vo = 'unknown';
  String _configuredVo = 'auto';

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

  bool get isPlaying => _state == PlayerState.playing;
  bool get isLoading => _state == PlayerState.loading || _state == PlayerState.buffering;
  bool get hasError => _state == PlayerState.error && _error != null;

  /// Check if current content is seekable (VOD or replay)
  bool get isSeekable {
    // 1. 妫€鏌ラ閬撶被鍨嬶紙濡傛灉鏄庣‘鏄洿鎾紝涓嶅彲鎷栧姩锛?
    if (_currentChannel?.isLive == true) return false;
    
    // 2. 妫€鏌ラ閬撶被鍨嬶紙濡傛灉鏄偣鎾垨鍥炴斁锛屽彲鎷栧姩锛?
    if (_currentChannel?.isSeekable == true) {
      // 浣嗚繕闇€瑕佹鏌?duration 鏄惁鏈夋晥
      if (_duration.inSeconds > 0 && _duration.inSeconds <= 86400) {
        return true;
      }
    }
    
    // 3. 妫€鏌?duration锛堢偣鎾唴瀹规湁鏄庣‘鏃堕暱锛?
    // 鐩存挱娴侀€氬父 duration 涓?0 鎴栬秴澶у€?
    if (_duration.inSeconds > 0 && _duration.inSeconds <= 86400) {
      // 鏈夋晥鏃堕暱锛?绉掑埌24灏忔椂锛夛紝浣嗚鎺掗櫎鐩存挱娴?
      if (_currentChannel?.isLive != true) {
        return true;
      }
    }
    
    // 4. 榛樿涓嶅彲鎷栧姩锛堝畨鍏ㄨ捣瑙侊級
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

  // 娓呴櫎閿欒鐘舵€侊紙鐢ㄤ簬鏄剧ず閿欒鍚庨槻姝㈤噸澶嶆樉绀猴級
  void clearError() {
    _error = null;
    _errorDisplayed = true; // 鏍囪閿欒宸茶鏄剧ず锛岄槻姝㈤噸澶嶈Е鍙?
    // 閲嶇疆鐘舵€佷负 idle锛岄伩鍏?hasError 涓€鐩翠负 true
    if (_state == PlayerState.error) {
      _state = PlayerState.idle;
    }
    notifyListeners();
  }

  // 閿欒闃叉姈锛氳褰曚笂娆￠敊璇椂闂达紝閬垮厤鐭椂闂村唴閲嶅瑙﹀彂
  DateTime? _lastErrorTime;
  String? _lastErrorMessage;
  bool _errorDisplayed = false; // 鏍囪閿欒鏄惁宸茶鏄剧ず

  void _setError(String error) {
    ServiceLocator.log.d('PlayerProvider: _setError 琚皟鐢?- 褰撳墠閲嶈瘯娆℃暟: $_retryCount/$_maxRetries, 閿欒: $error');
    
    // 蹇界暐 seek 鐩稿叧鐨勯敊璇紙鐩存挱娴佷笉鏀寔 seek锛?
    if (error.contains('seekable') || 
        error.contains('Cannot seek') || 
        error.contains('seek in this stream')) {
      ServiceLocator.log.d('PlayerProvider: 蹇界暐 seek 閿欒锛堢洿鎾祦涓嶆敮鎸佹嫋鍔級');
      return;
    }
    
    // 蹇界暐闊抽瑙ｇ爜璀﹀憡锛堝鏋滆兘鎾斁澹伴煶锛岃繖鍙槸璀﹀憡锛?
    if (error.contains('Error decoding audio') || 
        error.contains('audio decoder') ||
        error.contains('Audio decoding')) {
      ServiceLocator.log.d('PlayerProvider: Ignore audio decode warning (likely partial frame decode failure)');
      return;
    }
    
    // 灏濊瘯鑷姩閲嶈瘯锛堥噸璇曢樁娈典笉鍙楅槻鎶栭檺鍒讹級
    if (_retryCount < _maxRetries && _currentChannel != null) {
      _retryCount++;
      ServiceLocator.log.d('PlayerProvider: 鎾斁閿欒锛屽皾璇曢噸璇?($_retryCount/$_maxRetries): $error');
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(milliseconds: 500), () {
        if (_currentChannel != null) {
          _retryPlayback();
        }
      });
      return;
    }
    
    // 瓒呰繃閲嶈瘯娆℃暟锛屾鏌ユ槸鍚︽湁涓嬩竴涓簮
    if (_currentChannel != null && _currentChannel!.hasMultipleSources) {
      final currentSourceIndex = _currentChannel!.currentSourceIndex;
      final totalSources = _currentChannel!.sourceCount;
      
      ServiceLocator.log.d('PlayerProvider: 褰撳墠婧愮储寮? $currentSourceIndex, 鎬绘簮鏁? $totalSources');
      
      // 璁＄畻涓嬩竴涓簮绱㈠紩锛堜笉浣跨敤妯¤繍绠楋紝閬垮厤寰幆锛?
      int nextIndex = currentSourceIndex + 1;
      
      // 妫€鏌ヤ笅涓€涓簮鏄惁瀛樺湪
      if (nextIndex < totalSources) {
        // 涓嬩竴涓簮瀛樺湪锛屽厛妫€娴嬪啀灏濊瘯
        ServiceLocator.log.d('PlayerProvider: 褰撳墠婧?(${currentSourceIndex + 1}/$totalSources) 閲嶈瘯澶辫触锛屾娴嬫簮 ${nextIndex + 1}');
        
        // 鏍囪寮€濮嬭嚜鍔ㄦ娴?
        _isAutoDetecting = true;
        // 寮傛妫€娴嬩笅涓€涓簮
        _checkAndSwitchToNextSource(nextIndex, error);
        return;
      } else {
        ServiceLocator.log.d('PlayerProvider: Reached last source (${currentSourceIndex + 1}/$totalSources), stop trying');
      }
    }
    
    // 娌℃湁鏇村婧愭垨鎵€鏈夋簮閮藉け璐ワ紝鏄剧ず閿欒锛堟鏃舵墠搴旂敤闃叉姈锛?
    final now = DateTime.now();
    // 濡傛灉閿欒宸茬粡琚樉绀鸿繃锛屼笉鍐嶈缃?
    if (_errorDisplayed) {
      return;
    }
    // 鐩稿悓閿欒鍦?0绉掑唴涓嶉噸澶嶈缃?
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
  
  
  /// 妫€娴嬪苟鍒囨崲鍒颁笅涓€涓簮锛堢敤浜庤嚜鍔ㄥ垏鎹級
  Future<void> _checkAndSwitchToNextSource(int nextIndex, String originalError) async {
    if (_currentChannel == null || !_isAutoDetecting) return; // 濡傛灉妫€娴嬭鍙栨秷锛屽仠姝?
    
    // 鏇存柊UI鏄剧ず姝ｅ湪妫€娴嬬殑婧?
    _currentChannel!.currentSourceIndex = nextIndex;
    _state = PlayerState.loading;
    notifyListeners();
    
    ServiceLocator.log.d('PlayerProvider: 妫€娴嬫簮 ${nextIndex + 1}/${_currentChannel!.sourceCount}');
    
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
    
    if (!_isAutoDetecting) return; // 妫€娴嬪畬鎴愬悗鍐嶆妫€鏌ユ槸鍚﹁鍙栨秷
    
    if (!result.isAvailable) {
      ServiceLocator.log.d('PlayerProvider: 婧?${nextIndex + 1} 涓嶅彲鐢? ${result.error}锛岀户缁皾璇曚笅涓€涓簮');
      
      // 妫€鏌ユ槸鍚﹁繕鏈夋洿澶氭簮
      final totalSources = _currentChannel!.sourceCount;
      final nextNextIndex = nextIndex + 1;
      
      if (nextNextIndex < totalSources) {
        // 缁х画妫€娴嬩笅涓€涓簮
        _checkAndSwitchToNextSource(nextNextIndex, originalError);
      } else {
        // 宸插埌杈炬渶鍚庝竴涓簮锛屾樉绀洪敊璇?
        ServiceLocator.log.d('PlayerProvider: 宸插埌杈炬渶鍚庝竴涓簮锛屾墍鏈夋簮閮戒笉鍙敤');
        _isAutoDetecting = false;
        _state = PlayerState.error;
        _error = '鎵€鏈?$totalSources 涓簮鍧囦笉鍙敤';
        notifyListeners();
      }
      return;
    }
    
    ServiceLocator.log.d('PlayerProvider: Source ${nextIndex + 1} is available (${result.responseTime}ms), switching');
    _isAutoDetecting = false;
    _retryCount = 0; // 閲嶇疆閲嶈瘯璁℃暟
    _isAutoSwitching = true; // 鏍囪涓鸿嚜鍔ㄥ垏鎹?
    _lastErrorMessage = null; // 閲嶇疆閿欒娑堟伅锛屽厑璁告柊婧愮殑閿欒琚鐞?
    _playCurrentSource();
    _isAutoSwitching = false; // 閲嶇疆鏍囪
  }

  /// 閲嶈瘯鎾斁褰撳墠棰戦亾
  Future<void> _retryPlayback() async {
    if (_currentChannel == null) return;
    
    ServiceLocator.log.d('PlayerProvider: 姝ｅ湪閲嶈瘯鎾斁 ${_currentChannel!.name}, 褰撳墠婧愮储寮? ${_currentChannel!.currentSourceIndex}, 閲嶈瘯璁℃暟: $_retryCount');
    final startTime = DateTime.now();
    
    _state = PlayerState.loading;
    _error = null;
    notifyListeners();
    
    // 浣跨敤 currentUrl 鑰屼笉鏄?url锛屼互浣跨敤褰撳墠閫夋嫨鐨勬簮
    final url = _currentChannel!.currentUrl;
    ServiceLocator.log.d('PlayerProvider: 閲嶈瘯URL: $url');
    
    try {
      if (!_useNativePlayer) {
        // 瑙ｆ瀽鐪熷疄鎾斁鍦板潃锛堝鐞?02閲嶅畾鍚戯級
        ServiceLocator.log.i('>>> Retry: start resolving redirect', tag: 'PlayerProvider');
        final redirectStartTime = DateTime.now();
        
        final realUrl = await ServiceLocator.redirectCache.resolveRealPlayUrl(url);
        
        final redirectTime = DateTime.now().difference(redirectStartTime).inMilliseconds;
        ServiceLocator.log.i('>>> 閲嶈瘯: 302閲嶅畾鍚戣В鏋愬畬鎴愶紝鑰楁椂: ${redirectTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log.d('>>> 閲嶈瘯: 浣跨敤鎾斁鍦板潃: $realUrl', tag: 'PlayerProvider');
        
        final playStartTime = DateTime.now();
        await _mediaKitPlayer?.open(Media(realUrl));
        
        final playTime = DateTime.now().difference(playStartTime).inMilliseconds;
        final totalTime = DateTime.now().difference(startTime).inMilliseconds;
        ServiceLocator.log.i('>>> 閲嶈瘯: 鎾斁鍣ㄥ垵濮嬪寲瀹屾垚锛岃€楁椂: ${playTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log.i('>>> 閲嶈瘯: 鎬昏€楁椂: ${totalTime}ms', tag: 'PlayerProvider');
        
        _state = PlayerState.playing;
      }
      // 娉ㄦ剰锛氫笉鍦ㄨ繖閲岄噸缃?_retryCount锛屽洜涓烘挱鏀惧櫒鍙兘杩樹細寮傛鎶ラ敊
      // 閲嶈瘯璁℃暟浼氬湪鎾斁鐪熸绋冲畾鍚庯紙playing 鐘舵€佹寔缁竴娈垫椂闂达級鎴栧垏鎹㈤閬撴椂閲嶇疆
      ServiceLocator.log.d('PlayerProvider: Retry command sent');
    } catch (e) {
      final totalTime = DateTime.now().difference(startTime).inMilliseconds;
      ServiceLocator.log.d('PlayerProvider: 閲嶈瘯澶辫触 (${totalTime}ms): $e');
      // 閲嶈瘯澶辫触锛岀户缁皾璇曟垨鏄剧ず閿欒
      _setError('Failed to play channel: $e');
    }
    notifyListeners();
  }

  String _hwdecMode = 'unknown';
  String _videoCodec = '';
  double _fps = 0;
  
  // 淇濆瓨鍒濆鍖栨椂鐨?hwdec 閰嶇疆
  String _configuredHwdec = 'unknown';
  
  // FPS 鏄剧ず
  double _currentFps = 0;
  
  // 瑙嗛淇℃伅
  int _videoWidth = 0;
  int _videoHeight = 0;
  double _downloadSpeed = 0; // bytes per second

  double get currentFps => _currentFps;
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;
  double get downloadSpeed => _downloadSpeed;

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

    // 鍏朵粬骞冲彴锛堝寘鎷?Android 鎵嬫満锛夐兘浣跨敤 media_kit
    _initMediaKitPlayer(useSoftwareDecoding: useSoftwareDecoding);
  }
  
  /// 棰勭儹鎾斁鍣?- 鍦ㄥ簲鐢ㄥ惎鍔ㄦ椂璋冪敤,鎻愬墠鍒濆鍖栨挱鏀惧櫒璧勬簮
  /// 杩欐牱棣栨杩涘叆鎾斁椤甸潰鏃跺氨涓嶄細鍗￠】
  Future<void> warmup() async {
    if (_useNativePlayer) {
      return; // 鍘熺敓鎾斁鍣ㄤ笉闇€瑕侀鐑?
    }
    
    if (_mediaKitPlayer == null) {
      ServiceLocator.log.d('PlayerProvider: 棰勭儹鎾斁鍣?- 鍒濆鍖?media_kit', tag: 'PlayerProvider');
      _initMediaKitPlayer();
    }
    
    // 浣跨敤绌?Media 棰勭儹浼氳Е鍙戦敊璇洖璋冿紝鍙兘瀵艰嚧棣栨鎾斁榛戝睆/绾㈠徆鍙?
    // 鐩墠鍙仛瀹炰緥鍒濆鍖栵紝涓嶅仛鏃犳晥濯掍綋棰勫姞杞?
  }

  void _initMediaKitPlayer({bool useSoftwareDecoding = false, String bufferStrength = 'fast'}) {
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

    ServiceLocator.log.i('========== 鍒濆鍖栨挱鏀惧櫒 ==========', tag: 'PlayerProvider');
    ServiceLocator.log.i('骞冲彴: ${Platform.operatingSystem}', tag: 'PlayerProvider');
    ServiceLocator.log.i('杞В鐮佹ā寮? $useSoftwareDecoding', tag: 'PlayerProvider');
    ServiceLocator.log.i('缂撳啿寮哄害: $bufferStrength', tag: 'PlayerProvider');

    // 鏍规嵁缂撳啿寮哄害璁剧疆缂撳啿鍖哄ぇ灏?
    final bufferSize = switch (bufferStrength) {
      'fast' => 32 * 1024 * 1024,      // 32MB - 蹇€熷惎鍔?
      'balanced' => 64 * 1024 * 1024,  // 64MB - 骞宠　
      'stable' => 128 * 1024 * 1024,   // 128MB - 绋冲畾
      _ => 32 * 1024 * 1024,
    };

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
        // 璁剧疆缃戠粶瓒呮椂锛堢锛?
        // timeout: 3 绉掕繛鎺ヨ秴鏃?
        // 鏍规嵁鏃ュ織绾у埆鍚敤 mpv 鏃ュ織
        logLevel: ServiceLocator.log.currentLevel == LogLevel.debug
            ? MPVLogLevel.debug
            : (ServiceLocator.log.currentLevel == LogLevel.off
                ? MPVLogLevel.error
                : MPVLogLevel.info),
      ),
    );

    // 纭畾纭欢瑙ｇ爜妯″紡
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
    ServiceLocator.log.i('纭欢瑙ｇ爜妯″紡: ${hwdecMode ?? "榛樿"}', tag: 'PlayerProvider');
    ServiceLocator.log.i('纭欢鍔犻€? ${!effectiveSoftware}', tag: 'PlayerProvider');

    VideoControllerConfiguration config = VideoControllerConfiguration(
      hwdec: hwdecMode,
      enableHardwareAcceleration: !effectiveSoftware,
    );

    // 榛樿鏄剧ず涓洪厤缃€硷紝鍚庣画鍙瀹為檯鏃ュ織瑕嗙洊
    _hwdecMode = effectiveSoftware ? 'no' : _configuredHwdec;
    _vo = vo ?? 'auto';

    _videoController = VideoController(_mediaKitPlayer!, configuration: config);
    _setupMediaKitListeners();
    _updateDebugInfo();
    
    ServiceLocator.log.i('鎾斁鍣ㄥ垵濮嬪寲瀹屾垚', tag: 'PlayerProvider');
  }

  void _setupMediaKitListeners() {
    ServiceLocator.log.d('璁剧疆鎾斁鍣ㄧ洃鍚櫒', tag: 'PlayerProvider');
    
    // 鍙湪鏃ュ織寮€鍚椂鐩戝惉 mpv 鏃ュ織
      if (ServiceLocator.log.currentLevel != LogLevel.off) {
        _mediaKitPlayer!.stream.log.listen((log) {
          final message = log.text.toLowerCase();
          ServiceLocator.log.d('MPV log: ${log.text}', tag: 'PlayerProvider');
          
          // 妫€娴嬬‖浠惰В鐮佸櫒淇℃伅
        if (message.contains('using hardware decoding') || 
            message.contains('hwdec') ||
            message.contains('d3d11va') ||
            message.contains('nvdec') ||
            message.contains('dxva2') ||
            message.contains('qsv')) {
            ServiceLocator.log.i('馃幃 纭欢瑙ｇ爜: ${log.text}', tag: 'PlayerProvider');
            _updateHwdecFromLog(message);
          }
        
        // 妫€娴?GPU 淇℃伅
        if (message.contains('gpu') || 
            message.contains('nvidia') || 
            message.contains('intel') || 
            message.contains('amd') ||
            message.contains('adapter') ||
            message.contains('device')) {
          ServiceLocator.log.i('馃枼锔?GPU淇℃伅: ${log.text}', tag: 'PlayerProvider');
        }
        
        // 妫€娴嬫覆鏌撳櫒淇℃伅
          if (message.contains('vo/gpu') || 
              message.contains('opengl') || 
              message.contains('d3d11') ||
              message.contains('vulkan') ||
              message.contains('video output') ||
              message.contains('vo:')) {
            ServiceLocator.log.i('馃帹 娓叉煋鍣? ${log.text}', tag: 'PlayerProvider');
            _updateVoFromLog(message);
          }
        
        // 妫€娴嬭В鐮佸櫒閫夋嫨
        if (message.contains('decoder') || message.contains('codec')) {
          ServiceLocator.log.d('馃摴 瑙ｇ爜鍣? ${log.text}', tag: 'PlayerProvider');
        }
        
        // 璁板綍閿欒鍜岃鍛?
        if (log.level == MPVLogLevel.error) {
          ServiceLocator.log.e('MPV閿欒: ${log.text}', tag: 'PlayerProvider');
        } else if (log.level == MPVLogLevel.warn) {
          ServiceLocator.log.w('MPV璀﹀憡: ${log.text}', tag: 'PlayerProvider');
        }
        });
      }
    
    _mediaKitPlayer!.stream.playing.listen((playing) {
      ServiceLocator.log.d('鎾斁鐘舵€佸彉鍖? playing=$playing', tag: 'PlayerProvider');
      if (playing) {
        _state = PlayerState.playing;
        // 鍙湁鍦ㄦ挱鏀剧ǔ瀹氬悗鎵嶉噸缃噸璇曡鏁?
        // 浣跨敤寤惰繜纭繚鎾斁鐪熸寮€濮嬶紝鑰屼笉鏄煭鏆傜殑鐘舵€佸彉鍖?
        Future.delayed(const Duration(seconds: 3), () {
          if (_state == PlayerState.playing && _currentChannel != null) {
            ServiceLocator.log.d('PlayerProvider: Playback stable, reset retry count');
            _retryCount = 0;
          }
        });
      } else if (_state == PlayerState.playing) {
        _state = PlayerState.paused;
      }
      notifyListeners();
    });

    _mediaKitPlayer!.stream.buffering.listen((buffering) {
      ServiceLocator.log.d('缂撳啿鐘舵€? buffering=$buffering', tag: 'PlayerProvider');
      if (buffering && _state != PlayerState.idle && _state != PlayerState.error) {
        _state = PlayerState.buffering;
      } else if (!buffering && _state == PlayerState.buffering) {
        _state = _mediaKitPlayer!.state.playing ? PlayerState.playing : PlayerState.paused;
      }
      notifyListeners();
    });

    _mediaKitPlayer!.stream.position.listen((pos) {
      _position = pos;
      notifyListeners();
    });
    
    _mediaKitPlayer!.stream.duration.listen((dur) {
      _duration = dur;
      notifyListeners();
    });
    
    _mediaKitPlayer!.stream.tracks.listen((tracks) {
      ServiceLocator.log.d('杞ㄩ亾淇℃伅鏇存柊: 瑙嗛杞?${tracks.video.length}, 闊抽杞?${tracks.audio.length}', tag: 'PlayerProvider');
      
      for (final track in tracks.video) {
        if (track.codec != null) {
          _videoCodec = track.codec!;
          ServiceLocator.log.i('瑙嗛缂栫爜: ${track.codec}', tag: 'PlayerProvider');
        }
        if (track.fps != null) {
          _fps = track.fps!;
          ServiceLocator.log.i('瑙嗛甯х巼: ${track.fps} fps', tag: 'PlayerProvider');
        }
        if (track.w != null && track.h != null) {
          ServiceLocator.log.i('瑙嗛鍒嗚鲸鐜? ${track.w}x${track.h}', tag: 'PlayerProvider');
        }
      }
      
      for (final track in tracks.audio) {
        if (track.codec != null) {
          ServiceLocator.log.i('闊抽缂栫爜: ${track.codec}', tag: 'PlayerProvider');
        }
      }
      
      notifyListeners();
    });
    
    _mediaKitPlayer!.stream.volume.listen((vol) {
      _volume = vol / 100;
      notifyListeners();
    });
    
    _mediaKitPlayer!.stream.error.listen((err) {
      if (err.isNotEmpty) {
        ServiceLocator.log.e('鎾斁鍣ㄩ敊璇? $err', tag: 'PlayerProvider');
        
        // 鍒嗘瀽閿欒绫诲瀷
        if (err.toLowerCase().contains('decode') || err.toLowerCase().contains('decoder')) {
          ServiceLocator.log.e('>>> 瑙ｇ爜閿欒: $err', tag: 'PlayerProvider');
        } else if (err.toLowerCase().contains('render') || err.toLowerCase().contains('display')) {
          ServiceLocator.log.e('>>> 娓叉煋閿欒: $err', tag: 'PlayerProvider');
        } else if (err.toLowerCase().contains('hwdec') || err.toLowerCase().contains('hardware')) {
          ServiceLocator.log.e('>>> 纭欢鍔犻€熼敊璇? $err', tag: 'PlayerProvider');
        } else if (err.toLowerCase().contains('codec')) {
          ServiceLocator.log.e('>>> 缂栬В鐮佸櫒閿欒: $err', tag: 'PlayerProvider');
        }
        
        if (_shouldTrySoftwareFallback(err)) {
          ServiceLocator.log.w('灏濊瘯杞В鐮佸洖閫€', tag: 'PlayerProvider');
          _attemptSoftwareFallback();
        } else {
          _setError(err);
        }
      }
    });
    
    _mediaKitPlayer!.stream.width.listen((width) {
      if (width != null && width > 0) {
        ServiceLocator.log.d('瑙嗛瀹藉害: $width', tag: 'PlayerProvider');
      }
      notifyListeners();
    });
    
    _mediaKitPlayer!.stream.height.listen((height) {
      if (height != null && height > 0) {
        ServiceLocator.log.d('瑙嗛楂樺害: $height', tag: 'PlayerProvider');
      }
      notifyListeners();
    });
  }

  Timer? _debugInfoTimer;
  
  void _updateDebugInfo() {
    _debugInfoTimer?.cancel();
    
    _debugInfoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_mediaKitPlayer == null) return;
      
      // 濡傛灉鏃ュ織鏈紑鍚垨灏氭湭瑙ｆ瀽鍒板疄闄呭€硷紝浣跨敤閰嶇疆鍊煎厹搴?
      if (ServiceLocator.log.currentLevel == LogLevel.off &&
          (_hwdecMode == 'unknown' || _hwdecMode.isEmpty)) {
        _hwdecMode = _configuredHwdec;
      }
      
      // 鏇存柊瑙嗛灏哄
      final newWidth = _mediaKitPlayer!.state.width ?? 0;
      final newHeight = _mediaKitPlayer!.state.height ?? 0;
      
      // 妫€娴嬭棰戝昂瀵稿彉鍖栵紙鍙兘琛ㄧず瑙ｇ爜鎴愬姛锛?
      if (newWidth != _videoWidth || newHeight != _videoHeight) {
        if (newWidth > 0 && newHeight > 0) {
          ServiceLocator.log.i('鉁?瑙嗛瑙ｇ爜鎴愬姛: ${newWidth}x${newHeight}', tag: 'PlayerProvider');
        } else if (_videoWidth > 0 && newWidth == 0) {
          ServiceLocator.log.w('鉁?瑙嗛瑙ｇ爜涓㈠け', tag: 'PlayerProvider');
        }
      }
      
      _videoWidth = newWidth;
      _videoHeight = newHeight;
      
      // Windows 绔洿鎺ヤ娇鐢?track 涓殑 fps 淇℃伅
      // media_kit (mpv) 鐨勬覆鏌撳抚鐜囧熀鏈瓑浜庤棰戞簮甯х巼
      if (_state == PlayerState.playing && _fps > 0) {
        _currentFps = _fps;
      } else {
        _currentFps = 0;
      }
      
      // 浼扮畻涓嬭浇閫熷害 - 鍩轰簬瑙嗛鍒嗚鲸鐜囧拰甯х巼
      // media_kit 娌℃湁鐩存帴鐨勪笅杞介€熷害 API锛屼娇鐢ㄨ棰戝弬鏁颁及绠?
      if (_state == PlayerState.playing && _videoWidth > 0 && _videoHeight > 0) {
        final pixels = _videoWidth * _videoHeight;
        final fps = _fps > 0 ? _fps : 25.0;
        // 浼扮畻鍏紡锛氬儚绱犳暟 * 甯х巼 * 鍘嬬缉绯绘暟 (H.264/H.265 鍏稿瀷鍘嬬缉姣?
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
      
      notifyListeners();
    });
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
    _retryCount++;
    final channelToPlay = _currentChannel;
    _initMediaKitPlayer(useSoftwareDecoding: true);
    if (channelToPlay != null) playChannel(channelToPlay);
  }

  // ============ Public API ============

  Future<void> playChannel(Channel channel, {bool preserveCurrentSource = false}) async {
    ServiceLocator.log.i('========== 寮€濮嬫挱鏀鹃閬?==========', tag: 'PlayerProvider');
    ServiceLocator.log.i('棰戦亾: ${channel.name} (ID: ${channel.id})', tag: 'PlayerProvider');
    ServiceLocator.log.d('URL: ${channel.url}', tag: 'PlayerProvider');
    ServiceLocator.log.d('婧愭暟閲? ${channel.sourceCount}', tag: 'PlayerProvider');
    final playStartTime = DateTime.now();
    
    _currentChannel = channel;
    _state = PlayerState.loading;
    _error = null;
    _lastErrorMessage = null; // 閲嶇疆閿欒闃叉姈
    _errorDisplayed = false; // 閲嶇疆閿欒鏄剧ず鏍囪
    _retryCount = 0; // 閲嶇疆閲嶈瘯璁℃暟
    _retryTimer?.cancel(); // 鍙栨秷浠讳綍姝ｅ湪杩涜鐨勯噸璇?
    _isAutoDetecting = false; // 鍙栨秷浠讳綍姝ｅ湪杩涜鐨勮嚜鍔ㄦ娴?
    _noVideoFallbackAttempted = false;
    loadVolumeSettings(); // Apply volume boost settings
    notifyListeners();

    // 濡傛灉鏈夊涓簮锛屽厛妫€娴嬫壘鍒扮涓€涓彲鐢ㄧ殑婧?
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
    ServiceLocator.log.d('鍑嗗鎾斁URL: $playUrl', tag: 'PlayerProvider');

    try {
      final playerInitStartTime = DateTime.now();
      
      // Android TV 浣跨敤鍘熺敓鎾斁鍣紝閫氳繃 MethodChannel 澶勭悊
      // 鍏朵粬骞冲彴浣跨敤 media_kit
      if (!_useNativePlayer) {
        // 瑙ｆ瀽鐪熷疄鎾斁鍦板潃锛堝鐞?02閲嶅畾鍚戯級
        ServiceLocator.log.i('>>> Start resolving redirect', tag: 'PlayerProvider');
        final redirectStartTime = DateTime.now();
        
        final realUrl = await ServiceLocator.redirectCache.resolveRealPlayUrl(playUrl);
        
        final redirectTime = DateTime.now().difference(redirectStartTime).inMilliseconds;
        ServiceLocator.log.i('>>> 302閲嶅畾鍚戣В鏋愬畬鎴愶紝鑰楁椂: ${redirectTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log.d('>>> 浣跨敤鎾斁鍦板潃: $realUrl', tag: 'PlayerProvider');
        
        // 寮€濮嬫挱鏀?
        ServiceLocator.log.i('>>> Start initializing player', tag: 'PlayerProvider');
        final playStartTime = DateTime.now();
        
        await _mediaKitPlayer?.open(Media(realUrl));
        
        final playTime = DateTime.now().difference(playStartTime).inMilliseconds;
        ServiceLocator.log.i('>>> 鎾斁鍣ㄥ垵濮嬪寲瀹屾垚锛岃€楁椂: ${playTime}ms', tag: 'PlayerProvider');
        
        _state = PlayerState.playing;
        notifyListeners();
        _scheduleNoVideoFallbackIfNeeded();
      }
      
      // 璁板綍瑙傜湅鍘嗗彶
      if (channel.id != null && channel.playlistId != null) {
        await ServiceLocator.watchHistory.addWatchHistory(channel.id!, channel.playlistId!);
      }
      
      final playerInitTime = DateTime.now().difference(playerInitStartTime).inMilliseconds;
      final totalTime = DateTime.now().difference(playStartTime).inMilliseconds;
      ServiceLocator.log.i('>>> 鎾斁娴佺▼鎬昏€楁椂: ${totalTime}ms (鎾斁鍣ㄥ垵濮嬪寲: ${playerInitTime}ms)', tag: 'PlayerProvider');
      ServiceLocator.log.i('========== 棰戦亾鎾斁鎬昏€楁椂: ${totalTime}ms ==========', tag: 'PlayerProvider');
    } catch (e) {
      ServiceLocator.log.e('鎾斁棰戦亾澶辫触', tag: 'PlayerProvider', error: e);
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

  /// 鏌ユ壘绗竴涓彲鐢ㄧ殑婧?
  Future<int?> _findFirstAvailableSource(Channel channel) async {
    ServiceLocator.log.d('寮€濮嬫娴?${channel.sourceCount} 涓簮', tag: 'PlayerProvider');
    final testService = ChannelTestService();
    
    for (int i = 0; i < channel.sourceCount; i++) {
      // 鏇存柊UI鏄剧ず褰撳墠妫€娴嬬殑婧?
      channel.currentSourceIndex = i;
      notifyListeners();
      
      // 鍒涘缓涓存椂棰戦亾瀵硅薄鐢ㄤ簬娴嬭瘯
      final tempChannel = Channel(
        id: channel.id,
        name: channel.name,
        url: channel.sources[i],
        groupName: channel.groupName,
        logoUrl: channel.logoUrl,
        sources: [channel.sources[i]], // 鍙祴璇曞綋鍓嶆簮
        playlistId: channel.playlistId,
      );
      
      ServiceLocator.log.d('妫€娴嬫簮 ${i + 1}/${channel.sourceCount}', tag: 'PlayerProvider');
      final testStartTime = DateTime.now();
      
      final result = await testService.testChannel(tempChannel);
      final testTime = DateTime.now().difference(testStartTime).inMilliseconds;
      
      if (result.isAvailable) {
        ServiceLocator.log.i('鉁?婧?${i + 1} 鍙敤锛屽搷搴旀椂闂? ${result.responseTime}ms锛屾娴嬭€楁椂: ${testTime}ms', tag: 'PlayerProvider');
        return i;
      } else {
        ServiceLocator.log.w('鉁?婧?${i + 1} 涓嶅彲鐢? ${result.error}锛屾娴嬭€楁椂: ${testTime}ms', tag: 'PlayerProvider');
      }
    }
    
    ServiceLocator.log.e('鎵€鏈?${channel.sourceCount} 涓簮閮戒笉鍙敤', tag: 'PlayerProvider');
    return null; // 鎵€鏈夋簮閮戒笉鍙敤
  }

  Future<void> playUrl(String url, {String? name}) async {
    // Android TV 浣跨敤鍘熺敓鎾斁鍣紝涓嶆敮鎸佹鏂规硶
    if (_useNativePlayer) {
      ServiceLocator.log.w('playUrl: Android TV 浣跨敤鍘熺敓鎾斁鍣紝涓嶆敮鎸佹鏂规硶', tag: 'PlayerProvider');
      return;
    }
    
    final startTime = DateTime.now();
    _state = PlayerState.loading;
    _error = null;
    _lastErrorMessage = null; // 閲嶇疆閿欒闃叉姈
    _errorDisplayed = false; // 閲嶇疆閿欒鏄剧ず鏍囪
    _noVideoFallbackAttempted = false;
    loadVolumeSettings(); // Apply volume boost settings
    notifyListeners();

    try {
      // 瑙ｆ瀽鐪熷疄鎾斁鍦板潃锛堝鐞?02閲嶅畾鍚戯級
      ServiceLocator.log.i('>>> Start resolving redirect', tag: 'PlayerProvider');
      final redirectStartTime = DateTime.now();
      
      final realUrl = await ServiceLocator.redirectCache.resolveRealPlayUrl(url);
      
      final redirectTime = DateTime.now().difference(redirectStartTime).inMilliseconds;
      ServiceLocator.log.i('>>> 302閲嶅畾鍚戣В鏋愬畬鎴愶紝鑰楁椂: ${redirectTime}ms', tag: 'PlayerProvider');
      ServiceLocator.log.d('>>> 浣跨敤鎾斁鍦板潃: $realUrl', tag: 'PlayerProvider');
      
      // 寮€濮嬫挱鏀?
      ServiceLocator.log.i('>>> Start initializing player', tag: 'PlayerProvider');
      final playStartTime = DateTime.now();
      
      await _mediaKitPlayer?.open(Media(realUrl));
      
      final playTime = DateTime.now().difference(playStartTime).inMilliseconds;
      final totalTime = DateTime.now().difference(startTime).inMilliseconds;
      ServiceLocator.log.i('>>> 鎾斁鍣ㄥ垵濮嬪寲瀹屾垚锛岃€楁椂: ${playTime}ms', tag: 'PlayerProvider');
      ServiceLocator.log.i('>>> 鎾斁娴佺▼鎬昏€楁椂: ${totalTime}ms', tag: 'PlayerProvider');
      
      _state = PlayerState.playing;
      _scheduleNoVideoFallbackIfNeeded();
    } catch (e) {
      final totalTime = DateTime.now().difference(startTime).inMilliseconds;
      ServiceLocator.log.e('>>> 鎾斁澶辫触 (${totalTime}ms): $e', tag: 'PlayerProvider');
      _setError('Failed to play: $e');
      return;
    }
    notifyListeners();
  }

  void togglePlayPause() {
    if (_useNativePlayer) return; // TV 绔敱鍘熺敓鎾斁鍣ㄥ鐞?
    _mediaKitPlayer?.playOrPause();
  }

  void pause() {
    if (_useNativePlayer) return; // TV 绔敱鍘熺敓鎾斁鍣ㄥ鐞?
    _mediaKitPlayer?.pause();
  }

  void play() {
    if (_useNativePlayer) return; // TV 绔敱鍘熺敓鎾斁鍣ㄥ鐞?
    _mediaKitPlayer?.play();
  }

  Future<void> stop({bool silent = false}) async {
    // 娓呴櫎閿欒鐘舵€佸拰瀹氭椂鍣?
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryCount = 0;
    _error = null;
    _errorDisplayed = false;
    _lastErrorMessage = null;
    _lastErrorTime = null;
    _isAutoSwitching = false;
    _isAutoDetecting = false;
    
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
    if (_useNativePlayer) return; // TV 绔敱鍘熺敓鎾斁鍣ㄥ鐞?
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

  double _volumeBeforeMute = 1.0; // 淇濆瓨闈欓煶鍓嶇殑闊抽噺

  void toggleMute() {
    if (!_isMuted) {
      // 闈欓煶鍓嶄繚瀛樺綋鍓嶉煶閲?
      _volumeBeforeMute = _volume > 0 ? _volume : 1.0;
    }
    _isMuted = !_isMuted;
    if (!_isMuted && _volume == 0) {
      // 鍙栨秷闈欓煶鏃跺鏋滈煶閲忎负0锛屾仮澶嶅埌涔嬪墠鐨勯煶閲?
      _volume = _volumeBeforeMute;
    }
    _applyVolume();
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
    // 闊抽噺澧炲己鐙珛浜庨煶閲忔爣鍑嗗寲锛屽缁堝姞杞?
    _volumeBoostDb = prefs.getInt('volume_boost') ?? 0;
    _applyVolume();
  }

  /// Calculate and apply the effective volume with boost
  void _applyVolume() {
    if (_useNativePlayer) return; // TV 绔敱鍘熺敓鎾斁鍣ㄥ鐞?
    
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
    if (_useNativePlayer) return; // TV 绔敱鍘熺敓鎾斁鍣ㄥ鐞?
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
    
    // 鍙栨秷姝ｅ湪杩涜鐨勮嚜鍔ㄦ娴?
    _isAutoDetecting = false;
    _retryTimer?.cancel();
    
    final newIndex = (_currentChannel!.currentSourceIndex + 1) % _currentChannel!.sourceCount;
    _currentChannel!.currentSourceIndex = newIndex;
    
    ServiceLocator.log.d('PlayerProvider: 鎵嬪姩鍒囨崲鍒版簮 ${newIndex + 1}/${_currentChannel!.sourceCount}');
    
    // 鍙湁鍦ㄩ潪鑷姩鍒囨崲鏃舵墠閲嶇疆锛堟墜鍔ㄥ垏鎹㈡椂閲嶇疆锛?
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
    
    // 鍙栨秷姝ｅ湪杩涜鐨勮嚜鍔ㄦ娴?
    _isAutoDetecting = false;
    _retryTimer?.cancel();
    
    final newIndex = (_currentChannel!.currentSourceIndex - 1 + _currentChannel!.sourceCount) % _currentChannel!.sourceCount;
    _currentChannel!.currentSourceIndex = newIndex;
    
    ServiceLocator.log.d('PlayerProvider: 鎵嬪姩鍒囨崲鍒版簮 ${newIndex + 1}/${_currentChannel!.sourceCount}');
    
    // 鍙湁鍦ㄩ潪鑷姩鍒囨崲鏃舵墠閲嶇疆锛堟墜鍔ㄥ垏鎹㈡椂閲嶇疆锛?
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
    
    // 璁板綍鏃ュ織
    ServiceLocator.log.d('寮€濮嬫挱鏀鹃閬撴簮', tag: 'PlayerProvider');
    ServiceLocator.log.d('棰戦亾: ${_currentChannel!.name}, 婧愮储寮? ${_currentChannel!.currentSourceIndex}/${_currentChannel!.sourceCount}', tag: 'PlayerProvider');
    
    // 妫€娴嬪綋鍓嶆簮鏄惁鍙敤
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
    
    ServiceLocator.log.i('妫€娴嬫簮鍙敤鎬? ${_currentChannel!.currentUrl}', tag: 'PlayerProvider');
    
    final result = await testService.testChannel(tempChannel);
    
    if (!result.isAvailable) {
      ServiceLocator.log.w('婧愪笉鍙敤: ${result.error}', tag: 'PlayerProvider');
      _setError('婧愪笉鍙敤: ${result.error}');
      return;
    }
    
    ServiceLocator.log.i('婧愬彲鐢紝鍝嶅簲鏃堕棿: ${result.responseTime}ms', tag: 'PlayerProvider');
    
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
        // 瑙ｆ瀽鐪熷疄鎾斁鍦板潃锛堝鐞?02閲嶅畾鍚戯級
        ServiceLocator.log.i('>>> Source switch: start resolving redirect', tag: 'PlayerProvider');
        final redirectStartTime = DateTime.now();
        
        final realUrl = await ServiceLocator.redirectCache.resolveRealPlayUrl(url);
        
        final redirectTime = DateTime.now().difference(redirectStartTime).inMilliseconds;
        ServiceLocator.log.i('>>> 鍒囨崲婧? 302閲嶅畾鍚戣В鏋愬畬鎴愶紝鑰楁椂: ${redirectTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log.d('>>> 鍒囨崲婧? 浣跨敤鎾斁鍦板潃: $realUrl', tag: 'PlayerProvider');
        
        final playStartTime = DateTime.now();
        await _mediaKitPlayer?.open(Media(realUrl));
        
        final playTime = DateTime.now().difference(playStartTime).inMilliseconds;
        final totalTime = DateTime.now().difference(startTime).inMilliseconds;
        ServiceLocator.log.i('>>> 鍒囨崲婧? 鎾斁鍣ㄥ垵濮嬪寲瀹屾垚锛岃€楁椂: ${playTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log.i('>>> 鍒囨崲婧? 鎬昏€楁椂: ${totalTime}ms', tag: 'PlayerProvider');
        
        _state = PlayerState.playing;
        _scheduleNoVideoFallbackIfNeeded();
      }
      ServiceLocator.log.i('鎾斁鎴愬姛', tag: 'PlayerProvider');
    } catch (e) {
      final totalTime = DateTime.now().difference(startTime).inMilliseconds;
      ServiceLocator.log.e('鎾斁澶辫触 (${totalTime}ms)', tag: 'PlayerProvider', error: e);
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
      // 鑻ュ凡鎾斁浣嗕粛鏃犵敾闈紙瀹介珮涓?0锛夛紝灏濊瘯杞В鍥為€€
      if (_state == PlayerState.playing && _videoWidth == 0 && _videoHeight == 0) {
        ServiceLocator.log.w('PlayerProvider: 闊抽鏈変絾鏃犵敾闈紝灏濊瘯杞В鍥為€€', tag: 'PlayerProvider');
        _attemptSoftwareFallback();
      }
    });
  }
}

