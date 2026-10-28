import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';
import 'package:ocr_to_excel/views/screens/camera_scan_screen.dart';

class _MockPermissionService extends Fake implements PermissionService {
  @override
  Future<bool> requestCameraPermission() async => true;
  @override
  Future<bool> requestGalleryPermission() async => true;
  @override
  Future<bool> isCameraPermanentlyDenied() async => false;
}

class _MockImageService extends Fake implements ImageService {
  @override
  Future<String?> captureFromCamera({int? imageQuality}) async => null;
  @override
  Future<List<String>> pickMultipleImages({int? imageQuality}) async => [];
}

class _FakeOcrService extends Fake implements OcrService {
  String textToReturn = 'LR No: LR-998877\nConsignor: TEST LOGISTICS\nConsignee: RECEIVER CO\nVehicle No: MH04AB9999\nFreight: 5500';

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

class _QueueImagePicker extends Fake implements ImagePicker {
  final List<String> queuedPhotos = [];
  int _idx = 0;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    if (_idx < queuedPhotos.length) {
      final path = queuedPhotos[_idx++];
      return XFile(path);
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File photo1;
  late File photo2;
  late File photo3;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cam_scan_test_');

    // Create valid test JPEGs
    final im1 = img.Image(width: 200, height: 200);
    img.fill(im1, color: img.ColorRgb8(255, 0, 0));
    photo1 = File('${tempDir.path}/photo1.jpg');
    await photo1.writeAsBytes(img.encodeJpg(im1));

    final im2 = img.Image(width: 200, height: 200);
    img.fill(im2, color: img.ColorRgb8(0, 255, 0));
    photo2 = File('${tempDir.path}/photo2.jpg');
    await photo2.writeAsBytes(img.encodeJpg(im2));

    final im3 = img.Image(width: 200, height: 200);
    img.fill(im3, color: img.ColorRgb8(0, 0, 255));
    photo3 = File('${tempDir.path}/photo3.jpg');
    await photo3.writeAsBytes(img.encodeJpg(im3));
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('CameraScanScreen Continuous In-Camera Capture Tests', () {
    testWidgets('Initial camera state shows Document Camera and Capture button', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: CameraScanScreen(
            cameras: [], // Forces fallback mode cleanly without physical camera
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Document Camera'), findsOneWidget);
      expect(find.text('Capture'), findsOneWidget);
      expect(find.byKey(const Key('camera_shutter_btn')), findsOneWidget);
      expect(find.byKey(const Key('camera_done_btn')), findsNothing);
      expect(find.byKey(const Key('camera_thumbnail_btn')), findsNothing);
    });

    testWidgets('Capturing photo updates to + Add Page and enables Done button', (tester) async {
      final mockPicker = _QueueImagePicker()..queuedPhotos.addAll([photo1.path, photo2.path]);

      await tester.pumpWidget(
        MaterialApp(
          home: CameraScanScreen(
            cameras: const [],
            imagePicker: mockPicker,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Capture Page 1
      await tester.tap(find.byKey(const Key('camera_shutter_btn')));
      await tester.pumpAndSettle();

      expect(find.text('1 Page Captured'), findsOneWidget);
      expect(find.text('+ Add Page'), findsOneWidget);
      expect(find.byKey(const Key('camera_add_page_btn')), findsOneWidget);
      expect(find.byKey(const Key('camera_done_btn')), findsOneWidget);
      expect(find.text('Done (1)'), findsOneWidget);
      expect(find.byKey(const Key('camera_thumbnail_btn')), findsOneWidget);

      // 2. Continuous capture: Tap + Add Page to capture Page 2 without leaving screen
      await tester.tap(find.byKey(const Key('camera_add_page_btn')));
      await tester.pumpAndSettle();

      expect(find.text('2 Pages Captured'), findsOneWidget);
      expect(find.text('+ Add Page'), findsOneWidget);
      expect(find.text('Done (2)'), findsOneWidget);
    });

    testWidgets('Thumbnail button opens bottom sheet with reorder and delete actions', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CameraScanScreen(
            cameras: const [],
            initialPages: [photo1.path, photo2.path],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 Pages Captured'), findsOneWidget);

      // Open review bottom sheet
      await tester.tap(find.byKey(const Key('camera_thumbnail_btn')));
      await tester.pumpAndSettle();

      expect(find.text('Captured Pages (2)'), findsOneWidget);
      expect(find.text('Page 1'), findsOneWidget);
      expect(find.text('Page 2'), findsOneWidget);
      expect(find.text('Back to Camera'), findsOneWidget);
      expect(find.text('OK / Done (2)'), findsOneWidget);

      // Close bottom sheet
      await tester.tap(find.text('Back to Camera'));
      await tester.pumpAndSettle();
      expect(find.text('Captured Pages (2)'), findsNothing);
    });

    testWidgets('Done button pops ordered list of captured photos', (tester) async {
      List<String>? resultPages;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                resultPages = await Navigator.of(ctx).push<List<String>>(
                  MaterialPageRoute(
                    builder: (_) => CameraScanScreen(
                      cameras: const [],
                      initialPages: [photo1.path, photo2.path, photo3.path],
                    ),
                  ),
                );
              },
              child: const Text('Open Camera'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Camera'));
      await tester.pumpAndSettle();

      expect(find.text('3 Pages Captured'), findsOneWidget);

      // Tap Done (3)
      await tester.tap(find.byKey(const Key('camera_done_btn')));
      await tester.pumpAndSettle();

      expect(resultPages, isNotNull);
      expect(resultPages!.length, 3);
      expect(resultPages![0], photo1.path);
      expect(resultPages![1], photo2.path);
      expect(resultPages![2], photo3.path);
    });

    testWidgets('Close button with captured pages prompts discard confirmation', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CameraScanScreen(
            cameras: const [],
            initialPages: [photo1.path],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Close
      await tester.tap(find.byKey(const Key('camera_close_btn')));
      await tester.pumpAndSettle();

      expect(find.text('Discard Scan Session?'), findsOneWidget);
      expect(find.text('Keep Scanning'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);

      // Tap Keep Scanning
      await tester.tap(find.text('Keep Scanning'));
      await tester.pumpAndSettle();
      expect(find.text('Discard Scan Session?'), findsNothing);
      expect(find.text('1 Page Captured'), findsOneWidget);
    });
  });

  group('End-to-End Multi-Photo Session to Single LR Item OCR Flow', () {
    test('Combining 3 photos in addMultiPageScan creates 1 multi-page PDF & 1 LR item', () async {
      final ctrl = BatchProcessingController(
        permissionService: _MockPermissionService(),
        imageService: _MockImageService(),
        ocrService: _FakeOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: GeminiBackendService(),
      );
      ctrl.setUseGeminiBackend(false);

      final success = await ctrl.addMultiPageScan([photo1.path, photo2.path, photo3.path]);
      expect(success, isTrue);

      // Exactly ONE LR document record created
      expect(ctrl.items.length, 1);
      final item = ctrl.items.first;

      // File is assembled into a PDF
      expect(item.imagePath.toLowerCase().endsWith('.pdf'), isTrue);
      expect(File(item.imagePath).existsSync(), isTrue);

      // Multi-page metadata populated
      expect(item.record['page_count'], '3');
      final decodedPreview = jsonDecode(item.record['preview_pages']!);
      expect(decodedPreview is List, isTrue);
      expect((decodedPreview as List).length, 3);
      expect(item.status, BatchItemStatus.completed);
    });
  });
}
