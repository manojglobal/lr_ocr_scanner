import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/config/document_schema.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/image_preprocessor.dart';

void main() {
  late FormatParserService parser;

  setUp(() {
    parser = FormatParserService();
  });

  group('BNF LR No & LR No Extraction based on Image Type', () {
    test('Rule 1: Orange/Yellow handwritten image extracts only LR No, BNF LR No is blank', () {
      final lines = [
        'BOX N FREIGHT LOGISTICS SOLUTIONS PVT. LTD.',
        'CONSIGNMENT NOTE: 30035',
        'Date: 05/08/2026',
        'Vehicle No: PB13AR4739',
        'Weight / Measurement: 32 FT MXL',
        'From: HYDERABAD',
        'To: Haryana (Ambada)',
        'Consignor: Himalaya Wellness Company',
        'Consignee: Himalaya Wellness Company',
        'No. of Packages: 942',
        // Even if some number appears near the top:
        '33196',
      ];

      // Parse with isOrangeYellow: true
      final result = parser.parseLines(
        lines,
        schema: DocumentSchema.grBnf,
        isOrangeYellow: true,
      );

      // LR No * must be extracted
      expect(result.data['LR No *'], '30035');
      // BNF LR No MUST be completely blank
      expect(result.data['BNF LR No'] ?? '', '');
    });

    test('Rule 2: White printed page with handwritten/pencil number at top corner extracts BNF LR No', () {
      final lines = [
        'PATANJALI PARIVAHAN PVT. LTD.   33196',
        'C NOTE NO: 9415364',
        'DATE: 01/08/2026',
        'FROM: HARIDWAR',
        'TO: HOWRAH',
        'PKGS: 50',
      ];

      // Parse with isOrangeYellow: false
      final result = parser.parseLines(
        lines,
        schema: DocumentSchema.grBnf,
        isOrangeYellow: false,
      );

      // Printed consignment note number maps to LR No *
      expect(result.data['LR No *'], '9415364');
      // Top corner handwritten/pencil number maps to BNF LR No
      expect(result.data['BNF LR No'], '33196');
    });

    test('Rule 3: White printed page without handwritten/pencil number leaves BNF LR No blank', () {
      final lines = [
        'PATANJALI PARIVAHAN PVT. LTD.',
        'C NOTE NO: 9417559',
        'DATE: 02/08/2026',
        'FROM: HARIDWAR',
        'TO: BANGALORE',
        'PKGS: 120',
      ];

      // Parse with isOrangeYellow: false
      final result = parser.parseLines(
        lines,
        schema: DocumentSchema.grBnf,
        isOrangeYellow: false,
      );

      // Printed consignment note number maps to LR No *
      expect(result.data['LR No *'], '9417559');
      // BNF LR No must be blank
      expect(result.data['BNF LR No'] ?? '', '');
    });

    test('ImagePreprocessor classifies 1.jpeg, 2.jpeg, 3.jpeg as white pages (isOrangeYellow == false)', () async {
      for (final filename in ['1.jpeg', '2.jpeg', '3.jpeg']) {
        final isOrange = await ImagePreprocessor.isOrangeYellowImage(filename);
        expect(isOrange, isFalse, reason: '$filename should not be classified as orange/yellow');
      }
    });
  });
}
