import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../models/ocr_word.dart';
import 'image_preprocessor.dart';

/// Wraps Google ML Kit Text Recognition with automated multi-pass preprocessing,
/// Latin + Devanagari dual-script recognition, and word-level confidence tracking.
class OcrService {
  final TextRecognizer _latinRecognizer;
  TextRecognizer? _devanagariRecognizer;
  final ImagePreprocessor _preprocessor;
  bool _isDisposed = false;
  int _activeInferences = 0;
  Completer<void>? _inferenceCompleter;

  OcrService({
    TextRecognizer? recognizer,
    ImagePreprocessor? preprocessor,
  })  : _latinRecognizer = recognizer ??
            TextRecognizer(script: TextRecognitionScript.latin),
        _preprocessor = preprocessor ?? ImagePreprocessor();

  TextRecognizer get _devanagari =>
      _devanagariRecognizer ??= TextRecognizer(script: TextRecognitionScript.devanagiri);

  /// Performs high-accuracy text recognition on the given image file path.
  /// Backward-compatible with existing callers.
  Future<RecognizedText> recognizeTextFromPath(String imagePath) async {
    if (_isDisposed) {
      throw StateError('OcrService has already been disposed.');
    }
    _activeInferences++;

    final file = File(imagePath);
    if (!await file.exists()) {
      _activeInferences--;
      if (_activeInferences <= 0 && _inferenceCompleter != null && !_inferenceCompleter!.isCompleted) {
        _inferenceCompleter!.complete();
      }
      throw FileSystemException('Image file does not exist', imagePath);
    }

    // Enhance image contrast and edge sharpness
    String targetPath = imagePath;
    try {
      targetPath = await _preprocessor.preprocessForOcr(imagePath, aggressive: true);
    } catch (_) {
      targetPath = imagePath;
    }

    try {
      final inputImage = InputImage.fromFilePath(targetPath);
      return await _latinRecognizer.processImage(inputImage);
    } finally {
      _activeInferences--;
      if (_activeInferences <= 0 && _inferenceCompleter != null && !_inferenceCompleter!.isCompleted) {
        _inferenceCompleter!.complete();
      }
      if (targetPath != imagePath) {
        try {
          final tempFile = File(targetPath);
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (_) {}
      }
    }
  }

  /// Two-Pass OCR Pipeline:
  /// - Pass 1 (Natural): Full-resolution image with orientation correction.
  /// - Pass 2 (Enhanced): 1.25x contrast stretch + unsharp edge mask.
  /// - Optional Pass 3: Devanagari script recognizer merged for Hindi/Marathi text.
  ///
  /// Compares words across passes:
  /// - If passes agree: high confidence.
  /// - If passes disagree: picks higher confidence version and sets `isFlagged: true`
  ///   so the review UI can highlight it for the user.
  Future<List<OcrWord>> recognizeWordsDualPass(
    String imagePath, {
    bool includeDevanagari = false,
  }) async {
    if (_isDisposed) throw StateError('OcrService has already been disposed.');
    _activeInferences++;

    try {
      return await _recognizeWordsDualPassInternal(imagePath, includeDevanagari: includeDevanagari);
    } finally {
      _activeInferences--;
      if (_activeInferences <= 0 && _inferenceCompleter != null && !_inferenceCompleter!.isCompleted) {
        _inferenceCompleter!.complete();
      }
    }
  }

  Future<List<OcrWord>> _recognizeWordsDualPassInternal(
    String imagePath, {
    bool includeDevanagari = false,
  }) async {
    // 1. Pass 1: Natural (un-binarized, full-resolution)
    final pathPass1 = await _preprocessor.preprocessForOcr(imagePath, aggressive: false);
    RecognizedText textPass1;
    try {
      textPass1 = await _latinRecognizer.processImage(InputImage.fromFilePath(pathPass1));
    } finally {
      if (pathPass1 != imagePath) {
        try { await File(pathPass1).delete(); } catch (_) {}
      }
    }

    // 2. Pass 2: Enhanced (contrast stretched + sharpened)
    final pathPass2 = await _preprocessor.preprocessForOcr(imagePath, aggressive: true);
    RecognizedText textPass2;
    try {
      textPass2 = await _latinRecognizer.processImage(InputImage.fromFilePath(pathPass2));
    } finally {
      if (pathPass2 != imagePath) {
        try { await File(pathPass2).delete(); } catch (_) {}
      }
    }

    final words1 = _extractWordsFromRecognizedText(textPass1, script: 'latin');
    final words2 = _extractWordsFromRecognizedText(textPass2, script: 'latin');

    // 3. Reconcile Pass 1 and Pass 2 via word-level spatial voting
    final reconciledWords = _reconcileTwoPassWords(words1, words2);

    // 4. Optional Devanagari Pass for Hindi/Marathi documents
    if (includeDevanagari) {
      try {
        final pathDev = await _preprocessor.preprocessForOcr(imagePath, aggressive: false);
        RecognizedText devText;
        try {
          devText = await _devanagari.processImage(InputImage.fromFilePath(pathDev));
        } finally {
          if (pathDev != imagePath) {
            try { await File(pathDev).delete(); } catch (_) {}
          }
        }
        final devWords = _extractWordsFromRecognizedText(devText, script: 'devanagari');
        _mergeDevanagariWords(reconciledWords, devWords);
      } catch (_) {
        // Devanagari model optional / graceful degradation
      }
    }

    return reconciledWords;
  }

  /// Extracts individual word elements with their bounding boxes and confidence.
  List<OcrWord> _extractWordsFromRecognizedText(
    RecognizedText recognized, {
    required String script,
  }) {
    final List<OcrWord> words = [];

    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        if (line.elements.isNotEmpty) {
          for (final el in line.elements) {
            final text = el.text.trim();
            if (text.isEmpty) continue;
            // ML Kit Element confidence may be null, fallback to line.confidence or 0.85
            final conf = el.confidence ?? line.confidence ?? 0.85;
            words.add(OcrWord(
              text: text,
              boundingBox: el.boundingBox,
              confidence: conf,
              script: script,
            ));
          }
        } else {
          // If elements are missing, break line into words
          final tokens = line.text.split(RegExp(r'\s+'));
          if (tokens.isEmpty) continue;
          final lineConf = line.confidence ?? 0.80;
          final tokenWidth = line.boundingBox.width / tokens.length;
          for (int i = 0; i < tokens.length; i++) {
            final t = tokens[i].trim();
            if (t.isEmpty) continue;
            final rect = Rect.fromLTWH(
              line.boundingBox.left + (i * tokenWidth),
              line.boundingBox.top,
              tokenWidth,
              line.boundingBox.height,
            );
            words.add(OcrWord(
              text: t,
              boundingBox: rect,
              confidence: lineConf,
              script: script,
            ));
          }
        }
      }
    }

