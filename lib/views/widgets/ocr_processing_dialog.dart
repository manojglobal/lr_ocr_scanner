import 'package:flutter/material.dart';
import '../../state/batch_controller.dart';

/// Screen 3: OCR Processing (Step Checklist Dialog matching Web screen3_ocr).
class OcrProcessingDialog extends StatefulWidget {
  static const Color brandBlue = Color(0xFF0284C7);
  static const Color brandEmerald = Color(0xFF10B981);
  static const Color emeraldText = Color(0xFF059669);
  static const Color slateMuted = Color(0xFF94A3B8);
  static const Color slateBorder = Color(0xFFCBD5E1);

  final BatchProcessingController? controller;
  final int currentStep; // 1 to 5 (preserved for backward compatibility & testing)
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
  State<OcrProcessingDialog> createState() => _OcrProcessingDialogState();
}

class _OcrProcessingDialogState extends State<OcrProcessingDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _bounceAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _bounceAnimation = Tween<double>(begin: 0.0, end: -6.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller != null) {
      return ListenableBuilder(
        listenable: widget.controller!,
        builder: (context, _) {
          final step = widget.controller!.currentOcrStep;
          final file = widget.controller!.currentProcessingFileName.isNotEmpty
              ? widget.controller!.currentProcessingFileName
              : widget.currentFile;
          final fIndex = widget.controller!.processingFileIndex > 0
              ? widget.controller!.processingFileIndex
              : widget.fileIndex;
          final fTotal = widget.controller!.processingTotalFiles > 0
              ? widget.controller!.processingTotalFiles
              : widget.totalFiles;
          return _buildCard(context, step, file, fIndex, fTotal);
        },
      );
    }

    return _buildCard(
      context,
      widget.currentStep,
      widget.currentFile,
      widget.fileIndex,
      widget.totalFiles,
    );
  }

  Widget _buildCard(
    BuildContext context,
    int step,
    String file,
    int fIndex,
    int fTotal,
  ) {
    String titleText = 'Extracting LR Information...';
    if (fTotal > 1) {
      titleText = 'Reading Consignment ($fIndex/$fTotal)...';
    } else if (file.isNotEmpty && file != 'LR Document') {
      titleText = 'Reading Consignment ($file)...';
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFE2E8F0)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1A000000),
              offset: Offset(0, 10),
              blurRadius: 25,
              spreadRadius: -5,
            ),
            BoxShadow(
              color: Color(0x0A000000),
              offset: Offset(0, 8),
              blurRadius: 10,
              spreadRadius: -6,
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Animated Scanner Graphic matching Web screen3_ocr
            AnimatedBuilder(
              animation: _bounceAnimation,
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(0, _bounceAnimation.value),
                  child: child,
                );
              },
              child: Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F9FF),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x080284C7),
                      offset: Offset(0, 2),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(
                    Icons.find_in_page_outlined,
                    size: 38,
                    color: OcrProcessingDialog.brandBlue,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),

            // Title & Subtitle matching Web screen3_ocr
            Text(
              titleText,
              key: const Key('ocr_processing_title'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1E293B),
                letterSpacing: -0.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            const Text(
              'Please wait while the system reads and extracts the consignment details from your LR image.',
              key: Key('ocr_processing_sub'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF64748B),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 22),

            // 5-Step Process Checklist matching Web commit 28792914
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFF1F5F9)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildStepRow(
                    stepNumber: 1,
                    label: 'Image(s) Uploaded',
                    currentStep: step,
                  ),
                  const SizedBox(height: 10),
                  _buildStepRow(
                    stepNumber: 2,
                    label: 'Reading LR Document',
                    currentStep: step,
                  ),
                  const SizedBox(height: 10),
                  _buildStepRow(
                    stepNumber: 3,
                    label: step > 3
                        ? 'Extraction Complete'
                        : 'Extracting Consignment Details',
                    currentStep: step,
                  ),
                  const SizedBox(height: 10),
                  _buildStepRow(
                    stepNumber: 4,
                    label: step > 4
                        ? 'Mapped with BNF 49-Column Format'
                        : 'Mapping with BNF 49-Column Format',
                    currentStep: step,
                  ),
                  const SizedBox(height: 10),
                  _buildStepRow(
                    stepNumber: 5,
                    label: step >= 5
                        ? 'Data Validated & Blanks Preserved'
                        : 'Validating Data & Preserving Blanks',
                    currentStep: step,
                    isLast: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepRow({
    required int stepNumber,
    required String label,
    required int currentStep,
    bool isLast = false,
  }) {
    final bool isCompleted = currentStep > stepNumber;
    final bool isActive = currentStep == stepNumber;

    Widget iconWidget;
    Color textColor;

    if (isCompleted) {
      iconWidget = const Icon(
        Icons.check_circle_rounded,
        size: 18,
        color: OcrProcessingDialog.brandEmerald,
      );
      textColor = OcrProcessingDialog.emeraldText;
    } else if (isActive) {
      iconWidget = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2.2,
          color: OcrProcessingDialog.brandBlue,
        ),
      );
      textColor = OcrProcessingDialog.brandBlue;
    } else {
      iconWidget = const Icon(
        Icons.radio_button_unchecked,
        size: 18,
        color: OcrProcessingDialog.slateBorder,
      );
      textColor = OcrProcessingDialog.slateMuted;
    }

    return Row(
      children: [
        SizedBox(
          width: 22,
          height: 22,
          child: Center(child: iconWidget),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: isActive || isCompleted ? FontWeight.w600 : FontWeight.w500,
              color: textColor,
            ),
          ),
        ),
      ],
    );
  }
}
