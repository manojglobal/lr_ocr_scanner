import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/home_screen.dart';
import 'package:ocr_to_excel/views/login_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StubPermissionService extends PermissionService {}
class StubImageService extends ImageService {}
class StubOcrService extends OcrService {
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BatchProcessingController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'bnf_user_name': 'Test Officer',
      'bnf_user_mobile': '9876543210',
      'bnf_user_token': 'fake_token_abc',
    });

    controller = BatchProcessingController(
      permissionService: StubPermissionService(),
      imageService: StubImageService(),
      ocrService: StubOcrService(),
      parserService: FormatParserService(),
      excelService: ExcelService(),
    );
    controller.setActiveUser('9876543210', name: 'Test Officer', sessionToken: 'fake_token_abc');
  });

  group('Batch 4: Logout UI & Session Handling', () {
    testWidgets('Item 1: Visible hamburger menu icon exists in AppBar', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Verify the hamburger menu icon exists in AppBar
      final hamburgerBtn = find.byKey(const Key('hamburger_menu_btn'));
      expect(hamburgerBtn, findsOneWidget);
      expect(find.byIcon(Icons.menu), findsOneWidget);
    });

    testWidgets('Item 1 & 2: Tapping hamburger menu opens drawer with Logout option', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Tap the hamburger menu button
      final hamburgerBtn = find.byKey(const Key('hamburger_menu_btn'));
      await tester.tap(hamburgerBtn);
      await tester.pumpAndSettle();

      // Drawer should be open and display user details
      expect(find.byType(Drawer), findsOneWidget);
      expect(find.text('User: Test Officer'), findsOneWidget);
      expect(find.text('9876543210'), findsOneWidget);

      // Verify Drawer contains navigation items and visible Logout option
      final drawerFinder = find.byType(Drawer);
      expect(find.descendant(of: drawerFinder, matching: find.text('Home')), findsOneWidget);
      expect(find.descendant(of: drawerFinder, matching: find.text('LR History')), findsOneWidget);
      expect(find.descendant(of: drawerFinder, matching: find.text('LR List')), findsOneWidget);

      final drawerLogoutBtn = find.byKey(const Key('drawer_logout_btn'));
      expect(drawerLogoutBtn, findsOneWidget);
      expect(find.text('Logout'), findsWidgets);
    });

    testWidgets('Item 2: Logout confirms and navigates to LoginScreen while clearing session', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Open drawer
      await tester.tap(find.byKey(const Key('hamburger_menu_btn')));
      await tester.pumpAndSettle();

      // 2. Tap Logout in the drawer
      await tester.tap(find.byKey(const Key('drawer_logout_btn')));
      await tester.pumpAndSettle();

      // 3. Confirm dialog appears
      expect(find.text('Logout?'), findsOneWidget);
      expect(find.text('Are you sure you want to log out of your session?'), findsOneWidget);

      // 4. Confirm logout
      final confirmBtn = find.widgetWithText(FilledButton, 'Logout');
      expect(confirmBtn, findsOneWidget);
      await tester.tap(confirmBtn);
      await tester.pumpAndSettle();

      // 5. Verify user is returned to LoginScreen
      expect(find.byType(LoginScreen), findsOneWidget);

      // 6. Verify SharedPreferences session keys are cleared
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bnf_user_name'), isNull);
      expect(prefs.getString('bnf_user_mobile'), isNull);
      expect(prefs.getString('bnf_user_token'), isNull);

      // 7. Verify controller session is cleared
      expect(controller.activeUserMobile, isNull);
      expect(controller.activeUserName, isNull);
      expect(controller.activeSessionToken, isNull);
    });
  });
}
