import 'dart:io';
import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ocr_to_excel/config/document_schema.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/models/extraction_result.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/gemini_backend_service.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/master_data_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/screens/customization_driver_screen.dart';
import 'package:ocr_to_excel/views/screens/edit_bilty_screen.dart';
import 'package:ocr_to_excel/views/screens/excel_generated_screen.dart';
import 'package:ocr_to_excel/views/screens/excel_preview_screen.dart';

class _StubPermissionService extends PermissionService {}
class _StubImageService extends ImageService {}
class _StubOcrService extends OcrService {
  @override
  Future<void> dispose() async {}
}

class _MockParityGeminiService extends GeminiBackendService {
  final Map<String, String> payload;
  final String rawTextPayload;

  _MockParityGeminiService({
    required this.payload,
    this.rawTextPayload = '',
  });

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
      data: Map<String, String>.from(payload),
      missingFields: const [],
      rawText: rawTextPayload,
    );
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
    return ExtractionResult.success(
      data: Map<String, String>.from(payload),
      missingFields: const [],
      rawText: rawTextPayload,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'bnf_user_name': 'Test User',
      'bnf_user_mobile': '9876543210',
      'bnf_user_token': 'bnf_token',
    });
    MasterDataService.instance.setGoodsListForTesting([]);
    MasterDataService.instance.setPartyGstMapForTesting({});
    MasterDataService.instance.setVehicleTypesForTesting([
      '32 FT Open',
      '32 FT TRAULLA',
      '20 FT Open',
      '10 Axle Trolly',
      '8 Axle Trolly',
      'TAURUS',
      '14 FT Open',
    ]);
  });

  tearDown(() {
    MasterDataService.instance.setGoodsListForTesting([]);
    MasterDataService.instance.setPartyGstMapForTesting({});
  });

  group('Web Parity: 52-Column Excel Schema, Branch & Blank Columns', () {
    test('Excel export writes exact 52 GTInfiniti headers, Branch from Counter, Unicharm Global Marketing & blanks', () {
      MasterDataService.instance.setGoodsListForTesting(['FMCG PRODUCTS', 'AUTO PARTS']);

      final item = BatchItem(
        id: 'parity-1',
        imagePath: '/tmp/unicharm.jpg',
        fileName: 'unicharm.jpg',
        status: BatchItemStatus.completed,
        createdAt: DateTime(2026, 11, 24),
        record: {
          'grno (*)': '55123',
          'grdt *': '24/11/2026',
          'cngr *': 'UNICHARM INDIA PVT. LTD., NEEMRANA',
          'cnge *': 'GLOBAL MARKETING, BENGALURU',
          'Counter': 'MUMBAI 01',
          'orgrefcode': 'MUMBAI',
          'destrefcode': 'BENGALURU',
          'Vehicle No *': 'MH12AB9999',
          'Vehicle Type *': '32 FT Open',
          'Vehicle Category': 'Market',
          'freight  *': '12500',
          'valgoods': '850000',
          'pmark': 'SHOULD BE BLANK',
          'goods': 'fmcg products',
          'custrefcode': 'CM999',
          'staxpaidby': 'E',
          'dlvtype': 'D',
        },
      );

      final bytes = ExcelService().generateExcelBytes(
        items: [item],
        schema: DocumentSchema.grBnf,
      );
      final excel = Excel.decodeBytes(bytes);
      final sheet = excel.tables['Sheet1']!;

      expect(sheet.maxColumns, 52);
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).value?.toString(), 'Branch');
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 10, rowIndex: 0)).value?.toString(), 'PickupPoint');
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 11, rowIndex: 0)).value?.toString(), 'DeliveryPoint');
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 46, rowIndex: 0)).value?.toString(), 'EwayBillDate');

      // Row 1 values
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1)).value?.toString(), 'MUMBAI_1'); // Branch from Counter
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: 1)).value?.toString(), 'Global Marketing'); // Unicharm default
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: 1)).value?.toString(), 'MUMBAI 01');
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 10, rowIndex: 1)).value?.toString(), 'MUMBAI'); // PickupPoint -> Origin
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 11, rowIndex: 1)).value?.toString(), 'BENGALURU'); // DeliveryPoint -> Dest
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 18, rowIndex: 1)).value?.toString() ?? '', ''); // PMark blank
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 19, rowIndex: 1)).value?.toString(), 'FMCG PRODUCTS'); // Goods exact master case
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 21, rowIndex: 1)).value?.toString(), '32 FT Open'); // VehicleTypeName preserved
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 28, rowIndex: 1)).value?.toString(), '0.00'); // OtherAmount does not pull valgoods
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 42, rowIndex: 1)).value?.toString() ?? '', ''); // CustomerRefcode always blank
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 43, rowIndex: 1)).value?.toString() ?? '', ''); // staxpaidby always blank
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 44, rowIndex: 1)).value?.toString() ?? '', ''); // DeliveryType always blank
      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 46, rowIndex: 1)).value.toString(), contains('2026-11-24')); // EwayBillDate defaulted to GrDate
    });

    test('Customer Name manual edit persists and is not overwritten by Consignor', () {
      final item = BatchItem(
        id: 'parity-cust-edit',
        imagePath: '/tmp/cust.jpg',
        fileName: 'cust.jpg',
        status: BatchItemStatus.completed,
        createdAt: DateTime(2026, 11, 24),
        record: {
          'Customer Name *': 'CUSTOM B2B ACCOUNT LTD',
          'cngr *': 'SOME OTHER CONSIGNOR',
          'Counter': 'DELHI',
          'freight  *': '4500',
        },
      );

      final bytes = ExcelService().generateExcelBytes(items: [item], schema: DocumentSchema.grBnf);
      final excel = Excel.decodeBytes(bytes);
      final sheet = excel.tables['Sheet1']!;

      expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: 1)).value?.toString(), 'CUSTOM B2B ACCOUNT LTD');
      expect(item.resolveField('Customer Name *'), 'CUSTOM B2B ACCOUNT LTD');
    });

    test('GoodsMaster validation blanks unmatched goods when loaded', () {
      MasterDataService.instance.setGoodsListForTesting(['AUTO PARTS', 'GLASS SHEETS']);
      expect(MasterDataService.instance.matchValidGoods('auto parts'), 'AUTO PARTS');
      expect(MasterDataService.instance.matchValidGoods('RANDOM UNLISTED CARGO'), isNull);
    });
  });

  group('Web Parity: Shared Single-File & Multi-File Controller Enrichment', () {
    late Directory tmpDir;
    late File f1;
    late File f2;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('parity_ctrl_');
      final im = img.Image(width: 40, height: 40);
      img.fill(im, color: img.ColorRgb8(240, 240, 240));
      f1 = File('${tmpDir.path}/p1.jpg')..writeAsBytesSync(img.encodeJpg(im));
      f2 = File('${tmpDir.path}/p2.jpg')..writeAsBytesSync(img.encodeJpg(im));
    });

    tearDown(() async {
      if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
    });

    test('Single-file queue and multi-file upload apply identical Web enrichment rules', () async {
      MasterDataService.instance.setGoodsListForTesting(['AUTO PARTS', 'DIAPERS']);

      final mock = _MockParityGeminiService(
        payload: {
          'grno (*)': '90125',
          'grdt *': '2026-11-20',
          'cngr *': 'UNICHARM INDIA PVT LTD',
          'cnge *': 'GLOBAL MARKETING',
          'orgrefcode': 'MUMBAI',
          'destrefcode': 'JAIPUR',
          'goods': 'UNMATCHED JUNK GOODS',
          'pmark': 'MARK-XYZ',
          'freight  *': '0',
          'Vehicle No *': 'KA23B5235',
        },
        rawTextPayload: 'Unicharm Sofy MamyPoko',
      );

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
        geminiService: mock,
        useGeminiBackend: true,
      );

      // 1. Multi-file upload
      final okMulti = await ctrl.addMultipleFilesAsSingleLr([f1.path, f2.path]);
      expect(okMulti, isTrue);
      expect(ctrl.items.length, 1);
      final rec = ctrl.items.first.record;

      expect(rec['Customer Name *'], 'Global Marketing');
      expect(rec['Counter'], 'MUMBAI 01');
      expect(rec['Branch'], 'MUMBAI_1');
      expect(rec['branchrefcode'], 'MUMBAI_1');
      expect(rec['goods'], ''); // Cleared because not in GoodsMaster
      expect(rec['pmark'], '');
      expect(rec['freight  *'], '');
      expect(rec['grdt *'], '20-11-2026');
      expect(rec['ewaybilldt'], '20-11-2026');
      expect(rec['PickupPoint'], 'MUMBAI');
      expect(rec['DeliveryPoint'], 'JAIPUR');
      expect(rec['Driver Name *'], ''); // Auto-fill disabled even for KA23B5235
      expect(rec['cngrgstno *'], '29AJYPK4522G1ZR'); // Known brand GST auto-lookup
      ctrl.dispose();
    });
  });

  group('Web Parity: Step 2 EditBiltyScreen & Step 4b CustomizationDriverScreen', () {
    testWidgets('EditBiltyScreen has PickupPoint, DeliveryPoint, searchable pickers, mirroring & GST lookup', (tester) async {
      tester.view.physicalSize = const Size(1080, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      MasterDataService.instance.setGoodsListForTesting(['AUTO PARTS', 'MEDICINES']);
      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
      );
      addTearDown(ctrl.dispose);
      final item = BatchItem(
        id: 'edit-parity-1',
        fileName: 'lr.jpg',
        imagePath: '/tmp/lr.jpg',
        status: BatchItemStatus.completed,
        createdAt: DateTime.now(),
        record: {
          'grno (*)': '12345',
          'grdt *': '24-11-2026',
          'Customer Name *': 'Global Marketing',
          'orgrefcode': 'DELHI',
          'destrefcode': 'PUNE',
          'Vehicle No *': 'MH12AB1234',
          'Vehicle Type *': '',
          'goods': 'INVALID GOOD',
        },
      );
      ctrl.addItemDirectly(item);

      await tester.pumpWidget(
        MaterialApp(
          home: EditBiltyScreen(item: item, controller: ctrl, initialTab: 0),
        ),
      );
      await tester.pumpAndSettle();

      // Pickup Point & Delivery Point labels present
      expect(find.text('Pickup Point'), findsOneWidget);
      expect(find.text('Delivery Point'), findsOneWidget);

      // Searchable Vehicle Type picker works
      final vehPickerBtn = find.byKey(const Key('picker_btn_Vehicle Type *'));
      expect(vehPickerBtn, findsOneWidget);
      await tester.ensureVisible(vehPickerBtn);
      await tester.tap(vehPickerBtn);
      await tester.pumpAndSettle();

      expect(find.text('TAURUS'), findsOneWidget);
      await tester.tap(find.text('TAURUS'));
      await tester.pumpAndSettle();
      expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'TAURUS'), findsOneWidget);

      // Mirroring check: editing Origin Station mirrors into Pickup Point when unmodified
      final orgField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Origin Station',
      );
      await tester.enterText(orgField, 'NOIDA');
      await tester.pumpAndSettle();
      final pickupField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Pickup Point',
      );
      expect(tester.widget<TextField>(pickupField).controller?.text, 'NOIDA');

      // Switch to Cargo Details tab and verify unmatched goods cleared & picker works
      await tester.tap(find.text('Cargo Details'));
      await tester.pumpAndSettle();
      expect(find.text('INVALID GOOD'), findsNothing);

      final goodsPickerBtn = find.byKey(const Key('picker_btn_goods'));
      expect(goodsPickerBtn, findsOneWidget);
      await tester.ensureVisible(goodsPickerBtn);
      await tester.tap(goodsPickerBtn);
      await tester.pumpAndSettle();
      await tester.tap(find.text('AUTO PARTS'));
      await tester.pumpAndSettle();
      expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'AUTO PARTS'), findsOneWidget);

      // Switch to Consignor / Consignee tab and verify party GST auto-lookup
      await tester.tap(find.text('Consignor / Consignee'));
      await tester.pumpAndSettle();
      final cngrField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Consignor Name *',
      );
      await tester.tap(cngrField);
      await tester.pumpAndSettle();
      await tester.enterText(cngrField, 'Himalaya Wellness Company');
      await tester.pumpAndSettle();
      final cngrGstField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Consignor GSTIN *',
      );
      expect(tester.widget<TextField>(cngrField).controller?.text, 'Himalaya Wellness Company');
      expect(tester.widget<TextField>(cngrGstField).controller?.text, '29AADFT3025B2ZK');
    });

    testWidgets('CustomizationDriverScreen keeps Vehicle Type intact, resolves Branch, and disables driver auto-fill', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
      );
      addTearDown(ctrl.dispose);
      final item = BatchItem(
        id: 'custom-parity-1',
        fileName: 'lr.jpg',
        imagePath: '/tmp/lr.jpg',
        status: BatchItemStatus.completed,
        createdAt: DateTime.now(),
        record: {
          'grno (*)': '44556',
          'grdt *': '24-11-2026',
          'Customer Name *': 'HIMALAYA WELLNESS COMPANY',
          'Depatment Name': 'HIMALAYA-DELHI',
          'Counter': 'MUMBAI 01',
          'Vehicle No *': 'KA23B5235',
          'Vehicle Type *': '32 FT Open',
          'cngr *': 'HIMALAYA WELLNESS COMPANY',
          'cngrgstno *': '29AADFT3025B2ZK',
          'cnge *': 'DEST PHARMA',
          'cngegstno *': '29BBBBB1111B2Z9',
          'Driver Name *': 'OCR DRIVER',
          'Mobile no   *': '9988776655',
          'Liscense No *': 'MH12 20200001234',
          'Valid Up to *': '31-12-2030',
          'freight  *': '9500',
        },
      );
      ctrl.addItemDirectly(item);

      await tester.pumpWidget(
        MaterialApp(
          home: CustomizationDriverScreen(item: item, controller: ctrl),
        ),
      );
      await tester.pumpAndSettle();

      // Web Vehicle Category options ('Market' selected by default)
      expect(find.text('Market'), findsOneWidget);

      final saveBtn = find.text('Save & Verify');
      await tester.ensureVisible(saveBtn);
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      final saved = ctrl.items.first.record;
      expect(saved['Vehicle Type *'], '32 FT Open'); // NOT overwritten with Market!
      expect(saved['Vehicle Category'], 'Market');
      expect(saved['Counter'], 'MUMBAI 01');
      expect(saved['Branch'], 'MUMBAI_1');
      expect(saved['Driver Name *'], 'OCR DRIVER');
    });

    testWidgets('ExcelPreviewScreen displays 52 Columns badges', (tester) async {
      tester.view.physicalSize = const Size(1080, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
      );
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(MaterialApp(home: ExcelPreviewScreen(controller: ctrl)));
      await tester.pumpAndSettle();
      expect(find.text('Sheet 1: BNF Import Format (52 Columns)'), findsWidgets);
    });

    testWidgets('ExcelGeneratedScreen displays 52 Columns badges', (tester) async {
      tester.view.physicalSize = const Size(1080, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final ctrl = BatchProcessingController(
        permissionService: _StubPermissionService(),
        imageService: _StubImageService(),
        ocrService: _StubOcrService(),
      );
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ExcelGeneratedScreen(
            controller: ctrl,
            exportResult: {'filename': 'Test.xlsx', 'total_lrs': 0},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('52 COLUMNS'), findsOneWidget);
      expect(find.text('Clean BNF (All 52 Columns)'), findsOneWidget);
    });
  });
}
