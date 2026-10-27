import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/screens/batch_queue_screen.dart';
import 'package:ocr_to_excel/views/screens/excel_preview_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StubPermissionService extends PermissionService {}
class StubImageService extends ImageService {}
class StubOcrService extends OcrService {
  @override
  Future<void> dispose() async {}
}


void _makeItemVerified(BatchProcessingController ctrl, String id) {
  for (final key in BatchItem.mandatoryKeys) {
    ctrl.updateRecordField(id, key, 'Val-$key');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BatchProcessingController controller;

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
  });

  tearDown(() {
    controller.dispose();
  });

  Widget buildTestableWidget() {
    return MaterialApp(
      home: BatchQueueScreen(controller: controller),
    );
  }

  testWidgets('top duplicate green Preview Excel button is removed', (tester) async {
    await tester.pumpWidget(buildTestableWidget());
    await tester.pumpAndSettle();

    // Verify top green Preview Excel button no longer exists
    final topBtnFinder = find.widgetWithText(FilledButton, 'Preview Excel');
    expect(topBtnFinder, findsNothing);
  });

  testWidgets('bottom Preview Excel button is removed and Download Excel button is present', (tester) async {
    // Add a consignment item to batch queue
    controller.addImagePath('/docs/test_lr.jpg');
    final item = controller.items.first;
    controller.updateRecordField(item.id, 'LR No *', 'LR-12345');

    await tester.pumpWidget(buildTestableWidget());
    await tester.pumpAndSettle();

    final previewBtnFinder = find.widgetWithText(FilledButton, 'Preview Excel (1 LRs)');
    expect(previewBtnFinder, findsNothing);

    final downloadBtnFinder = find.byKey(const Key('direct_download_excel_btn'));
    expect(downloadBtnFinder, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('ExcelPreviewScreen: Navbar History button switches to Sheet 2 and old History tab is removed', (tester) async {
    controller.addImagePath('/docs/test_lr.jpg');
    final item = controller.items.first;
    controller.updateRecordField(item.id, 'LR No *', 'LR-12345');

    await tester.pumpWidget(
      MaterialApp(
        home: ExcelPreviewScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    // Sheet 1 switcher button is present in the preview toolbar
    final sheet1BtnFinder = find.widgetWithText(FilledButton, 'Sheet 1: BNF Import Format (49 Columns)');
    expect(sheet1BtnFinder, findsOneWidget);

    // Old duplicate History tab is removed from the bottom/preview toolbar (no Tab widget)
    expect(find.byType(Tab), findsNothing);

    // Top Navbar History button exists
    final navHistoryBtn = find.byKey(const Key('navbar_history_btn'));
    expect(navHistoryBtn, findsOneWidget);

    // Tap Navbar History button -> switches to Sheet 2
    await tester.tap(navHistoryBtn);
    await tester.pumpAndSettle();

    expect(find.text('Generated Excel Exports History'), findsOneWidget);

    // Tap Sheet 1 button -> switches back to Sheet 1
    await tester.tap(sheet1BtnFinder);
    await tester.pumpAndSettle();

    expect(sheet1BtnFinder, findsOneWidget);
  });

  testWidgets('BatchQueueScreen renders direct Download Excel button and opens confirmation dialog', (tester) async {
    controller.addImagePath('/docs/test_lr.jpg');
    final item = controller.items.first;
    _makeItemVerified(controller, item.id);

    await tester.pumpWidget(buildTestableWidget());
    await tester.pumpAndSettle();

    final downloadBtnFinder = find.byKey(const Key('direct_download_excel_btn'));
    expect(downloadBtnFinder, findsOneWidget);
    expect(find.text('Download Excel (1 LRs)'), findsOneWidget);

    await tester.tap(downloadBtnFinder);
    await tester.pumpAndSettle();

    // Verify confirmation dialog
    expect(find.text('Download Excel'), findsWidgets);
    expect(find.text('Are you sure you want to download 1 verified consignment note(s)?'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    // Cancel dismisses dialog
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Are you sure you want to download 1 verified consignment note(s)?'), findsNothing);
  });

  testWidgets('ExcelPreviewScreen generates Excel with in-place confirmation without opening ExcelGeneratedScreen', (tester) async {
    controller.addImagePath('/docs/test_lr.jpg');
    final item = controller.items.first;
    _makeItemVerified(controller, item.id);

    await tester.pumpWidget(
      MaterialApp(
        home: ExcelPreviewScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    final genBtnFinder = find.textContaining('Generate Excel');
    expect(genBtnFinder, findsOneWidget);

    await tester.tap(genBtnFinder);
    await tester.pumpAndSettle();

    expect(find.text('Are you sure you want to generate the Excel sheet with 1 verified consignment note(s)?'), findsOneWidget);

    // Tap Cancel
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Are you sure you want to generate the Excel sheet with 1 verified consignment note(s)?'), findsNothing);
    // Verified: ExcelGeneratedScreen was NOT opened
    expect(find.byType(ExcelPreviewScreen), findsOneWidget);
  });
}
