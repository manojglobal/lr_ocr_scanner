import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/master_data_service.dart';
import 'package:ocr_to_excel/config/document_schema.dart';
import 'package:excel/excel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Requirement 1: Consignor & Consignee GST Validation', () {
    test('Whitespace removal strips all spaces from GSTINs', () {
      final dirtyCngrGst = '  07 AAAAA 0000 A 1 Z 5  ';
      final cleaned = dirtyCngrGst.replaceAll(RegExp(r'\s+'), '').toUpperCase();
      expect(cleaned, equals('07AAAAA0000A1Z5'));
      expect(cleaned.contains(' '), isFalse);
      expect(cleaned.length, equals(15));
    });

    test('ExcelService ensures exported GST columns contain zero spaces in 49-column export', () {
      final item = BatchItem(
        id: 'test-gst-1',
        createdAt: DateTime.now(),
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        record: {
          'cngr *': 'HIMALAYA WELLNESS COMPANY',
          'cngrgstno *': '07 AAAAA 0000 A 1 Z 5',
          'cnge *': 'DEST CUSTOMER',
          'cngegstno *': '29 BBBBB 1111 B 2 Z 9',
          'Depatment Name': 'HIMALAYA-SILIGURI',
          'Counter': 'DELHI',
          'product_type': 'Surface-FTL',
          'freight  *': '1500.50',
        },
      );

      final excelBytes = ExcelService().generateExcelBytes(
        items: [item],
        schema: DocumentSchema.grBnf,
      );

      final excel = Excel.decodeBytes(excelBytes);
      final sheet = excel.tables[excel.tables.keys.first]!;

      // Column 11 is ConsignorGST, Column 13 is ConsigneeGST
      final cngrGstCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 11, rowIndex: 1)).value?.toString() ?? '';
      final cngeGstCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 13, rowIndex: 1)).value?.toString() ?? '';

      expect(cngrGstCell, equals('07AAAAA0000A1Z5'));
      expect(cngrGstCell.contains(' '), isFalse);
      expect(cngeGstCell, equals('29BBBBB1111B2Z9'));
      expect(cngeGstCell.contains(' '), isFalse);
    });
  });

  group('Requirement 2: Freight Must Be Mandatory Manual Input', () {
    test('ExcelService blocks export and throws ArgumentError when Freight is empty', () {
      final emptyFreightItem = BatchItem(
        id: 'test-empty-freight',
        createdAt: DateTime.now(),
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        record: {
          'cngr *': 'HIMALAYA WELLNESS COMPANY',
          'Depatment Name': 'HIMALAYA-SILIGURI',
          'Counter': 'DELHI',
          'product_type': 'Surface-FTL',
          'freight  *': '',
        },
      );

      expect(
        () => ExcelService().generateExcelBytes(
          items: [emptyFreightItem],
          schema: DocumentSchema.grBnf,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('Excel export succeeds when Freight is manually entered and maps to Column 25', () {
      final item = BatchItem(
        id: 'test-freight-1',
        createdAt: DateTime.now(),
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        record: {
          'cngr *': 'HIMALAYA WELLNESS COMPANY',
          'Depatment Name': 'HIMALAYA-SILIGURI',
          'Counter': 'DELHI',
          'product_type': 'Surface-FTL',
          'freight  *': '2450.75',
        },
      );

      final excelBytes = ExcelService().generateExcelBytes(
        items: [item],
        schema: DocumentSchema.grBnf,
      );

      final excel = Excel.decodeBytes(excelBytes);
      final sheet = excel.tables[excel.tables.keys.first]!;

      // Col 25 is Freight header at row 0, data at row 1
      final freightHeader = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 25, rowIndex: 0)).value?.toString();
      final freightVal = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 25, rowIndex: 1)).value?.toString();

      expect(freightHeader, equals('Freight'));
      expect(freightVal, equals('2450.75'));
    });
  });

  group('Requirement 3: Product Code and Product Type Separation', () {
    test('Product Type defaults to Surface-FTL for new records (Col 14 ProductName)', () {
      final itemNew = BatchItem(
        id: 'test-prod-new',
        createdAt: DateTime.now(),
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        record: {
          'cngr *': 'HIMALAYA WELLNESS COMPANY',
          'Depatment Name': 'HIMALAYA-SILIGURI',
          'Counter': 'DELHI',
          'freight  *': '1200.00',
        },
      );

      final excelBytesNew = ExcelService().generateExcelBytes(
        items: [itemNew],
        schema: DocumentSchema.grBnf,
      );
      final excelNew = Excel.decodeBytes(excelBytesNew);
      final sheetNew = excelNew.tables[excelNew.tables.keys.first]!;

      final prodHeader = sheetNew.cell(CellIndex.indexByColumnRow(columnIndex: 14, rowIndex: 0)).value?.toString();
      final prodValNew = sheetNew.cell(CellIndex.indexByColumnRow(columnIndex: 14, rowIndex: 1)).value?.toString();

      expect(prodHeader, equals('ProductName'));
      expect(prodValNew, equals('Surface-FTL'));
    });

    test('Product Code and Product Type remain separate throughout editing and export', () {
      final itemExisting = BatchItem(
        id: 'test-prod-existing',
        createdAt: DateTime.now(),
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        record: {
          'cngr *': 'HIMALAYA WELLNESS COMPANY',
          'Depatment Name': 'HIMALAYA-SILIGURI',
          'Counter': 'DELHI',
          'product_type': 'Global-TT',
          'productcode': 'PRD-RAW-ITEM-88',
          'freight  *': '3200.00',
        },
      );

      final excelBytesExisting = ExcelService().generateExcelBytes(
        items: [itemExisting],
        schema: DocumentSchema.grBnf,
      );
      final excelExisting = Excel.decodeBytes(excelBytesExisting);
      final sheetExisting = excelExisting.tables[excelExisting.tables.keys.first]!;

      // Col 14 maps Product Type
      final prodValExisting = sheetExisting.cell(CellIndex.indexByColumnRow(columnIndex: 14, rowIndex: 1)).value?.toString();
      expect(prodValExisting, equals('Global-TT'));

      // The record's actual Product Code is intact
      expect(itemExisting.record['productcode'], equals('PRD-RAW-ITEM-88'));
      expect(itemExisting.record['product_type'], equals('Global-TT'));
    });
  });

  group('Requirements 4 & 5: Department and Counter Auto-Detection & Exact Master Validation', () {
    test('MasterDataService validates exact Department values including exact spaces', () {
      // Exact trailing space from ManiFest.xlsx
      expect(MasterDataService.instance.isDepartmentValid('HIMALAYA-ZIRAKPUR ', 'HIMALAYA WELLNESS COMPANY'), isTrue);
      expect(MasterDataService.instance.isDepartmentValid('HIMALAYA-SILIGURI', 'HIMALAYA WELLNESS COMPANY'), isTrue);
      // Spaces around hyphen
      expect(MasterDataService.instance.isDepartmentValid('HIM - TUMKUR', 'HIMALAYA WELLNESS COMPANY'), isTrue);
      expect(MasterDataService.instance.isDepartmentValid('HIMALAYA - VIJAYAWADA', 'HIMALAYA WELLNESS COMPANY'), isTrue);
      // Fake / invalid department must be REJECTED
      expect(MasterDataService.instance.isDepartmentValid('CIPLA-MUMBAI', 'HIMALAYA WELLNESS COMPANY'), isFalse);
      expect(MasterDataService.instance.isDepartmentValid('RANDOM-DEPARTMENT', 'HIMALAYA WELLNESS COMPANY'), isFalse);
    });

    test('MasterDataService validates exact Counter values and excludes Branch pollution', () {
      // Valid counters from BookingCounterMast.xlsx Col 1
      expect(MasterDataService.instance.isCounterValid('DELHI'), isTrue);
      expect(MasterDataService.instance.isCounterValid('KOL'), isTrue);
      expect(MasterDataService.instance.isCounterValid('MUMBAI 01'), isTrue);
      expect(MasterDataService.instance.isCounterValid('BANG-01'), isTrue);
      expect(MasterDataService.instance.isCounterValid('1'), isTrue);

      // Branch names that were previously mistakenly loaded as counters must be REJECTED
      expect(MasterDataService.instance.isCounterValid('KOLKATA'), isFalse);
      expect(MasterDataService.instance.isCounterValid('BANGLORE'), isFalse);
      expect(MasterDataService.instance.isCounterValid('delhi'), isFalse);
      expect(MasterDataService.instance.isCounterValid('UNKNOWN_COUNTER'), isFalse);
    });

    test('MasterDataService auto-detects Department uniquely and preserves exact Excel string with trailing spaces', () {
      final matched = MasterDataService.instance.autoDetectDepartment(
        customer: 'HIMALAYA WELLNESS COMPANY',
        destination: 'ZIRAKPUR',
      );
      expect(matched, equals('HIMALAYA-ZIRAKPUR '), reason: 'Trailing space must be preserved');

      final matchedSili = MasterDataService.instance.autoDetectDepartment(
        customer: 'HIMALAYA WELLNESS COMPANY',
        deptRaw: 'SILIGURI',
      );
      expect(matchedSili, equals('HIMALAYA-SILIGURI'));
    });

    test('MasterDataService returns empty string for unmatched and ambiguous Department clues', () {
      // Unmatched location
      final unmatched = MasterDataService.instance.autoDetectDepartment(
        customer: 'HIMALAYA WELLNESS COMPANY',
        destination: 'LONDON',
      );
      expect(unmatched, equals(''), reason: 'Unmatched destination must return empty string');

      // Ambiguous generic token without destination clue
      final ambiguous = MasterDataService.instance.autoDetectDepartment(
        customer: 'HIMALAYA WELLNESS COMPANY',
        destination: 'HIMALAYA',
      );
      expect(ambiguous, equals(''), reason: 'Ambiguous matches must return empty string');
    });

    test('MasterDataService auto-detects Counter from exact and branch clues, returns empty on unmatched', () {
      // Exact counter
      expect(MasterDataService.instance.autoDetectCounter(counterRaw: 'DELHI'), equals('DELHI'));

      // Branch clue from BookingCounterMast.xlsx (KOLKATA -> KOL)
      expect(MasterDataService.instance.autoDetectCounter(branchRaw: 'KOLKATA'), equals('KOL'));

      // Unmatched counter / branch
      expect(MasterDataService.instance.autoDetectCounter(counterRaw: 'RANDOM_CITY', branchRaw: 'UNKNOWN'), equals(''));
    });

    test('ExcelService throws ArgumentError on export if Department or Counter is invalid', () {
      final invalidItem = BatchItem(
        id: 'test-invalid-dept',
        createdAt: DateTime.now(),
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        record: {
          'cngr *': 'HIMALAYA WELLNESS COMPANY',
          'Depatment Name': 'INVALID_DEPARTMENT_XYZ',
          'Counter': 'DELHI',
          'freight  *': '1000',
        },
      );

      expect(
        () => ExcelService().generateExcelBytes(
          items: [invalidItem],
          schema: DocumentSchema.grBnf,
        ),
        throwsA(isA<ArgumentError>()),
      );

      final invalidCounterItem = BatchItem(
        id: 'test-invalid-counter',
        createdAt: DateTime.now(),
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        record: {
          'cngr *': 'HIMALAYA WELLNESS COMPANY',
          'Depatment Name': 'HIMALAYA-SILIGURI',
          'Counter': 'UNKNOWN_COUNTER_123',
          'freight  *': '1000',
        },
      );

      expect(
        () => ExcelService().generateExcelBytes(
          items: [invalidCounterItem],
          schema: DocumentSchema.grBnf,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('Excel export strictly preserves exact Department and Counter values with exact whitespace', () {
      final validItem = BatchItem(
        id: 'test-exact-spaces',
        createdAt: DateTime.now(),
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        record: {
          'cngr *': 'HIMALAYA WELLNESS COMPANY',
          'Depatment Name': 'HIMALAYA-ZIRAKPUR ', // Exact trailing space
          'Counter': 'MUMBAI 01',
          'product_type': 'Surface-FTL',
          'freight  *': '1850.00',
        },
      );

      final bytes = ExcelService().generateExcelBytes(
        items: [validItem],
        schema: DocumentSchema.grBnf,
      );

      final excel = Excel.decodeBytes(bytes);
      final sheet = excel.tables[excel.tables.keys.first]!;

      // Col 5 is CustomerDepartment, Col 6 is Countername
      final deptVal = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: 1)).value?.toString();
      final counterVal = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: 1)).value?.toString();

      expect(deptVal, equals('HIMALAYA-ZIRAKPUR '), reason: 'Department trailing space must not be stripped');
      expect(counterVal, equals('MUMBAI 01'));
    });
  });
}
