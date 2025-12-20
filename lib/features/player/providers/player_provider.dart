import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'dart:io' show Platform;
import 'dart:async';

import '../../../core/models/channel.dart';
import '../../../core/services/service_locator.dart';

enum PlayerState {
  idle,
  loading,
  playing,
  paused,
  error,
  buffering,
}

class PlayerProvider extends ChangeNotifier {
  Player? _player;
  VideoController? _videoController;

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

  // Track retry attempts for fallback
  int _retryCount = 0;
  static const int _maxRetries = 2;

  // Getters
  Player? get player => _player;
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
  bool get isLoading =>
      _state == PlayerState.loading || _state == PlayerState.buffering;
  bool get hasError => _state == PlayerState.error;

  // Debug info for display
  String _hwdecMode = 'unknown';
  String _videoCodec = '';
  double _fps = 0;
  int _droppedFrames = 0;
  
  String get videoInfo {
    if (_player == null) return '';

    // Access state safely
    final w = _player!.state.width;
    final h = _player!.state.height;

    if (w == 0 || h == 0) return '';

    final parts = <String>[];
    parts.add('${w}x$h');
    
    if (_videoCodec.isNotEmpty) {
      parts.add(_videoCodec);
    }
    
    if (_fps > 0) {
      parts.add('${_fps.toStringAsFixed(1)} fps');
    }
    
    parts.add('hwdec: $_hwdecMode');
    
    if (_droppedFrames > 0) {
      parts.add('dropped: $_droppedFrames');
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
    // Dispose existing player if any
    _player?.dispose();

    // Get decoding mode preference from settings
    // Options: 'auto', 'hardware', 'software'
    String decodingMode = 'auto';
    try {
      decodingMode = ServiceLocator.prefs.getString('decoding_mode') ?? 'auto';
    } catch (_) {}

    // If forced software decoding (fallback after error), override the setting
    if (useSoftwareDecoding) {
      decodingMode = 'software';
    }

    // Create player with configuration
    // Increase buffer size for smoother 4K playback
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024, // 64MB buffer for 4K streams
      ),
    );

    // Configure VideoController with appropriate hwdec settings
    // For Android TV, use more compatible settings
    VideoControllerConfiguration config;

    if (Platform.isAndroid) {
      switch (decodingMode) {
        case 'hardware':
          // Force hardware decoding via mediacodec
          // Use gpu vo with mediacodec hwdec for better compatibility
          config = const VideoControllerConfiguration(
            vo: 'gpu',
            hwdec: 'mediacodec',
            enableHardwareAcceleration: true,
          );
          break;
        case 'software':
          // Force software decoding
          config = const VideoControllerConfiguration(
            vo: 'gpu',
            hwdec: 'no',
            enableHardwareAcceleration: false,
          );
          break;
        case 'auto':
        default:
          // Auto mode: use mediacodec for hardware decoding
          // Try without specifying vo to let media_kit choose
          config = const VideoControllerConfiguration(
            hwdec: 'mediacodec',
            enableHardwareAcceleration: true,
          );
          break;
      }
    } else {
      // For Windows/Other platforms
      config = VideoControllerConfiguration(
        enableHardwareAcceleration: decodingMode != 'software',
      );
    }

    _videoController = VideoController(_player!, configuration: config);

    // Listen to player streams
    _player!.stream.playing.listen((playing) {
      if (playing) {
        _state = PlayerState.playing;
        _retryCount = 0; // Reset retry count on successful play
      } else if (_state == PlayerState.playing) {
        _state = PlayerState.paused;
      }
      notifyListeners();
    });

    _player!.stream.buffering.listen((buffering) {
      if (buffering) {
        if (_state != PlayerState.idle && _state != PlayerState.error) {
          _state = PlayerState.buffering;
          notifyListeners();
        }
      } else {
        // Buffering finished
        if (_state == PlayerState.buffering) {
          // Check actual playing status
          if (_player!.state.playing) {
            _state = PlayerState.playing;
          } else {
            _state = PlayerState.paused;
          }
          notifyListeners();
        }
      }
    });

    _player!.stream.position.listen((position) {
      _position = position;
      notifyListeners();
    });

    _player!.stream.duration.listen((duration) {
      _duration = duration;
      notifyListeners();
    });

    // Listen for track info to get codec and hwdec status
    _player!.stream.tracks.listen((tracks) {
      for (final track in tracks.video) {
        if (track.codec != null) {
          _videoCodec = track.codec!;
        }
        if (track.fps != null) {
          _fps = track.fps!;
        }
      }
      notifyListeners();
    });

    // Get hwdec mode from player properties periodically
    _updateDebugInfo();

    _player!.stream.volume.listen((volume) {
      _volume = volume / 100;
      notifyListeners();
    });

    _player!.stream.error.listen((error) {
      if (error.isNotEmpty) {
        // Check if this is a codec error and we should try software decoding
        if (_shouldTrySoftwareFallback(error)) {
          _attemptSoftwareFallback();
        } else {
          _state = PlayerState.error;
          _error = error;
          notifyListeners();
        }
      }
    });

