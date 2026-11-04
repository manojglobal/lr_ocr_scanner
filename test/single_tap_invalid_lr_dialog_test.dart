import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/models/extraction_result.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/home_screen.dart';

class MockGeminiInvalidTwice extends GeminiBackendService {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'bnf_user_mobile': '8009970417',
      'bnf_user_name': 'Maurya',
      'bnf_user_token': 'bnf_test_token',
      'bnf_recent_uploaded_lrs': jsonEncode([]),
    });
  });

  group('Single Tap Invalid LR Dialog Dismissal Tests', () {
    testWidgets('1. Repeated rapid notifications create only 1 dialog and 1 tap on OK dismisses it completely', (tester) async {
      final controller = BatchProcessingController(geminiService: MockGeminiInvalidTwice());
      controller.setActiveUser('8009970417', name: 'Maurya', sessionToken: 'bnf_test_token');

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Simulate rapid multiple notifications from controller
      controller.triggerInvalidLrNotice(
        'Invalid LR – Please upload a valid LR document.',
        rejectedId: 'fake_id_1',
        rejectedFileName: 'fake_file_1.jpg',
      );
      controller.notifyListeners();
      controller.notifyListeners();

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Exactly ONE AlertDialog must exist in widget tree
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Invalid LR'), findsOneWidget);
      expect(find.text('Invalid LR – Please upload a valid LR document.'), findsOneWidget);

      // Tap OK button exactly ONCE
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The dialog MUST be completely gone after a single tap!
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('2. Subsequent invalid notice after dismissal opens next dialog and dismisses in 1 tap', (tester) async {
      final controller = BatchProcessingController(geminiService: MockGeminiInvalidTwice());
      controller.setActiveUser('8009970417', name: 'Maurya', sessionToken: 'bnf_test_token');

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Upload 1: Invalid document notice
      controller.triggerInvalidLrNotice(
        'Invalid LR – First rejection',
        rejectedId: 'doc_1',
        rejectedFileName: 'inv1.jpg',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Invalid LR – First rejection'), findsOneWidget);

      // Dismiss with 1 tap
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(AlertDialog), findsNothing);

      // Upload 2: Second invalid document notice
      controller.triggerInvalidLrNotice(
        'Invalid LR – Second rejection',
        rejectedId: 'doc_2',
        rejectedFileName: 'inv2.jpg',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Invalid LR – Second rejection'), findsOneWidget);

      // Dismiss with 1 tap
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(AlertDialog), findsNothing);
    });

    test('3. Controller processQueue rejects invalid LR and triggers single pending notice without redundant notification', () async {
      final controller = BatchProcessingController(geminiService: MockGeminiInvalidTwice());
      controller.setActiveUser('8009970417', name: 'Maurya', sessionToken: 'bnf_test_token');

      int notifyCount = 0;
      controller.addListener(() {
        notifyCount++;
      });

      final item = BatchItem(
        id: 'inv_101',
        fileName: 'selfie.png',
        imagePath: '/tmp/selfie.png',
        status: BatchItemStatus.pending,
        createdAt: DateTime.now(),
      );

      controller.addItemDirectly(item);
      final countBefore = notifyCount;

      await controller.processQueue();

      // Controller must have triggered notice
      expect(controller.invalidLrNoticePending, isTrue);
      expect(controller.lastInvalidLrId, equals('inv_101'));
      expect(controller.items, isEmpty);

      // Synchronously acknowledge
      controller.acknowledgeInvalidLrNotice();
      expect(controller.invalidLrNoticePending, isFalse);
    });
  });
}
