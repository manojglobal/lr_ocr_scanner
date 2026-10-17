import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:ocr_to_excel/services/structure_detector.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final detector = DynamicStructureDetector();

  final testPaths = [
    '/sdcard/Pictures/image_2x.png',
  ];

  for (final path in testPaths) {
    print('========================================');
    print('TESTING OCR ON: $path');
    print('========================================');
    try {
      final inputImage = InputImage.fromFilePath(path);
      final recognizedText = await recognizer.processImage(inputImage);
      print('--- TEXT (${recognizedText.text.length} chars) ---');
      print(recognizedText.text);

      print('--- BLOCKS & LINES ---');
      for (final b in recognizedText.blocks) {
        for (final l in b.lines) {
          print('LINE: "${l.text}" bounds: ${l.boundingBox}');
        }
      }

      print('--- STRUCTURE DETECTION ---');
      final result = detector.detectFromRecognizedText(recognizedText);
      print('TYPE: ${result.structureType}');
      print('HEADERS: ${result.tableHeaders}');
      print('ROWS (${result.tableRows.length}):');
      for (final r in result.tableRows) {
        print('  $r');
      }
      print('KEY-VALUES (${result.data.length}):');
      result.data.forEach((k, v) {
        print('  $k: $v');
      });
    } catch (e, st) {
      print('ERROR ON $path: $e\n$st');
    }
  }

  print('=== EVAL COMPLETE ===');
  exit(0);
}
