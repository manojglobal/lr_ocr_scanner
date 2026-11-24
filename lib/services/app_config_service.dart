import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Centralized service managing backend server URL resolution, same-Wi-Fi LAN
/// auto-discovery, remote configuration, and local persistence.
class AppConfigService extends ChangeNotifier {
  static final AppConfigService instance = AppConfigService._internal();
  AppConfigService._internal();

  static const String prefKeyServerUrl = 'gemini_backend_server_url';
  static const String prefKeyRemoteConfigUrl = 'app_remote_config_url';
  static const String prefKeyIsLocalLan = 'bnf_is_local_lan_url';
  static const String prefKeyManualOverride = 'bnf_manual_server_override';

  /// Build-time environment mode:
  /// - 'auto' (default): Auto-discovers same-Wi-Fi backend first, falls back to production if none responds.
  /// - 'local': Auto-discovers same-Wi-Fi backend without silently falling back to production.
  /// - 'prod' : Uses production server URL + remote config directly (zero LAN discovery).
  static const String envMode = String.fromEnvironment('ENV_MODE', defaultValue: 'auto');

  /// Production fallback/default server URL (no local LAN IP is hardcoded).
  static const String defaultServerUrl = 'http://122.179.131.232:9015';

  static const int discoveryUdpPort = 8001;
  static const int defaultLocalHttpPort = 8000;
  static const String discoveryMagic = 'OCR_TO_EXCEL_DISCOVER';

  /// Primary remote configuration endpoints for production builds or non-LAN usage.
  static const List<String> defaultRemoteConfigEndpoints = [
    'https://raw.githubusercontent.com/boxnfreight/ocr_to_excel_config/main/server_config.json',
  ];

  String _baseUrl = defaultServerUrl;
  String _wsUrl = 'ws://122.179.131.232:9015/ws';
  bool _isInitialized = false;
  bool _isFetchingRemote = false;
  bool _isLocalLanActive = false;
  bool _manualOverride = false;
  int _configEpoch = 0;
  Future<void>? _inFlightInitialize;
  Future<String?>? _inFlightDiscovery;
  DateTime? _lastRediscoverAttempt;
  DateTime? _lastResumeCheck;

  /// Optional test hooks so unit tests can exercise LAN discovery deterministically.
  @visibleForTesting
  bool? allowDiscoveryInTests;
  @visibleForTesting
  Future<String?> Function(String candidateUrl, Duration timeout)? probeCandidateOverride;
  @visibleForTesting
  Future<String?> Function(Duration timeout)? udpDiscoverOverride;
  @visibleForTesting
  Future<List<String>> Function()? localIpv4ListOverride;

  String get baseUrl => _baseUrl;
  String get wsUrl => _wsUrl;
  bool get isInitialized => _isInitialized;
  bool get isFetchingRemote => _isFetchingRemote;
  bool get isLocalLanActive => _isLocalLanActive;
  bool get isManualOverride => _manualOverride;

  bool get _canAutoDiscover {
    if (envMode == 'prod') return false;
    final inFlutterTest = Platform.environment.containsKey('FLUTTER_TEST');
    if (inFlutterTest && allowDiscoveryInTests != true) return false;
    return true;
  }

  /// Hydrates cached server URL immediately, runs same-Wi-Fi LAN discovery in
  /// 'auto'/'local' mode, and triggers remote config only when appropriate.
  Future<void> initialize() {
    if (_isInitialized) return Future.value();
    if (_inFlightInitialize != null) return _inFlightInitialize!;
    final future = _doInitialize();
    _inFlightInitialize = future;
    return future.whenComplete(() {
      if (_inFlightInitialize == future) _inFlightInitialize = null;
    });
  }

