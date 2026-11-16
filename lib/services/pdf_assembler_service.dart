import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Assembles multiple image files (JPEG, PNG, etc.) into a single multi-page PDF document.
/// Uses standard PDF 1.4 specification with DCTDecode (raw JPEG streams) for zero compression loss
/// and high execution speed without requiring external native dependencies.
class PdfAssemblerService {
  /// Converts a list of image paths into a single multi-page PDF file saved at [outputPath].
  /// Returns the created File.
  static Future<File> assembleImagesToPdf({
    required List<String> imagePaths,
    required String outputPath,
  }) async {
    if (imagePaths.isEmpty) {
      throw ArgumentError('imagePaths cannot be empty');
    }

    final pdfBytes = await assembleImagesToBytes(imagePaths);
    final outFile = File(outputPath);
    if (!outFile.parent.existsSync()) {
      outFile.parent.createSync(recursive: true);
    }
    await outFile.writeAsBytes(pdfBytes, flush: true);
    return outFile;
  }

  /// Converts a list of image file paths into multi-page PDF bytes.
  static Future<Uint8List> assembleImagesToBytes(List<String> imagePaths) async {
    final List<_PdfPageImage> pages = [];

    for (final path in imagePaths) {
      final file = File(path);
      if (!await file.exists()) continue;
      final rawBytes = await file.readAsBytes();
      if (rawBytes.isEmpty) continue;

      int width = 0;
      int height = 0;
      Uint8List jpegBytes;

      // Check if it's already a valid JPEG
      final isJpeg = rawBytes.length > 3 &&
          rawBytes[0] == 0xFF &&
          rawBytes[1] == 0xD8 &&
          rawBytes[rawBytes.length - 2] == 0xFF &&
          rawBytes[rawBytes.length - 1] == 0xD9;

      if (isJpeg) {
        jpegBytes = rawBytes;
        final dims = _getJpegDimensions(rawBytes);
        if (dims != null) {
          width = dims.width;
          height = dims.height;
        } else {
          final decoded = img.decodeImage(rawBytes);
          if (decoded != null) {
            width = decoded.width;
            height = decoded.height;
          }
        }
      } else {
        // Decode and re-encode to JPEG for embedding
        final decoded = img.decodeImage(rawBytes);
        if (decoded != null) {
          width = decoded.width;
          height = decoded.height;
          jpegBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 92));
        } else {
          continue;
        }
      }

