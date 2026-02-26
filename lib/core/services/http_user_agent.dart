import 'package:http/http.dart' as http;

import 'service_locator.dart';

class HttpUserAgent {
  static Map<String, String> apply(Map<String, String>? headers) {
    final userAgent = ServiceLocator.userAgent.userAgent;
    if (userAgent == null) {
      return headers == null ? <String, String>{} : Map<String, String>.from(headers);
    }

    final merged = headers == null ? <String, String>{} : Map<String, String>.from(headers);
    merged['User-Agent'] = userAgent;
    return merged;
  }

  static void applyToRequest(http.BaseRequest request) {
    final userAgent = ServiceLocator.userAgent.userAgent;
    if (userAgent == null) return;
    request.headers['User-Agent'] = userAgent;
  }
}
