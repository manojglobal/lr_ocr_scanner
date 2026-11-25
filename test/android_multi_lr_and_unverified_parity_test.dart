import 'dart:async';
import 'dart:math' show Point;
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/models/extraction_result.dart';
import 'package:ocr_to_excel/services/app_config_service.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';
import 'package:ocr_to_excel/services/image_preprocessor.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/lr_multi_page_validator.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:image/image.dart' as img;
import 'package:ocr_to_excel/views/home_screen.dart';
import 'package:ocr_to_excel/views/screens/batch_queue_screen.dart';
import 'package:ocr_to_excel/views/widgets/lr_notice_dialogs.dart';
import 'package:ocr_to_excel/views/widgets/ocr_processing_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubPermissionService extends PermissionService {
  @override
  Future<bool> requestGalleryPermission() async => true;

  @override
  Future<bool> isGalleryPermanentlyDenied() async => false;
}

class _StubImageService extends ImageService {
  List<String> Function()? onPickMultipleImages;

  @override
  Future<List<String>> pickMultipleImages({int? imageQuality}) async {
    return onPickMultipleImages?.call() ?? const [];
  }
}

class _StubOcrService extends OcrService {
  RecognizedText? Function(String imagePath)? onRecognizeQuick;

  @override
  Future<RecognizedText?> recognizeTextQuick(String imagePath) async {
    return onRecognizeQuick?.call(imagePath);
  }

  @override
  Future<void> dispose() async {}
}

class _StubGeminiService extends GeminiBackendService {
  ExtractionResult Function(List<String> paths)? onExtractMultiple;
  ExtractionResult Function(String path)? onExtractSingle;
  List<Map<String, dynamic>> Function()? onGetPreviousUploads;
  int singleCalls = 0;
  int multiCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> getPreviousUploads({
    String? userId,
    String? userMobile,
    String? sessionToken,
  }) async {
    return onGetPreviousUploads?.call() ?? const [];
  }

  @override
  Future<ExtractionResult> extractMultipleFiles(
    List<String> filePaths, {
    String? customPrompt,
    String? userId,
    String? userMobile,
    String? userName,
    String? sessionToken,
  }) async {
    multiCalls++;
    if (onExtractMultiple != null) {
      return onExtractMultiple!(filePaths);
    }
    return ExtractionResult.failure(errorMessage: 'No stub configured');
  }

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
    singleCalls++;
    if (onExtractSingle != null) {
      return onExtractSingle!(imagePath);
    }
    return ExtractionResult.failure(errorMessage: 'No stub configured');
  }
}

class _LocalHttpOverrides extends HttpOverrides {
  final int statusCode;
  final Map<String, dynamic> payload;

  _LocalHttpOverrides(this.statusCode, this.payload);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _FakeHttpClient(statusCode, payload);
  }
}

class _FakeHttpClient implements HttpClient {
  final int statusCode;
  final Map<String, dynamic> payload;

  _FakeHttpClient(this.statusCode, this.payload);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return _FakeHttpClientRequest(url, statusCode, payload);
  }

  @override
  bool autoUncompress = true;

  @override
  Duration? connectionTimeout;

  @override
  Duration idleTimeout = const Duration(seconds: 15);
}

class _FakeHttpClientRequest implements HttpClientRequest {
  @override
  final Uri uri;
  final int statusCode;
  final Map<String, dynamic> payload;
  final _headers = _FakeHttpHeaders();

  _FakeHttpClientRequest(this.uri, this.statusCode, this.payload);

  @override
  HttpHeaders get headers => _headers;

  @override
  Encoding encoding = utf8;

  @override
  int contentLength = 0;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  bool persistentConnection = true;

  @override
  bool bufferOutput = true;

