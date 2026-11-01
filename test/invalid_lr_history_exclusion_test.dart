import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/models/extraction_result.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';
import 'package:ocr_to_excel/views/home_screen.dart';

class MockGeminiInvalid extends GeminiBackendService {
  @override
  Future<ExtractionResult> extractHandwriting(
    String imagePath, {
    String? originalFileName,
    String? customPrompt,
    String? userId,
    String? userMobile,
    String? userName,
    String? sessionToken,
  }) async {
    return ExtractionResult.failure(
      errorCode: 'INVALID_LR',
      errorMessage: 'Invalid LR – Please upload a valid LR document.',
    );
  }
}

class MockGeminiValid extends GeminiBackendService {
  @override
  Future<ExtractionResult> extractHandwriting(
    String imagePath, {
    String? originalFileName,
    String? customPrompt,
    String? userId,
    String? userMobile,
    String? userName,
    String? sessionToken,
  }) async {
    return ExtractionResult.success(
      data: {
        'LR No *': '99001',
        'Customer Name *': 'Patanjali Foods Ltd',
        'cngr *': 'Patanjali Haridwar',
        'cnge *': 'Delhi Distributor',
        'Vehicle No *': 'UP14BT1234',
        'stockpckgs': '500',
        'stockaweight': '2500',
      },
      missingFields: const [],
      rawText: 'PATANJALI CONSIGNMENT NOTE 99001',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Invalid LR History Exclusion Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'bnf_user_mobile': '8009970417',
        'bnf_user_name': 'Maurya',
        'bnf_user_token': 'bnf_test_token',
      });
    });

    test('1. Invalid LR is discarded from items and never added to previousUploadsCache or SharedPreferences', () async {
      final controller = BatchProcessingController(geminiService: MockGeminiInvalid());
      controller.setActiveUser('8009970417', name: 'Maurya', sessionToken: 'bnf_test_token');

      final item = BatchItem(
        id: 'inv_doc_1',
        imagePath: '/tmp/selfie.jpg',
        fileName: 'selfie.jpg',
        status: BatchItemStatus.pending,
        createdAt: DateTime.now(),
      );

      controller.addItemDirectly(item);
      expect(controller.items.length, 1);

      await controller.processQueue();

      // Ensure item is removed from queue
      expect(controller.items, isEmpty);

      // Ensure item was never added to previousUploadsCache
      expect(controller.previousUploadsCache.any((u) => u['id'] == 'inv_doc_1' || u['fileName'] == 'selfie.jpg'), isFalse);

      // Verify SharedPreferences does not contain the invalid LR
      final prefs = await SharedPreferences.getInstance();
      final recentJson = prefs.getString('bnf_recent_uploaded_lrs');
      if (recentJson != null) {
        final decoded = jsonDecode(recentJson) as List;
        expect(decoded.any((u) => u['id'] == 'inv_doc_1' || u['fileName'] == 'selfie.jpg'), isFalse);
      }
    });

    test('2. Multiple uploads: Invalid LR discarded while genuine LR is saved into history', () async {
      // Step A: Process invalid document
      final controllerInv = BatchProcessingController(geminiService: MockGeminiInvalid());
      controllerInv.setActiveUser('8009970417', name: 'Maurya', sessionToken: 'bnf_test_token');

      final invItem = BatchItem(
        id: 'invalid_doc_x',
        imagePath: '/tmp/screenshot.png',
        fileName: 'screenshot.png',
        status: BatchItemStatus.pending,
        createdAt: DateTime.now(),
      );
      controllerInv.addItemDirectly(invItem);
      await controllerInv.processQueue();

      expect(controllerInv.items, isEmpty);
      expect(controllerInv.previousUploadsCache, isEmpty);

      // Step B: Process genuine document
      final controllerVal = BatchProcessingController(geminiService: MockGeminiValid());
      controllerVal.setActiveUser('8009970417', name: 'Maurya', sessionToken: 'bnf_test_token');

      final valItem = BatchItem(
        id: 'genuine_doc_y',
        imagePath: '/tmp/genuine_patanjali.pdf',
        fileName: 'genuine_patanjali.pdf',
        status: BatchItemStatus.pending,
        createdAt: DateTime.now(),
      );
      controllerVal.addItemDirectly(valItem);
      await controllerVal.processQueue();

      expect(controllerVal.items.length, 1);
      expect(controllerVal.items.first.status, BatchItemStatus.completed);
      expect(controllerVal.previousUploadsCache.length, 1);
      expect(controllerVal.previousUploadsCache.first['id'], 'genuine_doc_y');
      expect(controllerVal.previousUploadsCache.first['lrNo'], '99001');

      // Verify invalid document is completely absent
      expect(controllerVal.previousUploadsCache.any((u) => u['id'] == 'invalid_doc_x'), isFalse);
    });

    testWidgets('3. Stale or invalid entries in local storage are cleansed on load and never shown', (tester) async {
      // Simulate existing local storage with one invalid/empty LR and one genuine LR
      SharedPreferences.setMockInitialValues({
        'bnf_user_mobile': '8009970417',
        'bnf_user_name': 'Maurya',
        'bnf_user_token': 'bnf_test_token',
        'bnf_recent_uploaded_lrs': jsonEncode([
          {
            'id': 'stale_invalid_id',
            'fileName': 'invalid_selfie.jpg',
            'status': 'pending',
            'isVerified': false,
            'lrNo': '',
            'record': {},
          },
          {
            'id': 'genuine_lr_1',
            'fileName': 'genuine_patanjali.pdf',
            'status': 'completed',
            'isVerified': true,
            'lrNo': '99001',
            'record': {
              'LR No *': '99001',
              'Customer Name *': 'Patanjali Foods Ltd',
            },
          }
        ]),
      });

      final controller = BatchProcessingController(geminiService: MockGeminiValid());
      controller.setActiveUser('8009970417', name: 'Maurya', sessionToken: 'bnf_test_token');

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Genuine LR must be displayed
      expect(find.text('LR: 99001'), findsOneWidget);

      // 2. Stale invalid LR must be filtered out
      expect(find.text('invalid_selfie.jpg'), findsNothing);
      expect(find.text('LR: invalid_selfie.jpg'), findsNothing);

      // 3. SharedPreferences must have been sanitized
      final prefs = await SharedPreferences.getInstance();
      final sanitizedJson = prefs.getString('bnf_recent_uploaded_lrs');
      expect(sanitizedJson, isNotNull);
      final decoded = jsonDecode(sanitizedJson!) as List;
      expect(decoded.any((u) => u['id'] == 'stale_invalid_id' || u['fileName'] == 'invalid_selfie.jpg'), isFalse);
      expect(decoded.any((u) => u['id'] == 'genuine_lr_1'), isTrue);
    });

    testWidgets('4. Invalid LR notice triggers exact popup and purges file from HomeScreen state', (tester) async {
      final controller = BatchProcessingController(geminiService: MockGeminiInvalid());
      controller.setActiveUser('8009970417', name: 'Maurya', sessionToken: 'bnf_test_token');

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Trigger the invalid LR notice with rejected file details
      controller.triggerInvalidLrNotice(
        'Invalid LR – Please upload a valid LR document.',
        rejectedId: 'rejected_file_1',
        rejectedFileName: 'fake_invoice.jpg',
      );
      await tester.pumpAndSettle();

      // 1. Verify exact dialog title and message
      expect(find.text('Invalid LR'), findsOneWidget);
      expect(find.text('Invalid LR – Please upload a valid LR document.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);

      // Tap OK button to dismiss
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Dialog is dismissed
      expect(find.byType(AlertDialog), findsNothing);

      // Ensure the rejected file is not in Previously Uploaded LRs
      expect(find.text('fake_invoice.jpg'), findsNothing);
      expect(find.text('LR: fake_invoice.jpg'), findsNothing);
    });
  });
}
