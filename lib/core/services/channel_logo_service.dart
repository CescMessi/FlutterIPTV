import '../database/database_helper.dart';
import 'service_locator.dart';

/// Service for managing channel logos
class ChannelLogoService {
  final DatabaseHelper _db;
  static const String _tableName = 'channel_logos';
  
  // Cache for logo mappings
  final Map<String, String> _logoCache = {};
  bool _isInitialized = false;

  ChannelLogoService(this._db);

  /// Initialize the service and load cache
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      ServiceLocator.log.d('ChannelLogoService: 开始初始化');
      await _loadCacheFromDatabase();
      _isInitialized = true;
      ServiceLocator.log.d('ChannelLogoService: 初始化完成');
    } catch (e) {
      ServiceLocator.log.e('ChannelLogoService: 初始化失败: $e');
    }
  }

  /// Load cache from database
  Future<void> _loadCacheFromDatabase() async {
    try {
      final logos = await _db.query(_tableName);
      _logoCache.clear();
      for (final logo in logos) {
        final channelName = logo['channel_name'] as String;
        final logoUrl = logo['logo_url'] as String;
        _logoCache[_normalizeChannelName(channelName)] = logoUrl;
      }
      ServiceLocator.log.d('ChannelLogoService: 缓存加载完成，共 ${_logoCache.length} 条记录');
    } catch (e) {
      ServiceLocator.log.e('ChannelLogoService: 缓存加载失败: $e');
    }
  }

  /// Normalize channel name for matching
  String _normalizeChannelName(String name) {
    // 先去除常见后缀，再去除空格、下划线（保留 + 号）
    return name
        .toUpperCase()
        .replaceAll(RegExp(r'(综合|综艺|体育|新闻|音乐|戏曲|少儿|电影|电视剧|纪录|科教|农业|军事|财经|国防|赛事|中文|国际|社会|与法|农村|高清|HD|4K|8K|超清|标清|频道|卫视)'), '') // Remove common suffixes first
        .replaceAll(RegExp(r'[-\s_]+'), ''); // Then remove spaces, dashes, underscores (keep + sign)
  }

  /// Find logo URL for a channel name with fuzzy matching
  Future<String?> findLogoUrl(String channelName) async {
    if (!_isInitialized) {
      await initialize();
    }

    // Try exact match from cache first
    final normalized = _normalizeChannelName(channelName);
    ServiceLocator.log.d('ChannelLogoService: 查询台标 "$channelName" → 规范化为 "$normalized"');
    
    if (_logoCache.containsKey(normalized)) {
      ServiceLocator.log.d('ChannelLogoService: 缓存命中 "$normalized"');
      return _logoCache[normalized];
    }

    // Try fuzzy match from database
    try {
      final cleanName = _normalizeChannelName(channelName);
      
      // Query with LIKE for fuzzy matching
      final results = await _db.rawQuery('''
        SELECT logo_url FROM $_tableName 
        WHERE UPPER(REPLACE(REPLACE(REPLACE(channel_name, '-', ''), ' ', ''), '_', '')) LIKE ?
           OR UPPER(REPLACE(REPLACE(REPLACE(search_keys, '-', ''), ' ', ''), '_', '')) LIKE ?
        LIMIT 1
      ''', ['%$cleanName%', '%$cleanName%']);
      
      if (results.isNotEmpty) {
        final logoUrl = results.first['logo_url'] as String;
        ServiceLocator.log.d('ChannelLogoService: 数据库模糊匹配成功 "$channelName" → "$logoUrl"');
        // Cache the result
        _logoCache[normalized] = logoUrl;
        return logoUrl;
      } else {
        ServiceLocator.log.w('ChannelLogoService: 未找到台标 "$channelName" (规范化: "$normalized")');
      }
    } catch (e) {
      ServiceLocator.log.w('ChannelLogoService: 查询失败: $e');
    }

    return null;
  }

  /// Get logo count from database
  Future<int> getLogoCount() async {
    try {
      final result = await _db.rawQuery('SELECT COUNT(*) as count FROM $_tableName');
      return result.first['count'] as int;
    } catch (e) {
      return 0;
    }
  }
}
