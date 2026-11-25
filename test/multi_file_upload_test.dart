import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/models/extraction_result.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/home_screen.dart';
import 'package:ocr_to_excel/views/screens/batch_queue_screen.dart';

class MockGeminiBackendService extends GeminiBackendService {
  ExtractionResult? stubResult;
  List<String> lastExtractedPaths = [];

  @override
  Future<ExtractionResult> extractMultipleFiles(
    List<String> filePaths, {
    String? customPrompt,
    String? userId,
    String? userMobile,
    String? userName,
    String? sessionToken,
  }) async {
    lastExtractedPaths = List.from(filePaths);
    return stubResult ??
        ExtractionResult.failure(
          errorCode: 'ERROR',
          errorMessage: 'No stub set in MockGeminiBackendService',
        );
  }

  @override
  Future<ExtractionResult> extractHandwriting(
    String filePath, {
    String? originalFileName,
    String? customPrompt,
    String? userId,
    String? userMobile,
    String? userName,
    String? sessionToken,
  }) async {
    return stubResult ??
        ExtractionResult.failure(
          errorCode: 'ERROR',
          errorMessage: 'No stub set in MockGeminiBackendService',
        );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Multiple File Upload (PDFs & Images) for Single LR Tests', () {
    test('Scenario 1: Multiple LRs detected -> Reject entire upload, show error, 0 items added to Step 2', () async {
      final mockBackend = MockGeminiBackendService();
      mockBackend.stubResult = ExtractionResult.failure(
        errorCode: 'MULTIPLE_LRS',
        errorMessage: 'Multiple LR documents detected. Please upload documents belonging to only one LR at a time.',
      );

      final controller = BatchProcessingController(
        geminiService: mockBackend,
        useGeminiBackend: true,
      );

      final files = ['/dummy/path/lr_page1.pdf', '/dummy/path/lr_page2.pdf'];

      final success = await controller.addMultipleFilesAsSingleLr(files);

      // 1. Must return false indicating rejection
      expect(success, isFalse);

      // 2. Controller flags must be set for user alert
      expect(controller.multipleLrsNoticePending, isTrue);
      expect(
        controller.multipleLrsNoticeMessage,
        'Multiple LR documents detected. Please upload documents belonging to only one LR at a time.',
      );

      // 3. Step 2 must have ZERO items (no partial records created)
      expect(controller.items.isEmpty, isTrue);
      expect(controller.previousUploadsCache.isEmpty, isTrue);

      // 4. Acknowledging clears the notice flag
      controller.acknowledgeMultipleLrsNotice();
      expect(controller.multipleLrsNoticePending, isFalse);
      expect(controller.multipleLrsNoticeMessage, isNull);
    });

    test('Scenario 2: Multiple files of same LR -> Accept as ONE logical LR record in Step 2 with pending verification', () async {
      final mockBackend = MockGeminiBackendService();
      mockBackend.stubResult = ExtractionResult.success(
        data: {
          'LR No *': '98765',
          'Customer Name *': 'Himalaya Wellness',
          'Vehicle No *': 'KA01AB1234',
          'saved_filename': 'LR_98765_combined.pdf',
          'page_count': '3',
        },
        missingFields: [],
        rawText: 'LR 98765 combined document',
        structureType: 'form',
      );

      final controller = BatchProcessingController(
        geminiService: mockBackend,
        useGeminiBackend: true,
      );

      final files = [
        '/dummy/path/doc_part1.pdf',
        '/dummy/path/doc_part2.jpg',
        '/dummy/path/doc_part3.png',
      ];

      final success = await controller.addMultipleFilesAsSingleLr(files);

      // 1. Must succeed
      expect(success, isTrue);
      expect(controller.multipleLrsNoticePending, isFalse);

      // 2. Must create exactly ONE BatchItem (not 3 separate records)
      expect(controller.items.length, 1);
      final item = controller.items.first;

      // 3. Status must be unverified and pending verification (Step 2)
      expect(item.isVerified, isFalse);
      expect(item.record['pending_verification'], 'true');
      expect(item.record['is_verified'], 'false');
      expect(item.record['LR No *'], '98765');
      expect(item.record['page_count'], '3');

      // 4. Step 3 isolation: Unverified LR must NEVER appear in verified list
      final verifiedItems = controller.items.where((i) => i.isVerified).toList();
      expect(verifiedItems.isEmpty, isTrue);
    });

    test('Scenario 3: Verification workflow - multi-file LR only appears in Step 3 after explicit verification', () async {
      final mockBackend = MockGeminiBackendService();
      mockBackend.stubResult = ExtractionResult.success(
        data: {
          'LR No *': '55555',
          'grno (*)': '55555',
          'grdt *': '15-11-2026',
          'Customer Name *': 'ABC Logistics',
          'Vehicle No *': 'MH12CD5678',
          'Vehicle Type *': 'Market',
          'Driver Name *': 'Suresh',
          'Mobile no   *': '9123456789',
          'Liscense No *': 'MH1220180009999',
          'Valid Up to *': '31-12-2029',
          'Loading Start date *': '15-11-2026',
          'freight  *': '8500',
          'cngr *': 'ABC Sender',
          'cnge *': 'XYZ Receiver',
          'cngrgstno *': '27ABCDE1234F1Z5',
          'cngegstno *': '27XYZAB5678F1Z2',
          'saved_filename': 'LR_55555_combined.pdf',
        },
        missingFields: [],
        rawText: 'Document LR 55555',
      );

      final controller = BatchProcessingController(
        geminiService: mockBackend,
        useGeminiBackend: true,
      );

      await controller.addMultipleFilesAsSingleLr([
        '/dummy/path/lr_main.pdf',
        '/dummy/path/lr_annexure.jpg',
      ]);

      expect(controller.items.length, 1);
      expect(controller.items.first.isVerified, isFalse);

      // Verify item (simulate user completing Step 2 Save & Verify)
      final existingItem = controller.items.first;
      final updatedRecord = Map<String, String>.from(existingItem.record);
      updatedRecord['is_verified'] = 'true';
      updatedRecord.remove('pending_verification');

      controller.updateItem(existingItem.copyWith(record: updatedRecord));

      // Now it must be verified and appear in Step 3
      expect(controller.items.first.isVerified, isTrue);
      final verifiedList = controller.items.where((i) => i.isVerified).toList();
      expect(verifiedList.length, 1);
      expect(verifiedList.first.record['LR No *'], '55555');

      // Subsequent attempt to upload the same LR number must now be blocked
      final isDup = controller.isDuplicate(lrNo: '55555');
      expect(isDup, isTrue);
    });

    testWidgets('Scenario 4: HomeScreen displays "Multiple LRs Not Allowed" dialog on notice trigger', (tester) async {
      final controller = BatchProcessingController(useGeminiBackend: false);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Trigger the multiple LRs notice
      controller.triggerMultipleLrsNotice();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Verify the dialog title, subtitle, and body text match Web requirements
      expect(find.text('Multiple LRs Not Allowed'), findsOneWidget);
      expect(find.text('Document Validation'), findsOneWidget);
      expect(
        find.text('Multiple LR documents detected. Please upload documents belonging to only one LR at a time.'),
        findsOneWidget,
      );

      // Tap OK button to dismiss
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Notice should now be acknowledged and dialog dismissed
      expect(find.text('Multiple LRs Not Allowed'), findsNothing);
      expect(controller.multipleLrsNoticePending, isFalse);
    });

    testWidgets('Scenario 4b: BatchQueueScreen displays "Multiple LRs Not Allowed" dialog on notice trigger', (tester) async {
      final controller = BatchProcessingController(useGeminiBackend: false);

      await tester.pumpWidget(
        MaterialApp(
          home: BatchQueueScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      controller.triggerMultipleLrsNotice();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Multiple LRs Not Allowed'), findsOneWidget);
      expect(find.text('Document Validation'), findsOneWidget);
      expect(
        find.text('Multiple LR documents detected. Please upload documents belonging to only one LR at a time.'),
        findsOneWidget,
      );

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.text('Multiple LRs Not Allowed'), findsNothing);
      expect(controller.multipleLrsNoticePending, isFalse);
    });

    test('Scenario 5: Single PDF with multiple different LRs -> addFilePaths triggers MULTIPLE_LRS and removes item', () async {
      final mockBackend = MockGeminiBackendService();
      mockBackend.stubResult = ExtractionResult.failure(
        errorCode: 'MULTIPLE_LRS',
        errorMessage: 'Multiple LR documents detected. Please upload documents belonging to only one LR at a time.',
      );

      final controller = BatchProcessingController(
        geminiService: mockBackend,
        useGeminiBackend: true,
      );

      await controller.addFilePaths(['/dummy/path/multi_lr_doc.pdf']);

      // 1. Must trigger multipleLrsNotice
      expect(controller.multipleLrsNoticePending, isTrue);
      expect(
        controller.multipleLrsNoticeMessage,
        'Multiple LR documents detected. Please upload documents belonging to only one LR at a time.',
      );

      // 2. Step 2 must have 0 items (rejected item removed)
      expect(controller.items.isEmpty, isTrue);
    });
  });
}
