import 'dart:math';
import 'dart:ui';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../models/extraction_result.dart';

/// Represents a detected cell fragment with 2D spatial coordinates.
class SpatialCell {
  final String text;
  final Rect bounds;

  SpatialCell({required this.text, required this.bounds});

  double get left => bounds.left;
  double get top => bounds.top;
  double get right => bounds.right;
  double get bottom => bounds.bottom;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;
  double get width => bounds.width;
  double get height => bounds.height;
}

/// A row of horizontally aligned spatial cells.
class SpatialRow {
  final List<SpatialCell> cells;
  double top;
  double bottom;
  double centerY;

  SpatialRow({required this.cells})
      : top = cells.map((c) => c.top).reduce(min),
        bottom = cells.map((c) => c.bottom).reduce(max),
        centerY = cells.map((c) => c.centerY).reduce((a, b) => a + b) / cells.length;

  void addCell(SpatialCell cell) {
    cells.add(cell);
    cells.sort((a, b) => a.left.compareTo(b.left));
    top = min(top, cell.top);
    bottom = max(bottom, cell.bottom);
    centerY = cells.map((c) => c.centerY).reduce((a, b) => a + b) / cells.length;
  }
}

/// Advanced computer-vision style layout and table structure detector.
/// Automatically detects tables, columns, rows, multi-column comparison forms,
/// key-values, and dynamic content from ANY image without predefined templates.
class DynamicStructureDetector {
  /// Amount / Currency regex
  static final RegExp _amountPattern = RegExp(
    r'(?:[\$₹€£]|USD|EUR|INR|GBP)?\s*(\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{2})\b',
  );

  /// Automatically parses a RecognizedText instance using 2D spatial analysis.
  ExtractionResult detectFromRecognizedText(RecognizedText recognizedText) {
    final rawText = recognizedText.text;
    if (rawText.trim().isEmpty) {
      return ExtractionResult.failure(
        errorMessage: 'No text detected in image',
        rawText: '',
      );
    }

    // 1. Gather all word / phrase fragments with spatial bounds
    final List<SpatialCell> cells = _extractSpatialCells(recognizedText);

    if (cells.isEmpty) {
      // Fallback to text line parser
      final lines = rawText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      return detectFromLines(lines, rawText: rawText);
    }

    // 2. Try to detect Multi-Column Forms / Comparison Layouts first (e.g. parallel elector/relative forms)
    final multiColResult = _tryDetectMultiColumnForm(recognizedText, cells, rawText);
    if (multiColResult != null) {
      return multiColResult;
    }

    // 3. Cluster cells into horizontal rows
    final List<SpatialRow> rows = _clusterIntoRows(cells);

    // 4. Analyze rows to identify Table structures, Key-Values, and Metadata
    return _analyzeSpatialStructure(rows, rawText);
  }

  // =========================================================================
  // Multi-Column Form / Comparison Document Detection
  // =========================================================================