  @override
  void add(List<int> data) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.drain<void>();
  }

  @override
  Future<HttpClientResponse> close() async {
    return _FakeHttpClientResponse(statusCode, jsonEncode(payload));
  }

  @override
  Future<HttpClientResponse> get done async => close();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _map = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _map[name.toLowerCase()] = [value.toString()];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _map.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _map.forEach(action);
  }

  @override
  String? value(String name) => _map[name.toLowerCase()]?.firstOrNull;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  final int statusCode;
  final List<int> _bytes;
  final _headers = _FakeHttpHeaders();

  _FakeHttpClientResponse(this.statusCode, String body) : _bytes = utf8.encode(body);

  @override
  HttpHeaders get headers => _headers;

  @override
  int get contentLength => _bytes.length;

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => statusCode == 422 ? 'Unprocessable Entity' : 'OK';

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([_bytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File sampleFile1;
  late File sampleFile2;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'bnf_user_mobile': '9876543210',
      'bnf_user_name': 'Test Dispatcher',
    });
    AppConfigService.instance.resetForTesting();
    await AppConfigService.instance.updateBaseUrl('http://127.0.0.1:1', manual: true);
    tempDir = await Directory.systemTemp.createTemp('android_parity_');
    sampleFile1 = File('${tempDir.path}/lr_doc_one.jpg')
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);
    sampleFile2 = File('${tempDir.path}/lr_doc_two.jpg')
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7, 8]);
  });

  tearDown(() async {
    HttpOverrides.global = null;
    AppConfigService.instance.resetForTesting();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Requirement 1: Multiple LRs Error Message & Pop-up Parity', () {
    test('GeminiBackendService preserves MULTIPLE_LRS error_code and server message on 422 and 200', () async {
      const serverMsg = 'Multiple LRs detected (LR 101 and LR 102). Upload one LR at a time.';
      HttpOverrides.global = _LocalHttpOverrides(422, {
        'success': false,
        'error_code': 'MULTIPLE_LRS',
        'title': 'Multiple LRs Not Allowed',
        'message': serverMsg,
        'detail': serverMsg,
      });

      final service = GeminiBackendService();
      final singleRes = await service.extractHandwriting(sampleFile1.path);
      expect(singleRes.isMultipleLrs, isTrue);
      expect(singleRes.errorCode, 'MULTIPLE_LRS');
      expect(singleRes.message, serverMsg);

      final multiRes = await service.extractMultipleFiles([sampleFile1.path, sampleFile2.path]);
      expect(multiRes.isMultipleLrs, isTrue);
      expect(multiRes.errorCode, 'MULTIPLE_LRS');
      expect(multiRes.message, serverMsg);

      // Also verify HTTP 200 payload with success: false & error_code: MULTIPLE_LRS
      HttpOverrides.global = _LocalHttpOverrides(200, {
        'success': false,
        'error_code': 'MULTIPLE_LRS',
        'message': serverMsg,
      });
      final ok200Multi = await service.extractMultipleFiles([sampleFile1.path, sampleFile2.path]);
      expect(ok200Multi.isMultipleLrs, isTrue);
      expect(ok200Multi.errorCode, 'MULTIPLE_LRS');
      expect(ok200Multi.message, serverMsg);
    });

    test('Multi-file upload still sends to server and triggers MULTIPLE_LRS even if one file matches a prior upload', () async {
      final gemini = _StubGeminiService();
      gemini.onExtractMultiple = (_) => ExtractionResult.failure(
            errorCode: 'MULTIPLE_LRS',
            errorMessage: 'Multiple LR documents detected. Please upload documents belonging to only one LR at a time.',
          );

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: gemini,
        useGeminiBackend: true,
      );

      // Seed prior verified LR matching sampleFile1 so pre-OCR duplicate would have blocked if present
      ctrl.addItemDirectly(
        BatchItem(
          id: 'verified-1',
          imagePath: sampleFile1.path,
          fileName: 'lr_doc_one.jpg',
          status: BatchItemStatus.completed,
          createdAt: DateTime.now(),
          imageHash: ctrl.computeImageHash(sampleFile1.path),
          record: {'LR No *': 'LR-100', 'is_verified': 'true'},
        ),
      );

      final ok = await ctrl.addMultipleFilesAsSingleLr([sampleFile1.path, sampleFile2.path]);
      expect(ok, isFalse);
      expect(gemini.multiCalls, 1);
      expect(ctrl.multipleLrsNoticePending, isTrue);
      expect(ctrl.duplicateNoticePending, isFalse);
      expect(ctrl.isProcessingMultiPage, isFalse);
    });

    test('addMultiPageScan handles MULTIPLE_LRS rejection and resets multi-page state', () async {
      final gemini = _StubGeminiService();
      gemini.onExtractSingle = (_) => ExtractionResult.failure(
            errorCode: 'MULTIPLE_LRS',
            errorMessage: 'Multiple LR numbers detected in multi-page scan (LR-101, LR-102).',
          );

      final page1 = File('${tempDir.path}/scan_p1.jpg')
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 24, height: 24)));
      final page2 = File('${tempDir.path}/scan_p2.jpg')
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 24, height: 24)));

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: gemini,
        useGeminiBackend: true,
      );

      final ok = await ctrl.addMultiPageScan([page1.path, page2.path]);
      expect(ok, isFalse);
      expect(gemini.singleCalls, 1);
      expect(ctrl.multipleLrsNoticePending, isTrue);
      expect(ctrl.multipleLrsNoticeMessage, contains('LR-101'));
      expect(ctrl.items, isEmpty);
      expect(ctrl.isProcessingMultiPage, isFalse);
    });

    testWidgets('OcrProcessingDialog route closes safely without popping Multiple LRs Not Allowed dialog', (tester) async {
      final ctrl = BatchProcessingController(useGeminiBackend: false);
      late BuildContext hostContext;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                hostContext = ctx;
                return const Text('HostScreen');
              },
            ),
          ),
        ),
      );

      // Simulate OCR run that triggers multiple LRs notice while OCR dialog is open.
      // Use a Completer + explicit pump frames because OcrProcessingDialog has a repeating animation.
      final gate = Completer<bool>();
      final future = runWithOcrProcessingRoute<bool>(
        context: hostContext,
        controller: ctrl,
        action: () => gate.future,
      );
      await tester.pump();
      expect(find.byType(OcrProcessingDialog), findsOneWidget);
      expect(find.text('HostScreen'), findsOneWidget);

      ctrl.triggerMultipleLrsNotice('Multiple LR documents detected (LR 1 & LR 2).');
      gate.complete(false);

      final result = await future;
      expect(result, isFalse);
      await tester.pump();
      expect(find.byType(OcrProcessingDialog), findsNothing);

      // Now display popup cleanly via shared dialog helper (as _drainPendingNotices does)
      if (ctrl.multipleLrsNoticePending) {
        final msg = ctrl.multipleLrsNoticeMessage;
        ctrl.acknowledgeMultipleLrsNotice();
        // ignore: use_build_context_synchronously
        unawaited(showMultipleLrsNotAllowedDialog(hostContext, message: msg));
      }
      await tester.pumpAndSettle();

      expect(find.text('Multiple LRs Not Allowed'), findsOneWidget);
      expect(find.text('Document Validation'), findsOneWidget);
      expect(find.text('Multiple LR documents detected (LR 1 & LR 2).'), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.text('Multiple LRs Not Allowed'), findsNothing);
      expect(find.text('HostScreen'), findsOneWidget);

      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();
    });

    testWidgets('BatchQueueScreen stays open and shows Multiple LRs Not Allowed dialog on triggerMultipleLrsNotice', (tester) async {
      final ctrl = BatchProcessingController(useGeminiBackend: false);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () {
                  Navigator.of(ctx).push(
                    MaterialPageRoute(
                      builder: (_) => BatchQueueScreen(controller: ctrl),
                    ),
                  );
                },
                child: const Text('GoQueue'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('GoQueue'));
      await tester.pumpAndSettle();
      expect(find.byType(BatchQueueScreen), findsOneWidget);

      ctrl.triggerMultipleLrsNotice();
      await tester.pumpAndSettle();

      expect(find.text('Multiple LRs Not Allowed'), findsOneWidget);
      expect(find.text('Document Validation'), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.text('Multiple LRs Not Allowed'), findsNothing);
      expect(find.byType(BatchQueueScreen), findsOneWidget);

      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();
    });

    test('addMultiPageScan PDF assembly fallback forwards all pages to extractMultipleFiles and triggers MULTIPLE_LRS', () async {
      final gemini = _StubGeminiService();
      List<String>? capturedPaths;
      gemini.onExtractMultiple = (paths) {
        capturedPaths = List<String>.from(paths);
        return ExtractionResult.failure(
          errorCode: 'MULTIPLE_LRS',
          errorMessage: 'Multiple LR numbers detected in multi-page scan (LR-501, LR-502).',
        );
      };

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: gemini,
        useGeminiBackend: true,
      );

      // sampleFile1/sampleFile2 contain raw header bytes so PDF assembly throws
      // and exercises the multi-file fallback branch.
      final ok = await ctrl.addMultiPageScan([sampleFile1.path, sampleFile2.path]);
      expect(ok, isFalse);
      expect(gemini.multiCalls, 1);
      expect(gemini.singleCalls, 0);
      expect(capturedPaths, isNotNull);
      expect(capturedPaths!.length, 2);
      expect(ctrl.multipleLrsNoticePending, isTrue);
      expect(ctrl.multipleLrsNoticeMessage, contains('LR-501'));
      expect(ctrl.items, isEmpty);
      expect(ctrl.isProcessingMultiPage, isFalse);
    });

    test('addFromGallery multi-image selection with matching basenames keeps distinct files and triggers MULTIPLE_LRS', () async {
      final dirA = await Directory('${tempDir.path}/a').create(recursive: true);
      final dirB = await Directory('${tempDir.path}/b').create(recursive: true);
      final fileA = File('${dirA.path}/lr_doc.jpg')..writeAsBytesSync([1, 2, 3, 4]);
      final fileB = File('${dirB.path}/lr_doc.jpg')..writeAsBytesSync([9, 8, 7, 6]);

      final imageService = _StubImageService()
        ..onPickMultipleImages = () => [fileA.path, fileB.path];

      final gemini = _StubGeminiService();
      List<String>? capturedPaths;
      List<List<int>> capturedBytes = [];
      gemini.onExtractMultiple = (paths) {
        capturedPaths = List<String>.from(paths);
        capturedBytes = paths.map((p) => File(p).readAsBytesSync()).toList();
        return ExtractionResult.failure(
          errorCode: 'MULTIPLE_LRS',
          errorMessage: 'Multiple LRs in gallery images.',
        );
      };

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: imageService,
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: gemini,
        useGeminiBackend: true,
      );

      final added = await ctrl.addFromGallery();
      expect(added, isFalse);
      expect(gemini.multiCalls, 1);
      expect(capturedPaths, isNotNull);
      expect(capturedPaths!.length, 2);
      expect(capturedPaths![0], isNot(equals(capturedPaths![1])));
      expect(capturedBytes, equals([[1, 2, 3, 4], [9, 8, 7, 6]]));
      expect(ctrl.multipleLrsNoticePending, isTrue);
      expect(ctrl.multipleLrsNoticeMessage, 'Multiple LRs in gallery images.');
    });

    testWidgets('Stacked HomeScreen underneath does not steal MULTIPLE_LRS notice from active BatchQueueScreen', (tester) async {
      final gemini = _StubGeminiService()..onGetPreviousUploads = () => const [];
      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: gemini,
        useGeminiBackend: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: ctrl),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final homeContext = tester.element(find.byType(HomeScreen));
      unawaited(
        Navigator.of(homeContext).push(
          MaterialPageRoute(
            builder: (_) => BatchQueueScreen(controller: ctrl),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BatchQueueScreen), findsOneWidget);

      ctrl.triggerMultipleLrsNotice('Multiple LR numbers on stacked route.');
      await tester.pumpAndSettle();

      expect(find.text('Multiple LRs Not Allowed'), findsOneWidget);
      expect(find.text('Multiple LR numbers on stacked route.'), findsOneWidget);
      expect(ctrl.multipleLrsNoticePending, isFalse);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Multiple LRs Not Allowed'), findsNothing);

      Navigator.of(tester.element(find.byType(BatchQueueScreen))).pop();
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('Multiple LRs Not Allowed'), findsNothing);

      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();
    });

    testWidgets('HomeScreen Select Image -> Photos from Gallery multi-select triggers MULTIPLE_LRS popup cleanly', (tester) async {
      final imageService = _StubImageService()
        ..onPickMultipleImages = () => [sampleFile1.path, sampleFile2.path];
      final gemini = _StubGeminiService()
        ..onGetPreviousUploads = (() => const [])
        ..onExtractMultiple = ((_) => ExtractionResult.failure(
              errorCode: 'MULTIPLE_LRS',
              errorMessage: 'Two different LRs detected in selected gallery photos.',
            ));

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: imageService,
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: gemini,
        useGeminiBackend: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: ctrl),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final selectBtn = find.text('Select Image');
      await tester.ensureVisible(selectBtn);
      await tester.tap(selectBtn);
      await tester.pumpAndSettle();

      expect(find.text('Select LR Files'), findsOneWidget);
      expect(find.text('Photos from Gallery'), findsOneWidget);

      await tester.tap(find.text('Photos from Gallery'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Select LR Files'), findsNothing);

      for (int i = 0; i < 6 && gemini.multiCalls == 0; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(gemini.multiCalls, 1);
      expect(find.byType(OcrProcessingDialog), findsNothing);
      expect(find.text('Multiple LRs Not Allowed'), findsOneWidget);
      expect(find.text('Document Validation'), findsOneWidget);
      expect(find.text('Two different LRs detected in selected gallery photos.'), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();
      expect(find.text('Multiple LRs Not Allowed'), findsNothing);
    });

    test('LrMultiPageValidator rejects sideways multi-LR BNF photos and ignores margin/invoice/seal/date noise', () async {
      TextLine makeLine(String text, double left, double top, {bool rotatedDownward = false}) {
        final corners = rotatedDownward
            ? [
                Point<int>(left.round(), top.round()),
                Point<int>(left.round(), (top + 100).round()),
                Point<int>((left - 24).round(), (top + 100).round()),
                Point<int>((left - 24).round(), top.round()),
              ]
            : [
                Point<int>(left.round(), top.round()),
                Point<int>((left + 120).round(), top.round()),
                Point<int>((left + 120).round(), (top + 22).round()),
                Point<int>(left.round(), (top + 22).round()),
              ];
        return TextLine(
          text: text,
          elements: const [],
          boundingBox: Rect.fromLTWH(
            left,
            top,
            rotatedDownward ? 22 : 120,
            rotatedDownward ? 120 : 22,
          ),
          recognizedLanguages: const ['en'],
          cornerPoints: corners,
          confidence: 0.95,
          angle: rotatedDownward ? 90.0 : 0.0,
        );
      }

      RecognizedText makeBlockDoc(List<TextLine> lines) {
        final fullText = lines.map((l) => l.text).join('\n');
        return RecognizedText(
          text: fullText,
          blocks: [
            TextBlock(
              text: fullText,
              lines: lines,
              boundingBox: const Rect.fromLTWH(0, 0, 1000, 1000),
              recognizedLanguages: const ['en'],
              cornerPoints: const [Point(0, 0), Point(1000, 0), Point(1000, 1000), Point(0, 1000)],
            ),
          ],
        );
      }

      // Page 1 (sideways 90 deg downward): BNF Driver Copy 32915 + margin pen note 187596 + Seal 010201 + Invoice/EWB
      final doc1 = makeBlockDoc([
        makeLine('187596 - BLR', 850, 20, rotatedDownward: true),
        makeLine('ISO No.: 9001:2015 BOX N FREIGHT LOGISTICS SOLUTIONS PVT. LTD.', 800, 40, rotatedDownward: true),
        makeLine('Mumbai - 400 063 Seal no: 010201', 760, 40, rotatedDownward: true),
        makeLine('DRIVER COPY Tempo/Truck No. HR37B1019', 720, 40, rotatedDownward: true),
        makeLine('CONSIGNMENT NOTE :', 650, 620, rotatedDownward: true),
        makeLine('No.', 620, 620, rotatedDownward: true),
        makeLine('32915', 590, 620, rotatedDownward: true),
        makeLine('18/08/2026', 590, 740, rotatedDownward: true),
        makeLine('Invoice No. 5526701406 E-way Bill No. 1325242947', 400, 100, rotatedDownward: true),
      ]);

      // Page 2 (sideways 90 deg downward): BNF Consignee Copy 30399
      final doc2 = makeBlockDoc([
        makeLine('BOX N FREIGHT LOGISTICS SOLUTIONS PVT. LTD.', 800, 40, rotatedDownward: true),
        makeLine('CONSIGNEE COPY Tempo/Truck No. HR46E4028', 720, 40, rotatedDownward: true),
        makeLine('CONSIGNMENT NOTE :', 650, 620, rotatedDownward: true),
        makeLine('No.', 620, 620, rotatedDownward: true),
        makeLine('30399', 590, 620, rotatedDownward: true),
        makeLine('06/08/2026', 590, 740, rotatedDownward: true),
      ]);

      expect(LrMultiPageValidator.detectClockwiseRotationDegrees(doc1), 270);
      final a1 = LrMultiPageValidator.analyzeRecognizedText(doc1);
      final a2 = LrMultiPageValidator.analyzeRecognizedText(doc2);
      expect(a1.isPrimaryConsignmentNote, isTrue);
      expect(a1.normalizedLrNumbers, equals({'32915'}));
      expect(a2.isPrimaryConsignmentNote, isTrue);
      expect(a2.normalizedLrNumbers, equals({'30399'}));

      final rejectOutcome = LrMultiPageValidator.evaluatePageAnalyses([a1, a2]);
      expect(rejectOutcome.hasMultipleLrs, isTrue);
      expect(rejectOutcome.detectedLrNumbers, equals(['32915', '30399']));
      expect(rejectOutcome.message, contains('32915'));
      expect(rejectOutcome.message, contains('30399'));

      // Supporting Invoice + E-Way Bill + Driving Licence + same LR must NOT false-trigger MULTIPLE_LRS
      final invoiceDoc = LrMultiPageValidator.analyzePlainText(
        'COMMERCIAL TAX INVOICE\nInvoice No: 5526701406\nTransporter LR No: 32915\nCGST 9% SGST 9%',
      );
      final dlDoc = LrMultiPageValidator.analyzePlainText(
        'INDIAN UNION DRIVING LICENCE\nDL No: UP24 20170011207\nValidity(TR): 02-02-2027',
      );
      final ewbDoc = LrMultiPageValidator.analyzePlainText(
        'FORM GST EWB-01\nE-Way Bill No: 1325242947',
      );
      expect(invoiceDoc.isPrimaryConsignmentNote, isFalse);
      expect(dlDoc.isPrimaryConsignmentNote, isFalse);
      expect(ewbDoc.isPrimaryConsignmentNote, isFalse);

      final singleOutcome = LrMultiPageValidator.evaluatePageAnalyses([a1, invoiceDoc, dlDoc, ewbDoc]);
      expect(singleOutcome.hasMultipleLrs, isFalse);

      // Verify upright rotation produces expected 20x40 swapped dimensions from 40x20 sideways JPEG
      final sidewaysImg = File('${tempDir.path}/sideways_lr.jpg')
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 40, height: 20)));
      final rotatedPath = await ImagePreprocessor.orientImageUprightIfNeeded(sidewaysImg.path, 270);
      expect(rotatedPath, isNot(equals(sidewaysImg.path)));
      expect(rotatedPath, endsWith('sideways_lr.jpg'));
      final decodedRotated = img.decodeJpg(File(rotatedPath).readAsBytesSync());
      expect(decodedRotated, isNotNull);
      expect(decodedRotated!.width, 20);
      expect(decodedRotated.height, 40);
    });

    test('BatchProcessingController on-device multi-LR audit blocks multi-LR gallery upload even without server failure', () async {
      final ocr = _StubOcrService()
        ..onRecognizeQuick = (path) {
          final isFirst = path.contains('lr_doc_one');
          final lr = isFirst ? '32915' : '30399';
          final text = 'BOX N FREIGHT LOGISTICS SOLUTIONS PVT. LTD.\nCONSIGNMENT NOTE :\nNo.\n$lr\n18/08/2026';
          return RecognizedText(
            text: text,
            blocks: [
              TextBlock(
                text: text,
                lines: [
                  TextLine(
                    text: 'CONSIGNMENT NOTE :',
                    elements: const [],
                    boundingBox: const Rect.fromLTWH(50, 50, 180, 20),
                    recognizedLanguages: const ['en'],
                    cornerPoints: const [Point(50, 50), Point(230, 50), Point(230, 70), Point(50, 70)],
                    confidence: 0.9,
                    angle: 0.0,
                  ),
                  TextLine(
                    text: lr,
                    elements: const [],
                    boundingBox: const Rect.fromLTWH(50, 80, 90, 22),
                    recognizedLanguages: const ['en'],
                    cornerPoints: const [Point(50, 80), Point(140, 80), Point(140, 102), Point(50, 102)],
                    confidence: 0.95,
                    angle: 0.0,
                  ),
                ],
                boundingBox: const Rect.fromLTWH(50, 50, 200, 60),
                recognizedLanguages: const ['en'],
                cornerPoints: const [Point(50, 50), Point(250, 50), Point(250, 110), Point(50, 110)],
              ),
            ],
          );
        };

      // Even if server stub returns HTTP 200 single LR, on-device audit must block it upfront
      final gemini = _StubGeminiService()
        ..onExtractMultiple = ((_) => ExtractionResult.success(
              data: {'LR No *': '32915'},
              missingFields: const [],
              rawText: 'LR 32915',
            ));

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: ocr,
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: gemini,
        useGeminiBackend: true,
      );

      final ok = await ctrl.addMultipleFilesAsSingleLr([sampleFile1.path, sampleFile2.path]);
      expect(ok, isFalse);
      expect(gemini.multiCalls, 0);
      expect(ctrl.multipleLrsNoticePending, isTrue);
      expect(ctrl.multipleLrsNoticeMessage, contains('32915'));
      expect(ctrl.multipleLrsNoticeMessage, contains('30399'));
      expect(ctrl.items, isEmpty);
      expect(ctrl.isProcessingMultiPage, isFalse);
    });
  });

  group('Requirement 2: Unverified LR Re-upload Allowed (Web Parity)', () {
    test('Re-uploading unverified or cancelled LR succeeds without Duplicate LR error and replaces stale unverified item', () async {
      final gemini = _StubGeminiService();
      gemini.onExtractSingle = (_) => ExtractionResult.success(
            data: {
              'LR No *': '445566',
              'grno (*)': '445566',
              'Customer Name *': 'Patanjali Foods Ltd',
            },
            missingFields: const ['Driver Name *'],
            rawText: 'LR No 445566',
          );

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: gemini,
        useGeminiBackend: true,
      );

      // 1. Upload first time (remains unverified because mandatory fields are missing & pending_verification=true)
      final firstOk = await ctrl.addFilePaths([sampleFile1.path]);
      expect(firstOk, isTrue);
      expect(ctrl.items.length, 1);
      expect(ctrl.items.first.isVerified, isFalse);
      final firstId = ctrl.items.first.id;

      // 2. Simulate Step 2 Cancel Verification flags
      final cancelledRec = Map<String, String>.from(ctrl.items.first.record);
      cancelledRec['is_cancelled'] = 'true';
      cancelledRec['pending_verification'] = 'true';
      ctrl.updateItem(ctrl.items.first.copyWith(record: cancelledRec));

      // 3. Re-upload the exact same file & LR No -> must succeed with NO Duplicate LR notice!
      final reuploadOk = await ctrl.addFilePaths([sampleFile1.path]);
      expect(reuploadOk, isTrue);
      expect(ctrl.duplicateNoticePending, isFalse);
      expect(ctrl.items.length, 1);
      expect(ctrl.items.first.id, isNot(firstId));
      expect(ctrl.lastUploadedItem?.id, ctrl.items.first.id);

      // 4. Re-upload same LR number via a DIFFERENT file -> still allowed while unverified
      final reuploadDiffFileOk = await ctrl.addFilePaths([sampleFile2.path]);
      expect(reuploadDiffFileOk, isTrue);
      expect(ctrl.duplicateNoticePending, isFalse);
      expect(ctrl.items.length, 1);
    });

    test('Server previous uploads & Web cloud docs lacking verification never cause false Duplicate LR', () {
      final ctrl = BatchProcessingController(useGeminiBackend: false);

      // Case A: Server /api/previous-uploads payload with partial data & status completed (no isVerified: true)
      ctrl.setPreviousUploadsCache([
        {
          'id': 'srv-unv-1',
          'fileName': 'unverified_server.pdf',
          'saved_filename': 'srv_unv_1.pdf',
          'lrNo': '778899',
          'status': 'completed',
          'data': {
            'LR No *': '778899',
            'Customer Name *': 'Test Customer',
          },
        },
        {
          'id': 'srv-ver-1',
          'fileName': 'verified_server.pdf',
          'saved_filename': 'srv_ver_1.pdf',
          'lrNo': '112233',
          'status': 'completed',
          'isVerified': true,
          'data': {
            'LR No *': '112233',
          },
        },
      ]);

      expect(
        ctrl.isDuplicate(lrNo: '778899', fileName: 'unverified_server.pdf'),
        isFalse,
        reason: 'Unverified /api/previous-uploads item must not trigger Duplicate LR',
      );
      expect(
        ctrl.isDuplicate(lrNo: '112233'),
        isTrue,
        reason: 'Explicitly verified cache entry must still block duplicates',
      );

      // Case B: Web cloud doc with top-level pending_verification / is_cancelled
      final webCancelledItem = BatchItem.fromCloudDoc({
        'id': 'web-cancel-1',
        'filename': 'web_doc.jpg',
        'pending_verification': true,
        'is_cancelled': true,
        'data': {
          'LR No *': '990011',
        },
      });
      expect(webCancelledItem.isVerified, isFalse);
      ctrl.addItemDirectly(webCancelledItem);
      expect(ctrl.isDuplicate(lrNo: '990011', fileName: 'web_doc.jpg'), isFalse);

      // Case C: Placeholder LR No '0' does not block other '0' uploads even when verified
      ctrl.addItemDirectly(
        BatchItem(
          id: 'ver-zero',
          imagePath: '/tmp/zero.jpg',
          fileName: 'zero.jpg',
          status: BatchItemStatus.completed,
          createdAt: DateTime.now(),
          record: {'LR No *': '0', 'is_verified': 'true'},
        ),
      );
      expect(ctrl.isDuplicate(lrNo: '0'), isFalse);
    });

    test('Re-uploading unverified multi-page scan succeeds and verified duplicate blocks', () async {
      final gemini = _StubGeminiService();
      gemini.onExtractSingle = (_) => ExtractionResult.success(
            data: {
              'LR No *': 'MP-774411',
              'Customer Name *': 'Test Logistics',
            },
            missingFields: const ['Driver Name *'],
            rawText: 'LR No MP-774411',
          );

      final page1 = File('${tempDir.path}/mp_p1.jpg')
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 24, height: 24)));
      final page2 = File('${tempDir.path}/mp_p2.jpg')
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 24, height: 24)));

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: gemini,
        useGeminiBackend: true,
      );

      final firstAdd = await ctrl.addMultiPageScan([page1.path, page2.path]);
      expect(firstAdd, isTrue);
      expect(ctrl.items.length, 1);
      expect(ctrl.items.first.isVerified, isFalse);

      // Re-uploading while unverified must succeed without Duplicate LR error
      final reuploadAdd = await ctrl.addMultiPageScan([page1.path, page2.path]);
      expect(reuploadAdd, isTrue);
      expect(ctrl.duplicateNoticePending, isFalse);
      expect(ctrl.items.length, 1);

      // Verify item now
      final verifiedRec = Map<String, String>.from(ctrl.items.first.record);
      verifiedRec['is_verified'] = 'true';
      verifiedRec.remove('pending_verification');
      ctrl.updateItem(ctrl.items.first.copyWith(record: verifiedRec));
      expect(ctrl.items.first.isVerified, isTrue);

      // Now duplicate must be blocked
      final dupAdd = await ctrl.addMultiPageScan([page1.path, page2.path]);
      expect(dupAdd, isFalse);
      expect(ctrl.duplicateNoticePending, isTrue);
      expect(ctrl.items.length, 1);
    });

    testWidgets('HomeScreen _syncLoadedUploads does not falsely mark status=completed server uploads as verified', (tester) async {
      SharedPreferences.setMockInitialValues({
        'bnf_user_mobile': '9876543210',
        'bnf_user_name': 'Tester',
        'bnf_recent_uploaded_lrs_9876543210': jsonEncode([
          {
            'id': 'srv-rec-1',
            'fileName': 'unverified_history.jpg',
            'saved_filename': 'srv_unverified_history.jpg',
            'lrNo': '654321',
            'status': 'completed',
            'isVerified': false,
            'record': {
              'LR No *': '654321',
              'Customer Name *': 'Himalaya',
            },
          },
        ]),
      });

      final gemini = _StubGeminiService();
      gemini.onGetPreviousUploads = () => [
            {
              'id': 'srv-rec-1',
              'filename': 'unverified_history.jpg',
              'saved_filename': 'srv_unverified_history.jpg',
              'lr_no': '654321',
              'status': 'completed',
              'data': {
                'LR No *': '654321',
                'Customer Name *': 'Himalaya',
              },
            },
          ];

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: ExcelService(),
        geminiService: gemini,
        useGeminiBackend: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: ctrl),
        ),
      );
      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();

      // Must show Unverified badge (not promoted to Verified) and must NOT trigger Duplicate LR
      expect(find.text('Unverified'), findsOneWidget);
      expect(find.text('Verified'), findsNothing);
      expect(ctrl.isDuplicate(lrNo: '654321', fileName: 'unverified_history.jpg'), isFalse);
    });
  });
}
