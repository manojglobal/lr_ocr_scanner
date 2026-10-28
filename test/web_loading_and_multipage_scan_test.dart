import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';
import 'package:ocr_to_excel/views/widgets/ocr_processing_dialog.dart';
import 'package:ocr_to_excel/views/screens/multi_page_scan_screen.dart';
import 'package:ocr_to_excel/views/screens/edit_bilty_screen.dart';
import 'package:image/image.dart' as img;

class _MockPermissionService extends Fake implements PermissionService {
  @override
  Future<bool> requestCameraPermission() async => true;
  @override
  Future<bool> requestGalleryPermission() async => true;
  @override
  Future<bool> isCameraPermanentlyDenied() async => false;
}

class _MockImageService extends Fake implements ImageService {
  String? mockPath;
  @override
  Future<String?> captureFromCamera({int? imageQuality}) async => mockPath;
  @override
  Future<List<String>> pickMultipleImages({int? imageQuality}) async => mockPath != null ? [mockPath!] : [];
}

class _FakeOcrService extends Fake implements OcrService {
  String textToReturn = 'LR No: LR-100200\nConsignor: ABC Logistics\nVehicle No: MH12AB1234';

  @override
  Future<RecognizedText> recognizeTextFromPath(String imagePath) async {
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

class _MockPicker extends Fake implements ImagePicker {
  String? nextPhotoPath;
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    if (nextPhotoPath != null) {
      return XFile(nextPhotoPath!);
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Web-Matched Loading Dialog UI Tests', () {
    testWidgets('Renders all 5 steps matching Web commit 28792914', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: OcrProcessingDialog(
              currentStep: 3,
              currentFile: 'bilty_scan.jpg',
              fileIndex: 1,
              totalFiles: 1,
            ),
          ),
        ),
      );

      // Verify Scanner icon
      expect(find.byIcon(Icons.find_in_page_outlined), findsOneWidget);

      // Verify Header
      expect(find.byKey(const Key('ocr_processing_title')), findsOneWidget);
      expect(find.text('Reading Consignment (bilty_scan.jpg)...'), findsOneWidget);
      expect(find.byKey(const Key('ocr_processing_sub')), findsOneWidget);

      // Verify all 5 Checklist Steps
      expect(find.text('Image(s) Uploaded'), findsOneWidget);
      expect(find.text('Reading LR Document'), findsOneWidget);
      expect(find.text('Extracting Consignment Details'), findsOneWidget);
      expect(find.text('Mapping with BNF 49-Column Format'), findsOneWidget);
      expect(find.text('Validating Data & Preserving Blanks'), findsOneWidget);

      // Steps 1 & 2 are completed (should have check_circle_rounded)
      expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(2));

