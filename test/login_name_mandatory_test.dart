import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/login_screen.dart';
import 'package:ocr_to_excel/views/home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Mandatory Name Field Validation Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets('1. Displays "Your Name *" mandatory label', (tester) async {
      final controller = BatchProcessingController(useGeminiBackend: false);

      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Your Name *'), findsOneWidget);
    });

    testWidgets('2. Prevents submission and displays "Please enter your name." when name is empty', (tester) async {
      final controller = BatchProcessingController(useGeminiBackend: false);

      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Clear the name field
      final nameField = find.widgetWithText(TextField, 'Your Name *');
      expect(nameField, findsOneWidget);
      await tester.enterText(nameField, '');
      await tester.pumpAndSettle();

      // Ensure mobile has valid number
      final mobileField = find.widgetWithText(TextField, 'Mobile Number *');
      await tester.enterText(mobileField, '9876543210');
      await tester.pumpAndSettle();

      // Tap Login & Continue
      await tester.tap(find.text('Login & Continue'));
      await tester.pumpAndSettle();

      // Verify error message is displayed
      expect(find.text('Please enter your name.'), findsOneWidget);
      // Verify did NOT navigate to HomeScreen
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('3. Prevents submission and displays "Please enter your name." when name is whitespace only', (tester) async {
      final controller = BatchProcessingController(useGeminiBackend: false);

      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Enter only spaces in the name field
      final nameField = find.widgetWithText(TextField, 'Your Name *');
      await tester.enterText(nameField, '     ');
      await tester.pumpAndSettle();

      final mobileField = find.widgetWithText(TextField, 'Mobile Number *');
      await tester.enterText(mobileField, '9876543210');
      await tester.pumpAndSettle();

      // Tap Login & Continue
      await tester.tap(find.text('Login & Continue'));
      await tester.pumpAndSettle();

      // Verify error message is displayed
      expect(find.text('Please enter your name.'), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('4. Trims and accepts valid name, navigating to HomeScreen and saving to SharedPreferences', (tester) async {
      final controller = BatchProcessingController(useGeminiBackend: false);

      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Enter name with surrounding spaces to verify trimming
      final nameField = find.widgetWithText(TextField, 'Your Name *');
      await tester.enterText(nameField, '  Ruchita Patel  ');
      await tester.pumpAndSettle();

      final mobileField = find.widgetWithText(TextField, 'Mobile Number *');
      await tester.enterText(mobileField, '9876543210');
      await tester.pumpAndSettle();

      // Tap Login & Continue
      await tester.tap(find.text('Login & Continue'));
      await tester.pumpAndSettle();

      // Verify navigated to HomeScreen
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(controller.activeUserName, 'Ruchita Patel');
      expect(controller.activeUserMobile, '9876543210');

      // Verify saved in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bnf_user_name'), 'Ruchita Patel');
      expect(prefs.getString('bnf_user_mobile'), '9876543210');
    });
  });
}
