import 'package:flutter/foundation.dart';
import 'extraction_result.dart';

/// Processing status of an item in the batch queue.
enum BatchItemStatus {
  pending,
  processing,
  completed,
  error,
}

/// Represents a single image item in the batch processing queue with dynamic structure support.
@immutable
class BatchItem {
  /// Unique identifier (UUID).
  final String id;

  /// Absolute file system path to the image.
  final String imagePath;

  /// Basename of the image file (e.g. 'image_picker_123.jpg').
  final String fileName;

  /// Lifecycle status in queue.
  final BatchItemStatus status;

  /// Timestamp when item was added.
  final DateTime createdAt;

  /// Timestamp when OCR processing completed.
  final DateTime? processedAt;

  /// Timestamp when item was last modified/edited.
  final DateTime? editedAt;

  /// Timestamp when item was exported.
  final DateTime? exportedAt;

  /// Timestamp when item was deleted.
  final DateTime? deletedAt;

  /// Granular audit log of edit events.
  final List<Map<String, dynamic>> editHistory;

  /// Current active version number (starts at 1).
  final int currentVersion;

  /// Immutable snapshot history of versions.
  final List<Map<String, dynamic>> versions;

  /// Flag indicating if item is soft-deleted.
  final bool isDeleted;

  /// Editable extracted record (field key -> value).
  final Map<String, String> record;

  /// Field keys that were expected but not found during extraction.
  final List<String> missingFields;

  /// Raw recognized OCR text from ML Kit.
  final String rawOcrText;

  /// Error message if processing failed.
  final String? errorMessage;

  /// Detected column headers if a tabular structure is present.
  final List<String> tableHeaders;

  /// Detected table rows (2D grid of rows and columns).
  final List<List<String>> tableRows;

  /// Detected document structure type: 'table', 'form', 'mixed', or 'text'.
  final String structureType;

  /// The engine used for OCR: 'server' (Gemini cloud API) or 'ml_fallback' (on-device ML Kit fallback).
  final String ocrEngine;

  /// SHA-256 content hash of the original image used for duplicate detection.
  final String? imageHash;

  const BatchItem({
    required this.id,
    required this.imagePath,
    required this.fileName,
    this.status = BatchItemStatus.pending,
    required this.createdAt,
    this.processedAt,
    this.editedAt,
    this.exportedAt,
    this.deletedAt,
    this.editHistory = const [],
    this.currentVersion = 1,
    this.versions = const [],
    this.isDeleted = false,
    this.record = const {},
    this.missingFields = const [],
    this.rawOcrText = '',
    this.errorMessage,
    this.tableHeaders = const [],
    this.tableRows = const [],
    this.structureType = 'form',
    this.ocrEngine = 'server',
    this.imageHash,
  });

  /// True if extraction was performed using on-device ML fallback due to server unavailability.
  bool get isFallbackOcr => ocrEngine == 'ml_fallback';

  /// True if the image contains a multi-column or multi-row table.
  bool get hasTable => tableRows.isNotEmpty && tableHeaders.isNotEmpty;

  /// High-level extraction status for review and Excel highlighting.
  ExtractionStatus get extractionStatus {
    if (status == BatchItemStatus.error) {
      return ExtractionStatus.failed;
    }
    if (status == BatchItemStatus.completed) {
      return missingFields.isEmpty
          ? ExtractionStatus.completed
          : ExtractionStatus.partial;
    }
    return ExtractionStatus.partial;
  }

  /// Label string representation of the extraction status.
  String get extractionStatusLabel {
    switch (extractionStatus) {
      case ExtractionStatus.completed:
        return 'Completed';
      case ExtractionStatus.partial:
        return 'Partial';
      case ExtractionStatus.failed:
        return 'Failed';
    }
  }

  /// Human-readable label for the detected structure.
  String get structureLabel {
    switch (structureType) {
      case 'table':
        return 'Table (${tableHeaders.length} cols × ${tableRows.length} rows)';
      case 'mixed':
        return 'Mixed (${record.length} fields + ${tableRows.length} table rows)';
      case 'form':
        return 'Key-Values (${record.length} fields)';
      case 'text':
      default:
        return 'Text Content';
    }
  }

  BatchItem copyWith({
    String? id,
    String? imagePath,
    String? fileName,
    BatchItemStatus? status,
    DateTime? createdAt,
    DateTime? processedAt,
    DateTime? editedAt,
    DateTime? exportedAt,
    DateTime? deletedAt,
    List<Map<String, dynamic>>? editHistory,
    int? currentVersion,
    List<Map<String, dynamic>>? versions,
    bool? isDeleted,
    Map<String, String>? record,
    List<String>? missingFields,
    String? rawOcrText,
    String? errorMessage,
    List<String>? tableHeaders,
    List<List<String>>? tableRows,
    String? structureType,
    String? ocrEngine,
    String? imageHash,
  }) {
    return BatchItem(
      id: id ?? this.id,
      imagePath: imagePath ?? this.imagePath,
      fileName: fileName ?? this.fileName,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      processedAt: processedAt ?? this.processedAt,
      editedAt: editedAt ?? this.editedAt,
      exportedAt: exportedAt ?? this.exportedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      editHistory: editHistory ?? this.editHistory,
      currentVersion: currentVersion ?? this.currentVersion,
      versions: versions ?? this.versions,
      isDeleted: isDeleted ?? this.isDeleted,
      record: record ?? this.record,
      missingFields: missingFields ?? this.missingFields,
      rawOcrText: rawOcrText ?? this.rawOcrText,
      errorMessage: errorMessage ?? this.errorMessage,
      tableHeaders: tableHeaders ?? this.tableHeaders,
      tableRows: tableRows ?? this.tableRows,
      structureType: structureType ?? this.structureType,
      ocrEngine: ocrEngine ?? this.ocrEngine,
      imageHash: imageHash ?? this.imageHash,
    );
  }
}
