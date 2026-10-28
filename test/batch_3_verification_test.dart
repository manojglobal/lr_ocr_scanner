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
  late BatchItem verifiedItem;
  late BatchItem unverifiedItem;

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

    // Completely verified item with all mandatory fields filled
    verifiedItem = BatchItem(
      id: 'verified-1',
      imagePath: '/path/to/verified_lr.jpg',
      fileName: 'verified_lr.jpg',
      status: BatchItemStatus.completed,
      createdAt: DateTime.now(),
      record: {
        'grno (*)': 'BNF-1001',
        'LR No *': 'BNF-1001',
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
        'Loading Start date *': '28/10/2026',
        'freight  *': '15000',
        'Counter': 'CENTRAL',
      },
    );

    // Unverified item with missing mandatory fields
    unverifiedItem = BatchItem(
      id: 'unverified-2',
      imagePath: '/path/to/unverified_lr.jpg',
      fileName: 'unverified_lr.jpg',
      status: BatchItemStatus.pending,
      createdAt: DateTime.now(),
      record: {
        'LR No *': 'BNF-UNVERIFIED',
        // Missing mandatory driver, customer, vehicle fields
      },
    );
  });

  group('Batch 3: LR Upload, Duplicate Detection & Verification Status', () {
    test('Item 1: Duplicate LR detection catches duplicates on FIRST upload attempt via previous cache', () {
      // Set previous uploads cache (simulating prior uploads/sessions from cloud or storage)
      controller.setPreviousUploadsCache([
        {
          'id': 'cloud-rec-001',
          'lrNo': 'BNF-9999',
          'fileName': 'previous_consign.jpg',
          'imagePath': '/storage/emulated/0/previous_consign.jpg',
        },
      ]);

      // 1. Attempting to upload duplicate by LR number on FIRST attempt
      final isDupByLr = controller.isDuplicate(
        lrNo: 'BNF-9999',
        fileName: 'new_random_filename.jpg',
      );
      expect(isDupByLr, isTrue, reason: 'Duplicate document with matching LR number must be caught on 1st attempt');

      // 2. Attempting to upload duplicate by fileName on FIRST attempt
      final isDupByFileName = controller.isDuplicate(
        fileName: 'previous_consign.jpg',
      );
      expect(isDupByFileName, isTrue, reason: 'Duplicate document with matching fileName must be caught on 1st attempt');

      // 3. Attempting to upload duplicate by image path on FIRST attempt
      final isDupByPath = controller.isDuplicate(
        imagePath: '/storage/emulated/0/previous_consign.jpg',
      );
      expect(isDupByPath, isTrue, reason: 'Duplicate document with matching path must be caught on 1st attempt');

      // 4. A completely new distinct document must NOT be flagged as duplicate
      final isNotDup = controller.isDuplicate(
        lrNo: 'BNF-NEW-1234',
        fileName: 'brand_new_doc.jpg',
        imagePath: '/storage/emulated/0/brand_new_doc.jpg',
      );
      expect(isNotDup, isFalse, reason: 'Brand new distinct LR document should not be flagged as duplicate');
    });

    testWidgets('Item 2: Previously Uploaded LRs does not display an unverified LR twice', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // Prepare an unverified item
      final unverifiedLR = BatchItem(
        id: 'dup-unverified-1',
        imagePath: '/path/to/unverified_doc.jpg',
        fileName: 'unverified_doc.jpg',
        status: BatchItemStatus.pending,
        createdAt: DateTime.now(),
        record: {'LR No *': 'BNF-DUP-CHECK'},
      );

      // Preload shared preferences with the same unverified LR record
      SharedPreferences.setMockInitialValues({
        'bnf_user_name': 'Test User',
        'bnf_user_mobile': '9876543210',
        'bnf_recent_uploaded_lrs': '[{"id":"dup-unverified-1","fileName":"unverified_doc.jpg","imagePath":"/path/to/unverified_doc.jpg","lrNo":"BNF-DUP-CHECK","status":"pending"}]',
      });

      // Add to controller as active item as well (simulating active item + persisted entry overlap)
      controller.addItemDirectly(unverifiedLR);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Find widget rendering the LR card in Previously Uploaded LRs
      expect(find.text('LR: BNF-DUP-CHECK'), findsOneWidget, reason: 'Unverified uploaded LR must appear exactly once in Previously Uploaded LRs');
      expect(find.text('Unverified'), findsOneWidget, reason: 'Unverified status badge must appear exactly once');
      expect(find.text('1 files'), findsOneWidget, reason: 'Previously Uploaded LRs header must indicate exactly 1 file');
    });

    testWidgets('Item 3: Show only verified LRs in the LR List (BatchQueueScreen)', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // Add one verified item and one unverified item to controller
      expect(verifiedItem.isVerified, isTrue);
      expect(unverifiedItem.isVerified, isFalse);

      controller.addItemDirectly(verifiedItem);
      controller.addItemDirectly(unverifiedItem);

      await tester.pumpWidget(
        MaterialApp(
          home: BatchQueueScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Verified item must be present in the LR List
      expect(find.text('BNF-1001'), findsWidgets);
      expect(find.textContaining('HIMALAYA WELLNESS COMPANY'), findsOneWidget);
      expect(find.textContaining('KA23B5235'), findsOneWidget);

      // 2. Unverified or incomplete item must NOT appear in the LR List
      expect(find.text('unverified_lr.jpg'), findsNothing);
      expect(find.text('BNF-UNVERIFIED'), findsNothing);

      // 3. Count indicators must indicate only verified count
      expect(find.text('Total: 1 Verified LR'), findsOneWidget);
      expect(find.text('1 Verified'), findsOneWidget);
    });

    testWidgets('Item 3: BatchQueueScreen empty state shown when only unverified LRs exist', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // Controller has ONLY an unverified/incomplete item
      controller.addItemDirectly(unverifiedItem);

      await tester.pumpWidget(
        MaterialApp(
          home: BatchQueueScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // The unverified LR must NOT appear in the list
      expect(find.text('unverified_lr.jpg'), findsNothing);
      expect(find.text('BNF-UNVERIFIED'), findsNothing);

      // The empty queue message should be displayed because there are no verified LRs
      expect(find.text('Empty LR'), findsOneWidget);
      expect(find.text('Total: 0 Verified LRs'), findsOneWidget);
    });
  });
}
