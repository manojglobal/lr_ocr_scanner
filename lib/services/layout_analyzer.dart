import 'dart:math';
import 'dart:ui';
import '../models/ocr_word.dart';

/// Structured field item holding key, value, confidence, and review flag.
class ExtractedField {
  final String key;
  final String value;
  final double confidence;
  final bool isFlagged;

  ExtractedField({
    required this.key,
    required this.value,
    this.confidence = 1.0,
    this.isFlagged = false,
  });
}

/// Output of LayoutAnalyzer containing extracted fields, tables, and unassigned text.
class LayoutAnalysisResult {
  final Map<String, String> fields;
  final Map<String, ExtractedField> detailedFields;
  final List<String> tableHeaders;
  final List<List<String>> tableRows;
  final List<String> unassigned;
  final String structureType; // 'table', 'form', 'mixed', 'text'

  LayoutAnalysisResult({
    required this.fields,
    required this.detailedFields,
    this.tableHeaders = const [],
    this.tableRows = const [],
    this.unassigned = const [],
    this.structureType = 'form',
  });

  bool get hasTable => tableHeaders.isNotEmpty && tableRows.isNotEmpty;
}

/// Geometry-based layout analyzer that processes word bounding boxes into
/// structured key-value pairs, comparison tables, and grids.
class LayoutAnalyzer {
  /// Analyzes a spatial list of OcrWord tokens to discover document layout.
  LayoutAnalysisResult analyze(List<OcrWord> words) {
    if (words.isEmpty) {
      return LayoutAnalysisResult(
        fields: const {},
        detailedFields: const {},
        structureType: 'text',
      );
    }

    // 1. Group words into horizontal lines
    final List<OcrLine> lines = _groupWordsIntoLines(words);

    // 2. Check for multi-column comparison form (e.g. side-by-side forms)
    final multiColResult = _tryAnalyzeMultiColumnForm(words, lines);
    if (multiColResult != null) {
      return multiColResult;
    }

    // 3. Check for grid table structure
    final tableResult = _tryAnalyzeGridTable(lines);
    if (tableResult != null) {
      return tableResult;
    }

    // 4. Default: Standard key-value pairing via geometry & colons
    return _analyzeKeyValuePairs(lines);
  }

  /// Groups words into horizontal lines based on vertical overlap and distance.
  List<OcrLine> _groupWordsIntoLines(List<OcrWord> words) {
    final sorted = List<OcrWord>.from(words)..sort((a, b) => a.top.compareTo(b.top));
    final List<List<OcrWord>> lineBuckets = [];

    for (final word in sorted) {
      bool matched = false;
      for (final bucket in lineBuckets) {
        final bucketAvgY = bucket.map((w) => w.centerY).reduce((a, b) => a + b) / bucket.length;
        final bucketAvgHeight = bucket.map((w) => w.height).reduce((a, b) => a + b) / bucket.length;
        final maxDiff = max(word.height, bucketAvgHeight) * 0.55;

        if ((word.centerY - bucketAvgY).abs() <= maxDiff) {
          bucket.add(word);
          matched = true;
          break;
        }
      }
      if (!matched) {
        lineBuckets.add([word]);
      }
    }

    final List<OcrLine> lines = [];
    for (final bucket in lineBuckets) {
      bucket.sort((a, b) => a.left.compareTo(b.left));
      double minL = bucket.first.left;
      double minT = bucket.map((w) => w.top).reduce(min);
      double maxR = bucket.map((w) => w.right).reduce(max);
      double maxB = bucket.map((w) => w.bottom).reduce(max);
      lines.add(OcrLine(
        words: bucket,
        boundingBox: Rect.fromLTRB(minL, minT, maxR, maxB),
      ));
    }

    lines.sort((a, b) => a.boundingBox.top.compareTo(b.boundingBox.top));
    return lines;
  }

  /// Detects side-by-side comparative sections (e.g. Elector vs Relative).
  LayoutAnalysisResult? _tryAnalyzeMultiColumnForm(List<OcrWord> words, List<OcrLine> lines) {
    if (words.length < 8) return null;

    double minX = words.first.left;
    double maxX = words.first.right;
    for (final w in words) {
      minX = min(minX, w.left);
      maxX = max(maxX, w.right);
    }
    final totalWidth = maxX - minX;
    if (totalWidth < 300) return null;

    final splitX = minX + (totalWidth * 0.48);

    final leftLines = lines.where((l) => l.boundingBox.left < splitX).toList();
    final rightLines = lines.where((l) => l.boundingBox.left >= splitX).toList();

    // Check if both sides contain multiple label patterns
    final leftLabels = leftLines.where((l) => _looksLikeFieldLabel(l.text)).toList();
    final rightLabels = rightLines.where((l) => _looksLikeFieldLabel(l.text)).toList();

    if (leftLabels.length < 2 || rightLabels.length < 2) return null;

    // Detect titles
    String leftTitle = 'Details of the Elector';
    String rightTitle = 'Details of the relative';
    for (final l in leftLines) {
      final t = l.text.toLowerCase();
      if (t.contains('elector') || t.contains('column 1')) {
        leftTitle = l.text;
        break;
      }
    }
    for (final l in rightLines) {
      final t = l.text.toLowerCase();
      if (t.contains('relative') || t.contains('column 2')) {
        rightTitle = l.text;
        break;
      }
    }

    final Map<String, ExtractedField> leftFields = _extractFieldsFromColumn(leftLines, words, splitX, isLeft: true);
    final Map<String, ExtractedField> rightFields = _extractFieldsFromColumn(rightLines, words, splitX, isLeft: false);

    // Build 3-column table
    final headers = ['Field / Attribute', leftTitle, rightTitle];
    final List<List<String>> tableRows = [];
    final Set<String> allKeys = {...leftFields.keys, ...rightFields.keys};

    for (final k in allKeys) {
      final lv = leftFields[k]?.value ?? '';
      final rv = rightFields[k]?.value ?? '';
      tableRows.add([k, lv, rv]);
    }

    final Map<String, String> flatFields = {};
    final Map<String, ExtractedField> detailedFields = {};

    leftFields.forEach((k, f) {
      flatFields['Elector - $k'] = f.value;
      detailedFields['Elector - $k'] = f;
    });
    rightFields.forEach((k, f) {
      flatFields['Relative - $k'] = f.value;
      detailedFields['Relative - $k'] = f;
    });

    return LayoutAnalysisResult(
      fields: flatFields,
      detailedFields: detailedFields,
      tableHeaders: headers,
      tableRows: tableRows,
      structureType: 'mixed',
    );
  }

