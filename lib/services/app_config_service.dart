import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Centralized service managing backend server URL resolution, remote configuration,
/// local persistence, and unified access across all app services.
class AppConfigService extends ChangeNotifier {
  static final AppConfigService instance = AppConfigService._internal();
  AppConfigService._internal();

  static const String prefKeyServerUrl = 'gemini_backend_server_url';
  static const String prefKeyRemoteConfigUrl = 'app_remote_config_url';
  static const String defaultServerUrl = 'http://192.168.1.5:8000';

  /// Primary remote configuration endpoints.
  /// You can update the server IP in this JSON file without modifying Flutter code or rebuilding the APK.
  static const List<String> defaultRemoteConfigEndpoints = [
    // Primary remote config URL (e.g. GitHub raw, Gist, or custom CDN)
    'https://raw.githubusercontent.com/boxnfreight/ocr_to_excel_config/main/server_config.json',
  ];

  String _baseUrl = defaultServerUrl;
  String _wsUrl = 'ws://192.168.1.5:8000/ws';
  bool _isInitialized = false;
  bool _isFetchingRemote = false;

  String get baseUrl => _baseUrl;
  String get wsUrl => _wsUrl;
  bool get isInitialized => _isInitialized;
  bool get isFetchingRemote => _isFetchingRemote;

  /// Fast zero-delay initialization on app startup.
  /// Hydrates the cached server URL from local storage immediately,
  /// then asynchronously checks the remote configuration in the background.
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(prefKeyServerUrl);

      if (saved != null && saved.trim().isNotEmpty) {
        final cleaned = _sanitizeUrl(saved);
        if (cleaned.isNotEmpty) {
          _baseUrl = cleaned;
          _wsUrl = _deriveWsUrl(cleaned);
        }
      } else {
        _baseUrl = defaultServerUrl;
        _wsUrl = _deriveWsUrl(defaultServerUrl);
      }
    } catch (e) {
      debugPrint('[AppConfigService] Init cache read error: $e');
      _baseUrl = defaultServerUrl;
      _wsUrl = _deriveWsUrl(defaultServerUrl);
    }

    _isInitialized = true;
    notifyListeners();

    // Trigger non-blocking remote config update in background
    unawaited(fetchRemoteConfig());
  }

  /// Fetches centralized remote configuration from remote endpoint(s)
  /// with a short timeout to prevent UI freezes.
  Future<bool> fetchRemoteConfig({Duration timeout = const Duration(seconds: 2)}) async {
    if (_isFetchingRemote) return false;
    _isFetchingRemote = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final customRemoteUrl = prefs.getString(prefKeyRemoteConfigUrl);

      final endpointsToTry = <String>[
        if (customRemoteUrl != null && customRemoteUrl.trim().isNotEmpty)
          customRemoteUrl.trim(),
        ...defaultRemoteConfigEndpoints,
        // Fallback to active backend's own /api/config endpoint
        '$_baseUrl/api/config',
        // Fallback to default server URL if active base URL differs
        if (_baseUrl != defaultServerUrl)
          '$defaultServerUrl/api/config',
      ];

      for (final endpoint in endpointsToTry) {
        try {
          final uri = Uri.tryParse(endpoint);
          if (uri == null || !uri.hasScheme) continue;

          final response = await http.get(uri).timeout(timeout);
          if (response.statusCode == 200) {
            final data = json.decode(response.body);
            if (data is Map<String, dynamic>) {
              final remoteServerUrl = data['server_url']?.toString();
              final remoteWsUrl = data['websocket_url']?.toString();

              if (remoteServerUrl != null && remoteServerUrl.trim().isNotEmpty) {
                final sanitizedServerUrl = _sanitizeUrl(remoteServerUrl);
                if (sanitizedServerUrl.isNotEmpty && sanitizedServerUrl != _baseUrl) {
                  debugPrint('[AppConfigService] Updating base URL from remote: $_baseUrl -> $sanitizedServerUrl');
                  _baseUrl = sanitizedServerUrl;
                  _wsUrl = (remoteWsUrl != null && remoteWsUrl.trim().isNotEmpty)
                      ? remoteWsUrl.trim()
                      : _deriveWsUrl(sanitizedServerUrl);

                  await prefs.setString(prefKeyServerUrl, _baseUrl);
                  notifyListeners();
                } else if (remoteWsUrl != null && remoteWsUrl.trim().isNotEmpty) {
                  _wsUrl = remoteWsUrl.trim();
                }
                return true;
              }
            }
          }
        } catch (_) {
          // Continue to next endpoint on failure
        }
      }
    } catch (e) {
      debugPrint('[AppConfigService] fetchRemoteConfig error: $e');
    } finally {
      _isFetchingRemote = false;
    }

    return false;
  }

  /// Updates and persists the backend server URL manually.
  Future<void> updateBaseUrl(String newUrl) async {
    final sanitized = _sanitizeUrl(newUrl);
    if (sanitized.isEmpty) return;

    _baseUrl = sanitized;
    _wsUrl = _deriveWsUrl(sanitized);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKeyServerUrl, _baseUrl);
    } catch (e) {
      debugPrint('[AppConfigService] updateBaseUrl save error: $e');
    }

    notifyListeners();
  }

  /// Sets a custom remote configuration URL.
  Future<void> setCustomRemoteConfigUrl(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (url.trim().isEmpty) {
        await prefs.remove(prefKeyRemoteConfigUrl);
      } else {
        await prefs.setString(prefKeyRemoteConfigUrl, url.trim());
      }
    } catch (_) {}
  }

  /// Sanitizes and validates a URL string.
  static String _sanitizeUrl(String input) {
    var trimmed = input.trim();
    if (trimmed.isEmpty) return '';

    // Remove trailing slashes
    trimmed = trimmed.replaceAll(RegExp(r'/+$'), '');

    // Add http scheme if omitted
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'http://$trimmed';
    }

    try {
      final uri = Uri.parse(trimmed);
      if (uri.hasScheme && uri.host.isNotEmpty) {
        return trimmed;
      }
    } catch (_) {}

    return '';
  }

  /// Derives WebSocket URL from HTTP/HTTPS base URL.
  static String _deriveWsUrl(String httpUrl) {
    if (httpUrl.startsWith('https://')) {
      return 'wss://${httpUrl.substring(8)}/ws';
    } else if (httpUrl.startsWith('http://')) {
      return 'ws://${httpUrl.substring(7)}/ws';
    }
    return 'ws://$httpUrl/ws';
  }
}
