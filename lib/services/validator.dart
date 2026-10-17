import 'layout_analyzer.dart';

/// Validation report summarizing field corrections, confidence warnings,
/// and items needing human review.
class ValidationReport {
  final Map<String, String> validatedFields;
  final List<List<String>> validatedTableRows;
  final Set<String> flaggedKeys;
  final List<String> warnings;

  ValidationReport({
    required this.validatedFields,
    required this.validatedTableRows,
    required this.flaggedKeys,
    required this.warnings,
  });

  bool get hasWarnings => warnings.isNotEmpty || flaggedKeys.isNotEmpty;
}

/// Applies domain-aware field validation, look-alike character normalization,
/// and confidence checks across extracted data before Excel export.
class Validator {
  /// Validates and normalizes layout analysis results.
  ValidationReport validate(LayoutAnalysisResult layout) {
    final Map<String, String> cleanFields = {};
    final Set<String> flaggedKeys = {};
    final List<String> warnings = [];

    // 1. Validate Key-Value Fields
    for (final entry in layout.fields.entries) {
      final key = entry.key;
      final rawVal = entry.value;
      final detailed = layout.detailedFields[key];

      // Check if word was flagged by two-pass disagreement or low confidence
      bool isFlagged = detailed?.isFlagged ?? false;
      if (detailed != null && detailed.confidence < 0.65) {
        isFlagged = true;
      }

      // Apply type-aware look-alike character corrections
      final validatedVal = _normalizeValueForField(key, rawVal);

      if (isFlagged) {
        flaggedKeys.add(key);
        warnings.add('Low confidence or two-pass disagreement on "$key": "$validatedVal"');
      }

      cleanFields[key] = validatedVal;
    }

    // 2. Validate Table Rows
    final List<List<String>> cleanRows = [];
    for (final row in layout.tableRows) {
      final List<String> cleanRow = [];
      for (int c = 0; c < row.length; c++) {
        final cell = row[c];
        // If row has an attribute name in column 0, use it to normalize subsequent columns
        if (c > 0 && row.isNotEmpty) {
          final attr = row[0];
          cleanRow.add(_normalizeValueForField(attr, cell));
        } else {
          cleanRow.add(cell.trim());
        }
      }
      cleanRows.add(cleanRow);
    }

    return ValidationReport(
      validatedFields: cleanFields,
      validatedTableRows: cleanRows,
      flaggedKeys: flaggedKeys,
      warnings: warnings,
    );
  }

  /// Normalizes characters according to semantic field type.
  String _normalizeValueForField(String fieldName, String value) {
    String v = value.trim();
    if (v.isEmpty) return '';

    final lowerKey = fieldName.toLowerCase();

    // 1. Alphanumeric Indian EPIC ID (Pattern: 3 Letters + 7 Digits, e.g. ABEFG123 or ABC1238000)
    if (lowerKey.contains('epic') || lowerKey.contains('voter id')) {
      return _disambiguateEpicNumber(v);
    }

    // 2. Purely Numeric Fields (Age, Phone, Pin Code, Mobile, Serial)
    if (lowerKey.contains('age') ||
        lowerKey.contains('phone') ||
        lowerKey.contains('mobile') ||
        lowerKey.contains('pin') ||
        lowerKey.contains('serial')) {
      return _disambiguateNumeric(v);
    }

    // 3. Family Relationship (FATHER, MOTHER, HUSBAND, WIFE, etc.)
    if (lowerKey.contains('relation')) {
      return _disambiguateRelationship(v);
    }

    // 4. State / Region Names
    if (lowerKey.contains('state') || lowerKey.contains('district')) {
      return _disambiguateStateName(v);
    }

    // 5. General Person Names (force alphabetic)
    if (lowerKey.contains('name')) {
      return _disambiguateAlphabetic(v);
    }

    return v;
  }

  /// Corrects EPIC numbers: first 3 characters must be letters, remaining must be digits.
  String _disambiguateEpicNumber(String text) {
    var clean = text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (clean.length >= 7) {
      final prefixLen = clean.length > 3 ? 3 : clean.length;
      final prefix = clean.substring(0, prefixLen)
          .replaceAll('0', 'O')
          .replaceAll('1', 'I')
          .replaceAll('5', 'S')
          .replaceAll('8', 'B');

      final suffix = clean.substring(prefixLen)
          .replaceAll('O', '0')
          .replaceAll('I', '1')
          .replaceAll('L', '1')
          .replaceAll('S', '5')
          .replaceAll('B', '8')
          .replaceAll('Z', '2');

      return prefix + suffix;
    }
    return clean;
  }

  /// Replaces look-alike letters with numbers in numeric fields.
  String _disambiguateNumeric(String text) {
    return text.toUpperCase()
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1')
        .replaceAll('|', '1')
        .replaceAll('S', '5')
        .replaceAll('B', '8')
        .replaceAll('Z', '2');
  }

  /// Replaces look-alike digits with letters in names.
  String _disambiguateAlphabetic(String text) {
    return text
        .replaceAll('0', 'O')
        .replaceAll('1', 'I')
        .replaceAll('5', 'S')
        .replaceAll('8', 'B');
  }

  /// Disambiguates common relationship words.
  String _disambiguateRelationship(String text) {
    final upper = text.toUpperCase();
    const map = {
      'FATHER': ['FATHLR', 'FATH3R', 'FATH8R', 'FATHAR', 'FATAL', 'FATH'],
      'MOTHER': ['MOTHLR', 'MOTH3R', 'MOTHZR', 'MOTHAR', 'MOTH'],
      'HUSBAND': ['HUSBA ND', 'HUSBND', 'H USBAND'],
      'WIFE': ['WlFE', 'W1FE'],
      'SON': ['S0N', 'S ON'],
      'DAUGHTER': ['DAUGHTR', 'DAUGTHER', 'DAUGHT3R'],
      'BROTHER': ['BROTHLR', 'BROT HER', 'BR0THER'],
      'SISTER': ['SISTLR', 'S1STER'],
    };
    for (final entry in map.entries) {
      if (entry.value.any((bad) => upper == bad || upper.startsWith(bad))) {
        return entry.key;
      }
    }
    return text;
  }

  /// Disambiguates Indian State names.
  String _disambiguateStateName(String text) {
    final upper = text.toUpperCase();
    const states = {
      'UTTAR PRADESH': ['U7TAR PRADESH', 'UT7AR PRADESH', 'UTTAR PARDESH', 'UTTAR PARDISA', 'U7TAR PARDISA', 'UT7AR PARDISA', 'UTTAR PR'],
      'MAHARASHTRA': ['MAHARAS HRA', 'MAHARASH TRA'],
      'MADHYA PRADESH': ['MADHYA PARDESH', 'M.P.'],
      'DELHI': ['D3LHI', 'D ELHI'],
      'GUJARAT': ['GUJRAT', 'GUJURAT'],
      'RAJASTHAN': ['RAJAS THAN', 'RAJASTNAN'],
    };
    for (final entry in states.entries) {
      if (entry.value.any((bad) => upper.contains(bad))) {
        return entry.key;
      }
    }
    return text;
  }
}
