import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../config/document_schema.dart';
import '../models/extraction_result.dart';
import 'structure_detector.dart';

/// Layout-aware parser that extracts structured key-value pairs from OCR output
/// using delimiter-based, positional/tabular, and regex pattern strategies,
/// with automatic 2D spatial table and structure detection.
class FormatParserService {
  final DynamicStructureDetector _detector;

  FormatParserService({DynamicStructureDetector? detector})
      : _detector = detector ?? DynamicStructureDetector();

  /// Date extraction regular expressions (supports DD/MM/YYYY, YYYY-MM-DD, Month DD, YYYY)
  static final RegExp datePattern = RegExp(
    r'\b(\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4}[/-]\d{1,2}[/-]\d{1,2}|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2},?\s+\d{4})\b',
    caseSensitive: false,
  );

  /// Currency and decimal amount regular expression (supports $, ₹, €, £, or bare decimals)
  static final RegExp amountPattern = RegExp(
    r'(?:[\$₹€£]|USD|EUR|INR|GBP)?\s*(\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{2})\b',
  );

  /// Standard invoice / document ID pattern
  static final RegExp idPattern = RegExp(
    r'\b([A-Z0-9]{2,}[-/#][A-Z0-9-]+|\d{4,})\b',
  );

  /// Parses an ML Kit RecognizedText instance according to the provided schema.
  ExtractionResult parseRecognizedText(
    RecognizedText recognizedText, {
    DocumentSchema schema = DocumentSchema.active,
    bool isOrangeYellow = false,
  }) {
    // If schema is dynamic or generic, run advanced 2D computer-vision structure detector
    if (schema.id == 'dynamic' || schema.fields.isEmpty) {
      return _detector.detectFromRecognizedText(recognizedText);
    }

    // 1. Collect all lines across blocks
    final List<TextLine> allLines = [];
    for (final block in recognizedText.blocks) {
      allLines.addAll(block.lines);
    }

    // 2. Spatially sort lines: top-to-bottom, left-to-right
    allLines.sort((a, b) {
      final aTop = a.boundingBox.top;
      final bTop = b.boundingBox.top;
      // If within 10px vertical distance, treat as same line and sort by left
      if ((aTop - bTop).abs() <= 10.0) {
        return a.boundingBox.left.compareTo(b.boundingBox.left);
      }
      return aTop.compareTo(bTop);
    });

    final List<String> lineTexts = allLines
        .map((l) => l.text.trim())
        .where((text) => text.isNotEmpty)
        .toList();

    // Run schema parser, and also run 2D spatial detector to extract any tables
    final result = parseLines(
      lineTexts,
      schema: schema,
      rawText: recognizedText.text,
      isOrangeYellow: isOrangeYellow,
    );

    final Map<String, String> updatedData = Map<String, String>.from(result.data);

    // Document Type Logic for BNF LR No:
    // * Orange/Yellow handwritten-image: Extract only the LR No.; do not treat any number as BNF LR No.
    // * White printed page: If a number is handwritten/penciled at top-left or top-right, treat it as BNF LR No.
    // * If there is no handwritten/pencil number on the white page, leave BNF LR No blank (skip the value).
    if (isOrangeYellow) {
      updatedData['BNF LR No'] = '';
    } else {
      // Spatially detect handwritten/pencil BNF LR No near top-left or top-right corners
      final handwrittenBnf = _detectHandwrittenBnfLrNoFromLines(allLines);
      if (handwrittenBnf != null && handwrittenBnf.isNotEmpty) {
        updatedData['BNF LR No'] = handwrittenBnf;
      } else {
        updatedData['BNF LR No'] = '';
      }
    }

    // If detector found tables, attach them to the result
    final spatialResult = _detector.detectFromRecognizedText(recognizedText);
    return ExtractionResult.success(
      data: updatedData,
      missingFields: result.missingFields.where((f) => f != 'BNF LR No' || (updatedData['BNF LR No']?.isEmpty ?? true)).toList(),
      rawText: recognizedText.text,
      tableHeaders: spatialResult.hasTable ? spatialResult.tableHeaders : result.tableHeaders,
      tableRows: spatialResult.hasTable ? spatialResult.tableRows : result.tableRows,
      structureType: spatialResult.hasTable ? 'mixed' : result.structureType,
    );
  }

