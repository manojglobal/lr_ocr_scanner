import 'package:flutter/foundation.dart';

/// Status of the data extraction process for an image.
enum ExtractionStatus {
  completed,
  partial,
  failed,
}

/// Represents the extracted structured data resulting from dynamic OCR layout parsing.
@immutable
class ExtractionResult {
  /// Structured key-value mapping of field keys to extracted text.
  final Map<String, String> data;

  /// Keys of required fields that could not be parsed (if validating against a schema).
  final List<String> missingFields;

  /// Full raw recognized text from ML Kit.
  final String rawText;

  /// Overall status of this extraction.
  final ExtractionStatus status;

  /// Optional error or warning message.
  final String? message;

  /// Detected column headers if a tabular structure is present.
  final List<String> tableHeaders;

  /// Detected table rows (2D grid of rows and columns).
  final List<List<String>> tableRows;

  /// Detected document structure type: 'table', 'form', 'mixed', or 'text'.
  final String structureType;

  const ExtractionResult({
    required this.data,
    required this.missingFields,
    required this.rawText,
    required this.status,
    this.message,
    this.tableHeaders = const [],
    this.tableRows = const [],
    this.structureType = 'form',
  });

  /// True if the image contains a multi-column or multi-row table.
  bool get hasTable => tableRows.isNotEmpty && tableHeaders.isNotEmpty;

  /// Factory for an empty/failed extraction result.
  factory ExtractionResult.failure({required String errorMessage, String rawText = ''}) {
    return ExtractionResult(
      data: const {},
      missingFields: const [],
      rawText: rawText,
      status: ExtractionStatus.failed,
      message: errorMessage,
      tableHeaders: const [],
      tableRows: const [],
      structureType: 'text',
    );
  }

  /// Factory for a successful extraction result with dynamic structure support.
  factory ExtractionResult.success({
    required Map<String, String> data,
    required List<String> missingFields,
    required String rawText,
    List<String> tableHeaders = const [],
    List<List<String>> tableRows = const [],
    String structureType = 'form',
    String? message,
  }) {
    final status = missingFields.isEmpty
        ? ExtractionStatus.completed
        : ExtractionStatus.partial;
    return ExtractionResult(
      data: data,
      missingFields: missingFields,
      rawText: rawText,
      status: status,
      message: message,
      tableHeaders: tableHeaders,
      tableRows: tableRows,
      structureType: structureType,
    );
  }

  ExtractionResult copyWith({
    Map<String, String>? data,
    List<String>? missingFields,
    String? rawText,
    ExtractionStatus? status,
    String? message,
    List<String>? tableHeaders,
    List<List<String>>? tableRows,
    String? structureType,
  }) {
    return ExtractionResult(
      data: data ?? this.data,
      missingFields: missingFields ?? this.missingFields,
      rawText: rawText ?? this.rawText,
      status: status ?? this.status,
      message: message ?? this.message,
      tableHeaders: tableHeaders ?? this.tableHeaders,
      tableRows: tableRows ?? this.tableRows,
      structureType: structureType ?? this.structureType,
    );
  }
}
