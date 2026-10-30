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
import 'package:shared_preferences/shared_preferences.dart';

class StubPermissionService extends PermissionService {}
class StubImageService extends ImageService {}
class StubOcrService extends OcrService {
  @override
  Future<void> dispose() async {}
}

BatchItem createVerifiedItem({
  required String id,
  required String lrNo,
  required String lrDate, // e.g. "15/10/2026"
  required DateTime createdAt,
}) {
  return BatchItem(
    id: id,
    imagePath: '/path/to/$id.jpg',
    fileName: '$id.jpg',
    status: BatchItemStatus.completed,
    createdAt: createdAt,
    record: {
      'grno (*)': lrNo,
      'LR No *': lrNo,
      'grdt *': lrDate,
      'Vehicle No *': 'KA23B5235',
      'Vehicle Type *': 'MARKET',
      'Customer Name *': 'HIMALAYA WELLNESS COMPANY',
      'cngr *': 'HIMALAYA SENDER',
      'cngrgstno *': '27ABCDE1234F1Z5',
      'cnge *': 'HIMALAYA RECEIVER',
      'cngegstno *': '27ABCDE1234F2Z6',
      'Driver Name *': 'DHANAJI PATIL',
      'Mobile no   *': '9739443101',
      'Liscense No *': 'KA23 20000044025',
      'Valid Up to *': '31/12/2030',
      'Loading Start date *': lrDate,
      'freight  *': '15000',
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BatchProcessingController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'bnf_user_name': 'Logistics Test',
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

  group('Batch 3 - Date Range Validation & UI Fix Tests', () {
    testWidgets('1. From Date earlier than To Date - filtering works inclusively', (tester) async {
      // Item 1: LR Date 10/10/2026
      // Item 2: LR Date 15/10/2026
      // Item 3: LR Date 25/10/2026
      final item1 = createVerifiedItem(id: 'item1', lrNo: 'LR-1001', lrDate: '10/10/2026', createdAt: DateTime(2026, 10, 30));
      final item2 = createVerifiedItem(id: 'item2', lrNo: 'LR-1002', lrDate: '15/10/2026', createdAt: DateTime(2026, 10, 30));
      final item3 = createVerifiedItem(id: 'item3', lrNo: 'LR-1003', lrDate: '25/10/2026', createdAt: DateTime(2026, 10, 30));

      controller.addItemDirectly(item1);
      controller.addItemDirectly(item2);
      controller.addItemDirectly(item3);

      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      final state = tester.state(find.byType(BatchQueueScreen)) as dynamic;
      state.setShowFiltersForTesting(true);
      state.setDateRangeForTesting(DateTime(2026, 10, 12), DateTime(2026, 10, 20));
      await tester.pumpAndSettle();

      // Only item2 (15/10/2026) is in range 12/10/2026 to 20/10/2026
      expect(find.textContaining('LR-1002'), findsOneWidget);
      expect(find.textContaining('LR-1001'), findsNothing);
      expect(find.textContaining('LR-1003'), findsNothing);
      expect(find.text('Showing 1 of 3 Verified LRs'), findsOneWidget);
    });

    testWidgets('2. From Date equal to To Date - filtering works for that exact date', (tester) async {
      final item1 = createVerifiedItem(id: 'item1', lrNo: 'LR-1001', lrDate: '15/10/2026', createdAt: DateTime(2026, 10, 30));
      final item2 = createVerifiedItem(id: 'item2', lrNo: 'LR-1002', lrDate: '16/10/2026', createdAt: DateTime(2026, 10, 30));

      controller.addItemDirectly(item1);
      controller.addItemDirectly(item2);

      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      final state = tester.state(find.byType(BatchQueueScreen)) as dynamic;
      state.setShowFiltersForTesting(true);
      state.setDateRangeForTesting(DateTime(2026, 10, 15), DateTime(2026, 10, 15));
      await tester.pumpAndSettle();

      // Exact match for 15/10/2026
      expect(find.textContaining('LR-1001'), findsOneWidget);
      expect(find.textContaining('LR-1002'), findsNothing);
      expect(find.text('Showing 1 of 2 Verified LRs'), findsOneWidget);
    });

    testWidgets('3. From Date later than To Date - shows validation message and blocks filtering', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final item1 = createVerifiedItem(id: 'item1', lrNo: 'LR-1001', lrDate: '10/10/2026', createdAt: DateTime(2026, 10, 30));
      final item2 = createVerifiedItem(id: 'item2', lrNo: 'LR-1002', lrDate: '20/10/2026', createdAt: DateTime(2026, 10, 30));

      controller.addItemDirectly(item1);
      controller.addItemDirectly(item2);

      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      final state = tester.state(find.byType(BatchQueueScreen)) as dynamic;
      state.setShowFiltersForTesting(true);
      // From Date (Oct 25) is LATER than To Date (Oct 15)
      state.setDateRangeForTesting(DateTime(2026, 10, 25), DateTime(2026, 10, 15));
      await tester.pumpAndSettle();

      // Must show the exact validation message
      expect(
        find.text('Invalid date range: From Date cannot be later than To Date.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('dateRangeValidationBanner')), findsOneWidget);

      // Filtering is blocked: both items remain visible and are not filtered out
      expect(find.textContaining('LR-1001'), findsOneWidget);
      expect(find.textContaining('LR-1002'), findsOneWidget);
    });

    testWidgets('4. Change From Date after selecting To Date revalidates the range', (tester) async {
      final item1 = createVerifiedItem(id: 'item1', lrNo: 'LR-1001', lrDate: '10/10/2026', createdAt: DateTime(2026, 10, 30));

      controller.addItemDirectly(item1);

      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      final state = tester.state(find.byType(BatchQueueScreen)) as dynamic;

      // Start in valid state: 10/10/2026 to 20/10/2026
      state.setShowFiltersForTesting(true);
      state.setDateRangeForTesting(DateTime(2026, 10, 10), DateTime(2026, 10, 20));
      await tester.pumpAndSettle();
      expect(find.text('Invalid date range: From Date cannot be later than To Date.'), findsNothing);

      // Change From Date to 25/10/2026 (now invalid)
      state.setDateRangeForTesting(DateTime(2026, 10, 25), DateTime(2026, 10, 20));
      await tester.pumpAndSettle();
      expect(find.text('Invalid date range: From Date cannot be later than To Date.'), findsOneWidget);

      // Change From Date back to 05/10/2026 (now valid again)
      state.setDateRangeForTesting(DateTime(2026, 10, 5), DateTime(2026, 10, 20));
      await tester.pumpAndSettle();
      expect(find.text('Invalid date range: From Date cannot be later than To Date.'), findsNothing);
    });

    testWidgets('5. Verify filtering uses actual LR Date and NOT upload/creation date', (tester) async {
      // Record created today (30/10/2026), but LR Date is 05/10/2026
      final item1 = createVerifiedItem(
        id: 'item1',
        lrNo: 'LR-PAST-DATE',
        lrDate: '05/10/2026',
        createdAt: DateTime(2026, 10, 30),
      );

      // Record created today (30/10/2026), with LR Date today (30/10/2026)
      final item2 = createVerifiedItem(
        id: 'item2',
        lrNo: 'LR-TODAY-DATE',
        lrDate: '30/10/2026',
        createdAt: DateTime(2026, 10, 30),
      );

      controller.addItemDirectly(item1);
      controller.addItemDirectly(item2);

      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      final state = tester.state(find.byType(BatchQueueScreen)) as dynamic;
      // Filter for 01/10/2026 to 10/10/2026
      // If it erroneously used createdAt (30/10/2026), item1 would be excluded!
      // Using actual LR Date (05/10/2026), item1 is included, and item2 is excluded!
      state.setShowFiltersForTesting(true);
      state.setDateRangeForTesting(DateTime(2026, 10, 1), DateTime(2026, 10, 10));
      await tester.pumpAndSettle();

      expect(find.textContaining('LR-PAST-DATE'), findsOneWidget);
      expect(find.textContaining('LR-TODAY-DATE'), findsNothing);
    });

    testWidgets('6. Reset filters clears both dates and hides validation banner', (tester) async {
      final item1 = createVerifiedItem(id: 'item1', lrNo: 'LR-1001', lrDate: '10/10/2026', createdAt: DateTime(2026, 10, 30));
      controller.addItemDirectly(item1);

      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      final state = tester.state(find.byType(BatchQueueScreen)) as dynamic;
      state.setShowFiltersForTesting(true);
      state.setDateRangeForTesting(DateTime(2026, 10, 25), DateTime(2026, 10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Invalid date range: From Date cannot be later than To Date.'), findsOneWidget);

      // Tap Reset button
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();

      // Error banner gone and both dates cleared
      expect(find.text('Invalid date range: From Date cannot be later than To Date.'), findsNothing);
      expect(find.text('From Date'), findsOneWidget);
      expect(find.text('To Date'), findsOneWidget);
    });
  });
}