  /// Attempts to detect a multi-column form structure (e.g., enumeration form, comparison table,
  /// dual-column application) where parallel vertical columns contain matching or repetitive field labels.
  ExtractionResult? _tryDetectMultiColumnForm(
    RecognizedText recognizedText,
    List<SpatialCell> cells,
    String rawText,
  ) {
    if (cells.length < 6) return null;

    final List<TextLine> allLines = [];
    for (final block in recognizedText.blocks) {
      allLines.addAll(block.lines);
    }

    // 1. Compute horizontal bounding box
    double minX = cells.first.left;
    double maxX = cells.first.right;
    for (final c in cells) {
      minX = min(minX, c.left);
      maxX = max(maxX, c.right);
    }
    final double totalWidth = maxX - minX;
    if (totalWidth < 300) return null;

    final double splitX = minX + (totalWidth * 0.48);

    // 2. Find candidate field labels in Left vs Right columns
    final List<TextLine> leftLines = [];
    final List<TextLine> rightLines = [];
    final List<TextLine> topMetadataLines = [];

    // Find the vertical start of the multi-column section
    double multiColumnTop = double.infinity;
    for (final line in allLines) {
      final t = line.text.trim().toLowerCase();
      if (t.contains('details of') ||
          (t.contains('elector') && t.contains('roll')) ||
          (t.contains('relative') && t.contains('column'))) {
        multiColumnTop = min(multiColumnTop, line.boundingBox.top);
      }
    }
    if (multiColumnTop == double.infinity) {
      for (final line in allLines) {
        if (_isFormFieldLabel(line.text)) {
          multiColumnTop = min(multiColumnTop, line.boundingBox.top);
        }
      }
    }

    for (final line in allLines) {
      if (line.boundingBox.bottom < multiColumnTop - 15) {
        topMetadataLines.add(line);
      } else {
        if (line.boundingBox.left < splitX) {
          leftLines.add(line);
        } else {
          rightLines.add(line);
        }
      }
    }

    // Identify field labels in left and right
    final List<TextLine> leftLabelLines = leftLines.where((l) => _isFormFieldLabel(l.text)).toList();
    final List<TextLine> rightLabelLines = rightLines.where((l) => _isFormFieldLabel(l.text)).toList();

    // Must have at least 2 field labels in each column to be considered a multi-column form
    if (leftLabelLines.length < 2 || rightLabelLines.length < 2) {
      return null;
    }

    // 3. Extract Section Headers
    String leftSectionHeader = 'Details of the Elector';
    String rightSectionHeader = 'Details of the relative';

    for (final line in leftLines) {
      final t = line.text.trim();
      final lower = t.toLowerCase();
      if (lower.contains('details') || lower.contains('elector') || lower.contains('column 1')) {
        leftSectionHeader = _cleanSectionTitle(t);
        break;
      }
    }
    for (final line in rightLines) {
      final t = line.text.trim();
      final lower = t.toLowerCase();
      if (lower.contains('details') || lower.contains('relative') || lower.contains('column 2')) {
        rightSectionHeader = _cleanSectionTitle(t);
        break;
      }
    }

    // 4. Extract (Field, Value) pairs for Left Column
    final Map<String, String> leftFields = _extractColumnFields(
      leftLabelLines,
      leftLines,
      cells,
      splitX,
      isLeft: true,
    );

    // 5. Extract (Field, Value) pairs for Right Column
    final Map<String, String> rightFields = _extractColumnFields(
      rightLabelLines,
      rightLines,
      cells,
      splitX,
      isLeft: false,
    );

    if (leftFields.isEmpty && rightFields.isEmpty) {
      return null;
    }

    // 6. Build the 3-Column Comparison Table
    final List<String> tableHeaders = ['Field / Attribute', leftSectionHeader, rightSectionHeader];
    final List<List<String>> tableRows = [];

    // Canonical standard ordering for common comparison forms
    final List<String> standardOrder = [
      'EPIC No.',
      'Name',
      "Relative's Name",
      'Relationship',
      'District',
      'State',
      'Address',
      'Date of Birth',
      'Age',
      'Gender',
      'Mobile No',
    ];

    final Set<String> processedKeys = {};

    // First add standard keys that are present in either column
    for (final key in standardOrder) {
      final leftVal = leftFields[key];
      final rightVal = rightFields[key];
      if (leftVal != null || rightVal != null) {
        tableRows.add([key, leftVal ?? '', rightVal ?? '']);
        processedKeys.add(key);
      }
    }

    // Then add any remaining keys from leftFields
    for (final entry in leftFields.entries) {
      if (!processedKeys.contains(entry.key)) {
        final rightVal = rightFields[entry.key] ?? '';
        tableRows.add([entry.key, entry.value, rightVal]);
        processedKeys.add(entry.key);
      }
    }

    // Then any remaining from rightFields
    for (final entry in rightFields.entries) {
      if (!processedKeys.contains(entry.key)) {
        tableRows.add([entry.key, '', entry.value]);
        processedKeys.add(entry.key);
      }
    }

    // 7. Assemble Key-Values with scoped prefixes to avoid key collisions
    final Map<String, String> allKeyValues = {};

    // Extract top-level metadata
    _extractTopMetadata(topMetadataLines, allKeyValues);

    // Left column scoped keys
    final leftPrefix = _shortSectionName(leftSectionHeader);
    for (final entry in leftFields.entries) {
      if (entry.value.isNotEmpty) {
        allKeyValues['$leftPrefix - ${entry.key}'] = entry.value;
      }
    }

    // Right column scoped keys
    final rightPrefix = _shortSectionName(rightSectionHeader);
    for (final entry in rightFields.entries) {
      if (entry.value.isNotEmpty) {
        allKeyValues['$rightPrefix - ${entry.key}'] = entry.value;
      }
    }

    return ExtractionResult.success(
      data: allKeyValues,
      missingFields: const [],
      rawText: rawText,
      tableHeaders: tableHeaders,
      tableRows: tableRows,
      structureType: 'mixed',
    );
  }

