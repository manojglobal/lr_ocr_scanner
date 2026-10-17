import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Preprocesses captured or uploaded images before OCR to significantly boost
/// recognition accuracy on handwritten text, low-contrast ink, small numbers, and tables.
class ImagePreprocessor {
  /// Preprocesses the image at [imagePath] and returns the path to the enhanced image file.
  /// - If [aggressive] is true, applies contrast stretching and unsharp masking.
  /// - If [skewAngleDegrees] is non-zero, rotates the image to deskew prior to OCR.
  /// If preprocessing fails or image cannot be decoded, returns the original [imagePath] safely.
  Future<String> preprocessForOcr(
    String imagePath, {
    bool aggressive = true,
    double skewAngleDegrees = 0.0,
  }) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return imagePath;

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return imagePath;

      // Offload pixel manipulation to background isolate
      final enhancedBytes = await compute(
        _processBytesWithConfig,
        _PreprocessorConfig(
          rawBytes: bytes,
          aggressive: aggressive,
          skewAngleDegrees: skewAngleDegrees,
        ),
      );
      if (enhancedBytes == null || enhancedBytes.isEmpty) {
        return imagePath;
      }

      // Save enhanced image to temporary directory
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      final enhancedPath = '${tempDir.path}/ocr_prep_$timestamp.jpg';

      final enhancedFile = File(enhancedPath);
      await enhancedFile.writeAsBytes(enhancedBytes, flush: true);
      return enhancedPath;
    } catch (_) {
      // Graceful fallback to original image on any error
      return imagePath;
    }
  }

  /// Checks whether an image is predominantly orange/yellow (like handwritten transport bilties).
  static Future<bool> isOrangeYellowImage(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return false;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return false;
      return await compute(_checkIfOrangeYellow, bytes);
    } catch (_) {
      return false;
    }
  }

  static bool _checkIfOrangeYellow(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return false;
      final thumb = img.copyResize(decoded, width: 100, height: 100);
      int yellowCount = 0;
      final totalPixels = thumb.width * thumb.height;
      for (int y = 0; y < thumb.height; y++) {
        for (int x = 0; x < thumb.width; x++) {
          final pixel = thumb.getPixel(x, y);
          final r = pixel.r;
          final g = pixel.g;
          final b = pixel.b;
          if (r > 115 && g > 90 && (r - b > 35 || g - b > 30)) {
            yellowCount++;
          }
        }
      }
      return (yellowCount / totalPixels) > 0.15;
    } catch (_) {
      return false;
    }
  }

  /// Background isolate image processor with configurable enhancement modes.
  static Uint8List? _processBytesWithConfig(_PreprocessorConfig config) {
    try {
      final decoded = img.decodeImage(config.rawBytes);
      if (decoded == null) return null;

      // 1. Auto-orient image based on EXIF metadata
      img.Image processed = img.bakeOrientation(decoded);

      // 2. Deskew / rotate if skew angle is specified
      if (config.skewAngleDegrees.abs() >= 0.5 && config.skewAngleDegrees.abs() <= 45.0) {
        processed = img.copyRotate(processed, angle: -config.skewAngleDegrees);
      }

      final origWidth = processed.width;
      final origHeight = processed.height;

      // 3. Intelligent Resolution Optimization:
      // A) Downscale ultra-high resolution images (>2400px) to prevent OOM
      if (origWidth > 2400 || origHeight > 2400) {
        final scale = 2200.0 / max(origWidth, origHeight);
        final targetW = (origWidth * scale).round();
        final targetH = (origHeight * scale).round();
        processed = img.copyResize(
          processed,
          width: targetW,
          height: targetH,
          interpolation: img.Interpolation.linear,
        );
      }
      // B) Upscale low resolution images (<1600x1200) by up to 2x with cubic interpolation
      else if (origWidth < 1600 && origHeight < 1200) {
        final scale = min(2.0, 2400.0 / max(origWidth, origHeight));
        if (scale > 1.2) {
          final targetW = (origWidth * scale).round();
          final targetH = (origHeight * scale).round();
          processed = img.copyResize(
            processed,
            width: targetW,
            height: targetH,
            interpolation: img.Interpolation.cubic,
          );
        }
      }

      // 4. Aggressive mode (Pass 2): contrast stretch & sharpen for faint blue ink / handwriting
      if (config.aggressive) {
        processed = img.contrast(processed, contrast: 125);
        processed = _sharpenImage(processed);
      }

      // 5. Encode as high-quality JPEG
      return Uint8List.fromList(img.encodeJpg(processed, quality: 95));
    } catch (_) {
      return null;
    }
  }

  /// Mild edge-sharpening convolution kernel to enhance character boundaries.
  static img.Image _sharpenImage(img.Image image) {
    const kernel = [
      0.0, -0.5, 0.0,
      -0.5, 3.0, -0.5,
      0.0, -0.5, 0.0,
    ];
    return img.convolution(image, filter: kernel, div: 1.0);
  }
}

class _PreprocessorConfig {
  final Uint8List rawBytes;
  final bool aggressive;
  final double skewAngleDegrees;

  _PreprocessorConfig({
    required this.rawBytes,
    required this.aggressive,
    required this.skewAngleDegrees,
  });
}
