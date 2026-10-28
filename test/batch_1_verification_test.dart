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
import 'package:ocr_to_excel/views/screens/batch_queue_screen.dart';
import 'package:ocr_to_excel/views/screens/edit_bilty_screen.dart';
import 'package:ocr_to_excel/views/widgets/step_indicator_bar.dart';
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
      id: 'test-batch-1',
      imagePath: '/test/lr.jpg',
      fileName: 'test_lr.jpg',
      status: BatchItemStatus.completed,
      createdAt: DateTime.now(),
      record: const {
        'LR No *': 'LR-B1-001',
        'Customer Name *': 'BNF Logistics',
      },
    );
  });

  tearDown(() {
    controller.dispose();
  });

  testWidgets('Batch 1 - Item 1: StepIndicatorBar renders responsively on small screens without overflow', (tester) async {
    // Simulate compact screen width (320px)
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox(),
          bottomNavigationBar: StepIndicatorBar(currentStep: 1, controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Upload LR'), findsOneWidget);
    expect(find.text('LR & Master Verification'), findsOneWidget);
    expect(find.text('LR List'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Batch 1 - Item 2 & 4: HomeScreen removes duplicate bottom controls & has enlarged delete icon', (tester) async {
    controller.addItemDirectly(testItem);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Duplicate bottom bar with Camera and Gallery is removed
    expect(find.widgetWithText(OutlinedButton, 'Camera'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Gallery'), findsNothing);

    // 2. Enlarged delete icon (Icons.close, size: 15) is rendered
    final closeIconFinder = find.byWidgetPredicate(
      (w) => w is Icon && w.icon == Icons.close && w.size == 15,
    );
    expect(closeIconFinder, findsOneWidget);

    // 3. Action toolbar directly below title BNF BOX N FREIGHT: History is present, Queue(0) is removed per Fix 1
    expect(find.byKey(const Key('navbar_history_btn')), findsOneWidget);
    expect(find.byKey(const Key('navbar_queue_btn')), findsNothing);
  });

  testWidgets('Batch 1 - Item 3 & 5: EditBiltyScreen removes car & list icons, places actions below title', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EditBiltyScreen(item: testItem, controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Car icon and list icon are removed
    expect(find.byIcon(Icons.local_shipping_outlined), findsNothing);
    expect(find.byIcon(Icons.list_alt), findsNothing);

    // 2. Action buttons: View LR Image button removed from toolbar row next to History
    final historyBtn = find.widgetWithText(OutlinedButton, 'History');
    expect(historyBtn, findsOneWidget);
    final toolbarRow = find.ancestor(of: historyBtn, matching: find.byType(Row)).first;
    expect(find.descendant(of: toolbarRow, matching: find.widgetWithText(OutlinedButton, 'View LR Image')), findsNothing);
  });

  testWidgets('Batch 1 - Item 5: BatchQueueScreen places Add More LR, Excel Preview, and History below title', (tester) async {
    controller.addItemDirectly(testItem);

    await tester.pumpWidget(
      MaterialApp(
        home: BatchQueueScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    // Title is present
    expect(find.text('LR List (For Excel Export)'), findsOneWidget);

    // Actions below title are present
    expect(find.text('Add More LR'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Excel Preview'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'History'), findsOneWidget);
  });
}