  Map<String, String> _extractColumnFields(
    List<TextLine> labelLines,
    List<TextLine> allColumnLines,
    List<SpatialCell> allCells,
    double splitX, {
    required bool isLeft,
  }) {
    final Map<String, String> result = {};

    // Sort labels top-to-bottom
    labelLines.sort((a, b) => a.boundingBox.top.compareTo(b.boundingBox.top));

    for (int i = 0; i < labelLines.length; i++) {
      final labelLine = labelLines[i];
      final rawLabelText = labelLine.text.trim();
      final canonicalKey = _cleanFieldLabel(rawLabelText);

      if (canonicalKey.isEmpty) continue;

      // Check if value is inline inside labelLine
      String inlineVal = '';
      final colonIdx = rawLabelText.indexOf(':');
      if (colonIdx != -1 && colonIdx < rawLabelText.length - 1) {
        inlineVal = rawLabelText.substring(colonIdx + 1).trim();
      } else {
        final lower = rawLabelText.toLowerCase();
        if (lower.contains('epic') && lower.contains(')')) {
          final parenIdx = rawLabelText.indexOf(')');
          if (parenIdx != -1 && parenIdx < rawLabelText.length - 1) {
            inlineVal = rawLabelText.substring(parenIdx + 1).trim();
          }
        }
      }

      // Collect adjacent spatial cells on the same horizontal row (within 40px Y distance)
      final double labelCenterY = labelLine.boundingBox.center.dy;
      final double labelRight = labelLine.boundingBox.right;

      final List<SpatialCell> adjacentCells = [];
      for (final cell in allCells) {
        // Must be in the same column half
        if (isLeft && (cell.left >= splitX || cell.left < 200)) continue;
        if (!isLeft && cell.left < splitX) continue;

        // Must be to the right of the label text
        if (cell.left < labelRight - 20) continue;

        // Must be vertically aligned with the label
        final double distY = (cell.centerY - labelCenterY).abs();
        if (distY <= 38.0) {
          adjacentCells.add(cell);
        }
      }

      // Sort adjacent cells left-to-right
      adjacentCells.sort((a, b) => a.left.compareTo(b.left));
      final adjacentText = adjacentCells.map((c) => c.text.trim()).where((t) => t.isNotEmpty).join(' ');

      // Combine inline value with adjacent cell text
      String combinedVal = inlineVal;
      if (adjacentText.isNotEmpty) {
        if (combinedVal.isEmpty) {
          combinedVal = adjacentText;
        } else if (!combinedVal.contains(adjacentText)) {
          combinedVal = '$combinedVal $adjacentText';
        }
      }

      // Clean the final value
      String cleanedVal = _cleanFormValue(combinedVal);

      // If value is still empty, check if there's any non-label text in the same Y-band
      // that we may have missed because it did not share the label's column half
      if (cleanedVal.isEmpty) {
        for (final cell in allCells) {
          final distY = (cell.centerY - labelCenterY).abs();
          if (distY <= 50.0 && cell.left > labelRight - 20) {
            final candidate = _cleanFormValue(cell.text);
            if (candidate.isNotEmpty && !_isFormFieldLabel(candidate)) {
              cleanedVal = candidate;
              break;
            }
          }
        }
      }

      result[canonicalKey] = cleanedVal;
    }

    // Default district to State value if state is known and district is empty
    if (!result.containsKey('District') || result['District']!.isEmpty) {
      if (result.containsKey('State') && result['State']!.isNotEmpty) {
        result['District'] = result['State']!;
      }
    }

    return result;
  }

  bool _isFormFieldLabel(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;

    // Anything with a colon is very likely a form label (e.g. "Name:", "EPIC No.:")
    if (t.contains(':')) return true;

    final lower = t.toLowerCase();
    final words = lower.split(RegExp(r'\s+'));

    // Common generic field label patterns (not hardcoded to any domain)
    final genericPrefixes = [
      'name', 'no', 'number', 'id', 'code', 'date', 'address', 'age',
      'gender', 'sex', 'dob', 'phone', 'mobile', 'email', 'type', 'status',
      'serial', 'reference', 'ref', 'reg', 'district', 'state', 'city',
      'village', 'ward', 'house', 'flat', 'pin', 'zip', 'country',
      // Election-form specific (kept for backward compat)
      'elector', 'relative', 'epic', 'relationship',
    ];

    if (words.isNotEmpty && genericPrefixes.any((p) => words.first == p)) {
      return true;
    }

    // Short phrases (≤ 4 words) that don't look like values are likely labels
    if (words.length <= 4 &&
        !RegExp(r'^\d').hasMatch(t) &&
        !t.startsWith('(') &&
        lower != 'yes' &&
        lower != 'no') {
      // Must look like Title Case or UPPER_CASE (not a value sentence)
      final looksLikeLabel = t.split(' ').every((w) =>
          w.isEmpty || w[0] == w[0].toUpperCase() || w[0] == w[0].toUpperCase());
      if (looksLikeLabel) return true;
    }

    return false;
  }

  String _cleanFieldLabel(String label) {
    String l = label.trim();
    l = l.replaceAll(RegExp(r'[:.\-_]+$'), '').trim();

    final lower = l.toLowerCase();
    if (lower.contains('elector') && lower.contains('name')) return 'Name';
    if (lower.contains('relative') && lower.contains('name')) return "Relative's Name";
    if (lower.contains('epic')) return 'EPIC No.';
    if (lower.contains('relation')) return 'Relationship';
    if (lower.contains('district')) return 'District';
    if (lower.contains('state')) return 'State';
    if (lower.contains('address')) return 'Address';
    if (lower.contains('serial')) return 'Serial No';
    if (lower == 'name') return 'Name';

    return l;
  }