  Map<String, ExtractedField> _extractFieldsFromColumn(
    List<OcrLine> columnLines,
    List<OcrWord> allWords,
    double splitX, {
    required bool isLeft,
  }) {
    final Map<String, ExtractedField> result = {};

    for (final line in columnLines) {
      final text = line.text.trim();
      final colonIdx = text.indexOf(':');

      if (colonIdx != -1) {
        final rawKey = text.substring(0, colonIdx).trim();
        final rawVal = text.substring(colonIdx + 1).trim();
        final canonicalKey = _cleanLabel(rawKey);

        if (rawVal.isNotEmpty) {
          result[canonicalKey] = ExtractedField(
            key: canonicalKey,
            value: rawVal,
            confidence: line.confidence,
            isFlagged: line.hasFlaggedWords,
          );
        } else {
          // Raycast to the right to find adjacent value words
          final adjacentWords = allWords.where((w) {
            if (isLeft && w.left >= splitX) return false;
            if (!isLeft && w.left < splitX) return false;
            if (w.left < line.boundingBox.right - 10) return false;
            return (w.centerY - line.boundingBox.center.dy).abs() <= 35.0;
          }).toList()..sort((a, b) => a.left.compareTo(b.left));

          if (adjacentWords.isNotEmpty) {
            final val = adjacentWords.map((w) => w.text).join(' ').trim();
            final avgConf = adjacentWords.map((w) => w.confidence).reduce((a, b) => a + b) / adjacentWords.length;
            final flagged = adjacentWords.any((w) => w.isFlagged);
            result[canonicalKey] = ExtractedField(
              key: canonicalKey,
              value: val,
              confidence: avgConf,
              isFlagged: flagged,
            );
          }
        }
      }
    }
    return result;
  }

  /// Detects grid tables by identifying rows with 2+ aligned column anchors.
  LayoutAnalysisResult? _tryAnalyzeGridTable(List<OcrLine> lines) {
    final multiCellLines = lines.where((l) => l.words.length >= 2).toList();
    if (multiCellLines.length < 3) return null;

    // Check if first line looks like table headers
    final first = multiCellLines.first;
    if (first.text.contains(':')) return null;

    final headers = first.words.map((w) => w.text).toList();
    if (headers.length < 2) return null;

    final List<List<String>> tableRows = [];
    for (final line in multiCellLines.skip(1)) {
      if (line.text.contains(':')) continue; // Skip form lines
      final row = line.words.map((w) => w.text).toList();
      tableRows.add(row);
    }

    if (tableRows.length >= 2) {
      return LayoutAnalysisResult(
        fields: const {},
        detailedFields: const {},
        tableHeaders: headers,
        tableRows: tableRows,
        structureType: 'table',
      );
    }

    return null;
  }

  /// Fallback: standard key-value pairing from lines.
  LayoutAnalysisResult _analyzeKeyValuePairs(List<OcrLine> lines) {
    final Map<String, String> fields = {};
    final Map<String, ExtractedField> detailed = {};
    final List<String> unassigned = [];

    for (final line in lines) {
      final text = line.text.trim();
      final delimIdx = text.indexOf(':');

      if (delimIdx != -1) {
        final k = text.substring(0, delimIdx).trim();
        final v = text.substring(delimIdx + 1).trim();
        if (k.isNotEmpty && v.isNotEmpty) {
          fields[k] = v;
          detailed[k] = ExtractedField(
            key: k,
            value: v,
            confidence: line.confidence,
            isFlagged: line.hasFlaggedWords,
          );
          continue;
        }
      }
      if (text.isNotEmpty) {
        unassigned.add(text);
      }
    }

    return LayoutAnalysisResult(
      fields: fields,
      detailedFields: detailed,
      unassigned: unassigned,
      structureType: fields.isNotEmpty ? 'form' : 'text',
    );
  }

  bool _looksLikeFieldLabel(String text) {
    if (text.contains(':')) return true;
    final lower = text.toLowerCase();
    return lower.startsWith('name') ||
        lower.startsWith('epic') ||
        lower.startsWith('relative') ||
        lower.startsWith('elector') ||
        lower.startsWith('district') ||
        lower.startsWith('state');
  }

  String _cleanLabel(String raw) {
    String l = raw.replaceAll(RegExp(r'[:.\-_]+$'), '').trim();
    final lower = l.toLowerCase();
    if (lower.contains('elector') && lower.contains('name')) return 'Name';
    if (lower.contains('relative') && lower.contains('name')) return "Relative's Name";
    if (lower.contains('epic')) return 'EPIC No.';
    if (lower.contains('relation')) return 'Relationship';
    if (lower.contains('district')) return 'District';
    if (lower.contains('state')) return 'State';
    return l;
  }
}
