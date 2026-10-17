import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/home_screen.dart';
import 'package:ocr_to_excel/views/screens/excel_preview_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/views/widgets/image_queue_card.dart';
import 'package:ocr_to_excel/views/widgets/ocr_processing_dialog.dart';

class MockPermissionService extends PermissionService {
  @override
  Future<bool> requestCameraPermission() async => true;
  @override
  Future<bool> requestGalleryPermission() async => true;
}

class MockImageService extends ImageService {
  String? cameraReturn;
  List<String> galleryReturn = [];

  @override
  Future<String?> captureFromCamera({int? imageQuality}) async => cameraReturn;

  @override
  Future<List<String>> pickMultipleImages({int? imageQuality}) async =>
      galleryReturn;

  @override
  Future<String?> pickSingleImage({int? imageQuality}) async =>
      galleryReturn.isNotEmpty ? galleryReturn.first : null;
}

class MockOcrService extends OcrService {
  @override
  Future<void> dispose() async {}
}

void main() {
  late MockPermissionService permissionService;
  late MockImageService imageService;
  late MockOcrService ocrService;
  late FormatParserService parserService;
  late ExcelService excelService;
  late BatchProcessingController controller;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({
      'bnf_user_name': 'Test User',
      'bnf_user_mobile': '9876543210',
    });
    permissionService = MockPermissionService();
    imageService = MockImageService();
    ocrService = MockOcrService();
    parserService = FormatParserService();
    excelService = ExcelService();

    controller = BatchProcessingController(
      permissionService: permissionService,
      imageService: imageService,
      ocrService: ocrService,
      parserService: parserService,
      excelService: excelService,
    );
    controller.setActiveUser('9876543210', name: 'Test User');
  });

  Widget buildTestableWidget() {
    return MaterialApp(
      home: HomeScreen(controller: controller),
    );
  }

  testWidgets('renders empty state when queue has no items', (tester) async {
    await tester.pumpWidget(buildTestableWidget());
    await tester.pump();

    expect(find.text('Capture or Upload LR Image'), findsOneWidget);
    expect(find.text('Capture Image'), findsOneWidget);
    expect(find.text('Select Image'), findsOneWidget);

    // Export button should be present but disabled
    final exportButtonFinder = find.widgetWithText(FilledButton, 'Queue (0)');
    expect(exportButtonFinder, findsOneWidget);
    final button = tester.widget<FilledButton>(exportButtonFinder);
    expect(button.onPressed, isNull);
  });

  testWidgets('renders queue cards and enables review button when items are present', (tester) async {
    // Add completed item directly to queue for UI testing
    controller.addImagePath('/fake/doc1.jpg');

    await tester.pumpWidget(buildTestableWidget());
    await tester.pump();

    expect(find.byType(ImageQueueCard), findsOneWidget);
    expect(find.descendant(of: find.byType(ImageQueueCard), matching: find.text('doc1.jpg')), findsOneWidget);

    // Review & Export button should now reflect count
    expect(find.text('Review & Export (1)'), findsOneWidget);
  });

  testWidgets('Navbar contains History button immediately left of user profile without circular profile icon, and opens History view', (tester) async {
    await tester.pumpWidget(buildTestableWidget());
    await tester.pump();

    // Verify circular User/Profile icon is removed
    expect(find.byIcon(Icons.person_outline), findsNothing);

    // Verify History button exists in Navbar
    final historyBtnFinder = find.byKey(const Key('navbar_history_btn'));
    expect(historyBtnFinder, findsOneWidget);
    expect(find.text('History'), findsOneWidget);

    // Verify user profile badge exists
    expect(find.text('Test User'), findsOneWidget);

    // Tap History button and verify it opens ExcelPreviewScreen
    await tester.tap(historyBtnFinder);
    await tester.pumpAndSettle();

    expect(find.byType(ExcelPreviewScreen), findsOneWidget);
    // In ExcelPreviewScreen, Sheet 2 (Generated Excel Exports History) is active
    expect(find.text('Generated Excel Exports History'), findsOneWidget);
  });

  testWidgets('displays duplicate LR alert dialog with exact message when duplicate occurs', (tester) async {
    await tester.pumpWidget(buildTestableWidget());
    await tester.pump();

    // Trigger duplicate notice on controller
    controller.triggerDuplicateNotice('This LR already exists. You cannot add the same LR multiple times.');
    await tester.pumpAndSettle();

    // Verify dialog appears
    expect(find.text('Duplicate LR'), findsOneWidget);
    expect(
      find.text('This LR already exists. You cannot add the same LR multiple times.'),
      findsOneWidget,
    );

    // Tap OK to dismiss
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('Duplicate LR'), findsNothing);
  });

  testWidgets('OcrProcessingDialog has unified loading state and does not show separate step checklist items', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OcrProcessingDialog(
            currentFile: 'test_lr.jpg',
            fileIndex: 1,
            totalFiles: 1,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Uploading & Processing LR...'), findsOneWidget);
    expect(find.text('Reading Consignment 1 of 1 (test_lr.jpg)'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // Verify separate step checklist rows are NOT present
    expect(find.text('Image Uploaded'), findsNothing);
    expect(find.text('Reading LR Document'), findsNothing);
    expect(find.text('Extracting Data'), findsNothing);
    expect(find.text('Mapping with Excel Format'), findsNothing);
    expect(find.text('Validating Data'), findsNothing);
  });
}