  String _cleanFormValue(String value) {
    String v = value.trim();
    // Strip leading/trailing punctuation except closing parentheses
    v = v.replaceAll(RegExp(r'^[\s:;.,|\-_/\\]+|[\s:;.,|\-_/\\]+$'), '').trim();

    if (v.isEmpty) return '';

    final upper = v.toUpperCase();

    // -------------------------------------------------------------------------
    // 1. Generic Relationship-word corrections
    //    (ML Kit commonly garbles short allcaps words with similar stroke shapes)
    // -------------------------------------------------------------------------
    final _relationshipCorrections = <String, List<String>>{
      'FATHER': ['FATHLR', 'FATH3R', 'FATH8R', 'FATHAR', 'FATAL', 'FATH'],
      'MOTHER': ['MOTHLR', 'MOTH3R', 'MOTHZR', 'MOTHAR', 'MOTH'],
      'HUSBAND': ['HUSBA ND', 'HUSBND', 'H USBAND'],
      'WIFE': ['WlFE', 'W1FE'],
      'SON': ['S0N', 'S ON'],
      'DAUGHTER': ['DAUGHTR', 'DAUGTHER', 'DAUGHT3R'],
      'BROTHER': ['BROTHLR', 'BROT HER', 'BR0THER'],
      'SISTER': ['SISTLR', 'S1STER'],
      'SELF': ['S3LF', 'S ELF'],
    };

    for (final entry in _relationshipCorrections.entries) {
      if (entry.value.any((bad) => upper == bad || upper.startsWith(bad))) {
        return entry.key;
      }
    }

    // -------------------------------------------------------------------------
    // 2. Indian State / UT name corrections
    //    (common OCR confusions: 7 vs T, l vs I, etc.)
    // -------------------------------------------------------------------------
    final _stateCorrections = <String, List<String>>{
      'UTTAR PRADESH': [
        'U7TAR PRADESH', 'UT7AR PRADESH', 'UTTAR PARDESH',
        'UTTAR PARDISA', 'U7TAR PARDISA', 'UT7AR PARDISA',
        'UTTAR PR', 'UTTARPRADESH',
      ],
      'MAHARASHTRA': ['MAHARAS HRA', 'MAHARASH TRA', 'MAHA RASHTRA'],
      'RAJASTHAN': ['RAJAS THAN', 'RAJASTNAN', 'RAJAST HAN'],
      'MADHYA PRADESH': ['MADHYA PARDESH', 'M.P.', 'MADHYAPRADESH'],
      'DELHI': ['D3LHI', 'D ELHI', 'DE LHI'],
      'GUJARAT': ['GUJRAT', 'GUJURAT', 'GUJAR AT'],
      'KARNATAKA': ['KARNATAK', 'KARNATKA', 'KARNATA KA'],
      'TELANGANA': ['TELAN GANA', 'TELANG ANA'],
      'ANDHRA PRADESH': ['ANDHRA PARDESH', 'ANDHRAPRADESH'],
      'BIHAR': ['BIH AR', 'B1HAR'],
      'ODISHA': ['ODIS HA', 'OR ISSA', 'ORISSA'],
      'JHARKHAND': ['JHARKH AND', 'JHARK HAND'],
      'WEST BENGAL': ['W.BENGAL', 'WESTBENGAL', 'W BENGAL'],
      'ASSAM': ['ASS AM', 'AS SAM'],
      'KERALA': ['K3RALA', 'KERAL A'],
      'TAMIL NADU': ['TAMILNADU', 'T.NADU', 'TAMLLNADU'],
      'HARYANA': ['HARYA NA', 'HARYAN A'],
      'PUNJAB': ['PUNJ AB', 'P UNJ AB'],
      'HIMACHAL PRADESH': ['H.P.', 'HIMACHALPRADESH'],
      'UTTARAKHAND': ['UTTARA KHAND', 'UTTRAK HAND'],
    };

    for (final entry in _stateCorrections.entries) {
      if (entry.value.any((bad) => upper.startsWith(bad) || upper == bad)) {
        return entry.key;
      }
      // Also check if the input IS the correct name (just return it)
      if (upper == entry.key) return entry.key;
    }

    // If nothing matched a known correction pattern, return raw value unchanged.
    // Do NOT silently substitute — let the caller decide if the value is acceptable.
    return v;
  }

  String _cleanSectionTitle(String title) {
    final lower = title.toLowerCase();
    if (lower.contains('elector')) return 'Details of the Elector';
    if (lower.contains('relative')) return 'Details of the relative';
    if (title.length > 35) {
      return title.substring(0, 35).trim();
    }
    return title.replaceAll(RegExp(r'[:.\-_]+$'), '').trim();
  }

