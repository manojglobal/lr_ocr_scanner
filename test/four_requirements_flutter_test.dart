import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/config/document_schema.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/master_data_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/screens/edit_bilty_screen.dart';

void main() {
  group('Requirement 1: Counter Name Mapping from Origin City', () {
    test('Matches exact Counter Name from BookingCounterMast.xlsx using Origin City', () {
      final master = MasterDataService.instance;
      expect(master.autoDetectCounter(originCity: 'Delhi'), equals('DELHI'));
      expect(master.autoDetectCounter(originCity: 'Bangalore'), equals('BANG-01'));
      expect(master.autoDetectCounter(originCity: 'Banglore'), equals('BANG-01'));
      expect(master.autoDetectCounter(originCity: 'Belgaum'), equals('BEL'));
      expect(master.autoDetectCounter(originCity: 'Belagavi'), equals('BEL'));
      expect(master.autoDetectCounter(originCity: 'Indore'), equals('INDORE-1'));
      expect(master.autoDetectCounter(originCity: 'Kolkata'), equals('KOL'));
      expect(master.autoDetectCounter(originCity: 'Calcutta'), equals('KOL'));
      expect(master.autoDetectCounter(originCity: 'Nagpur'), equals('1'));
      expect(master.autoDetectCounter(originCity: 'Raipur'), equals('RAIPUR-01'));
      expect(master.autoDetectCounter(originCity: 'Siliguri'), equals('SILIGURI-1'));
      expect(master.autoDetectCounter(originCity: 'Mumbai'), equals('MUMBAI 01'));
      expect(master.autoDetectCounter(originCity: 'Patiala'), equals('PATIALA'));
    });

    test('Leaves Counter Name empty when no reliable match is found (no hardcoded fallback)', () {
      final master = MasterDataService.instance;
      expect(master.autoDetectCounter(originCity: 'Pune'), equals(''));
      expect(master.autoDetectCounter(originCity: 'UnknownCity'), equals(''));
      expect(master.autoDetectCounter(originCity: ''), equals(''));
      expect(master.autoDetectCounter(originCity: null), equals(''));
    });
  });

  group('Requirement 2: Date Format DD-MM-YYYY', () {
    test('Strictly formats all dates into DD-MM-YYYY without converting or shifting values', () {
      expect(ExcelService.formatToDdMmYyyy('12/10/2026'), equals('12-10-2026'));
      expect(ExcelService.formatToDdMmYyyy('12-10-2026'), equals('12-10-2026'));
      expect(ExcelService.formatToDdMmYyyy('2026-10-12'), equals('12-10-2026'));
      expect(ExcelService.formatToDdMmYyyy('12-OCT-2026'), equals('12-10-2026'));
      expect(ExcelService.formatToDdMmYyyy('05 Oct 26'), equals('05-10-2026'));
      expect(ExcelService.formatToDdMmYyyy('01/04/2025'), equals('01-04-2025'));
      expect(ExcelService.formatToDdMmYyyy('12/10/2026 11:59:00 PM'), equals('12-10-2026'));
      expect(ExcelService.formatToDdMmYyyy('2026-10-12T15:30:00'), equals('12-10-2026'));
      expect(ExcelService.formatToDdMmYyyy(''), equals(''));
      expect(ExcelService.formatToDdMmYyyy(null), equals(''));
    });
  });

  group('Requirement 3: Department Mapping from Origin City', () {
    test('Matches exact Department from ManiFest.xlsx using Origin City and Customer', () {
      final master = MasterDataService.instance;
      const himalaya = 'HIMALAYA WELLNESS COMPANY';
      expect(master.autoDetectDepartment(originCity: 'Siliguri', customer: himalaya), equals('HIMALAYA-SILIGURI'));
      expect(master.autoDetectDepartment(originCity: 'Nagpur', customer: himalaya), equals('HIMALAYA-NAGPUR'));
      expect(master.autoDetectDepartment(originCity: 'Bangalore', customer: himalaya), equals('HIMALAYA-BANGLORE'));
      expect(master.autoDetectDepartment(originCity: 'Raipur', customer: himalaya), equals('HIMALAYA-RAIPUR'));
      expect(master.autoDetectDepartment(originCity: 'Delhi', customer: himalaya), equals('HIMALAYA-DELHI'));

      const goldPlus = 'GOLD PLUS FLOAT GLASS PRIVATE LIMITED';
      expect(master.autoDetectDepartment(originCity: 'Belgaum', customer: goldPlus), equals('GOLD PLUS-BELGUAM'));
      expect(master.autoDetectDepartment(originCity: 'Belguam', customer: goldPlus), equals('GOLD PLUS-BELGUAM'));

      const patanjali = 'PATANJALI PARIVAHAN PRIVATE LIMITED';
      expect(master.autoDetectDepartment(originCity: 'Hyderabad', customer: patanjali), equals('PATANJALI-HYDERABAD'));
      expect(master.autoDetectDepartment(originCity: 'Karanpura', customer: patanjali), equals('PATAN-KARANPURA'));
    });

    test('Leaves Department empty when no reliable match is found (no hardcoded fallback)', () {
      final master = MasterDataService.instance;
      const himalaya = 'HIMALAYA WELLNESS COMPANY';
      expect(master.autoDetectDepartment(originCity: 'Pune', customer: himalaya), equals(''));
      expect(master.autoDetectDepartment(originCity: 'Goa', customer: himalaya), equals(''));
      expect(master.autoDetectDepartment(originCity: '', customer: himalaya), equals(''));
      expect(master.autoDetectDepartment(originCity: null, customer: null), equals(''));
    });
  });

  group('Requirement 4: E-Way Bill Date Field in Basic Details', () {
    testWidgets('E-Way Bill Date field is rendered only in Basic Details tab', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final controller = BatchProcessingController();
      final item = BatchItem(
        id: 'test_lr_eway',
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        createdAt: DateTime.now(),
        record: {
          'grno (*)': '12345',
          'grdt *': '12-10-2026',
          'Customer Name *': 'HIMALAYA WELLNESS COMPANY',
          'orgrefcode': 'DELHI',
          'destrefcode': 'MUMBAI',
          'Vehicle No *': 'MH12AB1234',
          'Vehicle Type *': 'Market',
          'freight  *': '5000',
          'ewaybilldt': '14-10-2026',
        },
      );
      controller.addItemDirectly(item);

      await tester.pumpWidget(
        MaterialApp(
          home: EditBiltyScreen(
            item: item,
            controller: controller,
            initialTab: 0, // Basic Details Tab
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check E-Way Bill Date field label in Basic Details tab
      expect(find.text('E-Way Bill Date'), findsOneWidget);
      expect(find.text('14-10-2026'), findsOneWidget);
    });

    test('E-Way Bill Date is strictly excluded from 49-column Excel schema', () {
      // 49-column canonical headers
      expect(ExcelService.lrFormat49Headers.length, equals(49));
      expect(ExcelService.lrFormat49Headers.contains('ewaybilldt'), isFalse);
      expect(ExcelService.lrFormat49Headers.contains('E-Way Bill Date'), isFalse);
      expect(ExcelService.lrFormat49Headers.contains('eway_bill_date'), isFalse);

      // grBnf schema headers
      expect(DocumentSchema.grBnf.fields.length, equals(49));
      final grBnfKeys = DocumentSchema.grBnf.fields.map((f) => f.key).toList();
      expect(grBnfKeys.contains('ewaybilldt'), isFalse);
      expect(grBnfKeys.contains('E-Way Bill Date'), isFalse);
    });
  });
}
