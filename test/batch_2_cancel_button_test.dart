import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/screens/customization_driver_screen.dart';
import 'package:ocr_to_excel/views/screens/edit_bilty_screen.dart';
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
  late BatchItem testItem;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'bnf_user_name': 'Test User',
      'bnf_user_mobile': '9876543210',
    });
    controller = BatchProcessingController(
      permissionService: StubPermissionService(),
      imageService: StubImageService(),
      ocrService: StubOcrService(),
      parserService: FormatParserService(),
      excelService: ExcelService(),
    );
    testItem = BatchItem(
      id: 'test-item-1',
      imagePath: 'test_asset.png',
      fileName: 'test_asset.png',
      status: BatchItemStatus.processing,
      createdAt: DateTime.now(),
      record: {
        'LR No *': 'LR-9999',
        'Customer Name *': 'TEST CUSTOMER',
        'Vehicle No *': 'KA01AB1234',
        'Vehicle Type *': 'Market',
        'cngr *': 'SENDER CO',
        'cnge *': 'RECEIVER CO',
        'goods': 'ELECTRONICS',
      },
    );
  });

  group('Batch 2: Cancel Button UI Update - EditBiltyScreen', () {
    testWidgets('Cancel button is displayed consistently on Tab 0, 1, 2, 3', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(MaterialApp(
        home: EditBiltyScreen(
          item: testItem,
          controller: controller,
        ),
      ));
      await tester.pumpAndSettle();

      // Check Tab 0 (Basic Details)
      expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);

      // Switch to Tab 1 (Consignor / Consignee)
      await tester.ensureVisible(find.text('Consignor / Consignee'));
      await tester.tap(find.text('Consignor / Consignee'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);

      // Switch to Tab 2 (Cargo Details)
      await tester.ensureVisible(find.text('Cargo Details'));
      await tester.tap(find.text('Cargo Details'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);

      // Switch to Tab 3 (Other Details)
      await tester.ensureVisible(find.text('Other Details'));
      await tester.tap(find.text('Other Details'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);
    });

    testWidgets('Tapping Cancel shows confirmation popup and Continue Verification keeps user on screen', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(MaterialApp(
        home: EditBiltyScreen(
          item: testItem,
          controller: controller,
        ),
      ));
      await tester.pumpAndSettle();

      // Tap Cancel button
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pumpAndSettle();

      // Confirmation popup should be visible
      expect(find.text('Cancel Verification?'), findsOneWidget);
      expect(find.text('Are you sure you want to cancel verification? Any unsaved changes may be lost.'), findsOneWidget);
      expect(find.text('Continue Verification'), findsOneWidget);
      expect(find.text('Yes, Cancel'), findsOneWidget);

      // Tap Continue Verification
      await tester.tap(find.text('Continue Verification'));
      await tester.pumpAndSettle();

      // Dialog should be dismissed, screen remains open
      expect(find.text('Cancel Verification?'), findsNothing);
      expect(find.byType(EditBiltyScreen), findsOneWidget);
    });

    testWidgets('Tapping Yes, Cancel in confirmation popup pops EditBiltyScreen', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () {
                Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => EditBiltyScreen(
                    item: testItem,
                    controller: controller,
                  ),
                ));
              },
              child: const Text('Open Step 2'),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Open EditBiltyScreen
      await tester.tap(find.text('Open Step 2'));
      await tester.pumpAndSettle();
      expect(find.byType(EditBiltyScreen), findsOneWidget);

      // Tap Cancel button
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pumpAndSettle();

      // Confirm cancellation
      await tester.tap(find.text('Yes, Cancel'));
      await tester.pumpAndSettle();

      // Screen should have popped back to caller
      expect(find.byType(EditBiltyScreen), findsNothing);
      expect(find.text('Open Step 2'), findsOneWidget);
    });
  });

  group('Batch 2: Cancel Button UI Update - CustomizationDriverScreen', () {
    testWidgets('Cancel button and Back to LR Data are both present on Master Verification', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(MaterialApp(
        home: CustomizationDriverScreen(
          item: testItem,
          controller: controller,
        ),
      ));
      await tester.pumpAndSettle();

      // Ensure Cancel button is scrolled into view and checked
      final cancelFinder = find.widgetWithText(OutlinedButton, 'Cancel');
      await tester.ensureVisible(cancelFinder);
      expect(cancelFinder, findsOneWidget);

      // Back to LR Data present
      expect(find.text('Back to LR Data'), findsAtLeastNWidgets(1));
      // Save & Verify present
      expect(find.widgetWithText(ElevatedButton, 'Save & Verify'), findsOneWidget);
    });

    testWidgets('Tapping Cancel on Master Verification prompts popup and pops on Yes, Cancel', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      dynamic popResult;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                popResult = await Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => CustomizationDriverScreen(
                    item: testItem,
                    controller: controller,
                  ),
                ));
              },
              child: const Text('Open Master'),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Open Master Verification
      await tester.tap(find.text('Open Master'));
      await tester.pumpAndSettle();

      // Scroll to Cancel and tap
      final cancelFinder = find.widgetWithText(OutlinedButton, 'Cancel');
      await tester.ensureVisible(cancelFinder);
      await tester.tap(cancelFinder);
      await tester.pumpAndSettle();

      // Verify dialog appears
      expect(find.text('Cancel Verification?'), findsOneWidget);
      expect(find.text('Continue Verification'), findsOneWidget);
      expect(find.text('Yes, Cancel'), findsOneWidget);

      // Confirm cancel
      await tester.tap(find.text('Yes, Cancel'));
      await tester.pumpAndSettle();

      // CustomizationDriverScreen popped with cancelled: true
      expect(find.byType(CustomizationDriverScreen), findsNothing);
      expect(popResult, isA<Map>());
      expect(popResult['cancelled'], isTrue);
    });
  });
}