  /// Parses an ordered list of text lines according to the provided schema.
  /// This pure method is directly unit-testable without ML Kit native dependencies.
  ExtractionResult parseLines(
    List<String> lines, {
    DocumentSchema schema = DocumentSchema.active,
    String? rawText,
    bool isOrangeYellow = false,
  }) {
    // If schema is dynamic or generic, delegate directly to the dynamic structure detector
    if (schema.id == 'dynamic' || schema.fields.isEmpty) {
      return _detector.detectFromLines(lines, rawText: rawText);
    }

    final Map<String, String> data = {};
    final String fullText = rawText ?? lines.join('\n');

    // Initialize all schema fields with empty values
    for (final field in schema.fields) {
      data[field.key] = '';
    }

    // Track which lines have already been consumed
    final Set<int> consumedLineIndices = {};

    // =========================================================================
    // Pattern 1: Delimiter-based extraction ("Key: Value", "Key - Value")
    // =========================================================================
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final delimiterIndex = _findFirstDelimiter(line);
      if (delimiterIndex != -1) {
        final rawKey = line.substring(0, delimiterIndex).trim();
        final rawVal = line.substring(delimiterIndex + 1).trim();

        if (rawVal.isNotEmpty) {
          final matchedField = _matchField(rawKey, schema.fields);
          if (matchedField != null && (data[matchedField.key]?.isEmpty ?? true)) {
            data[matchedField.key] = _cleanValue(rawVal);
            consumedLineIndices.add(i);
          }
        }
      }
    }

    // =========================================================================
    // Pattern 2: Positional / Tabular extraction (Header line, then value on next line)
    // =========================================================================
    for (int i = 0; i < lines.length - 1; i++) {
      if (consumedLineIndices.contains(i)) continue;

      final currentLine = lines[i];
      final cleanLabel = _normalizeString(currentLine);

      // Check if current line acts as a standalone label
      for (final field in schema.fields) {
        if ((data[field.key]?.isEmpty ?? true) && _matchesFieldLabel(cleanLabel, field)) {
          // Look ahead to next unconsumed non-label line
          for (int next = i + 1; next < lines.length && next <= i + 2; next++) {
            if (consumedLineIndices.contains(next)) continue;

            final candidateValue = lines[next].trim();
            // Ensure candidate value isn't another recognized field header
            if (candidateValue.isNotEmpty && !_isAnyFieldHeader(candidateValue, schema.fields)) {
              data[field.key] = _cleanValue(candidateValue);
              consumedLineIndices.add(i);
              consumedLineIndices.add(next);
              break;
            }
          }
        }
      }
    }

    // =========================================================================
    // Pattern 3: Regex Token Fallback for remaining empty fields
    // =========================================================================
    for (final field in schema.fields) {
      if ((data[field.key]?.isEmpty ?? true)) {
        final extractedValue = _extractWithRegex(field, lines, fullText);
        if (extractedValue != null && extractedValue.isNotEmpty) {
          data[field.key] = extractedValue;
        }
      }
    }

    // Ensure LR No * is filled if grno (*) was found (or vice-versa)
    if ((data['LR No *']?.isEmpty ?? true) && (data['grno (*)']?.isNotEmpty ?? false)) {
      data['LR No *'] = data['grno (*)']!;
    } else if ((data['grno (*)']?.isEmpty ?? true) && (data['LR No *']?.isNotEmpty ?? false)) {
      data['grno (*)'] = data['LR No *']!;
    }

    // Detect handwritten BNF LR No from top header lines (only for white printed pages)
    if (!isOrangeYellow && (data['BNF LR No']?.isEmpty ?? true)) {
      final bnfFromLines = _detectBnfLrNoFromHeaderLines(lines);
      if (bnfFromLines != null && bnfFromLines.isNotEmpty) {
        data['BNF LR No'] = bnfFromLines;
      }
    }
    if (isOrangeYellow) {
      data['BNF LR No'] = '';
    }

    // Determine missing required fields
    final List<String> missingFields = [];
    for (final field in schema.fields) {
      final value = data[field.key]?.trim() ?? '';
      if (field.isRequired && value.isEmpty) {
        missingFields.add(field.key);
      }
    }

    // Also run table structure detector to preserve any tabular rows & columns
    final detectedStructure = _detector.detectFromLines(lines, rawText: rawText);

