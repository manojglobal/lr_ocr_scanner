import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ocr_to_excel/services/pdf_assembler_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PdfAssemblerService combines multiple images into valid PDF 1.4', () async {
    final tempDir = await Directory.systemTemp.createTemp('pdf_test_');

    // Create 2 test JPEG images
    final img1 = img.Image(width: 300, height: 400);
    img.fill(img1, color: img.ColorRgb8(255, 0, 0));
    final file1 = File('${tempDir.path}/page1.jpg');
    await file1.writeAsBytes(img.encodeJpg(img1));

    final img2 = img.Image(width: 500, height: 600);
    img.fill(img2, color: img.ColorRgb8(0, 255, 0));
    final file2 = File('${tempDir.path}/page2.jpg');
    await file2.writeAsBytes(img.encodeJpg(img2));

    final pdfPath = '${tempDir.path}/output.pdf';
    final resultFile = await PdfAssemblerService.assembleImagesToPdf(
      imagePaths: [file1.path, file2.path],
      outputPath: pdfPath,
    );

    expect(await resultFile.exists(), isTrue);
    final pdfBytes = await resultFile.readAsBytes();
    final pdfString = String.fromCharCodes(pdfBytes.sublist(0, 100));

    expect(pdfString.startsWith('%PDF-1.4'), isTrue);
    // Check that it contains 2 pages
    final fullPdfString = String.fromCharCodes(pdfBytes);
    expect(fullPdfString.contains('/Count 2'), isTrue);
    expect(fullPdfString.contains('/Type /Page'), isTrue);
    expect(fullPdfString.contains('startxref'), isTrue);
    expect(fullPdfString.contains('%%EOF'), isTrue);

    await tempDir.delete(recursive: true);
  });
}