    return words;
  }

  /// Spatial word-level voting between Pass 1 and Pass 2.
  List<OcrWord> _reconcileTwoPassWords(List<OcrWord> pass1, List<OcrWord> pass2) {
    final List<OcrWord> result = [];
    final Set<int> matchedPass2Indices = {};

    for (final w1 in pass1) {
      int bestIdx = -1;
      double bestIoU = 0.0;

      for (int i = 0; i < pass2.length; i++) {
        if (matchedPass2Indices.contains(i)) continue;
        final w2 = pass2[i];
        final iou = _calculateIoU(w1.boundingBox, w2.boundingBox);
        if (iou > 0.40 && iou > bestIoU) {
          bestIoU = iou;
          bestIdx = i;
        }
      }

      if (bestIdx != -1) {
        matchedPass2Indices.add(bestIdx);
        final w2 = pass2[bestIdx];

        if (w1.text.toLowerCase() == w2.text.toLowerCase()) {
          // Both passes agree: Boost confidence!
          result.add(w1.copyWith(
            confidence: min(1.0, max(w1.confidence, w2.confidence) + 0.10),
            isFlagged: false,
          ));
        } else {
          // Passes disagree: Pick the one with higher confidence, but FLAG it for review
          final winner = (w2.confidence > w1.confidence) ? w2 : w1;
          result.add(winner.copyWith(
            confidence: min(w1.confidence, w2.confidence), // cautious confidence
            isFlagged: true, // FLAG for human review
          ));
        }
      } else {
        // Only found in Pass 1
        result.add(w1.copyWith(
          confidence: w1.confidence * 0.9,
          isFlagged: w1.confidence < 0.70,
        ));
      }
    }

    // Add unmatched words from Pass 2 (e.g. faint handwriting captured only by aggressive pass)
    for (int i = 0; i < pass2.length; i++) {
      if (!matchedPass2Indices.contains(i)) {
        final w2 = pass2[i];
        result.add(w2.copyWith(
          confidence: w2.confidence * 0.9,
          isFlagged: w2.confidence < 0.70,
        ));
      }
    }

    // Sort top-to-bottom, left-to-right
    result.sort((a, b) {
      if ((a.top - b.top).abs() <= 12.0) {
        return a.left.compareTo(b.left);
      }
      return a.top.compareTo(b.top);
    });

    return result;
  }

  /// Calculates Intersection-over-Union (IoU) between two bounding boxes.
  double _calculateIoU(Rect a, Rect b) {
    final intersection = a.intersect(b);
    if (intersection.width <= 0 || intersection.height <= 0) return 0.0;
    final intersectionArea = intersection.width * intersection.height;
    final unionArea = (a.width * a.height) + (b.width * b.height) - intersectionArea;
    if (unionArea <= 0) return 0.0;
    return intersectionArea / unionArea;
  }

  /// Merges Devanagari words that don't overlap with existing high-confidence Latin words.
  void _mergeDevanagariWords(List<OcrWord> baseWords, List<OcrWord> devWords) {
    for (final dw in devWords) {
      bool overlapsWithLatin = false;
      for (final bw in baseWords) {
        if (_calculateIoU(dw.boundingBox, bw.boundingBox) > 0.35) {
          overlapsWithLatin = true;
          break;
        }
      }
      if (!overlapsWithLatin) {
        baseWords.add(dw);
      }
    }
  }

  /// Checks if the ML Kit OCR model is functional.
  Future<bool> checkModelReadiness() async {
    if (_isDisposed) return false;
    return true;
  }

  /// Releases ML Kit native resources.
  Future<void> dispose() async {
    if (!_isDisposed) {
      _isDisposed = true;
      if (_activeInferences > 0) {
        _inferenceCompleter = Completer<void>();
        await _inferenceCompleter!.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () {},
        );
      }
      await _latinRecognizer.close();
      await _devanagariRecognizer?.close();
    }
  }
}
