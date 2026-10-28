import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/home_screen.dart';
import 'package:ocr_to_excel/views/screens/lr_preview_screen.dart';
import 'package:ocr_to_excel/views/screens/verified_screen.dart';
import 'package:ocr_to_excel/views/screens/edit_bilty_screen.dart';
import 'package:ocr_to_excel/views/widgets/billing_image_viewer.dart';
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
    controller.setActiveUser('9876543210', name: 'Test User');

    testItem = BatchItem(
      id: 'test-lr-1',
      imagePath: '/test/lr_doc.jpg',
      fileName: 'lr_doc.jpg',
      status: BatchItemStatus.completed,
      createdAt: DateTime.now(),
      record: const {
        'LR No *': 'BNF-9988',
        'Vehicle No *': 'WB11K3735',
        'Customer Name *': 'ABC Logistics',
      },
    );
  });

  testWidgets('VerifiedScreen renders View LR Image button and tapping opens BillingImageViewer', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      MaterialApp(
        home: VerifiedScreen(
          item: testItem,
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify 'View LR Image' button exists prominently
    final viewImageBtn = find.widgetWithText(ElevatedButton, 'View LR Image');
    expect(viewImageBtn, findsOneWidget);

    // Verify 'Preview Printable Voucher' secondary button exists
    expect(find.text('Preview Printable Voucher'), findsOneWidget);

    // Ensure button is visible in scrollview and tap
    await tester.ensureVisible(viewImageBtn);
    await tester.pumpAndSettle();
    await tester.tap(viewImageBtn);
    await tester.pumpAndSettle();

    // Verify BillingImageViewer is displayed
    expect(find.byType(BillingImageViewer), findsOneWidget);
  });

  testWidgets('LrPreviewScreen has View LR Image actions that open BillingImageViewer', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      MaterialApp(
        home: LrPreviewScreen(
          item: testItem,
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify AppBar action with tooltip 'View LR Image'
    final appBarAction = find.byTooltip('View LR Image');
    expect(appBarAction, findsOneWidget);

    // Tap AppBar action
    await tester.tap(appBarAction);
    await tester.pumpAndSettle();

    // Verify BillingImageViewer opens
    expect(find.byType(BillingImageViewer), findsOneWidget);
  });

  testWidgets('HomeScreen renders Previously Uploaded LRs and tapping item opens EditBiltyScreen (Step 2)', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    controller.addItemDirectly(testItem);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify 'Previously Uploaded LRs' section exists
    expect(find.text('Previously Uploaded LRs'), findsOneWidget);

    // Tap the item in previously uploaded strip
    final itemFinder = find.text('LR: BNF-9988');
    expect(itemFinder, findsOneWidget);
    await tester.tap(itemFinder);
    await tester.pumpAndSettle();

    // Verify EditBiltyScreen (Step 2) opens with the document as per Web parity
    expect(find.byType(EditBiltyScreen), findsOneWidget);
  });

  testWidgets('BillingImageViewer has Rotate Left and Rotate Right, and removes Excel Format & Excel -Next buttons', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      MaterialApp(
        home: BillingImageViewer(
          items: [testItem],
          initialIndex: 0,
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Verify "Excel Format", "Excel", and "Next" buttons are removed
    expect(find.text('Excel Format'), findsNothing);
    expect(find.text('Excel'), findsNothing);
    expect(find.text('Next'), findsNothing);

    // 2. Verify "Edit LR" button is present
    expect(find.text('Edit LR'), findsOneWidget);

    // 3. Verify Rotate Left and Rotate Right buttons exist in toolbar
    final rotateLeftBtn = find.byTooltip('Rotate Left 90°');
    final rotateRightBtn = find.byTooltip('Rotate Right 90°');
    expect(rotateLeftBtn, findsOneWidget);
    expect(rotateRightBtn, findsOneWidget);

    // 4. Test rotation turns
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox).first).quarterTurns, 0);

    // Tap Rotate Left (Counter-Clockwise) -> quarterTurns should become 3 (270° / -90°)
    await tester.tap(rotateLeftBtn);
    await tester.pumpAndSettle();
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox).first).quarterTurns, 3);

    // Tap Rotate Right (Clockwise) -> quarterTurns should become 0 (back to normal)
    await tester.tap(rotateRightBtn);
    await tester.pumpAndSettle();
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox).first).quarterTurns, 0);

    // Tap Rotate Right again -> quarterTurns should become 1 (90°)
    await tester.tap(rotateRightBtn);
    await tester.pumpAndSettle();
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox).first).quarterTurns, 1);
  });
}
