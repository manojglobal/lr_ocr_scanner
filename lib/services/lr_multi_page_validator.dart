import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Result of analyzing a single scanned/uploaded page for consignment note & LR identity.
class ConsignmentPageAnalysis {
  final bool isPrimaryConsignmentNote;
  final List<String> detectedLrNumbers;
  final Set<String> normalizedLrNumbers;

  const ConsignmentPageAnalysis({
    required this.isPrimaryConsignmentNote,
    required this.detectedLrNumbers,
    required this.normalizedLrNumbers,
  });
}

/// Outcome of auditing all pages/images in a multi-LR validation batch.
class MultiLrValidationOutcome {
  final bool hasMultipleLrs;
  final List<String> detectedLrNumbers;
  final String message;

  const MultiLrValidationOutcome({
    required this.hasMultipleLrs,
    required this.detectedLrNumbers,
    required this.message,
  });
}

/// On-device spatial/text analyzer for LR orientation and multi-LR batch validation.
class LrMultiPageValidator {
  static const String defaultRejectionMessage =
      'Multiple LR documents detected. Please upload documents belonging to only one LR at a time.';

  static final RegExp _explicitLrPattern = RegExp(
    r'''(?:consignment\s*note\s*(?:no\.?)?|c\.?\s*note\s*(?:no\.?)?|l\.?\s*r\.?\s*no\.?|g\.?\s*r\.?\s*no\.?|bilty\s*no\.?)\s*[:.\-#]*\s*([A-Z0-9][A-Z0-9\-/]{1,14})''',
    caseSensitive: false,
  );

  static final RegExp _cnHeaderAnchorPattern = RegExp(
    r'''(?:consignment\s*note|lorry\s*receipt|c\.?\s*note|g\.?\s*r\.?\s*no|bilty)''',
    caseSensitive: false,
  );

  static final RegExp _vehiclePlatePattern = RegExp(
    r'^[A-Z]{2}\d{1,2}[A-Z]{1,3}\d{3,4}$',
    caseSensitive: false,
  );

  static final RegExp _gstinPattern = RegExp(
    r'^\d{2}[A-Z]{5}\d{4}[A-Z]\d[A-Z\d]{2}$',
    caseSensitive: false,
  );

  static final RegExp _dateLikePattern = RegExp(
    r'\b\d{1,2}\s*[/\-.]\s*\d{1,2}\s*[/\-.]\s*\d{2,4}\b',
  );

  static final RegExp _noLabelPattern = RegExp(
    r'^(?:no\.?|s\.?\s*no\.?)$',
    caseSensitive: false,
  );

  static const Set<String> _knownNoiseNumbers = {
    '9001',
    '2015',
    '90012015',
    '400063',
    '122414',
    '110036',
    '453771',
    '562123',
    '562162',
    '0',
  };

  static const List<String> _primaryConsignmentMarkers = [
    'consignment note',
    'lorry receipt',
    'c.note',
    'c-note',
    'c note',
    'bilty',
    'consignor copy',
    'consignee copy',
    'driver copy',
    "at owner's risk",
    'at owners risk',
    'tempo/truck',
    'said of contain',
    'said to contain',
    'g.r. no',
    'gr no',
    'patanjali parivahan',
    'box n freight',
    'boxnfreight',
  ];

  static const List<String> _strongConsignmentHeaderMarkers = [
    'consignment note',
    'lorry receipt',
    'bilty',
    'consignor copy',
    'consignee copy',
    'driver copy',
    "at owner's risk",
    'at owners risk',
    'patanjali parivahan',
  ];

  static const List<String> _supportingOnlyMarkers = [
    'driving licence',
    'indian union driving',
    'validity(tr)',
    'validity (tr)',
    'certificate of registration',
    'registration certificate',
    'form gst ewb',
    'e-way bill',
    'eway bill',
    'tax invoice',
    'commercial invoice',
    'bill of supply',
    'delivery challan',
  ];

  static const List<String> _disallowedContextKeywords = [
    'seal',
    'pin',
    'iso',
    'eway',
    'e-way',
    'ewb',
    'invoice',
    'inv ',
    'incp',
    'cin',
    'gst',
    'ifsc',
    'account',
    'a/c',
    'tel',
    'mob',
    'phone',
    'fax',
    'package',
    'weight',
    'value',
    'truck',
    'tempo',
    'vehicle',
    'veh',
    'challan',
    'dl no',
    'licen',
    'policy',
    'date',
  ];

