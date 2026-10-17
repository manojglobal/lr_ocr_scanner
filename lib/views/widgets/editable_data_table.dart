import 'package:flutter/material.dart';
import '../../config/document_schema.dart';
import '../../models/batch_item.dart';
import '../../models/extraction_result.dart';

/// Interactive, horizontally and vertically scrollable data table
/// where each cell can be tapped to edit extracted values inline,
/// supporting dynamic schema columns and 2D table structures.
class EditableDataTable extends StatelessWidget {
  final List<BatchItem> items;
  final DocumentSchema schema;
  final void Function(String itemId, String fieldKey, String newValue) onCellEdited;
  final void Function(String itemId, int rowIndex, int colIndex, String newValue)? onTableCellEdited;
  final void Function(BatchItem item, int index)? onViewImage;

  const EditableDataTable({
    super.key,
    required this.items,
    required this.schema,
    required this.onCellEdited,
    this.onTableCellEdited,
    this.onViewImage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.table_chart_outlined, size: 64, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text(
                'No records in queue',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Add images from Camera or Gallery to review extracted data here.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Determine effective fields: either from predefined schema or dynamically from items
    final effectiveFields = _getEffectiveFields();
    final hasAnyTables = items.any((i) => i.hasTable);

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(
                  theme.colorScheme.primaryContainer.withAlpha(90),
                ),
                dataRowMinHeight: 52,
                dataRowMaxHeight: 64,
                columnSpacing: 20,
                horizontalMargin: 16,
                columns: [
                  const DataColumn(
                    label: Text(
                      'Image File',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const DataColumn(
                    label: Text(
                      'Status',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (hasAnyTables)
                    const DataColumn(
                      label: Text(
                        'Detected Table',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ...effectiveFields.map(
                    (field) => DataColumn(
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            field.displayName,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          if (field.isRequired)
                            const Text(
                              ' *',
                              style: TextStyle(
                                color: Colors.red,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                rows: items.map((item) {
                  return DataRow(
                    color: WidgetStateProperty.resolveWith<Color?>((states) {
                      if (item.extractionStatus == ExtractionStatus.failed) {
                        return Colors.red.withAlpha(20);
                      }
                      if (item.extractionStatus == ExtractionStatus.partial) {
                        return Colors.amber.withAlpha(20);
                      }
                      return null;
                    }),
                    cells: [
                      // File Name Cell (tap to view billing document)
                      DataCell(
                        InkWell(
                          onTap: onViewImage != null
                              ? () => onViewImage!(item, items.indexOf(item))
                              : null,
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.image_outlined, size: 16, color: Colors.blue),
                                const SizedBox(width: 6),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 130),
                                  child: Text(
                                    item.fileName,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: Colors.blue,
                                      decoration: TextDecoration.underline,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // Status Cell
                      DataCell(_buildStatusCell(item)),

                      // Detected Table Cell (if tables are present in batch)
                      if (hasAnyTables)
                        DataCell(
                          item.hasTable
                              ? ActionChip(
                                  avatar: const Icon(Icons.table_view, size: 16),
                                  label: Text(
                                    '${item.tableHeaders.length} cols × ${item.tableRows.length} rows',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  onPressed: () => _showTableViewerDialog(context, item),
                                )
                              : const Text('—', style: TextStyle(color: Colors.grey)),
                        ),

                      // Dynamic / Schema Field Cells (Editable)
                      ...effectiveFields.map((field) {
                        final value = item.record[field.key] ?? '';
                        final isMissing = field.isRequired && value.trim().isEmpty;

                        return DataCell(
                          InkWell(
                            onTap: () => _showEditDialog(
                              context,
                              item,
                              field,
                              value,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                color: isMissing
                                    ? Colors.amber.withAlpha(40)
                                    : Colors.transparent,
                                border: Border.all(
                                  color: isMissing
                                      ? Colors.amber.shade700
                                      : Colors.grey.withAlpha(60),
                                  style: isMissing ? BorderStyle.solid : BorderStyle.none,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 150),
                                    child: Text(
                                      value.isEmpty ? '(Empty)' : value,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: value.isEmpty
                                            ? Colors.grey.shade600
                                            : null,
                                        fontStyle: value.isEmpty
                                            ? FontStyle.italic
                                            : FontStyle.normal,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.edit_outlined,
                                    size: 14,
                                    color: Colors.grey.shade600,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Calculates effective fields: schema fields if populated, or dynamic unique keys across items.
  List<DocumentField> _getEffectiveFields() {
    if (schema.fields.isNotEmpty) {
      return schema.fields;
    }

    final List<String> uniqueKeys = [];
    final Set<String> seenNormalized = {};

    for (final item in items) {
      for (final key in item.record.keys) {
        // Skip snake_case key if title-cased key exists
        if (key.contains('_')) {
          final titleKey = key
              .split('_')
              .where((p) => p.isNotEmpty)
              .map((p) => p[0].toUpperCase() + p.substring(1).toLowerCase())
              .join(' ');
          if (item.record.containsKey(titleKey)) continue;
        }

        // Normalize: strip any "Prefix - " scoped segment for deduplication purposes
        final strippedKey = key.contains(' - ')
            ? key.substring(key.lastIndexOf(' - ') + 3)
            : key;
        final norm = strippedKey.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

        if (!seenNormalized.contains(norm)) {
          seenNormalized.add(norm);
          uniqueKeys.add(key);
        }
      }
    }

    return uniqueKeys.map((key) {
      return DocumentField(
        key: key,
        displayName: _formatKeyToDisplayName(key),
      );
    }).toList();
  }

  String _formatKeyToDisplayName(String key) {
    if (key.contains('_')) {
      return key
          .split('_')
          .where((p) => p.isNotEmpty)
          .map((p) => p[0].toUpperCase() + p.substring(1).toLowerCase())
          .join(' ');
    }
    if (key.isNotEmpty && key[0] == key[0].toLowerCase()) {
      return key[0].toUpperCase() + key.substring(1);
    }
    return key;
  }

  Widget _buildStatusCell(BatchItem item) {
    Color bg;
    Color fg;
    IconData icon;

    switch (item.extractionStatus) {
      case ExtractionStatus.completed:
        bg = Colors.green.shade50;
        fg = Colors.green.shade800;
        icon = Icons.check_circle;
        break;
      case ExtractionStatus.partial:
        bg = Colors.amber.shade50;
        fg = Colors.amber.shade800;
        icon = Icons.warning_amber_rounded;
        break;
      case ExtractionStatus.failed:
        bg = Colors.red.shade50;
        fg = Colors.red.shade800;
        icon = Icons.cancel;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: fg.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            item.extractionStatusLabel,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: fg),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditDialog(
    BuildContext context,
    BatchItem item,
    DocumentField field,
    String currentValue,
  ) async {
    final controller = TextEditingController(text: currentValue);

    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit ${field.displayName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'File: ${item.fileName}',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.outline,
                  ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: field.displayName,
                hintText: 'Enter ${field.displayName}',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (updated != null) {
      onCellEdited(item.id, field.key, updated);
    }
  }

  /// Opens an interactive modal to view and edit the detected 2D table grid for an image.
  void _showTableViewerDialog(BuildContext context, BatchItem item) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Container(
          width: double.maxFinite,
          height: 520,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.table_chart, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Detected Table: ${item.fileName}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              Text(
                'Tap any cell to edit before exporting to Excel',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const Divider(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      headingRowColor: WidgetStateProperty.all(Colors.blue.shade50),
                      columns: item.tableHeaders.map((header) {
                        return DataColumn(
                          label: Text(
                            header,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        );
                      }).toList(),
                      rows: List.generate(item.tableRows.length, (rowIndex) {
                        final row = item.tableRows[rowIndex];
                        return DataRow(
                          cells: List.generate(item.tableHeaders.length, (colIndex) {
                            final cellVal = colIndex < row.length ? row[colIndex] : '';
                            return DataCell(
                              InkWell(
                                onTap: () async {
                                  final controller = TextEditingController(text: cellVal);
                                  final newVal = await showDialog<String>(
                                    context: ctx,
                                    builder: (c) => AlertDialog(
                                      title: Text('Edit Cell [${item.tableHeaders[colIndex]}]'),
                                      content: TextField(
                                        controller: controller,
                                        autofocus: true,
                                        decoration: const InputDecoration(border: OutlineInputBorder()),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.of(c).pop(),
                                          child: const Text('Cancel'),
                                        ),
                                        FilledButton(
                                          onPressed: () => Navigator.of(c).pop(controller.text),
                                          child: const Text('Save'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (newVal != null && onTableCellEdited != null) {
                                    onTableCellEdited!(item.id, rowIndex, colIndex, newVal);
                                    Navigator.of(ctx).pop();
                                  }
                                },
                                child: Text(cellVal.isEmpty ? '—' : cellVal),
                              ),
                            );
                          }),
                        );
                      }),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
