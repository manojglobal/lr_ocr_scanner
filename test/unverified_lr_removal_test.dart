import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Unverified LR Removal & Duplicate Upload Prevention', () {
    test('Scenario 1: Scan LR -> Unverified -> Remove -> Step 2 Cleared -> Re-upload accepted', () async {
      final controller = BatchProcessingController(useGeminiBackend: false);

      // 1. Create an unverified LR item (scanned, but not verified)
      final unverifiedItem = BatchItem(
        id: 'unverified-doc-1',
        imagePath: '/test/scans/lr_33118.pdf',
        fileName: 'lr_33118.pdf',
        createdAt: DateTime.now(),
        status: BatchItemStatus.completed,
        record: {
          'LR No *': '33118',
          'pending_verification': 'true',
          'is_verified': 'false',
          'saved_filename': 'LR_33118_saved.pdf',
        },
      );

      controller.addItemDirectly(unverifiedItem);
      controller.setPreviousUploadsCache([
        {
          'id': 'unverified-doc-1',
          'fileName': 'lr_33118.pdf',
          'saved_filename': 'LR_33118_saved.pdf',
          'lrNo': '33118',
          'isVerified': false,
        }
      ]);

      // Confirm it is in controller.items (Step 2) but is unverified
      expect(controller.items.length, 1);
      expect(controller.items.first.isVerified, isFalse);

      // Confirm duplicate check would block re-upload while it is currently active
      final isDupBefore = controller.isDuplicate(
        lrNo: '33118',
        fileName: 'lr_33118.pdf',
      );
      expect(isDupBefore, isTrue);

      // 2. Remove unverified item (simulate user removing from Previously Uploaded LRs)
      final removed = controller.removeUnverifiedItem(
        id: 'unverified-doc-1',
        fileName: 'lr_33118.pdf',
        savedFilename: 'LR_33118_saved.pdf',
        lrNo: '33118',
      );
      expect(removed, isTrue, reason: 'Unverified item must be matched and removed');

      // 3. Confirm Step 2 is completely cleared of the unverified item
      expect(controller.items.isEmpty, isTrue, reason: 'Step 2 (controller.items) must be empty after removal');
      expect(controller.previousUploadsCache.isEmpty, isTrue, reason: 'Previous uploads cache must be empty');

      // 4. Try re-uploading the exact same LR
      final isDupAfter = controller.isDuplicate(
        lrNo: '33118',
        fileName: 'lr_33118.pdf',
      );
      expect(isDupAfter, isFalse, reason: 'Re-uploading the same LR must NOT be flagged as duplicate after removal');
    });

    test('Scenario 2: Verified LR -> Remove from history -> Retained in Step 3 LR List -> Re-upload blocked', () async {
      final controller = BatchProcessingController(useGeminiBackend: false);

      // 1. Create an already verified LR item (all mandatory fields filled and marked verified)
      final verifiedItem = BatchItem(
        id: 'verified-doc-1',
        imagePath: '/test/scans/lr_33119.pdf',
        fileName: 'lr_33119.pdf',
        createdAt: DateTime.now(),
        status: BatchItemStatus.completed,
        record: {
          'LR No *': '33119',
          'grno (*)': '33119',
          'grdt *': '15-11-2026',
          'Customer Name *': 'HIMALAYA WELLNESS COMPANY',
          'Vehicle No *': 'KA01AB1234',
          'Vehicle Type *': 'Market',
          'Driver Name *': 'Ramesh Kumar',
          'Mobile no   *': '9876543210',
          'Liscense No *': 'KA0120150001234',
          'Valid Up to *': '31-12-2028',
          'Loading Start date *': '15-11-2026',
          'freight  *': '12500',
          'cngr *': 'Himalaya Wellness',
          'cnge *': 'Global Marketing',
          'cngrgstno *': '29AABCH1234F1Z5',
          'cngegstno *': '29AABCG5678F1Z2',
          'is_verified': 'true',
          'saved_filename': 'LR_33119_saved.pdf',
        },
      );

      controller.addItemDirectly(verifiedItem);
      controller.setPreviousUploadsCache([
        {
          'id': 'verified-doc-1',
          'fileName': 'lr_33119.pdf',
          'saved_filename': 'LR_33119_saved.pdf',
          'lrNo': '33119',
          'isVerified': true,
        }
      ]);

      // Confirm item is verified
      expect(controller.items.length, 1);
      expect(controller.items.first.isVerified, isTrue);

      // 2. Call removeUnverifiedItem - MUST NOT DELETE VERIFIED LR!
      final removed = controller.removeUnverifiedItem(
        id: 'verified-doc-1',
        fileName: 'lr_33119.pdf',
        savedFilename: 'LR_33119_saved.pdf',
        lrNo: '33119',
      );
      expect(removed, isFalse, reason: 'removeUnverifiedItem must refuse to delete verified LRs');

      // 3. Confirm verified item is strictly retained in controller.items (Step 3 LR List intact)
      expect(controller.items.length, 1);
      expect(controller.items.first.id, 'verified-doc-1');
      expect(controller.items.first.isVerified, isTrue);

      // 4. Try re-uploading the exact same verified LR -> MUST BE BLOCKED as duplicate
      final isDup = controller.isDuplicate(
        lrNo: '33119',
        fileName: 'lr_33119.pdf',
      );
      expect(isDup, isTrue, reason: 'Verified LRs must strictly trigger duplicate protection');
    });

    testWidgets('Scenario 3: HomeScreen - Removing unverified LR clears Step 2 and allows re-upload', (tester) async {
      final controller = BatchProcessingController(useGeminiBackend: false);

      final unverifiedItem = BatchItem(
        id: 'doc-cancel-1',
        imagePath: 'dummy/path/LR_4444.pdf',
        fileName: 'LR_4444.pdf',
        createdAt: DateTime.now(),
        status: BatchItemStatus.completed,
        record: {
          'LR No *': '4444',
          'is_cancelled': 'true',
          'pending_verification': 'true',
          'is_verified': 'false',
          'saved_filename': 'LR_4444_saved.pdf',
        },
      );
      controller.addItemDirectly(unverifiedItem);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bnf_recent_uploaded_lrs', jsonEncode([
        {
          'id': 'doc-cancel-1',
          'fileName': 'LR_4444.pdf',
          'saved_filename': 'LR_4444_saved.pdf',
          'lrNo': '4444',
          'isVerified': false,
        }
      ]));

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Verify item appears in Previously Uploaded LRs
      expect(find.text('Previously Uploaded LRs'), findsOneWidget);
      expect(find.text('LR: 4444'), findsOneWidget);

      // Click remove (X) icon on the unverified card
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();

      // Click Confirm in removal modal
      expect(find.text('Confirm'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      // Verify unverified LR is completely removed from controller.items (Step 2 is cleared)
      expect(controller.items.isEmpty, isTrue, reason: 'Controller items (Step 2) must be empty after removing unverified LR');

      // Verify duplicate check now allows re-uploading LR 4444
      final isDup = controller.isDuplicate(lrNo: '4444', fileName: 'LR_4444.pdf');
      expect(isDup, isFalse, reason: 'Re-uploading LR 4444 must be allowed without duplicate error');
    });
  });
}
