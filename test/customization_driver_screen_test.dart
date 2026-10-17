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
      id: 'test-101',
      imagePath: '/path/to/test.jpg',
      fileName: 'test.jpg',
      status: BatchItemStatus.completed,
      createdAt: DateTime.now(),
      record: {
        'LR No *': 'LR-8901',
        'Customer Name *': 'HIMALAYA WELLNESS COMPANY',
        'Vehicle No *': 'KA23B5235',
      },
    );
  });

  Widget buildTestableWidget() {
    return MaterialApp(
      home: CustomizationDriverScreen(
        item: testItem,
        controller: controller,
      ),
    );
  }

  testWidgets('renders Customization & Driver details with automatic master fetch and removed Fetch button', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(buildTestableWidget());
    await tester.pumpAndSettle();

    expect(find.text('LR Customization & Driver Details'), findsOneWidget);
    expect(find.text('Customer & Department'), findsOneWidget);
    expect(find.text('Counter & Vehicle Category'), findsOneWidget);
    expect(find.text('Driver Information'), findsOneWidget);
    expect(find.text('Save & Verify'), findsOneWidget);

    // Verify 'Fetch from Master' button is removed
    expect(find.text('Fetch from Master'), findsNothing);

    // Verify driver info automatically pre-populated on load from KA23B5235 master record
    expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'DHANAJI S PATIL'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '9739443101'), findsOneWidget);
  });
}

