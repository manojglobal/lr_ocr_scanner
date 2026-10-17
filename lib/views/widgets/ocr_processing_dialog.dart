import 'package:flutter/material.dart';
import '../../state/batch_controller.dart';

/// Screen 3: OCR Processing (5-Step Checklist Dialog during document extraction).
class OcrProcessingDialog extends StatelessWidget {
  static const Color brandBlue = Color(0xFF0284C7);

  final BatchProcessingController? controller;
  final int currentStep; // 1 to 5 (preserved for backward compatibility)
  final String currentFile;
  final int fileIndex;
  final int totalFiles;

  const OcrProcessingDialog({
    super.key,
    this.controller,
    this.currentStep = 1,
    this.currentFile = 'LR Document',
    this.fileIndex = 1,
    this.totalFiles = 1,
  });

  @override
  Widget build(BuildContext context) {
    if (controller != null) {
      return ListenableBuilder(
        listenable: controller!,
        builder: (context, _) {
          final step = controller!.currentOcrStep;
          final file = controller!.currentProcessingFileName.isNotEmpty
              ? controller!.currentProcessingFileName
              : currentFile;
          final fIndex = controller!.processingFileIndex > 0 ? controller!.processingFileIndex : fileIndex;
          final fTotal = controller!.processingTotalFiles > 0 ? controller!.processingTotalFiles : totalFiles;
          return _buildDialogContent(context, step, file, fIndex, fTotal);
        },
      );
    }

    return _buildDialogContent(context, currentStep, currentFile, fileIndex, totalFiles);
  }

  Widget _buildDialogContent(
    BuildContext context,
    int step,
    String file,
    int fIndex,
    int fTotal,
  ) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Scanning Icon
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: const Color(0xFFE0F2FE),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Center(
                child: Icon(Icons.document_scanner, size: 30, color: brandBlue),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Uploading & Processing LR...',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 4),
            Text(
              'Reading Consignment $fIndex of $fTotal ($file)',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 18),
            // Single unified loading progress (no separate step breakdown)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: const LinearProgressIndicator(
                minHeight: 6,
                backgroundColor: Color(0xFFE2E8F0),
                color: brandBlue,
              ),
            ),
            const SizedBox(height: 16),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: brandBlue),
                ),
                SizedBox(width: 8),
                Text(
                  'Processing document in background...',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
