import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/config/document_schema.dart';
import 'package:ocr_to_excel/models/extraction_result.dart';
import 'package:ocr_to_excel/services/format_parser.dart';

void main() {
  late FormatParserService parser;

  setUp(() {
    parser = FormatParserService();
  });

  group('FormatParserService - Pattern 1 (Delimiter-based)', () {
    test('extracts invoice fields separated by colons', () {
      final lines = [
        'INVOICE',
        'Invoice No: INV-2026-0042',
        'Date: 12/05/2026',
        'Vendor: Acme Supplies Ltd',
        'Customer: Global Logistics Inc',
        r'Tax: $45.00',
        r'Total Amount: $495.00',
        'Payment Method: Bank Transfer',
      ];

      final result = parser.parseLines(lines, schema: DocumentSchema.invoice);

      expect(result.status, ExtractionStatus.completed);
      expect(result.data['invoice_no'], 'INV-2026-0042');
      expect(result.data['date'], '12/05/2026');
      expect(result.data['vendor'], 'Acme Supplies Ltd');
      expect(result.data['customer'], 'Global Logistics Inc');
      expect(result.data['tax'], r'$45.00');
      expect(result.data['total_amount'], r'$495.00');
      expect(result.data['payment_method'], 'Bank Transfer');
      expect(result.missingFields, isEmpty);
    });

    test('extracts fields with hyphen delimiters and aliases', () {
      final lines = [
        'Bill # - 98765',
        'Bill Date - 2026-08-15',
        'Seller - TechStore',
        'Amount Due - 1250.00',
      ];

      final result = parser.parseLines(lines, schema: DocumentSchema.invoice);

      expect(result.data['invoice_no'], '98765');
      expect(result.data['date'], '2026-08-15');
      expect(result.data['vendor'], 'TechStore');
      expect(result.data['total_amount'], '1250.00');
    });
  });

  group('FormatParserService - Pattern 2 (Positional / Tabular)', () {
    test('extracts values appearing on subsequent lines after headers', () {
      final lines = [
        'INVOICE NO',
        'INV-7721',
        'INVOICE DATE',
        '25/12/2026',
        'VENDOR',
        'MegaCorp Industries',
        'TOTAL AMOUNT',
        r'$3,420.50',
      ];

      final result = parser.parseLines(lines, schema: DocumentSchema.invoice);

      expect(result.data['invoice_no'], 'INV-7721');
      expect(result.data['date'], '25/12/2026');
      expect(result.data['vendor'], 'MegaCorp Industries');
      expect(result.data['total_amount'], r'$3,420.50');
    });
  });

  group('FormatParserService - Pattern 3 (Regex Token Fallback)', () {
    test('identifies date and amount via regex fallback when headers are irregular', () {
      final lines = [
        'Order Receipt Details',
        'Ref 450912',
        'Transaction occurred on 04/18/2026 at register 2',
        r'Total sum charged $189.99',
      ];

      final result = parser.parseLines(lines, schema: DocumentSchema.invoice);

      expect(result.data['date'], '04/18/2026');
      expect(result.data['total_amount'], r'$189.99');
    });
  });

  group('FormatParserService - Schema Handling & Missing Fields', () {
    test('marks partial status when required fields are missing', () {
      final lines = [
        'Vendor: Coffee Shop',
        r'Total Amount: $8.50',
        // Missing invoice_no and date (both required in invoice schema)
      ];

      final result = parser.parseLines(lines, schema: DocumentSchema.invoice);

      expect(result.status, ExtractionStatus.partial);
      expect(result.missingFields, contains('invoice_no'));
      expect(result.missingFields, contains('date'));
      expect(result.data['vendor'], 'Coffee Shop');
      expect(result.data['total_amount'], r'$8.50');
    });

    test('parses receipt schema properly', () {
      final lines = [
        'Store: Fresh Mart Supermarket',
        'Date: 2026-09-01',
        'Receipt #: RCPT-443',
        r'Subtotal: $40.00',
        r'Tax: $3.20',
        r'Total: $43.20',
      ];

      final result = parser.parseLines(lines, schema: DocumentSchema.receipt);

      expect(result.status, ExtractionStatus.completed);
      expect(result.data['store_name'], 'Fresh Mart Supermarket');
      expect(result.data['date'], '2026-09-01');
      expect(result.data['receipt_no'], 'RCPT-443');
      expect(result.data['subtotal'], r'$40.00');
      expect(result.data['tax'], r'$3.20');
      expect(result.data['total_amount'], r'$43.20');
    });

    test('parses arbitrary key-values using generic schema', () {
      final lines = [
        'Tracking ID: TRK-9901',
        'Carrier: FastPost',
        'Weight: 2.5 kg',
        'Destination: New York',
      ];

      final result = parser.parseLines(lines, schema: DocumentSchema.generic);

      expect(result.status, ExtractionStatus.completed);
      expect(result.data['Tracking ID'], 'TRK-9901');
      expect(result.data['Carrier'], 'FastPost');
      expect(result.data['Weight'], '2.5 kg');
      expect(result.data['Destination'], 'New York');
    });
  });
}