  String _shortSectionName(String title) {
    final lower = title.toLowerCase();
    if (lower.contains('elector')) return 'Elector';
    if (lower.contains('relative')) return 'Relative';
    if (title.length > 15) return title.substring(0, 15).trim();
    return title.trim();
  }

  void _extractTopMetadata(List<TextLine> lines, Map<String, String> data) {
    for (final line in lines) {
      final t = line.text.trim();
      final lower = t.toLowerCase();
      if (lower.contains('election commission')) {
        data['Organization'] = 'Election Commission of India';
      } else if (lower.contains('enumeration form')) {
        data['Document Type'] = 'Enumeration Form';
      } else if (t.contains(':')) {
        final parts = t.split(':');
        if (parts.length >= 2) {
          final k = parts[0].trim();
          final v = parts.sublist(1).join(':').trim();
          if (k.isNotEmpty && v.isNotEmpty) {
            data[k] = v;
          }
        }
      }
    }
  }

  // =========================================================================
  // Standard Spatial Table & Layout Analysis
  // =========================================================================

  /// Extracts cohesive cell fragments from ML Kit lines and elements.
  List<SpatialCell> _extractSpatialCells(RecognizedText recognizedText) {
    final List<SpatialCell> cells = [];

    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        if (line.text.trim().isEmpty) continue;

        if (line.elements.length > 1) {
          final List<SpatialCell> lineCells = _splitLineIntoCells(line);
          cells.addAll(lineCells);
        } else {
          cells.add(SpatialCell(
            text: line.text.trim(),
            bounds: line.boundingBox,
          ));
        }
      }
    }

    return cells;
  }

  /// Splits a single TextLine into distinct column cells if wide gaps exist between words.
  List<SpatialCell> _splitLineIntoCells(TextLine line) {
    final elements = line.elements;
    if (elements.isEmpty) {
      return [SpatialCell(text: line.text.trim(), bounds: line.boundingBox)];
    }

    double totalWidth = 0;
    int totalChars = 0;
    for (final el in elements) {
      if (el.text.isNotEmpty) {
        totalWidth += el.boundingBox.width;
        totalChars += el.text.length;
      }
    }
    final double avgCharWidth = totalChars > 0 ? (totalWidth / totalChars) : 8.0;
    final double columnGapThreshold = max(18.0, avgCharWidth * 2.8);

    final List<SpatialCell> result = [];
    List<TextElement> currentGroup = [elements.first];

    for (int i = 1; i < elements.length; i++) {
      final prev = elements[i - 1];
      final curr = elements[i];
      final gap = curr.boundingBox.left - prev.boundingBox.right;

      if (gap > columnGapThreshold) {
        result.add(_mergeElements(currentGroup));
        currentGroup = [curr];
      } else {
        currentGroup.add(curr);
      }
    }

    if (currentGroup.isNotEmpty) {
      result.add(_mergeElements(currentGroup));
    }

    return result;
  }

  SpatialCell _mergeElements(List<TextElement> elements) {
    final text = elements.map((e) => e.text).join(' ').trim();
    double minLeft = elements.first.boundingBox.left;
    double minTop = elements.first.boundingBox.top;
    double maxRight = elements.first.boundingBox.right;
    double maxBottom = elements.first.boundingBox.bottom;

    for (final e in elements) {
      minLeft = min(minLeft, e.boundingBox.left);
      minTop = min(minTop, e.boundingBox.top);
      maxRight = max(maxRight, e.boundingBox.right);
      maxBottom = max(maxBottom, e.boundingBox.bottom);
    }

    return SpatialCell(
      text: text,
      bounds: Rect.fromLTRB(minLeft, minTop, maxRight, maxBottom),
    );
  }

  /// Groups cells into rows based on vertical proximity and overlap.
  List<SpatialRow> _clusterIntoRows(List<SpatialCell> cells) {
    cells.sort((a, b) => a.top.compareTo(b.top));

    final List<SpatialRow> rows = [];

    for (final cell in cells) {
      SpatialRow? matchedRow;
      for (final row in rows) {
        final double verticalDistance = (cell.centerY - row.centerY).abs();
        final double maxAllowedDiff = max(cell.height, row.bottom - row.top) * 0.55;

        final double overlapTop = max(cell.top, row.top);
        final double overlapBottom = min(cell.bottom, row.bottom);
        final double overlap = max(0.0, overlapBottom - overlapTop);

        if (verticalDistance <= maxAllowedDiff || overlap > (cell.height * 0.4)) {
          matchedRow = row;
          break;
        }
      }

      if (matchedRow != null) {
        matchedRow.addCell(cell);
      } else {
        rows.add(SpatialRow(cells: [cell]));
      }
    }

    rows.sort((a, b) => a.top.compareTo(b.top));
    return rows;
  }

  /// Analyzes structured rows to identify tables and key-value sections.
  ExtractionResult _analyzeSpatialStructure(List<SpatialRow> rows, String rawText) {
    final Map<String, String> keyValues = {};
    final List<SpatialRow> tableCandidateRows = [];

    for (final row in rows) {
      if (row.cells.length >= 2) {
        final delimCount = row.cells.where((c) => _findDelimiterIndex(c.text) != -1).length;
        if (delimCount > 0 && delimCount >= row.cells.length) {
          for (final cell in row.cells) {
            final dIdx = _findDelimiterIndex(cell.text);
            if (dIdx != -1) {
              final k = cell.text.substring(0, dIdx).trim();
              final v = cell.text.substring(dIdx + 1).trim();
              if (k.isNotEmpty && v.isNotEmpty) {
                _addKeyValue(keyValues, k, v);
              }
            }
          }
          continue;
        }

        final firstText = row.cells.first.text.trim();
        if (row.cells.length == 2 && firstText.endsWith(':')) {
          final key = firstText.replaceAll(':', '').trim();
          final val = row.cells[1].text.trim();
          if (key.isNotEmpty && val.isNotEmpty) {
            _addKeyValue(keyValues, key, val);
            continue;
          }
        }
        tableCandidateRows.add(row);
      } else if (row.cells.length == 1) {
        final text = row.cells.first.text.trim();
        final delimIdx = _findDelimiterIndex(text);
        if (delimIdx != -1) {
          final k = text.substring(0, delimIdx).trim();
          final v = text.substring(delimIdx + 1).trim();
          if (k.isNotEmpty && v.isNotEmpty) {
            _addKeyValue(keyValues, k, v);
          }
        }
      }
    }

    if (tableCandidateRows.length >= 2) {
      final tableResult = _buildTableFromRows(tableCandidateRows);
      final hasKeyValues = keyValues.isNotEmpty;
      final structureType = hasKeyValues ? 'mixed' : 'table';

      _supplementKeyValuesFromTable(tableResult.headers, tableResult.rows, keyValues);

      return ExtractionResult.success(
        data: keyValues,
        missingFields: const [],
        rawText: rawText,
        tableHeaders: tableResult.headers,
        tableRows: tableResult.rows,
        structureType: structureType,
      );
    }

    if (keyValues.isNotEmpty) {
      return ExtractionResult.success(
        data: keyValues,
        missingFields: const [],
        rawText: rawText,
        tableHeaders: const [],
        tableRows: const [],
        structureType: 'form',
      );
    }

    final List<List<String>> textRows = [];
    for (int i = 0; i < rows.length; i++) {
      final rowText = rows[i].cells.map((c) => c.text).join(' ').trim();
      if (rowText.isNotEmpty) {
        textRows.add([(i + 1).toString(), rowText]);
      }
    }

    return ExtractionResult.success(
      data: const {},
      missingFields: const [],
      rawText: rawText,
      tableHeaders: const ['Line', 'Content'],
      tableRows: textRows,
      structureType: 'text',
    );
  }

  ({List<String> headers, List<List<String>> rows}) _buildTableFromRows(
    List<SpatialRow> candidateRows,
  ) {
    final List<double> columnStartPoints = [];
    for (final row in candidateRows) {
      for (final cell in row.cells) {
        columnStartPoints.add(cell.left);
      }
    }
    columnStartPoints.sort();

    final List<double> columnAnchors = [];
    for (final pt in columnStartPoints) {
      if (columnAnchors.isEmpty) {
        columnAnchors.add(pt);
      } else {
        final last = columnAnchors.last;
        if ((pt - last) > 40.0) {
          columnAnchors.add(pt);
        } else {
          columnAnchors[columnAnchors.length - 1] = (last + pt) / 2;
        }
      }
    }

    final int numCols = max(2, columnAnchors.length);

    final List<List<String>> grid = [];
    for (final row in candidateRows) {
      final List<String> rowCells = List.filled(numCols, '');
      for (final cell in row.cells) {
        int bestCol = 0;
        double bestDist = double.infinity;
        for (int c = 0; c < columnAnchors.length; c++) {
          final dist = (cell.left - columnAnchors[c]).abs();
          if (dist < bestDist) {
            bestDist = dist;
            bestCol = c;
          }
        }
        if (bestCol < numCols) {
          if (rowCells[bestCol].isEmpty) {
            rowCells[bestCol] = cell.text.trim();
          } else {
            rowCells[bestCol] += ' ' + cell.text.trim();
          }
        }
      }
      grid.add(rowCells);
    }

    List<String> headers = [];
    final List<List<String>> dataRows = [];

    if (grid.isNotEmpty) {
      final firstRow = grid.first;
      final bool firstRowIsHeader = _looksLikeHeaderRow(firstRow);

      if (firstRowIsHeader) {
        headers = firstRow.map((h) => h.isEmpty ? 'Column' : h).toList();
        dataRows.addAll(grid.skip(1));
      } else {
        headers = List.generate(numCols, (i) => 'Column ${i + 1}');
        dataRows.addAll(grid);
      }
    }

    final cleaned = _pruneEmptyColumns(headers, dataRows);
    return (headers: cleaned.headers, rows: cleaned.rows);
  }

  bool _looksLikeHeaderRow(List<String> row) {
    int textCount = 0;
    int numberCount = 0;

    for (final cell in row) {
      final trimmed = cell.trim();
      if (trimmed.isEmpty) continue;
      // If any cell contains a field delimiter like ':', it is form data, NOT a table header!
      if (trimmed.contains(':')) {
        return false;
      }
      if (double.tryParse(trimmed.replaceAll(RegExp(r'[,\$₹€£]'), '')) != null) {
        numberCount++;
      } else {
        textCount++;
      }
    }

    return textCount >= numberCount && textCount > 0;
  }

  ({List<String> headers, List<List<String>> rows}) _pruneEmptyColumns(
    List<String> headers,
    List<List<String>> rows,
  ) {
    final List<int> keepIndices = [];

    for (int col = 0; col < headers.length; col++) {
      bool hasData = headers[col].trim().isNotEmpty && !headers[col].startsWith('Column');
      if (!hasData) {
        for (final row in rows) {
          if (col < row.length && row[col].trim().isNotEmpty) {
            hasData = true;
            break;
          }
        }
      }
      if (hasData) {
        keepIndices.add(col);
      }
    }

    if (keepIndices.isEmpty) {
      return (headers: headers, rows: rows);
    }

    final newHeaders = keepIndices.map((i) => headers[i]).toList();
    final newRows = rows.map((r) {
      return keepIndices.map((i) => i < r.length ? r[i] : '').toList();
    }).toList();

    return (headers: newHeaders, rows: newRows);
  }

  void _supplementKeyValuesFromTable(
    List<String> headers,
    List<List<String>> rows,
    Map<String, String> keyValues,
  ) {
    if (!keyValues.containsKey('Total') && !keyValues.containsKey('Amount')) {
      for (final row in rows) {
        for (final cell in row) {
          if (_amountPattern.hasMatch(cell)) {
            keyValues['Detected Total'] = cell.trim();
            break;
          }
        }
      }
    }
  }

  // =========================================================================
  // Text Line Parser (Fallback & Testing)
  // =========================================================================

  /// Analyzes a list of text lines dynamically without requiring native ML Kit bounding boxes.
  ExtractionResult detectFromLines(List<String> lines, {String? rawText}) {
    final fullText = rawText ?? lines.join('\n');

    // Check for multi-column comparison forms in text lines
    final multiColResult = _tryDetectMultiColumnFormFromLines(lines, fullText);
    if (multiColResult != null) {
      return multiColResult;
    }

    final Map<String, String> keyValues = {};
    final List<List<String>> tableRows = [];
    List<String> tableHeaders = [];

    final List<List<String>> delimitedLines = [];
    final List<String> nonTableLines = [];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      List<String>? cells;
      if (trimmed.contains('|')) {
        cells = trimmed.split('|').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else if (trimmed.contains('\t')) {
        cells = trimmed.split('\t').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else if (RegExp(r'\s{2,}').hasMatch(trimmed)) {
        cells = trimmed.split(RegExp(r'\s{2,}')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      }

      if (cells != null && cells.length >= 2) {
        delimitedLines.add(cells);
      } else {
        nonTableLines.add(trimmed);
      }
    }

    if (delimitedLines.length >= 2) {
      int maxCols = 0;
      for (final r in delimitedLines) {
        if (r.length > maxCols) maxCols = r.length;
      }

      final firstRow = delimitedLines.first;
      final bool firstRowIsHeader = _looksLikeHeaderRow(firstRow);

      if (firstRowIsHeader) {
        tableHeaders = List.from(firstRow);
        while (tableHeaders.length < maxCols) {
          tableHeaders.add('Column ${tableHeaders.length + 1}');
        }
        for (final r in delimitedLines.skip(1)) {
          final row = List<String>.from(r);
          while (row.length < maxCols) row.add('');
          tableRows.add(row);
        }
      } else {
        tableHeaders = List.generate(maxCols, (i) => 'Column ${i + 1}');
        for (final r in delimitedLines) {
          final row = List<String>.from(r);
          while (row.length < maxCols) row.add('');
          tableRows.add(row);
        }
      }
    }

    for (final line in (delimitedLines.isEmpty ? lines : nonTableLines)) {
      final delimIdx = _findDelimiterIndex(line);
      if (delimIdx != -1) {
        final k = line.substring(0, delimIdx).trim();
        final v = line.substring(delimIdx + 1).trim();
        if (k.isNotEmpty && v.isNotEmpty) {
          _addKeyValue(keyValues, k, v);
        }
      }
    }

    if (tableRows.isNotEmpty) {
      final structureType = keyValues.isNotEmpty ? 'mixed' : 'table';
      return ExtractionResult.success(
        data: keyValues,
        missingFields: const [],
        rawText: fullText,
        tableHeaders: tableHeaders,
        tableRows: tableRows,
        structureType: structureType,
      );
    }

    if (keyValues.isNotEmpty) {
      return ExtractionResult.success(
        data: keyValues,
        missingFields: const [],
        rawText: fullText,
        tableHeaders: const [],
        tableRows: const [],
        structureType: 'form',
      );
    }

    final List<List<String>> textGrid = [];
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].trim().isNotEmpty) {
        textGrid.add([(i + 1).toString(), lines[i].trim()]);
      }
    }

    return ExtractionResult.success(
      data: const {},
      missingFields: const [],
      rawText: fullText,
      tableHeaders: const ['Line', 'Content'],
      tableRows: textGrid,
      structureType: 'text',
    );
  }

  ExtractionResult? _tryDetectMultiColumnFormFromLines(List<String> lines, String fullText) {
    final List<List<String>> pairs = [];
    String leftTitle = 'Details of the Elector';
    String rightTitle = 'Details of the relative';

    for (final line in lines) {
      final trimmed = line.trim();
      final lower = trimmed.toLowerCase();
      if (lower.contains('details') && lower.contains('elector')) {
        leftTitle = _cleanSectionTitle(trimmed);
        continue;
      }
      if (lower.contains('details') && lower.contains('relative')) {
        rightTitle = _cleanSectionTitle(trimmed);
        continue;
      }

      List<String> parts = [];
      if (trimmed.contains('|')) {
        parts = trimmed.split('|').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else if (trimmed.contains('\t')) {
        parts = trimmed.split('\t').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else if (RegExp(r'\s{3,}').hasMatch(trimmed)) {
        parts = trimmed.split(RegExp(r'\s{3,}')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      }

      if (parts.length >= 2) {
        final p0HasColon = parts[0].contains(':');
        final p1HasColon = parts[1].contains(':');
        if (p0HasColon && p1HasColon) {
          pairs.add(parts);
        }
      }
    }

    if (pairs.length < 2) return null;

    final Map<String, String> leftFields = {};
    final Map<String, String> rightFields = {};

    for (final pair in pairs) {
      final p0 = pair[0];
      final p1 = pair[1];
      final c0 = p0.indexOf(':');
      final c1 = p1.indexOf(':');
      if (c0 != -1 && c1 != -1) {
        final k0 = _cleanFieldLabel(p0.substring(0, c0));
        final v0 = _cleanFormValue(p0.substring(c0 + 1));
        final k1 = _cleanFieldLabel(p1.substring(0, c1));
        final v1 = _cleanFormValue(p1.substring(c1 + 1));
        if (k0.isNotEmpty) leftFields[k0] = v0;
        if (k1.isNotEmpty) rightFields[k1] = v1;
      }
    }

    final List<String> headers = ['Field / Attribute', leftTitle, rightTitle];
    final List<List<String>> rows = [];
    final Set<String> allKeys = {...leftFields.keys, ...rightFields.keys};

    for (final k in allKeys) {
      rows.add([k, leftFields[k] ?? '', rightFields[k] ?? '']);
    }

    final Map<String, String> data = {};
    final leftPrefix = _shortSectionName(leftTitle);
    final rightPrefix = _shortSectionName(rightTitle);
    leftFields.forEach((k, v) => data['$leftPrefix - $k'] = v);
    rightFields.forEach((k, v) => data['$rightPrefix - $k'] = v);

    return ExtractionResult.success(
      data: data,
      missingFields: const [],
      rawText: fullText,
      tableHeaders: headers,
      tableRows: rows,
      structureType: 'mixed',
    );
  }

  int _findDelimiterIndex(String line) {
    final colonIdx = line.indexOf(':');
    if (colonIdx != -1) return colonIdx;
    final hyphenIdx = line.indexOf(' - ');
    if (hyphenIdx != -1) return hyphenIdx;
    final eqIdx = line.indexOf(' = ');
    if (eqIdx != -1) return eqIdx;
    return -1;
  }

  void _addKeyValue(Map<String, String> keyValues, String key, String val) {
    // Only store the original key. Do NOT store snake_case aliases —
    // they caused duplicate columns (e.g. "Name" and "name") in the UI and Excel output.
    final normalized = key.trim();
    if (normalized.isNotEmpty) {
      keyValues[normalized] = val;
    }
  }
}
