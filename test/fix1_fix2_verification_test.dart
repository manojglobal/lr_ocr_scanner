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

  group('Fix 1: Remove Queue(0) from HomeScreen', () {
    testWidgets('Queue(0) control is completely removed while History button remains present', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // 1. History button must be present
      expect(find.byKey(const Key('navbar_history_btn')), findsOneWidget);
      expect(find.text('History'), findsOneWidget);

      // 2. Queue(0) / navbar_queue_btn must be removed
      expect(find.byKey(const Key('navbar_queue_btn')), findsNothing);
      expect(find.text('Queue (0)'), findsNothing);
      expect(find.textContaining('Queue ('), findsNothing);
    });

    testWidgets('Queue control remains absent even when batch items are present in controller', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // Add active item to controller
      controller.addItemDirectly(
        BatchItem(
          id: 'test-item-1',
          imagePath: '/fake/path.jpg',
          fileName: 'doc1.jpg',
          status: BatchItemStatus.pending,
          createdAt: DateTime.now(),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Queue button must still NOT be displayed on HomeScreen
      expect(find.byKey(const Key('navbar_queue_btn')), findsNothing);
      expect(find.textContaining('Queue ('), findsNothing);

      // History button remains present
      expect(find.byKey(const Key('navbar_history_btn')), findsOneWidget);
    });
  });

  group('Fix 2: Footer Visibility across Android Screen Sizes', () {
    testWidgets('Renders all 3 steps fully visible on small screen (320px width) without overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: StepIndicatorBar(currentStep: 1, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // All 3 steps must be rendered
      expect(find.text('Upload LR'), findsOneWidget);
      expect(find.text('LR & Master Verification'), findsOneWidget);
      expect(find.text('LR List'), findsOneWidget);

      // Zero overflow exceptions
      expect(tester.takeException(), isNull);
    });

    testWidgets('Renders all 3 steps on medium phone screen (375px width) without overflow', (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: StepIndicatorBar(currentStep: 2, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Upload LR'), findsOneWidget);
      expect(find.text('LR & Master Verification'), findsOneWidget);
      expect(find.text('LR List'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Renders on large phone screen (412px width) with safe area padding', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: StepIndicatorBar(currentStep: 3, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Upload LR'), findsOneWidget);
      expect(find.text('LR & Master Verification'), findsOneWidget);
      expect(find.text('LR List'), findsOneWidget);
      expect(find.byType(SafeArea), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
