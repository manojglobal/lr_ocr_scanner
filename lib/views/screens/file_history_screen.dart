import 'package:flutter/material.dart';
import '../../state/batch_controller.dart';
import 'excel_preview_screen.dart';

/// Screen displaying History matching Web version:
/// - Replaces 'File Lifecycle & History' with 'History'
/// - Displays Generated Excel Exports History table with retention and download actions
/// - Excludes Android-only Recycle Bin, 30-day manual retention purge, and Snapshot diffs
class FileHistoryScreen extends StatelessWidget {
  final BatchProcessingController controller;
  final String? initialItemId;
  final int initialTabIndex;

  const FileHistoryScreen({
    super.key,
    required this.controller,
    this.initialItemId,
    this.initialTabIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    return ExcelPreviewScreen(
      controller: controller,
      initialTab: 1, // Opens Sheet 2 (Generated Excel Exports History)
    );
  }
}
