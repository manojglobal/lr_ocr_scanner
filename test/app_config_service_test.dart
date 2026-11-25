import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/services/app_config_service.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';

class _NoopOcrService extends OcrService {
  @override
  Future<void> dispose() async {}
}

class _NoopPermissionService extends PermissionService {}

class _NoopImageService extends ImageService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppConfigService.instance.resetForTesting();
  });

  group('AppConfigService & Centralized Server URL Tests', () {
    test('1. Default base URL is http://192.168.1.3:8000 when no backend replies on Wi-Fi and Auto mode is on by default', () async {
      final config = AppConfigService.instance;
      config.allowDiscoveryInTests = true;
      config.udpDiscoverOverride = (_) async => null;
      config.probeCandidateOverride = (_, _) async => null;
      config.localIpv4ListOverride = () async => [];
      await config.initialize();

      expect(AppConfigService.defaultServerUrl, equals('http://192.168.1.3:8000'));
      expect(AppConfigService.isPrivateLanUrl(AppConfigService.defaultServerUrl), isTrue);
      expect(config.isAutoMode, isTrue);
      expect(config.baseUrl, equals('http://192.168.1.3:8000'));
      expect(config.wsUrl, equals('ws://192.168.1.3:8000/ws'));
    });

    test('1b. Fresh startup auto-discovers and connects to same-Wi-Fi backend automatically', () async {
      final config = AppConfigService.instance;
      config.allowDiscoveryInTests = true;
      config.probeCandidateOverride = (_, _) async => null;
      config.udpDiscoverOverride = (_) async => 'http://192.168.1.44:8000';
      await config.initialize();

      expect(config.isAutoMode, isTrue);
      expect(config.isLocalLanActive, isTrue);
      expect(config.baseUrl, equals('http://192.168.1.44:8000'));
      expect(config.wsUrl, equals('ws://192.168.1.44:8000/ws'));
    });

    test('2. Hydrates custom saved URL from SharedPreferences and locks manual priority', () async {
      SharedPreferences.setMockInitialValues({
        AppConfigService.prefKeyServerUrl: 'http://10.0.0.55:9000/',
      });

      final config = AppConfigService.instance;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConfigService.prefKeyServerUrl, 'http://10.0.0.55:9000/');
      await config.updateBaseUrl('http://10.0.0.55:9000/');

      expect(config.baseUrl, equals('http://10.0.0.55:9000'));
      expect(config.wsUrl, equals('ws://10.0.0.55:9000/ws'));
      expect(config.isManualOverride, isTrue);
      expect(config.isAutoMode, isFalse);
    });

    test('3. Derives wss:// from https:// base URL', () async {
      final config = AppConfigService.instance;
      await config.updateBaseUrl('https://api.boxnfreight.com');

      expect(config.baseUrl, equals('https://api.boxnfreight.com'));
      expect(config.wsUrl, equals('wss://api.boxnfreight.com/ws'));
    });

    test('4. GeminiBackendService shares unified base URL with AppConfigService and saves manual by default', () async {
      final config = AppConfigService.instance;
      await config.updateBaseUrl('http://192.168.1.188:8000');

      final backendService = GeminiBackendService();
      expect(backendService.serverUrl, equals('http://192.168.1.188:8000'));

      await backendService.updateServerUrl('http://192.168.0.224:8000');
      expect(config.baseUrl, equals('http://192.168.0.224:8000'));
      expect(backendService.serverUrl, equals('http://192.168.0.224:8000'));
      expect(config.isManualOverride, isTrue);
    });

    test('5. Auto-discovers same-Wi-Fi backend on startup ONLY when Auto mode is explicitly enabled', () async {
      SharedPreferences.setMockInitialValues({
        AppConfigService.prefKeyServerMode: 'auto',
      });
      final config = AppConfigService.instance;
      config.allowDiscoveryInTests = true;
      config.udpDiscoverOverride = (_) async => 'http://192.168.50.10:8000';
      config.localIpv4ListOverride = () async => ['192.168.50.25'];
      config.probeCandidateOverride = (url, _) async => null;

      await config.initialize();

      expect(config.baseUrl, equals('http://192.168.50.10:8000'));
      expect(config.wsUrl, equals('ws://192.168.50.10:8000/ws'));
      expect(config.isLocalLanActive, isTrue);
      expect(config.isAutoMode, isTrue);
      // While on active local LAN in 'auto' mode, fetchRemoteConfig must not overwrite with production URL
      expect(await config.fetchRemoteConfig(), isFalse);
    });

    test('6. Falls back to /24 HTTP subnet scan when UDP broadcast returns null in explicit Auto mode', () async {
      final config = AppConfigService.instance;
      config.allowDiscoveryInTests = true;
      config.udpDiscoverOverride = (_) async => null;
      config.localIpv4ListOverride = () async => ['192.168.43.15'];
      config.probeCandidateOverride = (url, _) async {
        if (url == 'http://192.168.43.88:8000') return url;
        return null;
      };

      final found = await config.enableAutoModeAndDiscover();

      expect(found, equals('http://192.168.43.88:8000'));
      expect(config.baseUrl, equals('http://192.168.43.88:8000'));
      expect(config.isLocalLanActive, isTrue);
      expect(config.isAutoMode, isTrue);
    });

    test('7. Auto mode rediscovers new Wi-Fi IP on connection error and never silently falls back to Test Server when offline', () async {
      final config = AppConfigService.instance;
      config.allowDiscoveryInTests = true;
      await config.enableAutoMode();
      await config.updateBaseUrl('http://192.168.0.111:8000', manual: false);

      config.udpDiscoverOverride = (_) async => 'http://192.168.1.77:8000';
      config.probeCandidateOverride = (_, _) async => null;
      config.localIpv4ListOverride = () async => [];

      final recovered = await config.handleConnectionErrorAndRediscover(force: true);
      expect(recovered, isTrue);
      expect(config.baseUrl, equals('http://192.168.1.77:8000'));
      expect(config.wsUrl, equals('ws://192.168.1.77:8000/ws'));
      expect(config.isLocalLanActive, isTrue);

      // Simulate leaving Wi-Fi / LAN server temporarily offline -> must preserve saved LAN URL, NOT switch to Test Server
      config.udpDiscoverOverride = (_) async => null;
      config.localIpv4ListOverride = () async => [];
      final resumedChanged = await config.refreshOnAppResume(force: true);
      expect(resumedChanged, isFalse);
      expect(config.baseUrl, equals('http://192.168.1.77:8000'));

      final errRecovered = await config.handleConnectionErrorAndRediscover(force: true);
      expect(errRecovered, isFalse);
      expect(config.baseUrl, equals('http://192.168.1.77:8000'));
    });

    test('8. Manual server selection always takes highest priority across restart, discovery, resume, connection failure, and logout', () async {
      final config = AppConfigService.instance;
      config.allowDiscoveryInTests = true;
      await config.updateBaseUrl('http://192.168.0.135:8000', manual: true);

      // Even if discovery and remote endpoints exist, manual URL is never overridden
      config.udpDiscoverOverride = (_) async => 'http://192.168.1.99:8000';
      config.probeCandidateOverride = (url, _) async => null;
      config.localIpv4ListOverride = () async => [];

      expect(await config.discoverLocalBackend(forceScan: true, applyResult: true), isNull);
      expect(await config.handleConnectionErrorAndRediscover(force: true), isFalse);
      expect(await config.refreshOnAppResume(force: true), isFalse);
      expect(await config.fetchRemoteConfig(), isFalse);
      expect(config.baseUrl, equals('http://192.168.0.135:8000'));

      // Failed Auto-Detect scan must also keep existing manual URL intact
      expect(await config.enableAutoModeAndDiscover(), equals('http://192.168.1.99:8000'));
      // Now re-save manual URL and verify failed Auto scan keeps manual URL protected
      await config.updateBaseUrl('http://192.168.0.135:8000', manual: true);
      config.udpDiscoverOverride = (_) async => null;
      expect(await config.enableAutoModeAndDiscover(), isNull);
      expect(config.baseUrl, equals('http://192.168.0.135:8000'));
      expect(config.isManualOverride, isTrue);

      // Simulate app restart (SharedPreferences persisted across resetForTesting)
      final prefs = await SharedPreferences.getInstance();
      final persisted = <String, Object>{};
      for (final k in prefs.getKeys()) {
        final v = prefs.get(k);
        if (v != null) persisted[k] = v;
      }
      SharedPreferences.setMockInitialValues(persisted);
      config.resetForTesting();
      config.allowDiscoveryInTests = true;
      config.udpDiscoverOverride = (_) async => 'http://192.168.1.99:8000';
      await config.initialize();

      expect(config.baseUrl, equals('http://192.168.0.135:8000'));
      expect(config.isManualOverride, isTrue);
      expect(config.isAutoMode, isFalse);

      // Simulate logout/login cycle -> must preserve manual server selection
      final controller = BatchProcessingController(
        permissionService: _NoopPermissionService(),
        imageService: _NoopImageService(),
        ocrService: _NoopOcrService(),
        useGeminiBackend: true,
      );
      controller.setActiveUser('9876543210', name: 'Operator');
      await Future<void>.delayed(Duration.zero);
      controller.clearForLogout();
      await controller.clearUserCachesOnLogout(mobile: '9876543210');

      // Connection failure during validateSession/checkHealth must also keep manual URL intact
      final backend = controller.geminiService;
      await backend.validateSession('dummy_token');
      await backend.checkHealth();

      expect(AppConfigService.instance.baseUrl, equals('http://192.168.0.135:8000'));
      expect(AppConfigService.instance.isManualOverride, isTrue);
      expect(AppConfigService.instance.isAutoMode, isFalse);
      controller.dispose();
    });

    test('9. Legacy saved non-default URL without override flag migrates to protected manual mode on startup', () async {
      SharedPreferences.setMockInitialValues({
        AppConfigService.prefKeyServerUrl: 'http://192.168.0.135:8000',
      });

      final config = AppConfigService.instance;
      config.allowDiscoveryInTests = true;
      // Local PC temporarily offline on launch & different UDP server on network
      config.udpDiscoverOverride = (_) async => null;
      config.probeCandidateOverride = (_, _) async => null;
      config.localIpv4ListOverride = () async => [];

      await config.initialize();

      expect(config.baseUrl, equals('http://192.168.0.135:8000'));
      expect(config.isManualOverride, isTrue);
      expect(config.isAutoMode, isFalse);
      expect(await config.fetchRemoteConfig(), isFalse);
      expect(await config.handleConnectionErrorAndRediscover(force: true), isFalse);
      expect(config.baseUrl, equals('http://192.168.0.135:8000'));
    });

    test('10. clearManualOverride clears manual flag without enabling Auto mode unexpectedly', () async {
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
      expect(await config.fetchRemoteConfig(), isFalse);

      await config.clearManualOverride();
      expect(config.isManualOverride, isFalse);
    });
  });
}
