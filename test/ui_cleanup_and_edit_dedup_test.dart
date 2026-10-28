import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/main.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/home_screen.dart';
import 'package:ocr_to_excel/views/screens/edit_bilty_screen.dart';
import 'package:ocr_to_excel/views/screens/excel_preview_screen.dart';
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

  final fullMandatoryRecord = <String, String>{
    'grno (*)': 'LR-VERIFIED-99',
    'LR No *': 'LR-VERIFIED-99',
    'grdt *': '25/10/2026',
    'LR Date *': '25/10/2026',
    'Vehicle No *': 'KA23B5235',
    'Vehicle Type *': 'MARKET',
    'Vehicle Category': 'MARKET',
    'Customer Name *': 'HIMALAYA WELLNESS COMPANY',
    'cngr *': 'HIMALAYA SENDER',
    'cngrgstno *': '27ABCDE1234F1Z5',
    'cnge *': 'HIMALAYA RECEIVER',
    'cngegstno *': '27ABCDE1234F2Z6',
    'Driver Name *': 'DHANAJI S PATIL',
    'Mobile no   *': '9739443101',
    'Liscense No *': 'KA23 20000044025',
    'Valid Up to *': '31/12/2030',
    'Loading Start date *': '28/10/2026',
    'freight  *': '15000',
    'Counter': 'CENTRAL',
  };

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'bnf_user_name': 'Test Officer',
      'bnf_user_mobile': '9876543210',
    });

    controller = BatchProcessingController(
      permissionService: StubPermissionService(),
      imageService: StubImageService(),
      ocrService: StubOcrService(),
      parserService: FormatParserService(),
      excelService: ExcelService(),
    );
    controller.setActiveUser('9876543210', name: 'Test Officer');
  });

  group('Item 1: Force Light Mode App-Wide', () {
    testWidgets('App strictly configures Light Theme regardless of system brightness', (tester) async {
      await tester.pumpWidget(const OcrToExcelApp());
      await tester.pump();

      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(materialApp.themeMode, equals(ThemeMode.light));
      expect(materialApp.darkTheme, isNull);
      expect(materialApp.theme?.brightness, equals(Brightness.light));
    });
  });

  group('Item 2: Upload LR Section - Remove User Profile Badge', () {
    testWidgets('HomeScreen subheader removes user profile badge while keeping History button functional', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // 1. History button is present
      expect(find.byKey(const Key('navbar_history_btn')), findsOneWidget);
      expect(find.text('History'), findsOneWidget);

      // 2. User profile PopupMenuButton/badge in subheader is removed
      expect(find.byTooltip('User Profile'), findsNothing);
      expect(find.text('Test Officer'), findsNothing);
    });
  });

  group('Item 3: Verify & Edit LR Section - Remove View LR Image Button', () {
    testWidgets('EditBiltyScreen toolbar removes View LR Image button directly left of History', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final testItem = BatchItem(
        id: 'item-edit-test',
        imagePath: '/test/path.jpg',
        fileName: 'lr_test.jpg',
        status: BatchItemStatus.pending,
        createdAt: DateTime.now(),
        record: Map.from(fullMandatoryRecord),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: EditBiltyScreen(
            item: testItem,
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. In the header toolbar row containing History, View LR Image is removed
      final historyBtn = find.widgetWithText(OutlinedButton, 'History');
      expect(historyBtn, findsOneWidget);

      final toolbarRow = find.ancestor(of: historyBtn, matching: find.byType(Row)).first;
      expect(
        find.descendant(of: toolbarRow, matching: find.widgetWithText(OutlinedButton, 'View LR Image')),
        findsNothing,
      );
    });
  });

  group('Item 4: History Section - Clean Header Controls', () {
    testWidgets('History tab (initialTab: 1) removes user profile badge and Excel Preview tab button', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: ExcelPreviewScreen(controller: controller, initialTab: 1),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Title is History
      expect(find.text('History'), findsOneWidget);

      // 2. User profile badge is removed from header
      expect(find.text('Test Officer'), findsNothing);

      // 3. Sheet 1: BNF Import Format (49 Columns) tab button is removed
      expect(find.textContaining('Sheet 1: BNF Import Format'), findsNothing);

      // 4. History exports section is visible and intact
      expect(find.text('Generated Excel Exports History'), findsOneWidget);
    });
  });

  group('Item 5: Excel Preview Section - Clean Header Controls', () {
    testWidgets('Excel Preview tab (initialTab: 0) removes History button and user profile badge', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: ExcelPreviewScreen(controller: controller, initialTab: 0),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Title is Excel Preview
      expect(find.text('Excel Preview'), findsOneWidget);

      // 2. History button is removed from subheader
      expect(find.byKey(const Key('navbar_history_btn')), findsNothing);

      // 3. User profile badge is removed
      expect(find.text('Test Officer'), findsNothing);

      // 4. Excel data preview switcher & controls remain preserved
      expect(find.textContaining('Sheet 1: BNF Import Format'), findsOneWidget);
      expect(find.text('Add More LR'), findsOneWidget);
    });
  });

  group('Item 6: Fix Duplicate Unverified LRs', () {
    testWidgets('Editing a verified LR updates existing record in-place without creating unverified duplicate', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // Setup a verified LR
      final verifiedItem = BatchItem(
        id: 'verified_lr_101',
        imagePath: '/storage/lr101.jpg',
        fileName: 'lr101.jpg',
        status: BatchItemStatus.completed,
        createdAt: DateTime.now(),
        record: Map.from(fullMandatoryRecord),
      );
      expect(verifiedItem.isVerified, isTrue);

      // Set initial SharedPreferences with this verified LR
      final initialPersisted = [
        {
          'id': 'verified_lr_101',
          'fileName': 'lr101.jpg',
          'imagePath': '/storage/lr101.jpg',
          'lrNo': 'LR-VERIFIED-99',
          'isPdf': false,
          'createdAt': DateTime.now().toIso8601String(),
          'status': 'completed',
          'isVerified': true,
          'record': Map.from(fullMandatoryRecord),
        }
      ];

      SharedPreferences.setMockInitialValues({
        'bnf_user_name': 'Test Officer',
        'bnf_user_mobile': '9876543210',
        'bnf_recent_uploaded_lrs': jsonEncode(initialPersisted),
      });

      // Add to controller
      controller.addItemDirectly(verifiedItem);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Verify only 1 file is shown in Previously Uploaded LRs
      expect(find.text('Previously Uploaded LRs'), findsOneWidget);
      expect(find.text('1 files'), findsOneWidget);

      // Verify the badge is "Verified" and NOT "Unverified"
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Unverified'), findsNothing);

      // Tap the LR to reopen for editing
      await tester.tap(find.text('LR: LR-VERIFIED-99'));
      await tester.pumpAndSettle();

      // EditBiltyScreen should be displayed
      expect(find.byType(EditBiltyScreen), findsOneWidget);

      // Update the LR in controller (simulating edit save)
      final updatedRecord = Map<String, String>.from(fullMandatoryRecord);
      updatedRecord['LR No *'] = 'LR-VERIFIED-99-EDITED';
      final updatedItem = verifiedItem.copyWith(record: updatedRecord);
      controller.updateItem(updatedItem);

      // Pop back to HomeScreen
      Navigator.of(tester.element(find.byType(EditBiltyScreen))).pop();
      await tester.pumpAndSettle();

      // After editing and saving, confirm:
      // 1. Still only 1 file exists (no duplicate unverified entry created)
      expect(find.text('1 files'), findsOneWidget);

      // 2. The single LR record is updated to the new LR No
      expect(find.text('LR: LR-VERIFIED-99-EDITED'), findsOneWidget);
      expect(find.text('LR: LR-VERIFIED-99'), findsNothing);

      // 3. Status remains "Verified" and no "Unverified" duplicate is shown
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Unverified'), findsNothing);
    });
  });
}
