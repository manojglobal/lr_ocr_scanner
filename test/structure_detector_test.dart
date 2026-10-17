import 'package:flutter_test/flutter_test.dart';
import 'package:excel/excel.dart';
import 'package:ocr_to_excel/config/document_schema.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/structure_detector.dart';

void main() {
  late DynamicStructureDetector detector;
  late ExcelService excelService;

  setUp(() {
    detector = DynamicStructureDetector();
    excelService = ExcelService();
  });

  group('DynamicStructureDetector - Table & Structure Detection', () {
    test('automatically detects pipe-delimited tables and preserves rows and columns', () {
      final lines = [
        'Item | Qty | Unit Price | Total',
        'Apples | 5 | 1.20 | 6.00',
        'Bananas | 12 | 0.50 | 6.00',
        'Milk | 2 | 3.50 | 7.00',
      ];

      final result = detector.detectFromLines(lines);

      expect(result.hasTable, isTrue);
      expect(result.structureType, 'table');
      expect(result.tableHeaders, ['Item', 'Qty', 'Unit Price', 'Total']);
      expect(result.tableRows.length, 3);
      expect(result.tableRows[0], ['Apples', '5', '1.20', '6.00']);
      expect(result.tableRows[1], ['Bananas', '12', '0.50', '6.00']);
      expect(result.tableRows[2], ['Milk', '2', '3.50', '7.00']);
    });

    test('automatically detects multi-space column tables', () {
      final lines = [
        'Description      Hours    Rate    Amount',
        'Design Work      10       50.00   500.00',
        'Development      20       75.00   1500.00',
        'QA Testing       5        40.00   200.00',
      ];

      final result = detector.detectFromLines(lines);

      expect(result.hasTable, isTrue);
      expect(result.structureType, 'table');
      expect(result.tableHeaders, ['Description', 'Hours', 'Rate', 'Amount']);
      expect(result.tableRows.length, 3);
      expect(result.tableRows[0], ['Design Work', '10', '50.00', '500.00']);
      expect(result.tableRows[1], ['Development', '20', '75.00', '1500.00']);
      expect(result.tableRows[2], ['QA Testing', '5', '40.00', '200.00']);
    });

    test('automatically detects multi-column comparison forms and avoids key collisions', () {
      final lines = [
        'Details of the Elector                  Details of the relative',
        'EPIC No.: ABEFG123                      EPIC No.: ABC1238000',
        'Elector Name: ROHIT AGRWAL              Relative Name: AMAN AGRWAL',
        'Relationship: FATHER                    Relationship: FATHER',
        'State: UTTAR PRADESH                    State: UTTAR PRADESH',
      ];

      final result = detector.detectFromLines(lines);

      expect(result.hasTable, isTrue);
      expect(result.structureType, 'mixed');
      expect(result.tableHeaders, ['Field / Attribute', 'Details of the Elector', 'Details of the relative']);
      expect(result.tableRows.isNotEmpty, isTrue);

      // Verify no key collision in data map
      expect(result.data['Elector - EPIC No.'], 'ABEFG123');
      expect(result.data['Relative - EPIC No.'], 'ABC1238000');
      expect(result.data['Elector - State'], 'UTTAR PRADESH');
      expect(result.data['Relative - State'], 'UTTAR PRADESH');
    });

    test('automatically detects mixed documents with both key-values and tables', () {
      final lines = [
        'Order ID: ORD-9982',
        'Customer: Tech Corp',
        'Date: 2026-09-28',
        'Product | Quantity | Price',
        'Server Rack | 1 | 850.00',
        'Switch 24-Port | 2 | 220.00',
        'Ethernet Cable | 10 | 15.00',
      ];

      final result = detector.detectFromLines(lines);

      expect(result.structureType, 'mixed');
      expect(result.hasTable, isTrue);
      expect(result.data['Order ID'], 'ORD-9982');
      expect(result.data['Customer'], 'Tech Corp');
      expect(result.data['Date'], '2026-09-28');
      expect(result.tableHeaders, ['Product', 'Quantity', 'Price']);
      expect(result.tableRows.length, 3);
      expect(result.tableRows[0], ['Server Rack', '1', '850.00']);
    });

    test('automatically detects pure form key-values without tables', () {
      final lines = [
        'Patient Name: Alice Smith',
        'Age: 34',
        'Blood Group: O+',
        'Diagnosis: Normal',
      ];

      final result = detector.detectFromLines(lines);

      expect(result.structureType, 'form');
      expect(result.hasTable, isFalse);
      expect(result.data['Patient Name'], 'Alice Smith');
      expect(result.data['Age'], '34');
      expect(result.data['Blood Group'], 'O+');
      expect(result.data['Diagnosis'], 'Normal');
    });

    test('automatically structures unformatted text lines into row index and content', () {
      final lines = [
        'Meeting Minutes',
        'Discussed Q3 results and project milestones.',
        'Next meeting scheduled for Friday.',
      ];

      final result = detector.detectFromLines(lines);

      expect(result.structureType, 'text');
      expect(result.tableHeaders, ['Line', 'Content']);
      expect(result.tableRows.length, 3);
      expect(result.tableRows[0][1], 'Meeting Minutes');
    });
  });

  group('ExcelService - Dynamic Layout Generation for Any Image', () {
    test('generates dynamic table workbook for single image with detected table', () {
      final now = DateTime(2026, 9, 28, 10, 0, 0);
      final item = BatchItem(
        id: 'test-table-1',
        imagePath: '/test/price_list.jpg',
        fileName: 'price_list.jpg',
        status: BatchItemStatus.completed,
        createdAt: now,
        processedAt: now,
        tableHeaders: const ['SKU', 'Product', 'Stock', 'Price'],
        tableRows: const [
          ['SKU-01', 'Keyboard', '45', '\$25.00'],
          ['SKU-02', 'Mouse', '120', '\$12.50'],
          ['SKU-03', 'Monitor', '15', '\$180.00'],
        ],
        structureType: 'table',
      );

      final bytes = excelService.generateExcelBytes(
        items: [item],
        schema: DocumentSchema.dynamic,
      );

      expect(bytes, isNotEmpty);

      final decoded = Excel.decodeBytes(bytes);
      expect(decoded.sheets.isNotEmpty, isTrue);

      final sheet = decoded.sheets.values.first;

      // Verify Table Headers are present
      final h0 = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).value?.toString();
      final h1 = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 0)).value?.toString();
      final h2 = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: 0)).value?.toString();
      final h3 = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: 0)).value?.toString();

      expect(h0, 'SKU');
      expect(h1, 'Product');
      expect(h2, 'Stock');
      expect(h3, 'Price');

      // Verify Data Row 1
      final r1c0 = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1)).value?.toString();
      final r1c1 = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 1)).value?.toString();
      expect(r1c0, 'SKU-01');
      expect(r1c1, 'Keyboard');
    });

    test('generates multi-sheet workbook with Overview and document sheets for multi-image batch', () {
      final now = DateTime(2026, 9, 28, 10, 0, 0);
      final items = [
        BatchItem(
          id: 'item-1',
          imagePath: '/test/table_doc.jpg',
          fileName: 'table_doc.jpg',
          status: BatchItemStatus.completed,
          createdAt: now,
          tableHeaders: const ['Col A', 'Col B'],
          tableRows: const [
            ['Val 1', 'Val 2'],
          ],
          structureType: 'table',
        ),
        BatchItem(
          id: 'item-2',
          imagePath: '/test/form_doc.jpg',
          fileName: 'form_doc.jpg',
          status: BatchItemStatus.completed,
          createdAt: now,
          record: const {
            'Name': 'John Doe',
            'Role': 'Engineer',
          },
          structureType: 'form',
        ),
      ];

      final bytes = excelService.generateExcelBytes(
        items: items,
        schema: DocumentSchema.dynamic,
      );

      expect(bytes, isNotEmpty);

      final decoded = Excel.decodeBytes(bytes);

      // Verify Overview Sheet exists
      expect(decoded.sheets.containsKey('Batch Overview'), isTrue);
      final overview = decoded.sheets['Batch Overview']!;

      final ovHeader0 = overview.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).value?.toString();
      final ovHeader1 = overview.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 0)).value?.toString();
      expect(ovHeader0, '#');
      expect(ovHeader1, 'Image File Name');

      // Verify dedicated sheets for each document exist
      expect(decoded.sheets.length, greaterThanOrEqualTo(3)); // Overview + 2 Doc sheets
    });
  });
}
