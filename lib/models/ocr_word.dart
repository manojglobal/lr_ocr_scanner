import 'dart:ui';

/// Represents a single recognized word with its 2D spatial bounding box,
/// confidence score, and optional language/script tag.
///
/// This engine-agnostic abstraction allows the LayoutAnalyzer and Validator
/// to work identically across Google ML Kit, Tesseract, or ONNX RapidOCR (on Windows).
class OcrWord {
  final String text;
  final Rect boundingBox;
  final double confidence; // Normalized 0.0 to 1.0
  final String script;     // e.g. 'latin', 'devanagari'
  final bool isFlagged;    // True if engines disagreed or validation failed

  OcrWord({
    required this.text,
    required this.boundingBox,
    this.confidence = 1.0,
    this.script = 'latin',
    this.isFlagged = false,
  });

  double get left => boundingBox.left;
  double get top => boundingBox.top;
  double get right => boundingBox.right;
  double get bottom => boundingBox.bottom;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;
  double get width => boundingBox.width;
  double get height => boundingBox.height;

  OcrWord copyWith({
    String? text,
    Rect? boundingBox,
    double? confidence,
    String? script,
    bool? isFlagged,
  }) {
    return OcrWord(
      text: text ?? this.text,
      boundingBox: boundingBox ?? this.boundingBox,
      confidence: confidence ?? this.confidence,
      script: script ?? this.script,
      isFlagged: isFlagged ?? this.isFlagged,
    );
  }

  @override
  String toString() => '$text (conf: ${(confidence * 100).toStringAsFixed(1)}%)';
}

/// Represents an aggregated horizontal line of words.
class OcrLine {
  final List<OcrWord> words;
  final Rect boundingBox;

  OcrLine({required this.words, required this.boundingBox});

  String get text => words.map((w) => w.text).join(' ').trim();
  double get confidence => words.isEmpty
      ? 1.0
      : words.map((w) => w.confidence).reduce((a, b) => a + b) / words.length;

  bool get hasFlaggedWords => words.any((w) => w.isFlagged);
}
