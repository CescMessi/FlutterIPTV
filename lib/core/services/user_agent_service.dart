import 'package:shared_preferences/shared_preferences.dart';

class UserAgentService {
  static const String keyUserAgent = 'user_agent';

  final SharedPreferences _prefs;

  UserAgentService(this._prefs);

  String? get userAgent {
    final value = _prefs.getString(keyUserAgent);
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }

  Future<void> setUserAgent(String? value) async {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await _prefs.remove(keyUserAgent);
      return;
    }
    await _prefs.setString(keyUserAgent, trimmed);
  }
}
