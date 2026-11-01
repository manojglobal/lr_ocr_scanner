import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/models/extraction_result.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';
import 'package:ocr_to_excel/views/home_screen.dart';

class MockGeminiInvalidLr extends GeminiBackendService {
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

class MockGeminiValidLr extends GeminiBackendService {
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
        'LR No *': '32298',
        'cngr *': 'Unicharm India Pvt Ltd',
        'cnge *': 'Global Marketing',
        'Vehicle No *': 'HR55AX5490',
        'stockpckgs': '1375',
      },
      missingFields: const [],
      rawText: 'BOX N FREIGHT CONSIGNMENT NOTE 32298',
    );
  }
}

class MockGeminiConnectionError extends GeminiBackendService {
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
      errorMessage: 'SocketException: Connection refused',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Genuine LR Validation & Error Dialog Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'bnf_user_mobile': '8009970417',
        'bnf_user_name': 'Maurya',
        'bnf_user_token': 'bnf_test_token',
      });
    });

    test('1. Controller rejects invalid LR, removes from items, and triggers invalid LR notice', () async {
      final controller = BatchProcessingController(geminiService: MockGeminiInvalidLr());
      controller.setActiveUser('8009970417', name: 'Maurya', sessionToken: 'bnf_test_token');

      // Add dummy pending item
      final item = BatchItem(
        id: 'test_inv_1',
        imagePath: 'test_path.jpg',
        fileName: 'selfie.jpg',
        status: BatchItemStatus.pending,
        createdAt: DateTime.now(),
      );
      controller.addItemDirectly(item);
      expect(controller.items.length, equals(1));

      // Trigger queue processing
      await controller.processQueue();

      // Item should be completely discarded from queue (zero persistence)
      expect(controller.items.where((i) => i.id == 'test_inv_1'), isEmpty);
      expect(controller.invalidLrNoticePending, isTrue);
      expect(controller.invalidLrNoticeMessage, equals('Invalid LR – Please upload a valid LR document.'));
    });

    test('2. Controller discards item on server connection failure and does NOT use ML fallback to accept', () async {
      final controller = BatchProcessingController(geminiService: MockGeminiConnectionError());
      controller.setActiveUser('8009970417', name: 'Maurya', sessionToken: 'bnf_test_token');

      final item = BatchItem(
        id: 'test_err_1',
        imagePath: 'test_err.jpg',
        fileName: 'offline.jpg',
        status: BatchItemStatus.pending,
        createdAt: DateTime.now(),
      );
      controller.addItemDirectly(item);
      await controller.processQueue();

      // Item discarded from items list
      expect(controller.items.where((i) => i.id == 'test_err_1'), isEmpty);
      expect(controller.connectionErrorNoticePending, isTrue);
    });

    test('3. Controller accepts genuine LR with valid logistics fields', () async {
      final controller = BatchProcessingController(geminiService: MockGeminiValidLr());
      controller.setActiveUser('8009970417', name: 'Maurya', sessionToken: 'bnf_test_token');

      final item = BatchItem(
        id: 'test_valid_1',
        imagePath: 'test_lr.jpg',
        fileName: 'bilty_32298.jpg',
        status: BatchItemStatus.pending,
        createdAt: DateTime.now(),
      );
      controller.addItemDirectly(item);
      await controller.processQueue();

      expect(controller.items.length, equals(1));
      expect(controller.items.first.status, equals(BatchItemStatus.completed));
      expect(controller.items.first.record['LR No *'], equals('32298'));
      expect(controller.invalidLrNoticePending, isFalse);
    });

    testWidgets('4. HomeScreen renders exact "Invalid LR" dialog on rejection', (tester) async {
      final controller = BatchProcessingController(geminiService: MockGeminiInvalidLr());
      controller.setActiveUser('8009970417', name: 'Maurya', sessionToken: 'bnf_test_token');

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Trigger the notice
      controller.triggerInvalidLrNotice('Invalid LR – Please upload a valid LR document.');
      await tester.pumpAndSettle();

      // Verify exact Dialog Title and Message
      expect(find.text('Invalid LR'), findsOneWidget);
      expect(find.text('Invalid LR – Please upload a valid LR document.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);

      // Tap OK button to dismiss
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Dialog is dismissed
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.invalidLrNoticePending, isFalse);
    });
  });
}
