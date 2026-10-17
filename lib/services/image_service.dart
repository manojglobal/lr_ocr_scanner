import 'package:image_picker/image_picker.dart';

/// Wraps ImagePicker for single camera captures and batch gallery selections.
class ImageService {
  final ImagePicker _picker;

  ImageService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  /// Captures a single photo using the device camera.
  /// Captures a single photo using the device camera at FULL sensor resolution.
  /// Does NOT downscale or compress with lossy quality before OCR.
  /// Returns the local file path, or null if cancelled or errored.
  Future<String?> captureFromCamera({int? imageQuality}) async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: imageQuality, // Full quality when null
        preferredCameraDevice: CameraDevice.rear,
        requestFullMetadata: false,
      );
      return photo?.path;
    } catch (_) {
      return null;
    }
  }

  /// Selects a single image from the photo gallery at FULL resolution.
  /// Returns the local file path, or null if cancelled or errored.
  Future<String?> pickSingleImage({int? imageQuality}) async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: imageQuality,
        requestFullMetadata: false,
      );
      return photo?.path;
    } catch (_) {
      return null;
    }
  }

  /// Selects multiple images from the photo gallery at FULL resolution.
  /// Returns a list of local file paths.
  Future<List<String>> pickMultipleImages({int? imageQuality}) async {
    try {
      final List<XFile> pickedFiles = await _picker.pickMultiImage(
        imageQuality: imageQuality, // Full quality when null
        requestFullMetadata: false,
      );
      return pickedFiles.map((file) => file.path).toList();
    } catch (_) {
      return [];
    }
  }

  /// Recovers any image captured before Android killed the app in the background.
  Future<String?> retrieveLostData() async {
    try {
      final LostDataResponse response = await _picker.retrieveLostData();
      if (response.isEmpty) return null;
      return response.file?.path;
    } catch (_) {
      return null;
    }
  }
}