    // Listen to video dimensions
    _player!.stream.width.listen((_) => notifyListeners());
    _player!.stream.height.listen((_) => notifyListeners());
  }

  Timer? _debugInfoTimer;
  
  void _updateDebugInfo() {
    _debugInfoTimer?.cancel();
    _debugInfoTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_player == null) return;
      
      // Try to get hwdec info from mpv properties
      try {
        // Check if hardware decoding is being used based on config
        if (Platform.isAndroid) {
          final decodingMode = ServiceLocator.prefs.getString('decoding_mode') ?? 'auto';
          _hwdecMode = decodingMode == 'software' ? 'sw' : 'mediacodec';
        }
        
        notifyListeners();
      } catch (e) {
        debugPrint('Error getting debug info: $e');
      }
    });
  }

  bool _shouldTrySoftwareFallback(String error) {
    // Check if this looks like a codec/decoder error
    final lowerError = error.toLowerCase();
    return (lowerError.contains('codec') ||
            lowerError.contains('decoder') ||
            lowerError.contains('hwdec') ||
            lowerError.contains('mediacodec')) &&
        _retryCount < _maxRetries;
  }

  void _attemptSoftwareFallback() {
    _retryCount++;
    debugPrint(
        'PlayerProvider: Hardware decoding failed, attempting software fallback (attempt $_retryCount)');

    // Store current channel to replay
    final channelToPlay = _currentChannel;

    // Reinitialize player with software decoding
    _initPlayer(useSoftwareDecoding: true);

    // Replay the channel if we had one
    if (channelToPlay != null) {
      playChannel(channelToPlay);
    }
  }

  // Play a channel
  Future<void> playChannel(Channel channel) async {
    _currentChannel = channel;
    _state = PlayerState.loading;
    _error = null;
    notifyListeners();

    try {
      await _player?.open(Media(channel.url));
      _state = PlayerState.playing;
    } catch (e) {
      _state = PlayerState.error;
      _error = 'Failed to play channel: $e';
    }

    notifyListeners();
  }

  // Play from URL
  Future<void> playUrl(String url, {String? name}) async {
    _state = PlayerState.loading;
    _error = null;
    notifyListeners();

    try {
      await _player?.open(Media(url));
      _state = PlayerState.playing;
    } catch (e) {
      _state = PlayerState.error;
      _error = 'Failed to play: $e';
    }

    notifyListeners();
  }

  // Toggle play/pause
  void togglePlayPause() {
    if (_player == null) return;
    _player!.playOrPause();
  }

  // Pause playback
  void pause() {
    _player?.pause();
  }

  // Resume playback
  void play() {
    _player?.play();
  }

  // Stop playback
  void stop() {
    _player?.stop();
    _state = PlayerState.idle;
    _currentChannel = null;
    notifyListeners();
  }

  // Seek to position
  void seek(Duration position) {
    _player?.seek(position);
  }

  // Seek forward by seconds
  void seekForward(int seconds) {
    final newPosition = _position + Duration(seconds: seconds);
    seek(newPosition);
  }

  // Seek backward by seconds
  void seekBackward(int seconds) {
    final newPosition = _position - Duration(seconds: seconds);
    seek(newPosition.isNegative ? Duration.zero : newPosition);
  }

  // Set volume (0.0 to 1.0)
  void setVolume(double volume) {
    _volume = volume.clamp(0.0, 1.0);
    _player?.setVolume(_volume * 100);

    if (_volume > 0) {
      _isMuted = false;
    }

    notifyListeners();
  }

  // Toggle mute
  void toggleMute() {
    _isMuted = !_isMuted;
    _player?.setVolume(_isMuted ? 0 : _volume * 100);
    notifyListeners();
  }

  // Set playback speed
  void setPlaybackSpeed(double speed) {
    _playbackSpeed = speed;
    _player?.setRate(speed);
    notifyListeners();
  }

  // Toggle fullscreen
  void toggleFullscreen() {
    _isFullscreen = !_isFullscreen;
    notifyListeners();
  }

  // Set fullscreen state
  void setFullscreen(bool fullscreen) {
    _isFullscreen = fullscreen;
    notifyListeners();
  }

  // Show/hide controls
  void setControlsVisible(bool visible) {
    _controlsVisible = visible;
    notifyListeners();
  }

  // Toggle controls visibility
  void toggleControls() {
    _controlsVisible = !_controlsVisible;
    notifyListeners();
  }

  // Play next channel from a list
  void playNext(List<Channel> channels) {
    if (_currentChannel == null || channels.isEmpty) return;

    final currentIndex =
        channels.indexWhere((c) => c.id == _currentChannel!.id);
    if (currentIndex == -1 || currentIndex >= channels.length - 1) return;

    playChannel(channels[currentIndex + 1]);
  }

  // Play previous channel from a list
  void playPrevious(List<Channel> channels) {
    if (_currentChannel == null || channels.isEmpty) return;

    final currentIndex =
        channels.indexWhere((c) => c.id == _currentChannel!.id);
    if (currentIndex <= 0) return;

    playChannel(channels[currentIndex - 1]);
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }
}
