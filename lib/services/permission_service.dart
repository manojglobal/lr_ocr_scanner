import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

/// Centralized service for requesting and verifying runtime permissions.
class PermissionService {
  /// Request camera permission for live photo capture.
  Future<bool> requestCameraPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted || status.isLimited;
  }

  /// Request media/gallery permission for photo selection.
  /// Handles Android 13+ (READ_MEDIA_IMAGES) and Android 10-12 (READ_EXTERNAL_STORAGE).
  Future<bool> requestGalleryPermission() async {
    if (Platform.isAndroid) {
      // Permission.photos maps to READ_MEDIA_IMAGES on Android 13+
      final photosStatus = await Permission.photos.request();
      if (photosStatus.isGranted || photosStatus.isLimited) {
        return true;
      }

      // Fallback for Android 10-12 (API 29-32)
      final storageStatus = await Permission.storage.request();
      return storageStatus.isGranted || storageStatus.isLimited;
    }
    final status = await Permission.photos.request();
    return status.isGranted || status.isLimited;
  }

  /// Check whether camera permission is currently granted.
  Future<bool> hasCameraPermission() async {
    final status = await Permission.camera.status;
    return status.isGranted || status.isLimited;
  }

  /// Check whether gallery access is currently granted.
  Future<bool> hasGalleryPermission() async {
    if (Platform.isAndroid) {
      final photosStatus = await Permission.photos.status;
      if (photosStatus.isGranted || photosStatus.isLimited) return true;
      final storageStatus = await Permission.storage.status;
      return storageStatus.isGranted || storageStatus.isLimited;
    }
    final status = await Permission.photos.status;
    return status.isGranted || status.isLimited;
  }

  /// Check if camera permission is permanently denied (requires opening settings).
  Future<bool> isCameraPermanentlyDenied() async {
    return Permission.camera.isPermanentlyDenied;
  }

  /// Check if gallery permission is permanently denied.
  Future<bool> isGalleryPermanentlyDenied() async {
    if (Platform.isAndroid) {
      final photosDenied = await Permission.photos.isPermanentlyDenied;
      final storageDenied = await Permission.storage.isPermanentlyDenied;
      return photosDenied || storageDenied;
    }
    return Permission.photos.isPermanentlyDenied;
  }

  /// Open application settings if permission was permanently denied.
  Future<bool> openSettings() async {
    return openAppSettings();
  }
}
