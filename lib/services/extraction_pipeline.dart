import '../models/extraction_result.dart';
import 'layout_analyzer.dart';
import 'ocr_service.dart';
import 'validator.dart';

/// Comprehensive end-to-end extraction pipeline:
/// Capture → OcrService (2 passes + Devanagari) → LayoutAnalyzer → Validator → ExtractionResult
///
/// Usage:
/// ```dart
/// final result = await ExtractionPipeline().run(imagePath);
/// // Display result in UI, review flagged fields, then export to Excel
/// ```
class ExtractionPipeline {
  final OcrService _ocrService;
  final LayoutAnalyzer _layoutAnalyzer;
  final Validator _validator;

  ExtractionPipeline({
    OcrService? ocrService,
    LayoutAnalyzer? layoutAnalyzer,
    Validator? validator,
  })  : _ocrService = ocrService ?? OcrService(),
        _layoutAnalyzer = layoutAnalyzer ?? LayoutAnalyzer(),
        _validator = validator ?? Validator();

  /// Runs the full dual-pass OCR, geometry layout detection, and validation pipeline.
  Future<ExtractionResult> run(
    String imagePath, {
    bool includeDevanagari = false,
  }) async {
    try {
      // 1. Two-pass word recognition with disagreement tracking & confidence
      final words = await _ocrService.recognizeWordsDualPass(
        imagePath,
        includeDevanagari: includeDevanagari,
      );

      if (words.isEmpty) {
        return ExtractionResult.failure(
          errorMessage: 'No text or characters detected in image.',
        );
      }

      // 2. Geometry-based layout analysis (tables, forms, multi-column comparison)
      final layout = _layoutAnalyzer.analyze(words);

      // 3. Domain & type-aware validation, character disambiguation, and warning generation
      final validation = _validator.validate(layout);

      final rawText = words.map((w) => w.text).join(' ');

      return ExtractionResult.success(
        data: validation.validatedFields,
        missingFields: const [],
        rawText: rawText,
        tableHeaders: layout.tableHeaders,
        tableRows: validation.validatedTableRows,
        structureType: layout.structureType,
        message: validation.hasWarnings ? validation.warnings.join('; ') : null,
      );
    } catch (e) {
      return ExtractionResult.failure(
        errorMessage: 'Extraction pipeline error: $e',
      );
    }
  }
}