      // Step 3 is active (should have CircularProgressIndicator)
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Steps 4 & 5 are pending (should have radio_button_unchecked)
      expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
    });

    testWidgets('Step 5 completion updates checklist labels', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: OcrProcessingDialog(
              currentStep: 5,
              currentFile: 'doc.jpg',
            ),
          ),
        ),
      );

      // Steps 1-4 completed -> 4 check circles
      expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(4));
      // Step 5 active -> CircularProgressIndicator
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Data Validated & Blanks Preserved'), findsOneWidget);
    });
  });

  group('MultiPageScanScreen Interactive Tests', () {
    late Directory tempDir;
    late File testFile1;
    late File testFile2;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('scan_test_');
      final im1 = img.Image(width: 100, height: 100);
      img.fill(im1, color: img.ColorRgb8(255, 0, 0));
      testFile1 = File('${tempDir.path}/page1.jpg');
      await testFile1.writeAsBytes(img.encodeJpg(im1));

      final im2 = img.Image(width: 100, height: 100);
      img.fill(im2, color: img.ColorRgb8(0, 0, 255));
      testFile2 = File('${tempDir.path}/page2.jpg');
      await testFile2.writeAsBytes(img.encodeJpg(im2));
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets('Displays initial page and single LR guidance banner', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MultiPageScanScreen(
            initialPages: [testFile1.path],
          ),
        ),
      );

      expect(find.text('Multi-Page LR Scan'), findsOneWidget);
      expect(find.text('1 Page Captured'), findsOneWidget);
      expect(
        find.text('All captured pages will be combined into a single LR document with one LR number.'),
        findsOneWidget,
      );
      expect(find.text('Page 1 of 1'), findsOneWidget);
      expect(find.text('Scan 1 Page as 1 LR'), findsOneWidget);
    });

    testWidgets('Can capture another page and update thumbnail strip', (tester) async {
      final mockPicker = _MockPicker()..nextPhotoPath = testFile2.path;

      await tester.pumpWidget(
        MaterialApp(
          home: MultiPageScanScreen(
            initialPages: [testFile1.path],
            imagePicker: mockPicker,
          ),
        ),
      );

      // Tap "+ Add Page"
      await tester.tap(find.byKey(const Key('add_another_page_btn')));
      await tester.pumpAndSettle();

      // Now 2 pages captured
      expect(find.text('2 Pages Captured'), findsOneWidget);
      expect(find.text('Scan 2 Pages as 1 LR'), findsOneWidget);
      expect(find.byKey(const Key('thumb_page_0')), findsOneWidget);
      expect(find.byKey(const Key('thumb_page_1')), findsOneWidget);
    });

    testWidgets('Reorders pages with Move Left / Move Right', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MultiPageScanScreen(
            initialPages: [testFile1.path, testFile2.path],
          ),
        ),
      );

      // Currently on Page 2 (last page)
      expect(find.text('Page 2 of 2'), findsOneWidget);

      // Move Left
      await tester.tap(find.byKey(const Key('move_page_left_btn')));
      await tester.pumpAndSettle();

      expect(find.text('Page 1 of 2'), findsOneWidget);
    });

    testWidgets('Submitting all pages returns the ordered file list', (tester) async {
      List<String>? resultPages;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                resultPages = await Navigator.of(ctx).push<List<String>>(
                  MaterialPageRoute(
                    builder: (_) => MultiPageScanScreen(
                      initialPages: [testFile1.path, testFile2.path],
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Tap "Scan 2 Pages as 1 LR"
      await tester.tap(find.byKey(const Key('upload_all_pages_btn')));
      await tester.pumpAndSettle();

      expect(resultPages, isNotNull);
      expect(resultPages!.length, 2);
      expect(resultPages![0], testFile1.path);
      expect(resultPages![1], testFile2.path);
    });
  });

  group('Single LR Number Across Multiple Pages Ingestion Tests', () {
    late Directory tempDir;
    late File testFile1;
    late File testFile2;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ctrl_test_');
      final im1 = img.Image(width: 150, height: 150);
      img.fill(im1, color: img.ColorRgb8(255, 128, 0));
      testFile1 = File('${tempDir.path}/p1.jpg');
      await testFile1.writeAsBytes(img.encodeJpg(im1));

      final im2 = img.Image(width: 150, height: 150);
      img.fill(im2, color: img.ColorRgb8(0, 128, 255));
      testFile2 = File('${tempDir.path}/p2.jpg');
      await testFile2.writeAsBytes(img.encodeJpg(im2));
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('addMultiPageScan creates exactly ONE BatchItem with 2 preview pages', () async {
      final ctrl = BatchProcessingController(
        permissionService: _MockPermissionService(),
        imageService: _MockImageService(),
        ocrService: _FakeOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: GeminiBackendService(),
      );

      final success = await ctrl.addMultiPageScan([testFile1.path, testFile2.path]);
      expect(success, isTrue);

      // Exactly ONE item created for the 2 pages
      expect(ctrl.items.length, 1);
      final item = ctrl.items.first;

      // Single item has multi-page metadata
      expect(item.record['page_count'], '2');
      final pagesJson = item.record['preview_pages'];
      expect(pagesJson, isNotNull);
      final decoded = jsonDecode(pagesJson!) as List;
      expect(decoded.length, 2);

      // PDF dossier was assembled
      expect(item.fileName.endsWith('.pdf'), isTrue);
      expect(File(item.imagePath).existsSync(), isTrue);
    });

    test('Duplicate prevention detects duplicate multi-page LR', () async {
      final ctrl = BatchProcessingController(
        permissionService: _MockPermissionService(),
        imageService: _MockImageService(),
        ocrService: _FakeOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: GeminiBackendService(),
      );

      final firstAdd = await ctrl.addMultiPageScan([testFile1.path, testFile2.path]);
      expect(firstAdd, isTrue);
      expect(ctrl.items.length, 1);

      // Adding the exact same session again should be blocked
      final secondAdd = await ctrl.addMultiPageScan([testFile1.path, testFile2.path]);
      expect(secondAdd, isFalse);
      expect(ctrl.items.length, 1);
      expect(ctrl.duplicateNoticePending, isTrue);
    });
  });

  group('EditBiltyScreen Multi-Page Badge Tests', () {
    late Directory tempDir;
    late File f1;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('bilty_badge_');
      final im = img.Image(width: 50, height: 50);
      f1 = File('${tempDir.path}/page1.jpg');
      await f1.writeAsBytes(img.encodeJpg(im));
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets('Displays page count badge when page_count > 1', (tester) async {
      final item = BatchItem(
        id: 'test-multi-id',
        imagePath: f1.path,
        fileName: 'consignment_doc.pdf',
        createdAt: DateTime.now(),
        record: {
          'LR No *': 'LR-998877',
          'grno (*)': 'LR-998877',
          'page_count': '3',
          'preview_pages': jsonEncode([f1.path]),
        },
      );

      final ctrl = BatchProcessingController(
        permissionService: _MockPermissionService(),
        imageService: _MockImageService(),
        ocrService: _FakeOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: GeminiBackendService(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EditBiltyScreen(
              item: item,
              controller: ctrl,
            ),
          ),
        ),
      );

      expect(find.text('3 Pages'), findsOneWidget);
      expect(find.text('consignment_doc.pdf'), findsOneWidget);
    });
  });
}
