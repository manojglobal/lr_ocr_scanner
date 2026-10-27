import 'dart:convert';
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
import 'package:ocr_to_excel/views/screens/edit_bilty_screen.dart';
import 'package:ocr_to_excel/views/widgets/billing_image_viewer.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StubPermissionService extends PermissionService {}
class StubImageService extends ImageService {}
class StubOcrService extends OcrService {
  @override
  Future<void> dispose() async {}
}

// 1x1 transparent GIF base64
const sampleBase64 = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BatchProcessingController controller;

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
  });

  tearDown(() {
    controller.dispose();
  });

  group('Issue 1: PDF Loading Performance & In-Memory Pre-warming', () {
    test('resolveBase64Bytes caches decoded bytes and returns cached instance', () {
      final item = BatchItem(
        id: 'test_pdf_cache_1',
        imagePath: '/test/doc.pdf',
        fileName: 'doc.pdf',
        createdAt: DateTime.now(),
        record: {
          'preview_image': sampleBase64,
          'preview_pages': jsonEncode(['/previews/doc_p1.jpg', '/previews/doc_p2.jpg']),
        },
      );

      final bytes1 = BillingImageViewer.resolveBase64Bytes(item);
      expect(bytes1, isNotNull);
      expect(bytes1!.isNotEmpty, isTrue);

      final bytes2 = BillingImageViewer.resolveBase64Bytes(item);
      expect(identical(bytes1, bytes2), isTrue, reason: 'Must return identical cached instance without re-decoding');
    });

    test('prewarm correctly decodes base64 and parses preview pages', () {
      final item = BatchItem(
        id: 'test_pdf_cache_2',
        imagePath: '/test/doc2.pdf',
        fileName: 'doc2.pdf',
        createdAt: DateTime.now(),
        record: {
          'preview_image': sampleBase64,
          'preview_pages': jsonEncode(['/previews/doc2_p1.jpg', '/previews/doc2_p2.jpg']),
        },
      );

      BillingImageViewer.prewarm(item);

      final pages = BillingImageViewer.getPdfPreviewPagesStatic(item);
      expect(pages.length, 2);
      expect(pages[0], '/previews/doc2_p1.jpg');

      final cached = BillingImageViewer.resolveBase64Bytes(item);
      expect(cached, isNotNull);
    });
  });

  group('Issue 3: Previous Upload Navigation & Duplicate Prevention', () {
    testWidgets('Tapping previous upload opens EditBiltyScreen without creating duplicate in controller', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final existingItem = BatchItem(
        id: 'existing_lr_item_1',
        imagePath: '/test/lr101.pdf',
        fileName: 'lr101.pdf',
        status: BatchItemStatus.completed,
        createdAt: DateTime.now(),
        record: {
          'LR No *': 'BNF-778899',
          'saved_filename': 'lr101.pdf',
          'preview_image': sampleBase64,
        },
      );

      controller.addItemDirectly(existingItem);
      expect(controller.items.length, 1);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Ensure Previously Uploaded LRs displays the card
      final cardFinder = find.text('LR: BNF-778899');
      expect(cardFinder, findsOneWidget);

      // Tap card
      await tester.tap(cardFinder);
      await tester.pumpAndSettle();

      // Verify opened into Step 2: LR & Master Verification (EditBiltyScreen)
      expect(find.byType(EditBiltyScreen), findsOneWidget);

      // Verify batch items count DID NOT duplicate
      expect(controller.items.length, 1, reason: 'Duplicate item must not be added to controller');
    });
  });
}
