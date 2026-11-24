import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/services/app_config_service.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppConfigService.instance.resetForTesting();
  });

  group('AppConfigService & Centralized Server URL Tests', () {
    test('1. Default base URL is production fallback (no hardcoded LAN IP) and derives WebSocket URL', () async {
      final config = AppConfigService.instance;
      await config.initialize();

      expect(AppConfigService.defaultServerUrl, equals('http://122.179.131.232:9015'));
      expect(AppConfigService.isPrivateLanUrl(AppConfigService.defaultServerUrl), isFalse);
      expect(config.baseUrl, equals(AppConfigService.defaultServerUrl));
      expect(config.wsUrl, equals('ws://122.179.131.232:9015/ws'));
    });

    test('2. Hydrates custom saved URL from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        AppConfigService.prefKeyServerUrl: 'http://10.0.0.55:9000/',
      });

      final config = AppConfigService.instance;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConfigService.prefKeyServerUrl, 'http://10.0.0.55:9000/');
      await config.updateBaseUrl('http://10.0.0.55:9000/');

      expect(config.baseUrl, equals('http://10.0.0.55:9000'));
      expect(config.wsUrl, equals('ws://10.0.0.55:9000/ws'));
    });

    test('3. Derives wss:// from https:// base URL', () async {
      final config = AppConfigService.instance;
      await config.updateBaseUrl('https://api.boxnfreight.com');

      expect(config.baseUrl, equals('https://api.boxnfreight.com'));
      expect(config.wsUrl, equals('wss://api.boxnfreight.com/ws'));
    });

    test('4. GeminiBackendService shares unified base URL with AppConfigService', () async {
      final config = AppConfigService.instance;
      await config.updateBaseUrl('http://192.168.1.188:8000');

      final backendService = GeminiBackendService();
      expect(backendService.serverUrl, equals('http://192.168.1.188:8000'));

      await backendService.updateServerUrl('http://192.168.0.224:8000');
      expect(config.baseUrl, equals('http://192.168.0.224:8000'));
      expect(backendService.serverUrl, equals('http://192.168.0.224:8000'));
    });

    test('5. Auto-discovers same-Wi-Fi backend on startup via UDP and prevents remote config overwrite', () async {
      final config = AppConfigService.instance;
      config.allowDiscoveryInTests = true;
      config.udpDiscoverOverride = (_) async => 'http://192.168.50.10:8000';
      config.localIpv4ListOverride = () async => ['192.168.50.25'];
      config.probeCandidateOverride = (url, _) async => null;

      await config.initialize();

      expect(config.baseUrl, equals('http://192.168.50.10:8000'));
      expect(config.wsUrl, equals('ws://192.168.50.10:8000/ws'));
      expect(config.isLocalLanActive, isTrue);
      // While on active local LAN in 'auto' mode, fetchRemoteConfig must not overwrite with production URL
      expect(await config.fetchRemoteConfig(), isFalse);
    });

    test('6. Falls back to /24 HTTP subnet scan when UDP broadcast returns null', () async {
      final config = AppConfigService.instance;
      config.allowDiscoveryInTests = true;
      config.udpDiscoverOverride = (_) async => null;
      config.localIpv4ListOverride = () async => ['192.168.43.15'];
      config.probeCandidateOverride = (url, _) async {
        if (url == 'http://192.168.43.88:8000') return url;
        return null;
      };

      final found = await config.discoverLocalBackend(forceScan: true, applyResult: true);

      expect(found, equals('http://192.168.43.88:8000'));
      expect(config.baseUrl, equals('http://192.168.43.88:8000'));
      expect(config.isLocalLanActive, isTrue);
    });

    test('7. Automatically rediscovers new Wi-Fi IP on connection error and falls back to production when offline from LAN', () async {
      final config = AppConfigService.instance;
      config.allowDiscoveryInTests = true;
      await config.updateBaseUrl('http://192.168.0.111:8000');

      config.udpDiscoverOverride = (_) async => 'http://192.168.1.77:9015';
      config.probeCandidateOverride = (_, _) async => null;
      config.localIpv4ListOverride = () async => [];

      final recovered = await config.handleConnectionErrorAndRediscover(force: true);
      expect(recovered, isTrue);
      expect(config.baseUrl, equals('http://192.168.1.77:9015'));
      expect(config.wsUrl, equals('ws://192.168.1.77:9015/ws'));
      expect(config.isLocalLanActive, isTrue);

      // Now simulate leaving Wi-Fi (no local server found on resume) -> reverts cleanly to production
      config.udpDiscoverOverride = (_) async => null;
      config.localIpv4ListOverride = () async => [];
      final resumedChanged = await config.refreshOnAppResume(force: true);
      expect(resumedChanged, isTrue);
      expect(config.baseUrl, equals(AppConfigService.defaultServerUrl));
      expect(config.isLocalLanActive, isFalse);
    });

    test('8. Manual override prevents automatic LAN overwrite until cleared', () async {
      SharedPreferences.setMockInitialValues({
        AppConfigService.prefKeyServerUrl: 'http://10.20.30.40:9015',
        AppConfigService.prefKeyManualOverride: true,
      });

      final config = AppConfigService.instance;
      config.allowDiscoveryInTests = true;
      config.udpDiscoverOverride = (_) async => 'http://192.168.50.10:8000';

      await config.initialize();
      expect(config.baseUrl, equals('http://10.20.30.40:9015'));
      expect(config.isManualOverride, isTrue);

      await config.clearManualOverride();
      expect(config.isManualOverride, isFalse);
    });
  });
}