    return ExtractionResult.success(
      data: data,
      missingFields: missingFields,
      rawText: fullText,
      tableHeaders: detectedStructure.tableHeaders,
      tableRows: detectedStructure.tableRows,
      structureType: detectedStructure.hasTable ? 'mixed' : 'form',
    );
  }

  /// Finds index of first valid key-value delimiter (: or - or =)
  int _findFirstDelimiter(String line) {
    final colonIdx = line.indexOf(':');
    if (colonIdx != -1) return colonIdx;

    final dashIdx = line.indexOf(' - ');
    if (dashIdx != -1) return dashIdx + 1;

    final equalIdx = line.indexOf('=');
    if (equalIdx != -1) return equalIdx;

    return -1;
  }

  /// Checks if label matches field key or any alias
  DocumentField? _matchField(String rawKey, List<DocumentField> fields) {
    final normalized = _normalizeString(rawKey);
    for (final field in fields) {
      if (_matchesFieldLabel(normalized, field)) {
        return field;
      }
    }
    return null;
  }

  bool _matchesFieldLabel(String normalized, DocumentField field) {
    final normFieldKey = _normalizeString(field.displayName);
    if (normalized == normFieldKey || normalized == _normalizeString(field.key)) {
      return true;
    }
    for (final alias in field.aliases) {
      final normAlias = _normalizeString(alias);
      if (normalized == normAlias || normalized.startsWith('$normAlias ')) {
        return true;
      }
    }
    return false;
  }

  bool _isAnyFieldHeader(String line, List<DocumentField> fields) {
    final norm = _normalizeString(line);
    for (final f in fields) {
      if (_matchesFieldLabel(norm, f)) return true;
    }
    return false;
  }

  /// Token-based regex fallback extraction
  String? _extractWithRegex(
    DocumentField field,
    List<String> lines,
    String fullText,
  ) {
    // 1. Custom field pattern if defined
    if (field.pattern != null) {
      final match = field.pattern!.firstMatch(fullText);
      if (match != null) {
        return match.group(1) ?? match.group(0);
      }
    }

    // 2. Date heuristics
    if (field.key.contains('date')) {
      for (final line in lines) {
        final match = datePattern.firstMatch(line);
        if (match != null) {
          return match.group(0)?.trim();
        }
      }
    }

    // 3. Amount / Total heuristics
    if (field.key.contains('amount') ||
        field.key.contains('total') ||
        field.key == 'subtotal' ||
        field.key == 'tax') {
      // Find line mentioning the key, aliases, or generic terms
      for (int i = lines.length - 1; i >= 0; i--) {
        final line = lines[i];
        final norm = _normalizeString(line);
        final match = amountPattern.firstMatch(line);
        if (match != null) {
          final keywords = [
            field.key,
            _normalizeString(field.displayName),
            ...field.aliases.map(_normalizeString),
            'total',
            'amount',
            'sum',
            'due',
            'charge',
            'price',
          ];
          if (keywords.any((kw) => kw.isNotEmpty && norm.contains(kw))) {
            return match.group(0)?.trim();
          }
        }
      }
    }

    // 4. Printed Consignment Note / LR No heuristics (e.g. 9415364)
    if (field.key == 'LR No *' || field.key == 'grno (*)' || field.key == 'grno') {
      for (final line in lines) {
        final norm = _normalizeString(line);
        if (norm.contains('cnote') || norm.contains('c note') || norm.contains('consignment note') || norm.contains('lr no') || norm.contains('bilty no')) {
          final match = RegExp(r'\b\d{4,10}\b').firstMatch(line);
          if (match != null) {
            return match.group(0)?.trim();
          }
        }
      }
    }

    // 5. Invoice / Receipt ID heuristics
    if (field.key.contains('no') || field.key.contains('id') || field.key.contains('number')) {
      for (final line in lines) {
        final norm = _normalizeString(line);
        if (norm.contains('inv') || norm.contains('bill') || norm.contains('receipt') || norm.contains('order')) {
          final match = idPattern.firstMatch(line);
          if (match != null) {
            return match.group(0)?.trim();
          }
        }
      }
    }

    return null;
  }

  /// Spatially identifies the handwritten/pencil BNF LR No near the top-left or top-right corner.
  String? _detectHandwrittenBnfLrNoFromLines(List<TextLine> allLines) {
    if (allLines.isEmpty) return null;

    double minY = double.infinity;
    double maxY = -double.infinity;
    double minX = double.infinity;
    double maxX = -double.infinity;

    for (final line in allLines) {
      final box = line.boundingBox;
      if (box.top < minY) minY = box.top;
      if (box.bottom > maxY) maxY = box.bottom;
      if (box.left < minX) minX = box.left;
      if (box.right > maxX) maxX = box.right;
    }

    final totalHeight = maxY - minY;
    final totalWidth = maxX - minX;
    if (totalHeight <= 0 || totalWidth <= 0) return null;

    // Top 25% of the consignment note
    final topCutoff = minY + (totalHeight * 0.25);
    final rightCutoff = minX + (totalWidth * 0.55);
    final leftCutoff = minX + (totalWidth * 0.45);

    final numberPattern = RegExp(r'\b\d{4,7}\b');
    final ignoreWords = RegExp(
      r'(?:patanjali|parivahan|transport|contractor|admin|office|registered|haridwar|uttarakhand|gstin|fssai|cin|iba|valid|consignment|kolkata|entry|bkg|edd|payment|billing|party|service|entered|truck|vehicle|tempo|vendor|code|ssrm)',
      caseSensitive: false,
    );
    const ignoreNumbers = {'2026', '2028', '2024', '2025', '2219', '249408'};

    TextLine? bestCandidate;
    int bestScore = -1;

    for (final line in allLines) {
      final box = line.boundingBox;
      if (box.top > topCutoff) continue;

      final isTopRight = box.left >= rightCutoff;
      final isTopLeft = box.right <= leftCutoff;
      if (!isTopRight && !isTopLeft) continue;

      final text = line.text.trim();
      if (text.isEmpty) continue;
      if (ignoreWords.hasMatch(text)) continue;

      final numMatch = numberPattern.firstMatch(text);
      if (numMatch != null) {
        final digits = numMatch.group(0)!;
        if (ignoreNumbers.contains(digits)) continue;

        int score = 0;
        if (isTopRight) score += 50; // Samples 1.jpeg, 2.jpeg, 3.jpeg have handwritten BNF LR at top-right
        if (isTopLeft) score += 30;
        if (RegExp(r'^\D*\d{4,7}\D*$').hasMatch(text)) score += 40; // Clean standalone number
        if (box.top <= minY + (totalHeight * 0.15)) score += 20;

        if (score > bestScore) {
          bestScore = score;
          bestCandidate = line;
        }
      }
    }

    if (bestCandidate != null) {
      final match = numberPattern.firstMatch(bestCandidate.text);
      return match?.group(0);
    }

    return null;
  }

  /// Text-based fallback to detect handwritten BNF LR No from top header lines
  String? _detectBnfLrNoFromHeaderLines(List<String> lines) {
    final ignoreWords = RegExp(
      r'(?:patanjali|parivahan|transport|contractor|admin|office|registered|haridwar|uttarakhand|gstin|fssai|cin|iba|valid|consignment|kolkata|entry|bkg|edd|payment|billing|party|service|entered|truck|vehicle|tempo|vendor|code|ssrm)',
      caseSensitive: false,
    );
    const ignoreNumbers = {'2026', '2028', '2024', '2025', '2219', '249408'};

    for (int i = 0; i < lines.length && i < 12; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (ignoreWords.hasMatch(line)) {
        final cornerMatch = RegExp(r'(?:^|\s)(\d{4,6})(?:\s*$)').firstMatch(line);
        if (cornerMatch != null) {
          final cand = cornerMatch.group(1)!;
          if (!ignoreNumbers.contains(cand)) return cand;
        }
        continue;
      }
      final standaloneMatch = RegExp(r'^\D*(\d{4,6})\D*$').firstMatch(line);
      if (standaloneMatch != null) {
        final cand = standaloneMatch.group(1)!;
        if (!ignoreNumbers.contains(cand)) return cand;
      }
    }
    return null;
  }

  String _normalizeString(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _cleanValue(String value) {
    return value
        .replaceAll(RegExp(r'^[\s:\-–—=]+'), '')
        .replaceAll(RegExp(r'[\s]+$'), '')
        .trim();
  }
}
