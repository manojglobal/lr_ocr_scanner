import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/screens/batch_queue_screen.dart';
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
  late BatchItem validCompleteItem;
  late BatchItem missingStep2FieldItem;
  late BatchItem missingCustomFieldItem;

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

    // Completely filled mandatory item
    validCompleteItem = BatchItem(
      id: 'item-complete',
      imagePath: '/path/to/test.jpg',
      fileName: 'test.jpg',
      status: BatchItemStatus.processing,
      createdAt: DateTime.now(),
      record: {
        'grno (*)': 'BNF-9999',
        'LR No *': 'BNF-9999',
        'grdt *': '28/10/2026',
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
        'Counter': 'CENTRAL',
      },
    );

    // Missing mandatory field on Page 1 (step2: e.g. Consignor GSTIN in Tab 1)
    missingStep2FieldItem = validCompleteItem.copyWith(
      id: 'item-missing-step2',
      record: Map<String, String>.from(validCompleteItem.record)..remove('cngrgstno *'),
    );

    // Missing mandatory field on Page 2 (custom: e.g. Customer Name)
    missingCustomFieldItem = validCompleteItem.copyWith(
      id: 'item-missing-custom',
      record: Map<String, String>.from(validCompleteItem.record)..['Customer Name *'] = '',
    );
  });

  group('Batch 2: Form UX & Mandatory Field Navigation', () {
    testWidgets('Item 1: EditBiltyScreen input fields have distinct italic placeholders and style', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: EditBiltyScreen(item: validCompleteItem, controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Find all TextFields
      final textFields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(textFields.isNotEmpty, isTrue);

      for (final tf in textFields) {
        expect(tf.decoration?.hintText, isNotNull);
        expect(tf.decoration?.hintStyle?.fontStyle, equals(FontStyle.italic));
        expect(tf.decoration?.hintStyle?.color, equals(const Color(0xFF94A3B8)));
        expect(tf.style?.fontStyle, equals(FontStyle.normal));
      }
    });

    testWidgets('Item 1: CustomizationDriverScreen input fields have distinct italic placeholders', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: CustomizationDriverScreen(item: validCompleteItem, controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      final textFields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(textFields.length, greaterThanOrEqualTo(4));

      for (final tf in textFields) {
        expect(tf.decoration?.hintText, isNotNull);
        expect(tf.decoration?.hintStyle?.fontStyle, equals(FontStyle.italic));
        expect(tf.decoration?.hintStyle?.color, equals(const Color(0xFF94A3B8)));
      }
    });

    testWidgets('Item 2: Save & Verify navigates to first empty mandatory field on Page 1 across pages', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // Start on EditBiltyScreen and push CustomizationDriverScreen to test full cross-page navigation
      await tester.pumpWidget(
        MaterialApp(
          home: EditBiltyScreen(item: missingStep2FieldItem, controller: controller, initialTab: 3),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Next: Master Data on Tab 3 to navigate to CustomizationDriverScreen
      final nextBtn = find.text('Next: Master Data');
      expect(nextBtn, findsOneWidget);
      await tester.tap(nextBtn);
      await tester.pumpAndSettle();

      // We are now on CustomizationDriverScreen
      expect(find.text('LR Customization & Driver Details'), findsOneWidget);

      // Tap Save & Verify
      final saveBtn = find.text('Save & Verify');
      expect(saveBtn, findsOneWidget);
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      // Modal dialog must appear listing the missing Consignor GSTIN (Consignor / Consignee)
      expect(find.text('Mandatory Fields Incomplete'), findsOneWidget);
      expect(find.textContaining('Consignor GSTIN * (Consignor / Consignee)'), findsOneWidget);

      // Tap 'Fix Incomplete Field'
      final fixBtn = find.byKey(const Key('modal_fix_first_field_btn'));
      expect(fixBtn, findsOneWidget);
      await tester.tap(fixBtn);
      await tester.pumpAndSettle();

      // Must have navigated back across pages to EditBiltyScreen, Tab 1 (Consignor / Consignee)
      expect(find.text('Verify & Edit LR'), findsOneWidget);
      expect(find.text('Consignor & Consignee Details'), findsOneWidget);
    });

    testWidgets('Item 2: Save & Verify with empty field on Page 2 stays on Page 2 and focuses field', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: CustomizationDriverScreen(item: missingCustomFieldItem, controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Save & Verify
      final saveBtn = find.text('Save & Verify');
      expect(saveBtn, findsOneWidget);
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      // Modal appears showing Customer Name is incomplete
      expect(find.text('Mandatory Fields Incomplete'), findsOneWidget);
      expect(find.textContaining('Customer Name * (Master Data)'), findsOneWidget);

      // Tap 'Fix Incomplete Field'
      final fixBtn = find.byKey(const Key('modal_fix_first_field_btn'));
      await tester.tap(fixBtn);
      await tester.pumpAndSettle();

      // Modal is dismissed, stays on CustomizationDriverScreen
      expect(find.text('Mandatory Fields Incomplete'), findsNothing);
      expect(find.text('LR Customization & Driver Details'), findsOneWidget);
    });

    testWidgets('Item 2: Save & Verify with all fields complete successfully verifies and navigates to LR List', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: CustomizationDriverScreen(item: validCompleteItem, controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Save & Verify
      final saveBtn = find.text('Save & Verify');
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      // Successful verification navigates directly to BatchQueueScreen (LR List)
      expect(find.byType(BatchQueueScreen), findsOneWidget);
      expect(find.text('LR List (For Excel Export)'), findsOneWidget);
    });
  });
}
