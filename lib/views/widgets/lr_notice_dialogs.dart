import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../services/pdf_assembler_service.dart';
import '../../state/batch_controller.dart';
import 'ocr_processing_dialog.dart';

const String defaultMultipleLrsMessage =
    'Multiple LR documents detected. Please upload documents belonging to only one LR at a time.';

const String defaultPageLimitMessage =
    'Maximum 15 pages are allowed per upload. Please upload documents containing 15 pages or fewer.';

const String defaultInvalidLrMessage =
    'Invalid LR – Please upload a valid LR document.';

/// Displays the "Multiple LRs Not Allowed" modal matching Web showMultipleLrsNotAllowedModal.
Future<void> showMultipleLrsNotAllowedDialog(
  BuildContext context, {
  String? message,
  VoidCallback? onDismissed,
}) {
  final displayMessage = (message != null && message.trim().isNotEmpty)
      ? message.trim()
      : defaultMultipleLrsMessage;

  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFFDE68A)),
            ),
            child: const Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFD97706),
              size: 24,
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Multiple LRs Not Allowed',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Document Validation',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      content: Text(
        displayMessage,
        style: const TextStyle(fontSize: 13, height: 1.4),
      ),
      actions: [
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF0284C7),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  ).whenComplete(() {
    onDismissed?.call();
  });
}

/// Runs [action] while displaying [OcrProcessingDialog] on a dedicated route
/// so closing it never dismisses subsequent validation error dialogs or parent screens.
Future<T> runWithOcrProcessingRoute<T>({
  required BuildContext context,
  required BatchProcessingController controller,
  required Future<T> Function() action,
}) async {
  final DialogRoute<void> route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => OcrProcessingDialog(controller: controller),
  );
  Navigator.of(context).push(route);
  try {
    return await action();
  } finally {
    if (route.isActive) {
      route.navigator?.removeRoute(route);
    }
  }
}

/// Presents a notice dialog immediately when draining after an async upload flow,
/// or schedules it after the current frame (guaranteeing a visual update) when triggered by a listener.
void presentNoticeDialog({
  required bool immediate,
  required VoidCallback show,
}) {
  if (immediate) {
    show();
    return;
  }
  WidgetsBinding.instance.addPostFrameCallback((_) {
    show();
  });
  WidgetsBinding.instance.ensureVisualUpdate();
}

/// Displays the 10 MB per-file validation dialog matching Web showFileSizeValidationModal.
Future<void> showFileSizeValidationDialog(
  BuildContext context, {
  required String fileName,
  required String sizeMb,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 28),
          SizedBox(width: 8),
          Text(
            'File Size Validation',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Limit Exceeded',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'File "$fileName" ($sizeMb MB) exceeds the allowed limit of 10 MB per file. Please choose files smaller than 10 MB.',
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0F172A)),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Resolves a picked [PlatformFile] to a readable local file path without basename collisions.
Future<String?> resolvePickedPlatformFilePath(PlatformFile file, {int index = 0}) async {
  if (file.path != null && file.path!.isNotEmpty && File(file.path!).existsSync()) {
    return file.path!;
  }
  try {
    if (file.xFile.path.isNotEmpty && File(file.xFile.path).existsSync()) {
      return file.xFile.path;
    }
  } catch (_) {}

  for (final reader in [file.readAsBytes, file.xFile.readAsBytes]) {
    try {
      final bytes = await reader();
      if (bytes.isNotEmpty) {
        final tmp = await getTemporaryDirectory();
        final uniqueDir = Directory('${tmp.path}/pick_${DateTime.now().microsecondsSinceEpoch}_$index');
        if (!uniqueDir.existsSync()) uniqueDir.createSync(recursive: true);
        final safeName = file.name.isNotEmpty
            ? file.name
            : 'upload_${DateTime.now().millisecondsSinceEpoch}_$index.pdf';
        final localFile = File('${uniqueDir.path}/$safeName');
        await localFile.writeAsBytes(bytes, flush: true);
        return localFile.path;
      }
    } catch (_) {}
  }
  return null;
}

/// Validates that every picked [PlatformFile] is <= 10 MB; shows dialog and returns false if any exceeds.
Future<bool> validatePickedFileSizes(
  BuildContext context,
  List<PlatformFile> files,
) async {
  for (final f in files) {
    final fSize = f.lengthSync() ??
        (await f.length()) ??
        (f.path != null && File(f.path!).existsSync() ? File(f.path!).lengthSync() : 0);
    if (fSize > 10 * 1024 * 1024) {
      if (context.mounted) {
        final sizeMb = (fSize / (1024 * 1024)).toStringAsFixed(2);
        await showFileSizeValidationDialog(context, fileName: f.name, sizeMb: sizeMb);
      }
      return false;
    }
  }
  return true;
}

/// Validates that every local file path is <= 10 MB; shows dialog and returns false if any exceeds.
Future<bool> validatePathFileSizes(
  BuildContext context,
  List<String> paths,
) async {
  for (final p in paths) {
    final file = File(p);
    if (!file.existsSync()) continue;
    final fSize = file.lengthSync();
    if (fSize > 10 * 1024 * 1024) {
      if (context.mounted) {
        final name = p.split(RegExp(r'[/\\]')).last;
        final sizeMb = (fSize / (1024 * 1024)).toStringAsFixed(2);
        await showFileSizeValidationDialog(context, fileName: name, sizeMb: sizeMb);
      }
      return false;
    }
  }
  return true;
}

/// Counts total pages across selected images (1 page each) and PDFs.
Future<int> countTotalUploadPages(List<String> paths) async {
  int totalPages = 0;
  for (final p in paths) {
    final ext = p.split('.').last.toLowerCase();
    if (ext == 'pdf') {
      final count = await PdfAssemblerService.countPdfPages(p);
      totalPages += count > 0 ? count : 1;
    } else {
      totalPages += 1;
    }
  }
  return totalPages;
}
