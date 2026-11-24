import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/models/extraction_result.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/master_data_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/screens/batch_queue_screen.dart';
import 'package:ocr_to_excel/views/screens/customization_driver_screen.dart';
import 'package:ocr_to_excel/views/screens/excel_generated_screen.dart';

class _StubPermissionService extends PermissionService {}

class _StubImageService extends ImageService {}

class _StubOcrService extends OcrService {
  @override
  Future<void> dispose() async {}
}

class _StubExcelService extends ExcelService {
  @override
  Future<File> saveBytesToFile(List<int> bytes, {String? customFileName}) async {
    return File('/dummy/local/${customFileName ?? 'BNF_Export.xlsx'}');
  }

  @override
  Future<String?> saveFileToDownloads(
    String sourceFilePath, {
    String? targetFileName,
  }) async {
    return '/dummy/downloads/${targetFileName ?? 'BNF_Export.xlsx'}';
  }
}

class _MockGeminiService extends GeminiBackendService {
  bool failPreviousDelete = false;
  bool failPreviousClearAll = false;
  final List<String> deletedPreviousTargets = [];
  int clearAllPreviousCalls = 0;

  bool exportCalled = false;
  List<Map<String, dynamic>> lastExportDocs = [];
  String? mockExportId = 'exp_abcd1234';

  ExtractionResult nextMultiFileResult = ExtractionResult.success(
    data: {
      'grno (*)': 'LR-MULTI-777',
      'LR No *': 'LR-MULTI-777',
      'Customer Name *': 'HIMALAYA WELLNESS COMPANY',
      'saved_filename': 'multi_dossier_777.pdf',
      'page_count': '2',
    },
    missingFields: const [],
    rawText: 'HIMALAYA LR-MULTI-777',
  );

  @override
  Future<ExtractionResult> extractMultipleFiles(
    List<String> filePaths, {
    String? customPrompt,
    String? userId,
    String? userMobile,
    String? userName,
    String? sessionToken,
  }) async {
    return nextMultiFileResult;
  }

  @override
  Future<bool> deletePreviousUpload(
    String fileIdOrName, {
    String? userId,
    String? userMobile,
    String? userName,
    String? sessionToken,
  }) async {
    deletedPreviousTargets.add(fileIdOrName);
    return !failPreviousDelete;
  }

  @override
  Future<bool> clearAllPreviousUploads({
    String? userId,
    String? userMobile,
    String? userName,
    String? sessionToken,
  }) async {
    clearAllPreviousCalls++;
    return !failPreviousClearAll;
  }

  @override
  Future<Map<String, dynamic>> exportExcelWithSnapshot({
    required List<Map<String, dynamic>> documents,
    String formatType = 'gr_bnf_49',
    String? userName,
    String? userMobile,
    String? sessionToken,
  }) async {
    exportCalled = true;
    lastExportDocs = documents;
    return {
      'success': true,
      if (mockExportId != null) 'export_id': mockExportId,
      'filename': 'BNF_Parity_Export.xlsx',
      'download_url': '/downloads/BNF_Parity_Export.xlsx',
      'exported_by': userName ?? 'Test User',
      'user_name': userName ?? 'Test User',
      'user_mobile': userMobile ?? '9876543210',
      'total_lrs': documents.length,
    };
  }

  @override
  Future<List<int>?> downloadExportedFile(String downloadUrl) async {
    return [0x50, 0x4B, 0x03, 0x04];
  }
}

class _RecordedHttpCall {
  final String method;
  final Uri uri;
  final Map<String, dynamic>? jsonBody;

  _RecordedHttpCall(this.method, this.uri, this.jsonBody);
}

class _MockHttpOverrides extends HttpOverrides {
  final FutureOr<Map<String, dynamic>> Function(
    String method,
    Uri uri,
    Map<String, dynamic>? body,
  ) handler;
  final List<_RecordedHttpCall> calls = [];

