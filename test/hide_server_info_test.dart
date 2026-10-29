import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/login_screen.dart';
import 'package:ocr_to_excel/views/home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Hide Server Info in Android App UI Verification', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'bnf_user_name': 'Logistics Manager',
        'bnf_user_mobile': '9876543210',
        'gemini_backend_server_url': 'http://192.168.1.2:8000',
      });
    });

    testWidgets('LoginScreen hides server URL, settings icon, and status pill from user UI', (tester) async {
      final controller = BatchProcessingController(useGeminiBackend: false);

      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Verify header server icon is NOT present
      expect(find.byIcon(Icons.settings_ethernet), findsNothing);
      expect(find.byTooltip('Server IP Settings'), findsNothing);

      // 2. Verify bottom server pill and server URL are NOT visible
      expect(find.byIcon(Icons.dns_outlined), findsNothing);
      expect(find.textContaining('Server:'), findsNothing);
      expect(find.textContaining('192.168.1.2'), findsNothing);

      // 3. Verify standard login elements remain fully functional
      expect(find.text('BOX N FREIGHT'), findsOneWidget);
      expect(find.text('Secure Logistics Portal'), findsOneWidget);
      expect(find.text('Login & Continue'), findsOneWidget);
    });

    testWidgets('HomeScreen hides green cloud server indicator from user UI while keeping History button', (tester) async {
      final controller = BatchProcessingController(useGeminiBackend: true);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Verify green cloud server status indicator icon is NOT present
      expect(find.byIcon(Icons.cloud_done_rounded), findsNothing);
      expect(find.byIcon(Icons.cloud_off_rounded), findsNothing);
      expect(find.byTooltip('Server Settings'), findsNothing);

      // 2. Verify History button directly below title remains intact
      expect(find.byKey(const Key('navbar_history_btn')), findsOneWidget);
      expect(find.text('History'), findsOneWidget);

      // 3. Verify page title and intake actions remain intact
      expect(find.text('BOX N FREIGHT'), findsOneWidget);
      expect(find.text('Upload Consignment Notes (LRs)'), findsOneWidget);
      expect(find.text('Capture Image'), findsOneWidget);
      expect(find.text('Select Image'), findsOneWidget);

      // 4. Verify hidden developer long-press access on drawer logo
      final scaffoldState = tester.firstState<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      final drawerAvatar = find.descendant(
        of: find.byType(UserAccountsDrawerHeader),
        matching: find.text('BNF'),
      );
      expect(drawerAvatar, findsOneWidget);

      // Long press the BNF logo in the drawer to test developer configuration fallback
      await tester.longPress(drawerAvatar);
      await tester.pumpAndSettle();

      // Dialog opens via hidden developer gesture
      expect(find.text('Extraction Server'), findsOneWidget);
      expect(find.text('Server Base URL:'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });
  });
}