      if (width > 0 && height > 0) {
        pages.add(_PdfPageImage(
          width: width,
          height: height,
          jpegBytes: jpegBytes,
        ));
      }
    }

    if (pages.isEmpty) {
      throw StateError('No valid images could be processed to build PDF.');
    }

    return _buildPdfDocument(pages);
  }

  /// Builds a PDF 1.4 document from the given list of pages.
  static Uint8List _buildPdfDocument(List<_PdfPageImage> pages) {
    final builder = BytesBuilder();
    final List<int> xrefOffsets = [0]; // Index 0 is special free object

    void writeString(String s) {
      builder.add(utf8.encode(s));
    }

    // 1. Header
    writeString('%PDF-1.4\n%\xFF\xFF\xFF\xFF\n');

    final int totalPages = pages.length;
    final int totalObjects = 2 + (totalPages * 3);

    // Helper to record offset of next object
    void startObject(int expectedObjId) {
      xrefOffsets.add(builder.length);
      writeString('$expectedObjId 0 obj\n');
    }

    // Obj 1: Catalog
    startObject(1);
    writeString('<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');

    // Obj 2: Pages
    startObject(2);
    final kidsList = List.generate(totalPages, (i) => '${3 + i * 3} 0 R').join(' ');
    writeString('<< /Type /Pages /Kids [$kidsList] /Count $totalPages >>\nendobj\n');

    // Pages objects
    for (int i = 0; i < totalPages; i++) {
      final page = pages[i];
      final pageObjId = 3 + i * 3;
      final contentObjId = 4 + i * 3;
      final imgObjId = 5 + i * 3;
      final imgName = 'Im$i';

      // Page Object
      startObject(pageObjId);
      writeString(
        '<<\n'
        '  /Type /Page\n'
        '  /Parent 2 0 R\n'
        '  /MediaBox [0 0 ${page.width} ${page.height}]\n'
        '  /Resources <<\n'
        '    /ProcSet [/PDF /ImageC]\n'
        '    /XObject << /$imgName $imgObjId 0 R >>\n'
        '  >>\n'
        '  /Contents $contentObjId 0 R\n'
        '>>\nendobj\n',
      );

      // Content Stream Object
      final contentStream = utf8.encode(
        'q\n'
        '${page.width} 0 0 ${page.height} 0 0 cm\n'
        '/$imgName Do\n'
        'Q\n',
      );
      startObject(contentObjId);
      writeString('<< /Length ${contentStream.length} >>\nstream\n');
      builder.add(contentStream);
      writeString('\nendstream\nendobj\n');

      // Image XObject
      startObject(imgObjId);
      writeString(
        '<<\n'
        '  /Type /XObject\n'
        '  /Subtype /Image\n'
        '  /Width ${page.width}\n'
        '  /Height ${page.height}\n'
        '  /ColorSpace /DeviceRGB\n'
        '  /BitsPerComponent 8\n'
        '  /Filter /DCTDecode\n'
        '  /Length ${page.jpegBytes.length}\n'
        '>>\nstream\n',
      );
      builder.add(page.jpegBytes);
      writeString('\nendstream\nendobj\n');
    }

    // XREF Table
    final int xrefStartOffset = builder.length;
    writeString('xref\n0 ${totalObjects + 1}\n');
    writeString('0000000000 65535 f \n');
    for (int i = 1; i <= totalObjects; i++) {
      final offset = xrefOffsets[i];
      final offsetStr = offset.toString().padLeft(10, '0');
      writeString('$offsetStr 00000 n \n');
    }

    // Trailer
    writeString(
      'trailer\n'
      '<<\n'
      '  /Size ${totalObjects + 1}\n'
      '  /Root 1 0 R\n'
      '>>\n'
      'startxref\n'
      '$xrefStartOffset\n'
      '%%EOF\n',
    );

    return builder.toBytes();
  }

  static _Dimensions? _getJpegDimensions(Uint8List bytes) {
    int offset = 2;
    while (offset < bytes.length - 8) {
      if (bytes[offset] != 0xFF) break;
      final marker = bytes[offset + 1];
      // SOF markers: SOF0 (0xC0) to SOF2 (0xC2)
      if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) {
        final h = (bytes[offset + 5] << 8) | bytes[offset + 6];
        final w = (bytes[offset + 7] << 8) | bytes[offset + 8];
        return _Dimensions(width: w, height: h);
      }
      // Skip variable length markers
      if (marker == 0xD9 || marker == 0xDA) break; // EOI or SOS
      final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
      if (length < 2) break;
      offset += 2 + length;
    }
    return null;
  }

  /// Counts the total number of pages in a PDF file.
  /// Inspects the PDF's internal catalog/page tree structure without requiring heavy external dependencies.
  static Future<int> countPdfPages(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return 1;
      final bytes = await file.readAsBytes();
      return countPdfPagesFromBytes(bytes);
    } catch (_) {
      return 1;
    }
  }

  /// Counts the total number of pages from raw PDF bytes.
  static int countPdfPagesFromBytes(Uint8List bytes) {
    try {
      if (bytes.length < 10) return 1;
      // Decode with latin1 to safely examine byte characters
      final content = latin1.decode(bytes);

      // Strategy 1: Check root /Pages object count: /Type\s*/Pages\b.*?/Count\s+(\d+)
      final pagesCountMatches = RegExp(r'/Type\s*/Pages\b[^>]*?/Count\s+(\d+)').allMatches(content);
      int maxPages = 0;
      for (final m in pagesCountMatches) {
        final val = int.tryParse(m.group(1) ?? '');
        if (val != null && val > maxPages) {
          maxPages = val;
        }
      }
      if (maxPages > 0) return maxPages;

      // Strategy 2: Count individual page objects: /Type\s*/Page\b(?!s)
      final pageMatches = RegExp(r'/Type\s*/Page\b(?!s)').allMatches(content);
      if (pageMatches.isNotEmpty) {
        return pageMatches.length;
      }
    } catch (_) {}
    return 1;
  }
}

class _PdfPageImage {
  final int width;
  final int height;
  final Uint8List jpegBytes;

  const _PdfPageImage({
    required this.width,
    required this.height,
    required this.jpegBytes,
  });
}

class _Dimensions {
  final int width;
  final int height;

  const _Dimensions({required this.width, required this.height});
}
