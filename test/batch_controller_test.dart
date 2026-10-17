import 'dart:math';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:ocr_to_excel/config/document_schema.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';

class FakePermissionService extends PermissionService {
  bool granted = true;
  @override
  Future<bool> requestCameraPermission() async => granted;
  @override
  Future<bool> requestGalleryPermission() async => granted;
}

class FakeImageService extends ImageService {
  String? nextCameraImage;
  List<String> nextGalleryImages = [];

  @override
  Future<String?> captureFromCamera({int? imageQuality}) async =>
      nextCameraImage;

  @override
  Future<List<String>> pickMultipleImages({int? imageQuality}) async =>
      nextGalleryImages;

  @override
  Future<String?> pickSingleImage({int? imageQuality}) async =>
      nextGalleryImages.isNotEmpty ? nextGalleryImages.first : null;
}

class FakeOcrService extends OcrService {
  String textToReturn = 'Invoice No: INV-999\nDate: 2026-09-27\nTotal Amount: \$99.00';
  bool shouldThrow = false;

  @override
  Future<RecognizedText> recognizeTextFromPath(String imagePath) async {
    if (shouldThrow) {
      throw StateError('Simulated OCR failure');
    }
    int y = 0;
    final List<TextLine> lines = textToReturn.split('\n').map<TextLine>((line) {
      final rect = Rect.fromLTWH(0, y.toDouble(), 200, 20);
      y += 30;
      return TextLine(
        text: line,
        elements: const [],
        boundingBox: rect,
        recognizedLanguages: const ['en'],
        cornerPoints: const <Point<int>>[],
        confidence: 1.0,
        angle: 0.0,
      );
    }).toList();

    return RecognizedText(
      text: textToReturn,
      blocks: [
        TextBlock(
          text: textToReturn,
          lines: lines,
          boundingBox: const Rect.fromLTWH(0, 0, 100, 100),
          recognizedLanguages: const ['en'],
          cornerPoints: const <Point<int>>[],
        ),
      ],
    );
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late FakePermissionService permissionService;
  late FakeImageService imageService;
  late FakeOcrService ocrService;
  late FormatParserService parserService;
  late ExcelService excelService;
  late BatchProcessingController controller;

  setUp(() {
    permissionService = FakePermissionService();
    imageService = FakeImageService();
    ocrService = FakeOcrService();
    parserService = FormatParserService();
    excelService = ExcelService();

    controller = BatchProcessingController(
      permissionService: permissionService,
      imageService: imageService,
      ocrService: ocrService,
      parserService: parserService,
      excelService: excelService,
    );
  });

  group('BatchProcessingController - Queue & Pipeline', () {
    test('transitions through pending -> processing -> completed on camera intake', () async {
      imageService.nextCameraImage = '/path/to/invoice.jpg';

      final success = await controller.addFromCamera();

      expect(success, isTrue);
      expect(controller.items.length, 1);
      final item = controller.items.first;

      expect(item.status, BatchItemStatus.completed);
      // Keys are stored as extracted (Title Case / original), not as snake_case aliases
      expect(item.record['Invoice No'], 'INV-999');
      expect(item.record['Date'], '2026-09-27');
      expect(item.record['Total Amount'], r'$99.00');
      expect(controller.canExport, isTrue);
    });

    test('marks status as error when OCR throws an exception', () async {
      imageService.nextCameraImage = '/path/to/corrupted.jpg';
      ocrService.shouldThrow = true;

      await controller.addFromCamera();

      expect(controller.items.length, 1);
      final item = controller.items.first;

      expect(item.status, BatchItemStatus.error);
      expect(item.errorMessage, contains('Simulated OCR failure'));
      expect(controller.errorCount, 1);
    });

    test('adds multiple images from gallery and processes all sequentially', () async {
      imageService.nextGalleryImages = [
        '/gallery/img1.jpg',
        '/gallery/img2.jpg',
        '/gallery/img3.jpg',
      ];

      final success = await controller.addFromGallery();

      expect(success, isTrue);
      expect(controller.items.length, 3);
      expect(controller.completedCount, 3);
      expect(controller.totalCount, 3);
    });

    test('adds single image from gallery and processes one item', () async {
      imageService.nextGalleryImages = [
        '/gallery/single_img.jpg',
      ];

      final success = await controller.addFromGallerySingle();

      expect(success, isTrue);
      expect(controller.items.length, 1);
      expect(controller.completedCount, 1);
      expect(controller.totalCount, 1);
    });

    test('updates field value when user edits in review table', () async {
      imageService.nextCameraImage = '/path/to/invoice.jpg';
      await controller.addFromCamera();

      final itemId = controller.items.first.id;
      controller.updateRecordField(itemId, 'invoice_no', 'INV-EDITED-123');

      expect(controller.items.first.record['invoice_no'], 'INV-EDITED-123');
    });

    test('removes item and clears queue properly', () async {
      imageService.nextGalleryImages = ['/img1.jpg', '/img2.jpg'];
      await controller.addFromGallery();

      expect(controller.items.length, 2);
      final firstId = controller.items.first.id;

      controller.removeItem(firstId);
      expect(controller.items.length, 1);

      controller.clearQueue();
      expect(controller.items, isEmpty);
      expect(controller.canExport, isFalse);
    });

    test('switches document schema and updates active schema', () {
      expect(controller.currentSchema.id, 'dynamic');
      controller.setSchema(DocumentSchema.receipt);
      expect(controller.currentSchema.id, 'receipt');
    });

    test('isDuplicate detects normalized LR number duplicate', () {
      controller.addImagePath('/gallery/lr1.jpg');
      controller.updateRecordField(controller.items.first.id, 'LR No *', 'LR-10023-A');

      // Exact match
      expect(controller.isDuplicate(lrNo: 'LR-10023-A'), isTrue);
      // Case-insensitive & formatting difference (spaces, hyphens removed)
      expect(controller.isDuplicate(lrNo: 'lr 10023 a'), isTrue);
      // Different LR
      expect(controller.isDuplicate(lrNo: 'LR-99999'), isFalse);
      // Self-exclusion when editing
      expect(controller.isDuplicate(lrNo: 'LR-10023-A', excludeItemId: controller.items.first.id), isFalse);
    });

    test('isDuplicate detects duplicate by imageHash and core composite details', () {
      controller.addImagePath('/gallery/hash_doc.jpg');
      final firstId = controller.items.first.id;
      final hash = controller.computeImageHash('/gallery/hash_doc.jpg');

      // Hash match
      expect(controller.isDuplicate(imagePath: '/gallery/hash_doc.jpg'), isTrue);
      expect(controller.isDuplicate(imageHash: hash), isTrue);
      expect(controller.isDuplicate(imageHash: 'non_existent_hash'), isFalse);

      // Core composite match (Customer + Consignee + Vehicle)
      controller.updateRecordField(firstId, 'Customer Name *', 'Acme Logistics');
      controller.updateRecordField(firstId, 'cnge *', 'Beta Retail');
      controller.updateRecordField(firstId, 'Vehicle No *', 'MH12DE1234');

      expect(
        controller.isDuplicate(
          record: {
            'Customer Name *': 'Acme Logistics',
            'cnge *': 'Beta Retail',
            'Vehicle No *': 'MH12DE1234',
          },
        ),
        isTrue,
      );
    });

    test('duplicate rejection blocks second upload and triggers duplicateNoticePending', () async {
      imageService.nextCameraImage = '/gallery/photo1.jpg';
      final ok1 = await controller.addFromCamera();
      expect(ok1, isTrue);
      expect(controller.items.length, 1);

      // Try uploading the exact same path/image
      imageService.nextCameraImage = '/gallery/photo1.jpg';
      final ok2 = await controller.addFromCamera();
      expect(ok2, isFalse);
      expect(controller.items.length, 1);
      expect(controller.duplicateNoticePending, isTrue);
      expect(
        controller.duplicateNoticeMessage,
        'This LR already exists. You cannot add the same LR multiple times.',
      );

      // Acknowledge notice
      controller.acknowledgeDuplicateNotice();
      expect(controller.duplicateNoticePending, isFalse);
    });

    test('post-OCR duplicate check rejects duplicate LR and triggers duplicate notice', () async {
      imageService.nextGalleryImages = ['/gallery/first_doc.jpg'];
      await controller.addFromGallerySingle();
      expect(controller.items.length, 1);
      controller.updateRecordField(controller.items.first.id, 'LR No *', 'LR-7777');

      // Second upload will return text containing LR-7777
      ocrService.textToReturn = 'LR No: LR-7777\nVehicle: MH12AB1234\nCustomer: ABC Corp';
      imageService.nextGalleryImages = ['/gallery/second_different_file.jpg'];
      await controller.addFromGallerySingle();

      // Second item must be removed due to duplicate post-OCR
      expect(controller.items.length, 1);
      expect(controller.duplicateNoticePending, isTrue);
      expect(
        controller.duplicateNoticeMessage,
        'This LR already exists. You cannot add the same LR multiple times.',
      );
    });
  });
}