  /// Estimates the clockwise rotation angle `{0, 90, 180, 270}` needed to turn
  /// [recognizedText] upright based on line vectors / ML Kit angles.
  static int detectClockwiseRotationDegrees(RecognizedText recognizedText) {
    final weights = <int, double>{0: 0, 90: 0, 180: 0, 270: 0};

    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        final trimmed = line.text.trim();
        if (trimmed.length < 3) continue;

        double? deg;
        if (line.cornerPoints.length >= 2) {
          final p0 = line.cornerPoints[0];
          final p1 = line.cornerPoints[1];
          final dx = (p1.x - p0.x).toDouble();
          final dy = (p1.y - p0.y).toDouble();
          if (hypot(dx, dy) >= 12.0) {
            deg = atan2(dy, dx) * 180.0 / pi;
          }
        }
        deg ??= line.angle;
        if (deg == null || deg.isNaN) continue;

        final int correction;
        if (deg >= -45.0 && deg <= 45.0) {
          correction = 0;
        } else if (deg > 45.0 && deg <= 135.0) {
          // Baseline runs downward (+90 deg): rotate 270 deg CW (90 deg CCW) to make upright.
          correction = 270;
        } else if (deg < -45.0 && deg >= -135.0) {
          // Baseline runs upward (-90 deg): rotate 90 deg CW to make upright.
          correction = 90;
        } else {
          correction = 180;
        }
        weights[correction] = (weights[correction] ?? 0) + trimmed.length.toDouble();
      }
    }

    final totalWeight = weights.values.fold<double>(0.0, (a, b) => a + b);
    if (totalWeight < 20.0) return 0;

    int bestRot = 0;
    double bestWeight = -1.0;
    for (final entry in weights.entries) {
      if (entry.value > bestWeight) {
        bestWeight = entry.value;
        bestRot = entry.key;
      }
    }
    if (bestRot == 0) return 0;
    if (bestWeight >= totalWeight * 0.55) {
      return bestRot;
    }
    return 0;
  }

  /// Computes Euclidean norm `sqrt(dx*dx + dy*dy)`.
  static double hypot(double dx, double dy) => sqrt((dx * dx) + (dy * dy));

  /// Normalizes a candidate LR string consistently with backend `_normalize_lr_candidate`.
  static String normalizeLrCandidate(String raw) {
    final cleaned = raw.trim().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    if (cleaned.isEmpty) return '';
    if (RegExp(r'^\d+$').hasMatch(cleaned) && cleaned.length > 1) {
      final parsed = int.tryParse(cleaned);
      if (parsed != null) return parsed.toString();
    }
    return cleaned;
  }

  /// Classifies and extracts consignment note LR numbers from [recognizedText].
  static ConsignmentPageAnalysis analyzeRecognizedText(RecognizedText recognizedText) {
    final allLines = <_SpatialLine>[];
    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        final t = line.text.trim();
        if (t.isNotEmpty) {
          allLines.add(_SpatialLine(text: t, rect: line.boundingBox));
        }
      }
    }

    if (allLines.isEmpty) {
      return analyzePlainText(recognizedText.text);
    }

    final cwRot = detectClockwiseRotationDegrees(recognizedText);
    final orientedLines = allLines
        .map((l) => _SpatialLine(text: l.text, rect: _rotateRectForUprightSpace(l.rect, cwRot)))
        .toList();

    orientedLines.sort((a, b) {
      final threshold = max(10.0, min(a.rect.height, b.rect.height) * 0.65);
      if ((a.rect.top - b.rect.top).abs() <= threshold) {
        return a.rect.left.compareTo(b.rect.left);
      }
      return a.rect.top.compareTo(b.rect.top);
    });

    final fullText = orientedLines.map((l) => l.text).join('\n');
    final isPrimary = _isPrimaryConsignmentText(fullText);
    if (!isPrimary) {
      return const ConsignmentPageAnalysis(
        isPrimaryConsignmentNote: false,
        detectedLrNumbers: [],
        normalizedLrNumbers: {},
      );
    }

    final foundRaw = <String>[];
    final foundNorm = <String>{};

    void recordCandidate(String raw) {
      final norm = normalizeLrCandidate(raw);
      if (norm.length < 3 || norm == '0' || foundNorm.contains(norm)) return;
      foundNorm.add(norm);
      foundRaw.add(raw.trim());
    }

    // 1. Explicit LR/CN labels across oriented lines
    _collectExplicitPatternMatches(orientedLines.map((l) => l.text).toList(), recordCandidate);

    // 2. Spatial box lookup around "CONSIGNMENT NOTE" / "LORRY RECEIPT" / "BILTY" anchors
    _collectSpatialAnchorCandidates(orientedLines, recordCandidate);

    return ConsignmentPageAnalysis(
      isPrimaryConsignmentNote: true,
      detectedLrNumbers: foundRaw,
      normalizedLrNumbers: foundNorm,
    );
  }

  /// Pure string analysis fallback (used for plain lines and headless unit tests).
  static ConsignmentPageAnalysis analyzePlainText(String rawText) {
    final lines = rawText
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (lines.isEmpty || !_isPrimaryConsignmentText(rawText)) {
      return const ConsignmentPageAnalysis(
        isPrimaryConsignmentNote: false,
        detectedLrNumbers: [],
        normalizedLrNumbers: {},
      );
    }

    final foundRaw = <String>[];
    final foundNorm = <String>{};

    void recordCandidate(String raw) {
      final norm = normalizeLrCandidate(raw);
      if (norm.length < 3 || norm == '0' || foundNorm.contains(norm)) return;
      foundNorm.add(norm);
      foundRaw.add(raw.trim());
    }

    _collectExplicitPatternMatches(lines, recordCandidate);

    // Adjacent line fallback around "CONSIGNMENT NOTE" / "No." header lines
    for (int i = 0; i < lines.length; i++) {
      if (_cnHeaderAnchorPattern.hasMatch(lines[i])) {
        final upper = min(lines.length, i + 6);
        for (int j = i + 1; j < upper; j++) {
          final candLine = lines[j];
          if (_noLabelPattern.hasMatch(candLine)) {
            if (j + 1 < lines.length) {
              _tryExtractHeaderTokenFromLine(lines[j + 1], recordCandidate);
            }
            continue;
          }
          _tryExtractHeaderTokenFromLine(candLine, recordCandidate);
        }
      }
    }

    return ConsignmentPageAnalysis(
      isPrimaryConsignmentNote: true,
      detectedLrNumbers: foundRaw,
      normalizedLrNumbers: foundNorm,
    );
  }

  /// Evaluates analyzed pages and detects whether >= 2 distinct LR numbers exist.
  static MultiLrValidationOutcome evaluatePageAnalyses(
    List<ConsignmentPageAnalysis> pages,
  ) {
    final distinctNorm = <String>{};
    final distinctDisplay = <String>[];

    for (final page in pages) {
      if (!page.isPrimaryConsignmentNote) continue;
      for (final raw in page.detectedLrNumbers) {
        final norm = normalizeLrCandidate(raw);
        if (norm.length < 3 || norm == '0') continue;
        if (distinctNorm.add(norm)) {
          distinctDisplay.add(raw);
        }
      }
    }

    if (distinctNorm.length > 1) {
      return MultiLrValidationOutcome(
        hasMultipleLrs: true,
        detectedLrNumbers: distinctDisplay,
        message:
            'Multiple LR documents detected (${distinctDisplay.join(', ')}). Please upload documents belonging to only one LR at a time.',
      );
    }

    return MultiLrValidationOutcome(
      hasMultipleLrs: false,
      detectedLrNumbers: distinctDisplay,
      message: '',
    );
  }

  static bool _isPrimaryConsignmentText(String rawText) {
    final lower = rawText.toLowerCase();
    final hasAnyPrimary = _primaryConsignmentMarkers.any((m) => lower.contains(m));
    if (!hasAnyPrimary) return false;

    final hasStrongHeader =
        _strongConsignmentHeaderMarkers.any((m) => lower.contains(m));
    final hasSupportingOnly = _supportingOnlyMarkers.any((m) => lower.contains(m));
    if (!hasStrongHeader && hasSupportingOnly) {
      return false;
    }
    return true;
  }

  static void _collectExplicitPatternMatches(
    List<String> lines,
    void Function(String raw) recordCandidate,
  ) {
    for (final line in lines) {
      for (final m in _explicitLrPattern.allMatches(line)) {
        final token = (m.group(1) ?? '').trim();
        final prefix = line.substring(0, m.start).toLowerCase();
        if (_isValidLrCandidate(token, contextPrefix: prefix, fullLine: line)) {
          recordCandidate(token);
        }
      }
    }
  }

  static void _collectSpatialAnchorCandidates(
    List<_SpatialLine> orientedLines,
    void Function(String raw) recordCandidate,
  ) {
    for (int i = 0; i < orientedLines.length; i++) {
      final anchor = orientedLines[i];
      if (!_cnHeaderAnchorPattern.hasMatch(anchor.text)) continue;

      final anchorCenter = anchor.rect.center;
      final lineH = anchor.rect.height > 4.0 ? anchor.rect.height : 20.0;
      final maxDx = max(anchor.rect.width * 1.4, lineH * 9.0);
      final maxDyAbove = lineH * 0.5;
      final maxDyBelow = lineH * 4.5;

      // Sort nearby lines by proximity to this Consignment Note box and pick the best match
      final nearby = <_SpatialLine>[];
      for (final other in orientedLines) {
        if (identical(other, anchor)) continue;
        final dx = (other.rect.center.dx - anchorCenter.dx).abs();
        final dy = other.rect.center.dy - anchorCenter.dy;
        if (dx <= maxDx && dy >= -maxDyAbove && dy <= maxDyBelow) {
          nearby.add(other);
        }
      }

      nearby.sort((a, b) {
        final dA = hypot(a.rect.center.dx - anchorCenter.dx, a.rect.center.dy - anchorCenter.dy);
        final dB = hypot(b.rect.center.dx - anchorCenter.dx, b.rect.center.dy - anchorCenter.dy);
        return dA.compareTo(dB);
      });

      bool foundForAnchor = false;
      for (final item in nearby) {
        if (_noLabelPattern.hasMatch(item.text)) continue;
        _tryExtractHeaderTokenFromLine(item.text, (tok) {
          if (foundForAnchor) return;
          foundForAnchor = true;
          recordCandidate(tok);
        });
        if (foundForAnchor) break;
      }
    }
  }

  static void _tryExtractHeaderTokenFromLine(
    String line,
    void Function(String raw) recordCandidate,
  ) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    // Split dates out first so dd/mm/yyyy doesn't pollute token scan
    final cleanedLine = trimmed.replaceAll(_dateLikePattern, ' ');
    for (final m in RegExp(r'\b([A-Z0-9][A-Z0-9\-/]{1,12})\b', caseSensitive: false)
        .allMatches(cleanedLine)) {
      final tok = m.group(1) ?? '';
      final prefix = cleanedLine.substring(0, m.start).toLowerCase();
      if (_isValidLrCandidate(tok, contextPrefix: prefix, fullLine: trimmed)) {
        recordCandidate(tok);
      }
    }
  }

  static bool _isValidLrCandidate(
    String raw, {
    required String contextPrefix,
    required String fullLine,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || _dateLikePattern.hasMatch(trimmed)) return false;

    final cleanAlnum = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (cleanAlnum.length < 3 || cleanAlnum.length > 10) return false;
    // LR number must contain at least 3 digits so words like "No", "Date", "Note", "From" never match
    final digitCount = RegExp(r'\d').allMatches(cleanAlnum).length;
    if (digitCount < 3) return false;

    final lowerAlnum = cleanAlnum.toLowerCase();
    if (_knownNoiseNumbers.contains(lowerAlnum)) return false;
    if (RegExp(r'^0+$').hasMatch(cleanAlnum)) return false;
    if (_vehiclePlatePattern.hasMatch(cleanAlnum)) return false;
    if (_gstinPattern.hasMatch(cleanAlnum)) return false;
    // Reject >= 9 pure digits (invoices, eway bills, phones, bank accounts)
    if (RegExp(r'^\d{9,}$').hasMatch(cleanAlnum)) return false;

    final ctxLower = contextPrefix.toLowerCase();
    final lineLower = fullLine.toLowerCase();
    for (final kw in _disallowedContextKeywords) {
      if (ctxLower.contains(kw)) return false;
      // Avoid rejecting a genuine line like "No. 32915 Date 18/08/2026" just because "date" follows
      if (kw != 'date' && (lineLower.contains('$kw:') || lineLower.contains('$kw no'))) {
        if (!lineLower.contains('consignment') && !lineLower.contains('lr ') && !lineLower.contains('bilty')) {
          return false;
        }
      }
    }

    return true;
  }

  static Rect _rotateRectForUprightSpace(Rect r, int cwDegrees) {
    switch (cwDegrees) {
      case 90:
        return Rect.fromLTRB(-r.bottom, r.left, -r.top, r.right);
      case 180:
        return Rect.fromLTRB(-r.right, -r.bottom, -r.left, -r.top);
      case 270:
        return Rect.fromLTRB(r.top, -r.right, r.bottom, -r.left);
      default:
        return r;
    }
  }
}

class _SpatialLine {
  final String text;
  final Rect rect;

  const _SpatialLine({required this.text, required this.rect});
}
