import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';
import 'package:ocr_to_excel/views/login_screen.dart';
import 'package:ocr_to_excel/views/home_screen.dart';

class MockGeminiServiceValid extends GeminiBackendService {
  @override
  Future<Map<String, dynamic>> validateSession(String token) async {
    return {
      'valid': true,
      'user': {'mobile': '8009970417', 'name': 'Maurya'},
      'statusCode': 200,
    };
  }
}

class MockGeminiServiceUnauthorized extends GeminiBackendService {
  @override
  Future<Map<String, dynamic>> validateSession(String token) async {
    return {
      'valid': false,
      'statusCode': 401,
      'error': 'Session expired or invalidated',
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('24-Hour Session Persistence Tests', () {
    testWidgets('1. Auto-restores valid session within 24 hours and opens HomeScreen', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'bnf_user_mobile': '8009970417',
        'bnf_user_name': 'Maurya',
        'bnf_user_token': 'bnf_valid_token_test_123',
        'bnf_session_expires_at': now + (23 * 60 * 60 * 1000), // 23h in future (< 24h)
      });

      final controller = BatchProcessingController(geminiService: MockGeminiServiceValid());
      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Verified HomeScreen is opened
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(controller.activeUserMobile, equals('8009970417'));
      expect(controller.activeUserName, equals('Maurya'));
    });

    testWidgets('2. Rejects session expired past 24 hours, wipes storage, and displays message', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'bnf_user_mobile': '8009970417',
        'bnf_user_name': 'Maurya',
        'bnf_user_token': 'bnf_expired_token_test_123',
        'bnf_session_expires_at': now - 1000, // 1 second in past (> 24 hours expired)
      });

      final controller = BatchProcessingController(geminiService: MockGeminiServiceValid());
      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Remains on LoginScreen
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.text('Session expired after 24 hours. Please log in again.'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bnf_user_token'), isNull);
      expect(prefs.getInt('bnf_session_expires_at'), isNull);
    });

    testWidgets('3. Rejects session if backend returns 401 unauthorized, wipes storage', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'bnf_user_mobile': '8009970417',
        'bnf_user_name': 'Maurya',
        'bnf_user_token': 'bnf_revoked_token_test_123',
        'bnf_session_expires_at': now + (10 * 60 * 60 * 1000),
      });

      final controller = BatchProcessingController(geminiService: MockGeminiServiceUnauthorized());
      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Remains on LoginScreen
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.text('Session expired or invalidated. Please log in again.'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bnf_user_token'), isNull);
      expect(prefs.getInt('bnf_session_expires_at'), isNull);
    });
  });
}