  _MockHttpOverrides(this.handler);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _FakeHttpClient(handler, calls);
  }
}

class _FakeHttpClient implements HttpClient {
  final FutureOr<Map<String, dynamic>> Function(
    String method,
    Uri uri,
    Map<String, dynamic>? body,
  ) handler;
  final List<_RecordedHttpCall> calls;

  _FakeHttpClient(this.handler, this.calls);

  @override
  bool autoUncompress = true;

  @override
  Duration? connectionTimeout;

  @override
  Duration idleTimeout = const Duration(seconds: 15);

  @override
  int? maxConnectionsPerHost;

  @override
  String? userAgent;

  Future<HttpClientRequest> _open(String method, Uri url) async {
    return _FakeHttpClientRequest(method, url, handler, calls);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _open('GET', url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _open('POST', url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => _open(method, url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientRequest implements HttpClientRequest {
  @override
  final String method;
  @override
  final Uri uri;
  final FutureOr<Map<String, dynamic>> Function(
    String method,
    Uri uri,
    Map<String, dynamic>? body,
  ) handler;
  final List<_RecordedHttpCall> calls;
  final List<int> _bytes = [];

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  Encoding encoding = utf8;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  bool persistentConnection = true;

  @override
  bool bufferOutput = true;

  @override
  int contentLength = -1;

  _FakeHttpClientRequest(this.method, this.uri, this.handler, this.calls);

  @override
  void add(List<int> data) => _bytes.addAll(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _bytes.addAll(chunk);
    }
  }

  @override
  Future<HttpClientResponse> close() async {
    Map<String, dynamic>? decoded;
    if (_bytes.isNotEmpty) {
      try {
        final raw = utf8.decode(_bytes);
        final parsed = jsonDecode(raw);
        if (parsed is Map) {
          decoded = Map<String, dynamic>.from(parsed);
        }
      } catch (_) {}
    }
    calls.add(_RecordedHttpCall(method, uri, decoded));
    final result = await handler(method, uri, decoded);
    final statusCode = (result['_status'] as int?) ?? 200;
    final clean = Map<String, dynamic>.from(result)..remove('_status');
    final bodyBytes = utf8.encode(jsonEncode(clean));
    return _FakeHttpClientResponse(statusCode, bodyBytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  final int statusCode;
  final List<int> _bodyBytes;

  _FakeHttpClientResponse(this.statusCode, this._bodyBytes);

  @override
  int get contentLength => _bodyBytes.length;

  @override
  HttpHeaders get headers => _FakeHttpHeaders();

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => statusCode == 200 ? 'OK' : 'Error';

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  X509Certificate? get certificate => null;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  List<Cookie> get cookies => const [];

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) async =>
      this;

  @override
  Future<Socket> detachSocket() async => throw UnimplementedError();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(_bodyBytes).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

BatchItem _makeVerifiedItem({
  required String id,
  required String lrNo,
  String freight = '1800',
  DateTime? exportedAt,
  DateTime? editedAt,
}) {
  final rec = <String, String>{};
  for (final k in BatchItem.mandatoryKeys) {
    rec[k] = 'VAL-$k';
  }
  rec['grno (*)'] = lrNo;
  rec['LR No *'] = lrNo;
  rec['grno'] = lrNo;
  rec['grdt *'] = '24/11/2026';
  rec['Customer Name *'] = 'HIMALAYA WELLNESS COMPANY';
  rec['Vehicle No *'] = 'KA01AB1234';
  rec['Vehicle Type *'] = 'MARKET';
  rec['cngr *'] = 'HIMALAYA WELLNESS';
  rec['cngrgstno *'] = '29AAACH2707F1Z2';
  rec['cnge *'] = 'ACME DISTRIBUTOR';
  rec['cngegstno *'] = '27AAACZ1234F1Z5';
  rec['Driver Name *'] = 'RAVI KUMAR';
  rec['Mobile no   *'] = '9876543210';
  rec['Liscense No *'] = 'KA0120201234567';
  rec['Valid Up to *'] = '31/12/2030';
  rec['freight  *'] = freight;
  rec['freight'] = freight;
  rec['Counter'] = 'MUMBAI 01';
  rec['Vehicle Category'] = 'Market';
  rec['is_verified'] = 'true';
  if (exportedAt != null) {
    rec['is_exported'] = 'true';
    rec['exported_at'] = exportedAt.toIso8601String();
  }

  return BatchItem(
    id: id,
    imagePath: '/docs/$id.pdf',
    fileName: '$lrNo.pdf',
    status: BatchItemStatus.completed,
    createdAt: DateTime(2026, 11, 24, 10),
    editedAt: editedAt,
    exportedAt: exportedAt,
    record: rec,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    HttpOverrides.global = null;
  });

  group('Req 1 & 6: Export State Tracking, Re-Export Protection & ExcelGeneratedScreen', () {
    test('Export status persists across restart and resets when edited LR is saved', () async {
      SharedPreferences.setMockInitialValues({
        'bnf_user_mobile': '9876500001',
        'bnf_user_name': 'Persist User',
      });

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: _StubExcelService(),
        geminiService: _MockGeminiService(),
      );
      ctrl.setActiveUser('9876500001', name: 'Persist User');

      final item1 = _makeVerifiedItem(id: 'lr-p1', lrNo: 'LR-P1');
      final item2 = _makeVerifiedItem(id: 'lr-p2', lrNo: 'LR-P2');
      ctrl.addItemDirectly(item1);
      ctrl.addItemDirectly(item2);

      expect(ctrl.getExportableVerifiedItems().map((e) => e.id), ['lr-p1', 'lr-p2']);

      // Mark only item1 exported
      await ctrl.markItemsAsExported(['lr-p1']);
      expect(ctrl.isItemExported(ctrl.items.firstWhere((i) => i.id == 'lr-p1')), isTrue);
      expect(ctrl.items.firstWhere((i) => i.id == 'lr-p1').exportedAt, isNotNull);
      expect(ctrl.getExportableVerifiedItems().map((e) => e.id), ['lr-p2']);

      ctrl.dispose();

      // Restart controller with same SharedPreferences
      final restarted = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: _StubExcelService(),
        geminiService: _MockGeminiService(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final restored1 = restarted.items.firstWhere((i) => i.id == 'lr-p1');
      expect(restored1.isExported, isTrue);
      expect(restored1.exportedAt, isNotNull);
      expect(restarted.getExportableVerifiedItems().map((e) => e.id), ['lr-p2']);

      // Edit exported item1 -> exportedAt must reset
      restarted.updateRecordField('lr-p1', 'freight  *', '2500');
      final afterEdit1 = restarted.items.firstWhere((i) => i.id == 'lr-p1');
      expect(afterEdit1.exportedAt, isNull);
      expect(restarted.isItemExported(afterEdit1), isFalse);
      expect(restarted.getExportableVerifiedItems().map((e) => e.id), ['lr-p1', 'lr-p2']);

      restarted.dispose();
    });

    test('ExcelGeneratedScreen.deriveAuditSha256 matches Web formula', () {
      expect(
        ExcelGeneratedScreen.deriveAuditSha256({'export_id': 'exp_9a1b2c3d'}),
        'SHA256-9A1B2C3D8FBFD',
      );
      expect(
        ExcelGeneratedScreen.deriveAuditSha256({}),
        'SHA256-0E006244CEF8FBFD',
      );
      expect(
        ExcelGeneratedScreen.deriveAuditSha256({'sha256': 'CUSTOMSHA99'}),
        'CUSTOMSHA99',
      );
    });

    testWidgets(
      'BatchQueueScreen exports only unexported verified LRs, shows accurate unverified exclusion count, navigates to ExcelGeneratedScreen, and protects re-export',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        HttpOverrides.global = _MockHttpOverrides(
          (method, uri, body) => {'success': true, 'data': {}},
        );

        SharedPreferences.setMockInitialValues({
          'bnf_user_mobile': '9876543210',
          'bnf_user_name': 'Export Tester',
        });

        final mockGemini = _MockGeminiService();
        final ctrl = BatchProcessingController(
          permissionService: _StubPermissionService(),
          imageService: _StubImageService(),
          ocrService: _StubOcrService(),
          parserService: FormatParserService(),
          excelService: _StubExcelService(),
          geminiService: mockGemini,
        );
        ctrl.setActiveUser('9876543210', name: 'Export Tester');

        final exportedItem = _makeVerifiedItem(
          id: 'id-old-exp',
          lrNo: 'LR-OLD',
          exportedAt: DateTime(2026, 11, 23, 9),
        );
        final unexportedItem = _makeVerifiedItem(id: 'id-new-exp', lrNo: 'LR-NEW');
        final unverifiedItem = BatchItem(
          id: 'id-unver',
          imagePath: '/docs/u.pdf',
          fileName: 'UNVER.pdf',
          status: BatchItemStatus.completed,
          createdAt: DateTime.now(),
          record: {'grno (*)': 'LR-UNVER', 'is_verified': 'false'},
        );

        ctrl.addItemDirectly(exportedItem);
        ctrl.addItemDirectly(unexportedItem);
        ctrl.addItemDirectly(unverifiedItem);

        await tester.pumpWidget(
          MaterialApp(home: BatchQueueScreen(controller: ctrl)),
        );
        await tester.pumpAndSettle();

        // Tap Download Excel
        await tester.tap(find.byKey(const Key('direct_download_excel_btn')));
        await tester.pumpAndSettle();

        // Must show 1 unexported verified LR & 1 excluded unverified LR
        expect(find.textContaining('Download 1 Verified consignment note(s)?'), findsOneWidget);
        expect(find.textContaining('Note: 1 Unverified LR(s) will be excluded'), findsOneWidget);

        await tester.tap(find.text('Download (1 LRs)'));
        await tester.pumpAndSettle();

        // Export API called with ONLY unexported verified item
        expect(mockGemini.exportCalled, isTrue);
        expect(mockGemini.lastExportDocs.length, 1);
        expect(mockGemini.lastExportDocs.first['data']['grno (*)'], 'LR-NEW');

        // Navigated to ExcelGeneratedScreen with derived SHA256
        expect(find.byType(ExcelGeneratedScreen), findsOneWidget);
        expect(find.text('SHA256-ABCD12348FBFD'), findsOneWidget);

        // Return to BatchQueueScreen (now both verified items are exported)
        Navigator.of(tester.element(find.byType(ExcelGeneratedScreen))).pop();
        await tester.pumpAndSettle();

        // Tapping Download Excel again must trigger Re-Export Confirmation
        await tester.tap(find.byKey(const Key('direct_download_excel_btn')));
        await tester.pumpAndSettle();
        expect(find.text('Re-Export Verified LRs?'), findsOneWidget);
        expect(find.textContaining('Re-Export (2 LRs)'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 500));
        ctrl.dispose();
      },
    );
  });

  group('Req 2: Multi-File Upload & Cloud Sync', () {
    test('addMultipleFilesAsSingleLr combines files, triggers undismissCloudUpload & save-batch sync, and enforces 15-page limit', () async {
      SharedPreferences.setMockInitialValues({
        'bnf_user_mobile': '9112233445',
        'bnf_user_name': 'Multi User',
        'bnf_dismissed_recent_lrs_9112233445': ['multi_dossier_777.pdf'],
      });

      final httpMock = _MockHttpOverrides((method, uri, body) {
        return {'success': true, 'data': {}};
      });
      HttpOverrides.global = httpMock;

      final mockGemini = _MockGeminiService();
      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: _StubExcelService(),
        geminiService: mockGemini,
      );
      ctrl.setActiveUser('9112233445', name: 'Multi User');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final tmp = await Directory.systemTemp.createTemp('multi_parity_');
      addTearDown(() async {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });

      final p1 = File('${tmp.path}/page1.jpg');
      final p2 = File('${tmp.path}/page2.jpg');
      final im = img.Image(width: 20, height: 20);
      await p1.writeAsBytes(img.encodeJpg(im));
      await p2.writeAsBytes(img.encodeJpg(im));

      final ok = await ctrl.addMultipleFilesAsSingleLr([p1.path, p2.path]);
      expect(ok, isTrue);
      expect(ctrl.items.length, 1);

      // Wait for debounced triggerCloudSync (400ms)
      await Future<void>.delayed(const Duration(milliseconds: 550));

      final undismissCalled = httpMock.calls.any(
        (c) =>
            c.uri.path.contains('/api/user-cloud-storage/undismiss-upload') &&
            (c.jsonBody?['lr_identifiers'] as List?)?.contains('multi_dossier_777.pdf') == true,
      );
      final saveBatchCalled = httpMock.calls.any(
        (c) => c.uri.path.contains('/api/user-cloud-storage/save-batch'),
      );
      expect(undismissCalled, isTrue);
      expect(saveBatchCalled, isTrue);

      final prefs = await SharedPreferences.getInstance();
      final dismissedAfter = prefs.getStringList('bnf_dismissed_recent_lrs_9112233445') ?? [];
      expect(dismissedAfter.contains('multi_dossier_777.pdf'), isFalse);

      // Enforce >15 files limit
      final sixteenPaths = List.generate(16, (i) => '${tmp.path}/f$i.jpg');
      final limitOk = await ctrl.addMultipleFilesAsSingleLr(sixteenPaths);
      expect(limitOk, isFalse);
      expect(ctrl.pageLimitNoticePending, isTrue);

      ctrl.dispose();
    });
  });

  group('Req 3: CustomizationDriverScreen Validation & Auto-Fill', () {
    testWidgets(
      'Duplicate LR check blocks collision but allows self, Customer auto-fills Consignor GSTIN, Freight highlights real-time, and editing exported LR resets exportedAt',
      (tester) async {
        tester.view.physicalSize = const Size(900, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        HttpOverrides.global = _MockHttpOverrides(
          (method, uri, body) => {'success': true, 'data': {}},
        );

        SharedPreferences.setMockInitialValues({
          'bnf_user_mobile': '9876543210',
          'bnf_user_name': 'Edit Tester',
        });

        MasterDataService.instance.setPartyGstMapForTesting({
          'acmelogistics': '27AAAAC9999K1Z8',
        });

        final ctrl = BatchProcessingController(
          permissionService: _StubPermissionService(),
          imageService: _StubImageService(),
          ocrService: _StubOcrService(),
          parserService: FormatParserService(),
          excelService: _StubExcelService(),
          geminiService: _MockGeminiService(),
        );
        ctrl.setActiveUser('9876543210', name: 'Edit Tester');

        final existingOther = _makeVerifiedItem(id: 'other-lr', lrNo: 'LR-TAKEN-100');
        final targetItem = _makeVerifiedItem(
          id: 'edit-target',
          lrNo: 'LR-SELF-200',
          freight: '',
          exportedAt: DateTime(2026, 11, 20, 8),
        );
        targetItem.record['cngrgstno *'] = '';
        ctrl.addItemDirectly(existingOther);
        ctrl.addItemDirectly(targetItem);

        await tester.pumpWidget(
          MaterialApp(
            home: CustomizationDriverScreen(item: targetItem, controller: ctrl),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Real-time Freight error highlight when empty
        Text freightLabel() => tester.widget<Text>(find.text('Freight *'));
        expect(freightLabel().style?.color, const Color(0xFFDC2626));

        final textFields = find.byType(TextField);
        // Customer is index 0, Freight is index 1 on CustomizationDriverScreen
        await tester.enterText(textFields.at(1), '1450');
        await tester.pump();
        expect(freightLabel().style?.color, const Color(0xFF0F172A));

        await tester.enterText(textFields.at(1), '');
        await tester.pump();
        expect(freightLabel().style?.color, const Color(0xFFDC2626));

        // 2. Customer change auto-fills Consignor GSTIN (cngrgstno *)
        await tester.enterText(textFields.at(1), '1450');
        await tester.enterText(textFields.at(0), 'ACME LOGISTICS');
        await tester.pump();

        // First test duplicate LR check when targetItem's LR No matches existingOther
        targetItem.record['grno (*)'] = 'LR-TAKEN-100';
        targetItem.record['LR No *'] = 'LR-TAKEN-100';
        await tester.tap(find.text('Save & Verify'));
        await tester.pumpAndSettle();
        expect(find.text('Duplicate LR'), findsOneWidget);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        // Restore target's own LR number -> self must be excluded from duplicate check & save
        targetItem.record['grno (*)'] = 'LR-SELF-200';
        targetItem.record['LR No *'] = 'LR-SELF-200';
        await tester.tap(find.text('Save & Verify'));
        await tester.pumpAndSettle();

        expect(find.byType(BatchQueueScreen), findsOneWidget);
        final updated = ctrl.items.firstWhere((i) => i.id == 'edit-target');
        expect(updated.record['cngrgstno *'], '27AAAAC9999K1Z8');
        expect(updated.record['freight  *'], '1450');
        expect(updated.exportedAt, isNull);
        expect(ctrl.isItemExported(updated), isFalse);

        await tester.pump(const Duration(milliseconds: 500));
        ctrl.dispose();
      },
    );
  });

  group('Req 4: Cloud Sync Conflict Resolution, Delete Rollback & Clear All', () {
    test('deleteItemWithCloudSync waits for server & rolls back on error; Clear All syncs both endpoints', () async {
      SharedPreferences.setMockInitialValues({
        'bnf_user_mobile': '9888877777',
        'bnf_user_name': 'Sync Tester',
        'bnf_exported_batches_9888877777': jsonEncode([{'filename': 'old_export.xlsx'}]),
      });

      bool failDeleteLr = true;
      bool failClearAll = true;
      final httpMock = _MockHttpOverrides((method, uri, body) {
        if (uri.path.endsWith('/delete-lr')) {
          return failDeleteLr
              ? {'_status': 500, 'success': false}
              : {'success': true};
        }
        if (uri.path.endsWith('/clear-all')) {
          return failClearAll
              ? {'_status': 500, 'success': false}
              : {'success': true};
        }
        return {'success': true, 'data': {}};
      });
      HttpOverrides.global = httpMock;

      final mockGemini = _MockGeminiService();
      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: _StubExcelService(),
        geminiService: mockGemini,
      );
      ctrl.setActiveUser('9888877777', name: 'Sync Tester');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final i1 = _makeVerifiedItem(id: 'del-1', lrNo: 'LR-D1');
      i1.record['saved_filename'] = 'saved_d1.pdf';
      final i2 = _makeVerifiedItem(id: 'del-2', lrNo: 'LR-D2');
      ctrl.addItemDirectly(i1);
      ctrl.addItemDirectly(i2);

      // Server delete failure must preserve local item
      expect(await ctrl.deleteItemWithCloudSync('del-1'), isFalse);
      expect(ctrl.items.any((i) => i.id == 'del-1'), isTrue);

      // Server delete success removes item, calls /api/previous-uploads/delete & writes tombstone
      failDeleteLr = false;
      expect(await ctrl.deleteItemWithCloudSync('del-1'), isTrue);
      expect(ctrl.items.any((i) => i.id == 'del-1'), isFalse);
      expect(mockGemini.deletedPreviousTargets, contains('saved_d1.pdf'));

      final prefs = await SharedPreferences.getInstance();
      final dismissed = prefs.getStringList('bnf_dismissed_recent_lrs_9888877777') ?? [];
      expect(dismissed, contains('saved_d1.pdf'));

      // Clear All failure must preserve remaining item
      expect(await ctrl.clearAllWithCloudSync(), isFalse);
      expect(ctrl.items.length, 1);

      // Clear All success hits both clear-all endpoints & preserves export history
      failClearAll = false;
      expect(await ctrl.clearAllWithCloudSync(), isTrue);
      expect(ctrl.items, isEmpty);
      expect(mockGemini.clearAllPreviousCalls, 1);
      expect(
        httpMock.calls.any(
          (c) =>
              c.uri.path.endsWith('/api/user-cloud-storage/clear-all') &&
              c.jsonBody?['clear_history'] == false,
        ),
        isTrue,
      );
      expect(prefs.getString('bnf_exported_batches_9888877777'), isNotNull);

      ctrl.dispose();
    });

    test('hydrateFromCloud resolves timestamp/version conflicts & filters dismissed tombstones', () async {
      SharedPreferences.setMockInitialValues({
        'bnf_user_mobile': '9777766666',
        'bnf_user_name': 'Merge Tester',
        'bnf_dismissed_recent_lrs_9777766666': ['dismissed_id_1'],
      });

      final localNewerItem = _makeVerifiedItem(
        id: 'lr-a',
        lrNo: 'LR-A',
        freight: '2200',
        editedAt: DateTime(2026, 11, 24, 12, 0),
      ).copyWith(currentVersion: 2);

      final localStaleItem = _makeVerifiedItem(
        id: 'lr-b',
        lrNo: 'LR-B',
        freight: '900',
        editedAt: DateTime(2026, 11, 24, 9, 0),
      ).copyWith(currentVersion: 1);

      final httpMock = _MockHttpOverrides((method, uri, body) {
        if (uri.path.endsWith('/api/user-cloud-storage') && method == 'GET') {
          return {
            'success': true,
            'data': {
              'active_batch': [
                {
                  'id': 'lr-a',
                  'filename': 'LR-A.pdf',
                  'editedAt': '2026-11-24T10:00:00.000',
                  'current_version': 1,
                  'is_verified': true,
                  'data': {
                    'grno (*)': 'LR-A',
                    'freight  *': '1000',
                    'is_verified': 'true',
                  },
                },
                {
                  'id': 'lr-b',
                  'filename': 'LR-B.pdf',
                  'editedAt': '2026-11-24T14:00:00.000',
                  'current_version': 3,
                  'is_verified': true,
                  'is_exported': true,
                  'exportedAt': '2026-11-24T15:00:00.000',
                  'data': {
                    'grno (*)': 'LR-B',
                    'freight  *': '3500',
                    'is_verified': 'true',
                  },
                },
                {
                  'id': 'lr-deleted-cloud',
                  'filename': 'Deleted.pdf',
                  'is_deleted': true,
                  'data': {'grno (*)': 'LR-DEL'},
                },
              ],
              'uploaded_lrs': [
                {'id': 'dismissed_id_1', 'filename': 'old_dismissed.pdf'},
                {'id': 'cloud_dismissed_id', 'filename': 'cloud_gone.pdf'},
                {'id': 'valid_upload_1', 'filename': 'valid_upload.pdf', 'lrNo': 'LR-V1'},
              ],
              'dismissed_uploads': ['cloud_dismissed_id'],
            },
          };
        }
        return {'success': true};
      });
      HttpOverrides.global = httpMock;

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: _StubExcelService(),
        geminiService: _MockGeminiService(),
      );
      ctrl.setActiveUser('9777766666', name: 'Merge Tester');
      ctrl.addItemDirectly(localNewerItem);
      ctrl.addItemDirectly(localStaleItem);

      await ctrl.hydrateFromCloud();

      // LR-A local newer edit must win over stale cloud
      final resolvedA = ctrl.items.firstWhere((i) => i.id == 'lr-a');
      expect(resolvedA.record['freight  *'], '2200');

      // LR-B newer cloud edit + exported status must win over stale local
      final resolvedB = ctrl.items.firstWhere((i) => i.id == 'lr-b');
      expect(resolvedB.record['freight  *'], '3500');
      expect(resolvedB.isExported, isTrue);

      // Deleted doc skipped
      expect(ctrl.items.any((i) => i.id == 'lr-deleted-cloud'), isFalse);

      // Dismissed tombstones filtered
      expect(ctrl.previousUploadsCache.any((u) => u['id'] == 'dismissed_id_1'), isFalse);
      expect(ctrl.previousUploadsCache.any((u) => u['id'] == 'cloud_dismissed_id'), isFalse);
      expect(ctrl.previousUploadsCache.any((u) => u['id'] == 'valid_upload_1'), isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 450));
      ctrl.dispose();
    });
  });

  group('Req 5: User Session Isolation & Logout Cleanup', () {
    test('Switching users isolates caches cleanly and logout deletes only current user local cache without touching server', () async {
      final userAData = jsonEncode([
        BatchItem(
          id: 'user-a-item',
          imagePath: '/a.pdf',
          fileName: 'UserA.pdf',
          status: BatchItemStatus.completed,
          createdAt: DateTime(2026, 11, 24),
          record: {'grno (*)': 'LR-A1'},
        ).toLocalJson(),
      ]);

      SharedPreferences.setMockInitialValues({
        'bnf_user_mobile': '9111111111',
        'bnf_user_name': 'User A',
        'bnf_active_batch_9111111111': userAData,
        'bnf_recent_uploaded_lrs_9111111111': jsonEncode([{'id': 'a-rec'}]),
        'bnf_exported_batches_9111111111': jsonEncode([{'filename': 'UserA_Export.xlsx'}]),
        'bnf_exported_batches_9222222222': jsonEncode([{'filename': 'UserB_Export.xlsx'}]),
        'bnf_recent_uploaded_lrs_9222222222': jsonEncode([{'id': 'b-rec'}]),
      });

      final httpMock = _MockHttpOverrides((method, uri, body) => {'success': true, 'data': {}});
      HttpOverrides.global = httpMock;

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        parserService: FormatParserService(),
        excelService: _StubExcelService(),
        geminiService: _MockGeminiService(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(ctrl.items.any((i) => i.id == 'user-a-item'), isTrue);

      // Switch to User B -> User A's items must vanish from memory, User B's scoped recents remain isolated
      ctrl.setActiveUser('9222222222', name: 'User B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(ctrl.items.any((i) => i.id == 'user-a-item'), isFalse);
      expect(ctrl.previousUploadsCache.any((u) => u['id'] == 'a-rec'), isFalse);
      expect(ctrl.previousUploadsCache.any((u) => u['id'] == 'b-rec'), isTrue);

      final prefs = await SharedPreferences.getInstance();
      // User A's scoped data was not wiped by switching to User B
      expect(prefs.getString('bnf_exported_batches_9111111111'), isNotNull);

      // Logout User B -> removes User B's scoped keys only, preserves User A's keys, makes zero server delete calls
      httpMock.calls.clear();
      ctrl.clearForLogout();
      await ctrl.clearUserCachesOnLogout(mobile: '9222222222');

      expect(prefs.getString('bnf_recent_uploaded_lrs_9222222222'), isNull);
      expect(prefs.getString('bnf_exported_batches_9222222222'), isNull);
      expect(prefs.getString('bnf_exported_batches_9111111111'), isNotNull);
      expect(
        httpMock.calls.any(
          (c) => c.uri.path.contains('delete') || c.uri.path.contains('clear-all'),
        ),
        isFalse,
      );

      ctrl.dispose();
    });
  });
}
