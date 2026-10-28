import 'dart:io';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';
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

class StubExcelService extends ExcelService {
  @override
  Future<File> saveBytesToFile(List<int> bytes, {String? customFileName}) async {
    return File('/dummy/path/${customFileName ?? 'BNF_Bilty_Export.xlsx'}');
  }

  @override
  Future<String?> saveFileToDownloads(String sourceFilePath, {String? targetFileName}) async {
    return '/dummy/downloads/${targetFileName ?? 'BNF_Bilty_Export.xlsx'}';
  }
}

class MockGeminiBackendService extends GeminiBackendService {
  bool exportExcelWithSnapshotCalled = false;
  List<Map<String, dynamic>> lastDocuments = [];

  @override
  Future<Map<String, dynamic>> exportExcelWithSnapshot({
    required List<Map<String, dynamic>> documents,
    String formatType = 'gr_bnf_49',
    String? userName,
    String? userMobile,
    String? sessionToken,
  }) async {
    exportExcelWithSnapshotCalled = true;
    lastDocuments = documents;
    return {
      'success': true,
      'filename': 'BNF_Bilty_Export_Test.xlsx',
      'download_url': '/downloads/test.xlsx',
    };
  }

  @override
  Future<List<int>?> downloadExportedFile(String downloadUrl) async {
    return [0x50, 0x4B, 0x03, 0x04];
  }
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

  Widget buildTestableWidget({BatchProcessingController? ctrl}) {
    return MaterialApp(
      home: BatchQueueScreen(controller: ctrl ?? controller),
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

  testWidgets('ExcelPreviewScreen: History button removed from Excel Preview header per UI cleanup', (tester) async {
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

    // History button is removed from Excel Preview header per Item 5 UI cleanup
    expect(find.byKey(const Key('navbar_history_btn')), findsNothing);

    // Drain cloud sync debounce timer
    await tester.pump(const Duration(milliseconds: 500));
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

  testWidgets('BatchQueueScreen Download Excel invokes geminiService.exportExcelWithSnapshot for History persistence', (tester) async {
    final mockBackend = MockGeminiBackendService();
    final customCtrl = BatchProcessingController(
      permissionService: StubPermissionService(),
      imageService: StubImageService(),
      ocrService: StubOcrService(),
      parserService: FormatParserService(),
      excelService: StubExcelService(),
      geminiService: mockBackend,
      useGeminiBackend: true,
    );

    customCtrl.addImagePath('/docs/test_lr.jpg');
    final item = customCtrl.items.first;
    _makeItemVerified(customCtrl, item.id);

    await tester.pumpWidget(buildTestableWidget(ctrl: customCtrl));
    await tester.pumpAndSettle();

    final downloadBtnFinder = find.byKey(const Key('direct_download_excel_btn'));
    await tester.tap(downloadBtnFinder);
    await tester.pumpAndSettle();

    final confirmBtn = find.widgetWithText(FilledButton, 'Download (1 LRs)');
    expect(confirmBtn, findsOneWidget);
    await tester.tap(confirmBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(mockBackend.exportExcelWithSnapshotCalled, isTrue);
    expect(mockBackend.lastDocuments.length, 1);
    customCtrl.dispose();
  });
}
