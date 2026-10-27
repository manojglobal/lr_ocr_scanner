import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../config/document_schema.dart';
import '../../models/batch_item.dart';

/// Card widget displaying a single image item in the processing queue.
class ImageQueueCard extends StatelessWidget {
  final BatchItem item;
  final DocumentSchema schema;
  final VoidCallback onRemove;
  final VoidCallback? onRetry;
  final VoidCallback? onTap;
  final VoidCallback? onViewImage;

  const ImageQueueCard({
    super.key,
    required this.item,
    required this.schema,
    required this.onRemove,
    this.onRetry,
    this.onTap,
    this.onViewImage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: _borderColor(colorScheme),
          width: 1.2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Image Thumbnail with View Document Trigger
              InkWell(
                onTap: onViewImage ?? onTap,
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Builder(
                        builder: (context) {
                          final isPdf = item.fileName.toLowerCase().endsWith('.pdf') || item.imagePath.toLowerCase().endsWith('.pdf');
                          final b64 = item.record['preview_image'] ?? '';
                          if (b64.startsWith('data:image/') && b64.contains('base64,')) {
                            try {
                              final bytes = base64Decode(b64.split('base64,').last);
                              return Image.memory(bytes, fit: BoxFit.cover, errorBuilder: (_, _, _) => _thumbnailFallback(colorScheme));
                            } catch (_) {}
                          }
                          final pUrl = item.record['preview_url'] ?? '';
                          if (pUrl.isNotEmpty) {
                            final fullUrl = pUrl.startsWith('http') ? pUrl : 'http://192.168.1.2:8000${pUrl.startsWith('/') ? pUrl : '/$pUrl'}';
                            return Image.network(fullUrl, fit: BoxFit.cover, errorBuilder: (_, _, _) => _thumbnailFallback(colorScheme));
                          }
                          if (!isPdf && File(item.imagePath).existsSync()) {
                            return Image.file(
                              File(item.imagePath),
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  _thumbnailFallback(colorScheme),
                            );
                          }
                          return _thumbnailFallback(colorScheme);
                        },
                      ),
                    ),
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(160),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(Icons.fullscreen, color: Colors.white, size: 14),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),

              // Content Details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // File name and Remove button
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.fileName,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          tooltip: 'Remove',
                          onPressed: onRemove,
                        ),
                      ],
                    ),

                    // Status Badge
                    _buildStatusBadge(context),
                    const SizedBox(height: 6),

                    // Preview of extracted key fields
                    _buildExtractedPreview(theme),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumbnailFallback(ColorScheme colors) {
    final isPdf = item.fileName.toLowerCase().endsWith('.pdf') || item.imagePath.toLowerCase().endsWith('.pdf');
    if (isPdf) {
      return Container(
        color: const Color(0xFFFEE2E2),
        child: const Center(
          child: Icon(Icons.picture_as_pdf, color: Color(0xFFDC2626), size: 28),
        ),
      );
    }
    return Container(
      color: colors.surfaceContainerHighest,
      child: Icon(Icons.image_outlined, color: colors.onSurfaceVariant),
    );
  }

  Color _borderColor(ColorScheme colors) {
    switch (item.status) {
      case BatchItemStatus.processing:
        return colors.primary;
      case BatchItemStatus.error:
        return colors.error;
      case BatchItemStatus.completed:
        return item.missingFields.isNotEmpty
            ? Colors.amber.shade700
            : Colors.green.shade600;
      case BatchItemStatus.pending:
        return colors.outlineVariant;
    }
  }

  Widget _buildStatusBadge(BuildContext context) {
    final theme = Theme.of(context);

    if (item.status == BatchItemStatus.pending) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 14, color: Colors.grey.shade600),
          const SizedBox(width: 4),
          Text(
            'Waiting in queue...',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
          ),
        ],
      );
    }

    if (item.status == BatchItemStatus.processing) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 6),
          Text(
            'Extracting text...',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    if (item.status == BatchItemStatus.error) {
      return Row(
        children: [
          Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              item.errorMessage ?? 'OCR recognition failed',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              child: const Text('Retry', style: TextStyle(fontSize: 12)),
            ),
        ],
      );
    }

    // Completed or Partial
    final isPartial = item.missingFields.isNotEmpty;
    final badgeColor = isPartial ? Colors.amber.shade800 : Colors.green.shade700;
    final badgeBg = isPartial ? Colors.amber.shade50 : Colors.green.shade50;
    final label = isPartial
        ? 'Partial (${item.missingFields.length} missing)'
        : 'Completed';

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: badgeBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: badgeColor.withAlpha(80)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isPartial ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                size: 13,
                color: badgeColor,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: badgeColor,
                ),
              ),
            ],
          ),
        ),

        // Fallback OCR Engine Badge if server fallback active
        if (item.isFallbackOcr)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFF59E0B),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 13,
                  color: Color(0xFFB45309),
                ),
                SizedBox(width: 4),
                Text(
                  'Fallback results',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFB45309),
                  ),
                ),
              ],
            ),
          ),

        // Structure Pill
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.blue.shade300),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                item.hasTable ? Icons.table_chart : Icons.list_alt,
                size: 13,
                color: Colors.blue.shade800,
              ),
              const SizedBox(width: 4),
              Text(
                item.structureLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.blue.shade800,
                ),
              ),
            ],
          ),
        ),


        // Edited indicator
        if (item.editedAt != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit_note, size: 13, color: Colors.amber.shade900),
                const SizedBox(width: 3),
                Text(
                  'Edited: ${item.editedAt!.hour.toString().padLeft(2, '0')}:${item.editedAt!.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.amber.shade900,
                  ),
                ),
              ],
            ),
          ),

        // Created time
        Text(
          'Created: ${item.createdAt.hour.toString().padLeft(2, '0')}:${item.createdAt.minute.toString().padLeft(2, '0')}',
          style: TextStyle(
            fontSize: 10,
            color: Colors.grey.shade600,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _buildExtractedPreview(ThemeData theme) {
    if (item.status != BatchItemStatus.completed) {
      return const SizedBox.shrink();
    }

    if (item.hasTable) {
      return Text(
        'Columns: ${item.tableHeaders.join(', ')}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    if (item.record.isEmpty) {
      return const SizedBox.shrink();
    }

    // Display first 2 non-empty values as quick summary
    final entries = item.record.entries
        .where((e) => e.value.trim().isNotEmpty && !e.key.contains('_'))
        .take(2)
        .map((e) => '${e.key}: ${e.value}')
        .join('  •  ');

    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }

    return Text(
      entries,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
