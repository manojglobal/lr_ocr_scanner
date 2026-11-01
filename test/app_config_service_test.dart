import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/services/app_config_service.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('AppConfigService & Centralized Server URL Tests', () {
    test('1. Default base URL and derived WebSocket URL', () async {
      final config = AppConfigService.instance;
      await config.initialize();

      expect(config.baseUrl, equals('http://192.168.0.224:8000'));
      expect(config.wsUrl, equals('ws://192.168.0.224:8000/ws'));
    });

    test('2. Hydrates custom saved URL from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        AppConfigService.prefKeyServerUrl: 'http://10.0.0.55:9000/',
      });

      final config = AppConfigService.instance;
      // Re-initialize with new prefs
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConfigService.prefKeyServerUrl, 'http://10.0.0.55:9000/');
      await config.updateBaseUrl('http://10.0.0.55:9000/');

      // Trailing slash should be sanitized
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

      // Updating through service updates central config
      await backendService.updateServerUrl('http://192.168.0.224:8000');
      expect(config.baseUrl, equals('http://192.168.0.224:8000'));
      expect(backendService.serverUrl, equals('http://192.168.0.224:8000'));
    });
  });
}