  Future<void> _doInitialize() async {
    final startEpoch = _configEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_configEpoch == startEpoch) {
        final saved = prefs.getString(prefKeyServerUrl);
        _manualOverride = prefs.getBool(prefKeyManualOverride) ?? false;

        if (saved != null && saved.trim().isNotEmpty) {
          final cleaned = _sanitizeUrl(saved);
          if (cleaned.isNotEmpty) {
            _baseUrl = cleaned;
            _wsUrl = _deriveWsUrl(cleaned);
            _isLocalLanActive = isPrivateLanUrl(cleaned);
          }
        } else {
          _baseUrl = defaultServerUrl;
          _wsUrl = _deriveWsUrl(defaultServerUrl);
          _isLocalLanActive = false;
        }
      }
    } catch (e) {
      debugPrint('[AppConfigService] Init cache read error: $e');
      if (_configEpoch == startEpoch) {
        _baseUrl = defaultServerUrl;
        _wsUrl = _deriveWsUrl(defaultServerUrl);
        _isLocalLanActive = false;
      }
    }

    if (_canAutoDiscover && !_manualOverride && _configEpoch == startEpoch) {
      final discovered = await discoverLocalBackend(
        cachedLanUrl: isPrivateLanUrl(_baseUrl) ? _baseUrl : null,
      );
      if (_configEpoch == startEpoch) {
        if (discovered != null) {
          await _applyDiscoveredLocalUrl(discovered);
        } else {
          _isLocalLanActive = false;
          if (envMode == 'auto' && isPrivateLanUrl(_baseUrl)) {
            _baseUrl = defaultServerUrl;
            _wsUrl = _deriveWsUrl(defaultServerUrl);
          }
        }
      }
    }

    _isInitialized = true;
    notifyListeners();

    final shouldFetchRemote = envMode == 'prod' || (envMode == 'auto' && !_isLocalLanActive);
    if (shouldFetchRemote && !_canSkipBackgroundRemoteInTest) {
      unawaited(fetchRemoteConfig());
    }
  }

  bool get _canSkipBackgroundRemoteInTest =>
      Platform.environment.containsKey('FLUTTER_TEST') && allowDiscoveryInTests != true;

  /// Runs tiered LAN discovery (1. Verify cached LAN IP, 2. UDP broadcast,
  /// 3. Parallel /24 HTTP subnet probe) and optionally applies the result.
  Future<String?> discoverLocalBackend({
    String? cachedLanUrl,
    bool forceScan = false,
    bool applyResult = false,
  }) async {
    if (envMode == 'prod') return null;

    if (_inFlightDiscovery != null) {
      final existing = await _inFlightDiscovery!;
      if (applyResult && existing != null) {
        await _applyDiscoveredLocalUrl(existing, clearManualOverride: true);
      }
      return existing;
    }

    final future = _runDiscoveryChain(
      cachedLanUrl: cachedLanUrl ?? (isPrivateLanUrl(_baseUrl) ? _baseUrl : null),
      forceScan: forceScan,
    );
    _inFlightDiscovery = future;
    try {
      final found = await future;
      if (applyResult && found != null) {
        await _applyDiscoveredLocalUrl(found, clearManualOverride: true);
      }
      return found;
    } finally {
      _inFlightDiscovery = null;
    }
  }

  Future<String?> _runDiscoveryChain({
    String? cachedLanUrl,
    required bool forceScan,
  }) async {
    // Tier 1: Fast verify last known LAN URL
    if (!forceScan && cachedLanUrl != null && isPrivateLanUrl(cachedLanUrl)) {
      final verified = await _probeCandidate(cachedLanUrl, const Duration(milliseconds: 700));
      if (verified != null) return verified;
    }

    // Tier 2: Fast UDP broadcast across local Wi-Fi interface(s)
    final udpFound = await _discoverViaUdpBroadcast(const Duration(milliseconds: 650));
    if (udpFound != null) return udpFound;

    // Tier 3: Asynchronous /24 subnet HTTP fallback when UDP broadcast is filtered
    final subnetFound = await _discoverViaSubnetProbe(const Duration(milliseconds: 500));
    if (subnetFound != null) return subnetFound;

    return null;
  }

  Future<void> _applyDiscoveredLocalUrl(
    String discoveredUrl, {
    bool clearManualOverride = false,
  }) async {
    final cleaned = _sanitizeUrl(discoveredUrl);
    if (cleaned.isEmpty) return;

    final changed = cleaned != _baseUrl || !_isLocalLanActive;
    _baseUrl = cleaned;
    _wsUrl = _deriveWsUrl(cleaned);
    _isLocalLanActive = true;
    if (clearManualOverride) {
      _manualOverride = false;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKeyServerUrl, _baseUrl);
      await prefs.setBool(prefKeyIsLocalLan, true);
      if (clearManualOverride) {
        await prefs.setBool(prefKeyManualOverride, false);
      }
    } catch (e) {
      debugPrint('[AppConfigService] Save discovered URL error: $e');
    }

    if (changed) {
      notifyListeners();
    }
  }

  /// Called automatically when an API call encounters a network/socket failure
  /// (e.g., PC IP changed or device switched Wi-Fi) so callers can retry.
  Future<bool> handleConnectionErrorAndRediscover({bool force = false}) async {
    if (!_canAutoDiscover || _manualOverride) return false;

    final now = DateTime.now();
    if (!force &&
        _lastRediscoverAttempt != null &&
        now.difference(_lastRediscoverAttempt!) < const Duration(seconds: 4)) {
      return false;
    }
    _lastRediscoverAttempt = now;

    final discovered = await discoverLocalBackend(forceScan: true);
    if (discovered != null) {
      await _applyDiscoveredLocalUrl(discovered);
      return true;
    }

    if (envMode == 'auto' && _isLocalLanActive) {
      _isLocalLanActive = false;
      if (isPrivateLanUrl(_baseUrl)) {
        _baseUrl = defaultServerUrl;
        _wsUrl = _deriveWsUrl(defaultServerUrl);
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  /// Called when app returns to foreground (AppLifecycleState.resumed).
  /// Returns true if the active backend baseUrl changed.
  Future<bool> refreshOnAppResume({bool force = false}) async {
    if (!_canAutoDiscover || _manualOverride) return false;

    final now = DateTime.now();
    if (!force &&
        _lastResumeCheck != null &&
        now.difference(_lastResumeCheck!) < const Duration(seconds: 8)) {
      return false;
    }
    _lastResumeCheck = now;

    final prevUrl = _baseUrl;

    // If currently pointing to a LAN URL, check if it is still reachable on this Wi-Fi
    if (_isLocalLanActive || isPrivateLanUrl(_baseUrl)) {
      final stillAlive = await _probeCandidate(_baseUrl, const Duration(milliseconds: 650));
      if (stillAlive != null) {
        return false;
      }
    }

    final discovered = await discoverLocalBackend(forceScan: true);
    if (discovered != null) {
      await _applyDiscoveredLocalUrl(discovered);
      return _baseUrl != prevUrl;
    }

    if (envMode == 'auto' && isPrivateLanUrl(_baseUrl)) {
      _isLocalLanActive = false;
      _baseUrl = defaultServerUrl;
      _wsUrl = _deriveWsUrl(defaultServerUrl);
      notifyListeners();
      unawaited(fetchRemoteConfig());
      return _baseUrl != prevUrl;
    }

    return false;
  }

  Future<String?> _probeCandidate(String candidateUrl, Duration timeout) async {
    if (probeCandidateOverride != null) {
      return probeCandidateOverride!(candidateUrl, timeout);
    }

    final cleaned = _sanitizeUrl(candidateUrl);
    if (cleaned.isEmpty) return null;

    HttpClient? client;
    try {
      final baseUri = Uri.parse(cleaned);
      final discoverUri = baseUri.replace(path: '/api/discover', query: null, fragment: null);
      client = HttpClient()..connectionTimeout = timeout;
      final req = await client.getUrl(discoverUri).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) return null;

      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final decoded = json.decode(body);
      if (decoded is Map && decoded['service'] == 'ocr_to_excel') {
        final dynamic portRaw = decoded['port'];
        final int port = portRaw is int
            ? portRaw
            : (int.tryParse(portRaw?.toString() ?? '') ?? (baseUri.hasPort ? baseUri.port : defaultLocalHttpPort));
        return '${baseUri.scheme}://${baseUri.host}:$port';
      }
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
    return null;
  }

  Future<String?> _discoverViaUdpBroadcast(Duration timeout) async {
    if (udpDiscoverOverride != null) {
      return udpDiscoverOverride!(timeout);
    }

    RawDatagramSocket? socket;
    try {
      final ips = await _getLocalIpv4Addresses();
      final targets = <InternetAddress>{
        InternetAddress('255.255.255.255'),
      };
      for (final ip in ips) {
        final parts = ip.split('.');
        if (parts.length == 4) {
          targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
        }
      }

      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      final completer = Completer<String?>();
      final payload = utf8.encode(discoveryMagic);

      late StreamSubscription<RawSocketEvent> sub;
      sub = socket.listen((event) async {
        if (event != RawSocketEvent.read) return;
        while (true) {
          final dg = socket?.receive();
          if (dg == null) break;
          try {
            final msg = utf8.decode(dg.data);
            final decoded = json.decode(msg);
            if (decoded is Map && decoded['service'] == 'ocr_to_excel') {
              final senderIp = dg.address.address;
              final dynamic portRaw = decoded['port'];
              final int port = portRaw is int
                  ? portRaw
                  : (int.tryParse(portRaw?.toString() ?? '') ?? defaultLocalHttpPort);

              final candidates = <String>[
                'http://$senderIp:$port',
                if (decoded['ip'] != null &&
                    decoded['ip'].toString().trim().isNotEmpty &&
                    decoded['ip'].toString().trim() != senderIp)
                  'http://${decoded['ip'].toString().trim()}:$port',
              ];

              for (final c in candidates) {
                final verified = await _probeCandidate(c, const Duration(milliseconds: 550));
                if (verified != null && !completer.isCompleted) {
                  completer.complete(verified);
                  return;
                }
              }
            }
          } catch (_) {}
        }
      });

      for (final target in targets) {
        try {
          socket.send(payload, target, discoveryUdpPort);
        } catch (_) {}
      }

      final retryTimer = Timer(const Duration(milliseconds: 110), () {
        if (completer.isCompleted || socket == null) return;
        for (final target in targets) {
          try {
            socket.send(payload, target, discoveryUdpPort);
          } catch (_) {}
        }
      });

      final timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete(null);
      });

      final result = await completer.future;
      retryTimer.cancel();
      timeoutTimer.cancel();
      await sub.cancel();
      return result;
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  Future<String?> _discoverViaSubnetProbe(Duration timeout) async {
    final ips = await _getLocalIpv4Addresses();
    final prefixes = <String>[];
    final selfIps = ips.toSet();

    for (final ip in ips) {
      if (!isPrivateIpv4(ip)) continue;
      final parts = ip.split('.');
      if (parts.length != 4) continue;
      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
      if (!prefixes.contains(prefix)) prefixes.add(prefix);
    }

    if (prefixes.isEmpty) return null;

    for (final prefix in prefixes.take(2)) {
      final hosts = <String>[];
      for (var octet = 1; octet <= 254; octet++) {
        final ip = '$prefix.$octet';
        if (!selfIps.contains(ip)) hosts.add(ip);
      }

      const batchSize = 32;
      for (var i = 0; i < hosts.length; i += batchSize) {
        final end = (i + batchSize < hosts.length) ? i + batchSize : hosts.length;
        final batch = hosts.sublist(i, end);
        final results = await Future.wait(
          batch.map((ip) => _probeCandidate('http://$ip:$defaultLocalHttpPort', timeout)),
        );
        for (final found in results) {
          if (found != null) return found;
        }
      }
    }

    return null;
  }

  Future<List<String>> _getLocalIpv4Addresses() async {
    if (localIpv4ListOverride != null) {
      return localIpv4ListOverride!();
    }

    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final preferred = <String>[];
      final others = <String>[];
      for (final iface in interfaces) {
        final lowerName = iface.name.toLowerCase();
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('169.254.') || ip.startsWith('127.')) continue;
          if (lowerName.contains('wlan') || lowerName.contains('wi-fi') || lowerName.contains('wifi') || lowerName.contains('eth')) {
            preferred.add(ip);
          } else {
            others.add(ip);
          }
        }
      }
      return [...preferred, ...others];
    } catch (_) {
      return [];
    }
  }

  /// Fetches centralized remote configuration when running in production mode
  /// or when no local Wi-Fi backend is active.
  Future<bool> fetchRemoteConfig({Duration timeout = const Duration(seconds: 2)}) async {
    if (envMode == 'local') return false;
    if (envMode == 'auto' && _isLocalLanActive) return false;
    if (_isFetchingRemote) return false;
    _isFetchingRemote = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final customRemoteUrl = prefs.getString(prefKeyRemoteConfigUrl);

      final endpointsToTry = <String>[
        if (customRemoteUrl != null && customRemoteUrl.trim().isNotEmpty)
          customRemoteUrl.trim(),
        ...defaultRemoteConfigEndpoints,
        '$_baseUrl/api/config',
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
                  if (envMode == 'auto' && _isLocalLanActive) return false;
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

  /// Updates and persists the backend server URL.
  Future<void> updateBaseUrl(String newUrl, {bool manual = false}) async {
    final sanitized = _sanitizeUrl(newUrl);
    if (sanitized.isEmpty) return;

    _configEpoch++;
    _baseUrl = sanitized;
    _wsUrl = _deriveWsUrl(sanitized);
    _isLocalLanActive = isPrivateLanUrl(sanitized);
    if (manual) {
      _manualOverride = true;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKeyServerUrl, _baseUrl);
      await prefs.setBool(prefKeyIsLocalLan, _isLocalLanActive);
      if (manual) {
        await prefs.setBool(prefKeyManualOverride, true);
      }
    } catch (e) {
      debugPrint('[AppConfigService] updateBaseUrl save error: $e');
    }

    notifyListeners();
  }

  /// Clears any manual override and switches back to Wi-Fi auto-discovery.
  Future<void> clearManualOverride() async {
    _manualOverride = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKeyManualOverride, false);
    } catch (_) {}
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

  /// Resets singleton state for deterministic unit tests.
  @visibleForTesting
  void resetForTesting() {
    _isInitialized = false;
    _isFetchingRemote = false;
    _isLocalLanActive = false;
    _manualOverride = false;
    _configEpoch = 0;
    _inFlightInitialize = null;
    _inFlightDiscovery = null;
    _lastRediscoverAttempt = null;
    _lastResumeCheck = null;
    allowDiscoveryInTests = null;
    probeCandidateOverride = null;
    udpDiscoverOverride = null;
    localIpv4ListOverride = null;
    _baseUrl = defaultServerUrl;
    _wsUrl = _deriveWsUrl(defaultServerUrl);
  }

  /// Returns true if [url] points to a private/local LAN IPv4 address.
  static bool isPrivateLanUrl(String url) {
    try {
      final uri = Uri.tryParse(_sanitizeUrl(url));
      if (uri == null || uri.host.isEmpty) return false;
      return isPrivateIpv4(uri.host);
    } catch (_) {
      return false;
    }
  }

  /// Returns true if [host] is an RFC1918 LAN IPv4 address (plus loopback).
  static bool isPrivateIpv4(String host) {
    if (host == 'localhost') return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    final c = int.tryParse(parts[2]);
    final d = int.tryParse(parts[3]);
    if (a == null || b == null || c == null || d == null) return false;
    if (a == 10 || a == 127) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }

  /// Sanitizes and validates a URL string.
  static String _sanitizeUrl(String input) {
    var trimmed = input.trim();
    if (trimmed.isEmpty) return '';

    trimmed = trimmed.replaceAll(RegExp(r'/+$'), '');

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
