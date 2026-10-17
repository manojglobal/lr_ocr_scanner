import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import '../models/ocr_word.dart';
import 'ocr_service.dart';

/// Abstract engine interface allowing drop-in OCR backends:
/// - Android / iOS: Uses Google ML Kit (via OcrService)
/// - Windows (.exe): Uses RapidOCR / PP-OCR ONNX sidecar executable or Tesseract CLI
abstract class OcrEngine {
  Future<List<OcrWord>> recognizeWords(String imagePath);
}

/// Mobile OCR engine backed by Google ML Kit.
class MobileMlKitEngine implements OcrEngine {
  final OcrService _service;

  MobileMlKitEngine({OcrService? service}) : _service = service ?? OcrService();

  @override
  Future<List<OcrWord>> recognizeWords(String imagePath) {
    return _service.recognizeWordsDualPass(imagePath);
  }
}

/// Windows Desktop OCR Engine:
/// Calls a lightweight PP-OCR ONNX or Tesseract sidecar executable that emits JSON:
/// ```json
/// [
///   { "text": "Name", "box": [10, 20, 80, 25], "confidence": 0.98, "script": "latin" }
/// ]
/// ```
class WindowsSidecarOcrEngine implements OcrEngine {
  final String sidecarExecutablePath;

  WindowsSidecarOcrEngine({this.sidecarExecutablePath = 'rapidocr_windows.exe'});

  @override
  Future<List<OcrWord>> recognizeWords(String imagePath) async {
    final exeFile = File(sidecarExecutablePath);
    if (!await exeFile.exists()) {
      // Graceful fallback: return empty list or throw informative error
      throw StateError(
        'Windows OCR sidecar executable not found at "$sidecarExecutablePath". '
        'Please bundle the ONNX RapidOCR sidecar with the Windows installer.',
      );
    }

    final processResult = await Process.run(
      sidecarExecutablePath,
      [imagePath, '--output-json'],
    );

    if (processResult.exitCode != 0) {
      throw StateError('Windows OCR sidecar failed: ${processResult.stderr}');
    }

    final rawJson = processResult.stdout.toString().trim();
    final List<dynamic> parsedList = jsonDecode(rawJson);

    return parsedList.map<OcrWord>((item) {
      final text = item['text'] as String;
      final box = (item['box'] as List<dynamic>).map((v) => (v as num).toDouble()).toList();
      final conf = (item['confidence'] as num?)?.toDouble() ?? 0.90;
      final script = (item['script'] as String?) ?? 'latin';

      return OcrWord(
        text: text,
        boundingBox: Rect.fromLTWH(box[0], box[1], box[2], box[3]),
        confidence: conf,
        script: script,
      );
    }).toList();
  }
}

/// Factory that automatically provides the right OCR engine based on OS.
class OcrEngineFactory {
  static OcrEngine createDefault() {
    if (Platform.isWindows) {
      return WindowsSidecarOcrEngine();
    }
    return MobileMlKitEngine();
  }
}
