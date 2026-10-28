import 'package:flutter/material.dart';
import '../config/document_schema.dart';
import '../models/batch_item.dart';
import '../state/batch_controller.dart';
import 'widgets/billing_image_viewer.dart';
import 'widgets/editable_data_table.dart';

/// Screen for reviewing, editing, and exporting parsed batch records to Excel.
class ReviewScreen extends StatefulWidget {
  final BatchProcessingController controller;

  const ReviewScreen({super.key, required this.controller});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  bool _isExporting = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final items = controller.items;
        final schema = controller.currentSchema;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 1,
            titleSpacing: 14,
            title: const Text('Review & Export Data', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            actions: const [],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(40),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                child: Row(
                  children: [
                    if (items.isNotEmpty) ...[
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF0284C7),
                          backgroundColor: const Color(0xFFF0F9FF),
                          side: const BorderSide(color: Color(0xFFBAE6FD)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          minimumSize: const Size(0, 30),
                        ),
                        icon: const Icon(Icons.photo_library_outlined, size: 14),
                        label: Text('LR Image (${items.length})', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        onPressed: () => BillingImageViewer.show(context, items: items),
                      ),
                      const SizedBox(width: 8),
                    ],
                    const Spacer(),
                    PopupMenuButton<DocumentSchema>(
                      tooltip: 'Select Document Schema',
                      initialValue: schema,
                      onSelected: (selected) {
                        controller.setSchema(selected);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Switched schema to ${selected.name}'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFCBD5E1)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.tune, size: 14, color: Color(0xFF334155)),
                            const SizedBox(width: 6),
                            Text(schema.name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
                            const SizedBox(width: 2),
                            const Icon(Icons.arrow_drop_down, size: 14, color: Colors.blueGrey),
                          ],
                        ),
                      ),
                      itemBuilder: (ctx) => DocumentSchema.availableSchemas.map((s) {
                        return PopupMenuItem(
                          value: s,
                          child: Row(
                            children: [
                              Icon(
                                s.id == schema.id
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                                size: 18,
                                color: s.id == schema.id
                                    ? theme.colorScheme.primary
                                    : null,
                              ),
                              const SizedBox(width: 8),
                              Text(s.name),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
          ),
          body: Column(
            children: [
              // Summary Stats Banner
              _buildStatsBanner(context, controller),

              // Editable Table
              Expanded(
                child: EditableDataTable(
                  items: items,
                  schema: schema,
                  onCellEdited: (itemId, fieldKey, newValue) {
                    controller.updateRecordField(itemId, fieldKey, newValue);
                  },
                  onTableCellEdited: (itemId, rowIndex, colIndex, newValue) {
                    controller.updateTableCell(itemId, rowIndex, colIndex, newValue);
                  },
                  onViewImage: (item, idx) => BillingImageViewer.show(
                    context,
                    items: items,
                    initialIndex: idx,
                  ),
                ),
              ),

              // Bottom Action Bar
              _buildBottomBar(context, controller),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatsBanner(
      BuildContext context, BatchProcessingController controller) {
    final theme = Theme.of(context);
    final items = controller.items;
    final total = items.length;
    final completed = controller.completedCount;
    final errors = controller.errorCount;
    final partial = items.where((i) => i.missingFields.isNotEmpty && i.status != BatchItemStatus.error).length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.surfaceContainerHighest.withAlpha(120),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _statBadge('Total', total.toString(), Colors.blueGrey),
          _statBadge('Completed', (completed - partial).clamp(0, total).toString(), Colors.green),
          _statBadge('Partial', partial.toString(), Colors.amber.shade800),
          _statBadge('Failed', errors.toString(), Colors.red),
        ],
      ),
    );
  }

  Widget _statBadge(String label, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
        ),
      ],
    );
  }

  Widget _buildBottomBar(
      BuildContext context, BatchProcessingController controller) {
    final theme = Theme.of(context);
    final canExport = controller.canExport && !_isExporting;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(20),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.icon(
            onPressed: canExport ? () => _handleExport(controller) : null,
            icon: _isExporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.file_download),
            label: Text(
              _isExporting
                  ? 'Generating Spreadsheet...'
                  : 'Export to Excel (.xlsx)',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleExport(BatchProcessingController controller) async {
    setState(() => _isExporting = true);

    try {
      final filePath = await controller.exportToExcel();
      if (!mounted) return;

      if (filePath != null) {
        _showExportSuccessSheet(context, controller, filePath);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(controller.statusMessage ?? 'Export failed'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  void _showExportSuccessSheet(
    BuildContext context,
    BatchProcessingController controller,
    String filePath,
  ) {
    final fileName = filePath.split('/').last.split('\\').last;

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Icon(Icons.check_circle, color: Colors.green, size: 54),
            const SizedBox(height: 12),
            const Text(
              'Excel File Ready!',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              fileName,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      await controller.openLastExport();
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open File'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      await controller.shareLastExport();
                    },
                    icon: const Icon(Icons.share),
                    label: const Text('Share Sheet'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
