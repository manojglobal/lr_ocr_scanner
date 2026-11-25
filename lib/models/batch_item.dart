import 'dart:convert';
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

  /// 15 Mandatory BNF fields defined with (*) matching Web getLrMandatoryStatus()
  static const List<String> mandatoryKeys = [
    'grno (*)',
    'grdt *',
    'Customer Name *',
    'Vehicle No *',
    'Vehicle Type *',
    'cngr *',
    'cnge *',
    'cngrgstno *',
    'cngegstno *',
    'Driver Name *',
    'Mobile no   *',
    'Liscense No *',
    'Valid Up to *',
    'Loading Start date *',
    'freight  *',
  ];

  static const Map<String, String> mandatoryLabels = {
    'grno (*)': 'LR / Consignment No. *',
    'grdt *': 'LR Date *',
    'Customer Name *': 'Customer Name *',
    'Vehicle No *': 'Vehicle No. *',
    'Vehicle Type *': 'Vehicle Type *',
    'cngr *': 'Consignor Name *',
    'cnge *': 'Consignee Name *',
    'cngrgstno *': 'Consignor GSTIN *',
    'cngegstno *': 'Consignee GSTIN *',
    'Driver Name *': 'Driver Name *',
    'Mobile no   *': 'Mobile No *',
    'Liscense No *': 'License No *',
    'Valid Up to *': 'Valid Up to *',
    'Loading Start date *': 'Loading Start Date *',
    'freight  *': 'Freight Charge *',
  };
  static String getMandatoryLabel(String key) => mandatoryLabels[key] ?? key;


  static DateTime? _parseDdMmYyyy(String s) {
    try {
      final clean = s.trim().split(RegExp(r'\s+')).first;
      final parts = clean.split(RegExp(r'[/.-]'));
      if (parts.length == 3) {
        int d = int.parse(parts[0]);
        int m = int.parse(parts[1]);
        int y = int.parse(parts[2]);
        if (y < 100) y += 2000;
        return DateTime(y, m, d);
      }
      return DateTime.tryParse(s);
    } catch (_) {
      return null;
    }
  }

  /// Smart field resolver matching Web getBnfFieldValue alias handling.
  String resolveField(String key) {
    if (record.containsKey(key) && record[key] != null && record[key]!.trim().isNotEmpty) {
      return record[key]!.trim();
    }
    if (key == 'grno (*)' || key == 'LR No *' || key == 'grno') {
      for (final a in ['grno (*)', 'LR No *', 'grno', 'LR No', 'lrno', 'biltyno', 'Consignment Note No', 'consignment note no', 'Consignment Note', 'C Note No']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'grdt *' || key == 'grdt') {
      for (final a in ['grdt *', 'grdt', 'stockdt', 'stockdt ']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'Customer Name *') {
      for (final a in ['Customer Name *', 'Customer Name', 'Customer', 'customer_name', 'customer']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
      if (record.containsKey('Customer Name *')) return '';
      for (final a in ['cngr *', 'cngr', 'consignor']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'cngr *' || key == 'cngr') {
      for (final a in ['cngr *', 'cngr', 'Consignor Name & Address', 'consignor name & address', 'Consignor Name and Address', 'Customer Name *', 'consignor', 'sender']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'cnge *' || key == 'cnge') {
      for (final a in ['cnge *', 'cnge', 'Consignee Name & Address', 'consignee name & address', 'Consignee Name and Address', 'consignee', 'receiver']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'cngrgstno *' || key == 'cngrgstno') {
      for (final a in ['cngrgstno *', 'cngrgstno', 'cngr_gst', 'consignor_gst']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'cngegstno *' || key == 'cngegstno') {
      for (final a in ['cngegstno *', 'cngegstno', 'cnge_gst', 'consignee_gst']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'Vehicle No *' || key == 'Vehicle No') {
      for (final a in ['Vehicle No *', 'Vehicle No', 'vehno', 'vehicle_no', 'Tempo/Truck No', 'tempo/truck no', 'tempo truck no', 'truck no']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'Vehicle Type *' || key == 'VehicleTypeName' || key == 'Vehicle Type') {
      for (final a in ['Vehicle Type *', 'VehicleTypeName', 'Vehicle Type', 'vehtype', 'vehicle_type']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'Vehicle Category' || key == 'VehicleCategory') {
      for (final a in ['Vehicle Category', 'VehicleCategory', 'Vehicle Category *', 'vehicle_category']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'PickupPoint' || key == 'pickuppoint' || key == 'pickup_point') {
      if (record.containsKey('PickupPoint')) return record['PickupPoint']!.trim();
      for (final a in ['pickup_point', 'pickuppoint', 'Origen', 'orgrefcode', 'from', 'origin']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'DeliveryPoint' || key == 'deliverypoint' || key == 'delivery_point') {
      if (record.containsKey('DeliveryPoint')) return record['DeliveryPoint']!.trim();
      for (final a in ['delivery_point', 'deliverypoint', 'Destination', 'destrefcode', 'to', 'destination']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'ewaybilldt' || key == 'EwayBillDate' || key == 'ewaybilldate') {
      if (record.containsKey('ewaybilldt')) return record['ewaybilldt']!.trim();
      for (final a in ['EwayBillDate', 'ewaybilldate', 'eway_bill_date', 'E-Way Bill Date', 'grdt *', 'grdt', 'stockdt']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'Driver Name *' || key == 'Driver Name') {
      for (final a in ['Driver Name *', 'Driver Name', 'driver_name', 'driver']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'Mobile no   *' || key == 'Mobile no *' || key == 'Mobile No') {
      for (final a in ['Mobile no   *', 'Mobile no *', 'Mobile No', 'mobile_no', 'driver_mobile']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'Liscense No *' || key == 'License No *') {
      for (final a in ['Liscense No *', 'License No *', 'Liscense No', 'License No', 'license_no']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'Valid Up to *' || key == 'Valid Up to') {
      // Strictly Driver DL validity (NEVER fall back to E-Way bill valid_upto)
      for (final a in ['Valid Up to *', 'Valid Up to', 'valid_up_to', 'dl_valid_till', 'license_valid', 'driver_valid_upto']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'Valid Upto' || key == 'validupto') {
      // Strictly E-Way bill expiry date
      for (final a in ['Valid Upto', 'validupto', 'ewb valid upto', 'ewb_valid_upto', 'e-way bill valid upto']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'Loading Start date *') {
      for (final a in ['Loading Start date *', 'Loading Start Date *', 'grdt *', 'grdt', 'date']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'freight  *' || key == 'freight') {
      for (final a in ['freight  *', 'freight', 'Freight Charge', 'basic freight', 'total freight']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'pmark') {
      for (final a in ['pmark', 'Private Mark', 'private mark', 'Seal No', 'seal no', 'seal_no', 'seal', 'Seal', 'Seal No / Private Mark']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'oamount') {
      for (final a in ['oamount', 'Other Charges', 'other_amount', 'other charges', 'hamali', 'loading charges', 'unloading charges', 'aoc', 'labour', 'misc']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
      return '0.00';
    } else if (key == 'goods') {
      for (final a in ['goods', 'Description (Said to Contain)', 'description (said to contain)', 'Description', 'description', 'Said to Contain', 'commodity']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'pckgs' || key == 'bookedpckgs' || key == 'stockpckgs' || key == 'stockpkgs' || key == 'packages' || key == 'pkgs') {
      for (final a in ['pckgs', 'bookedpckgs', 'stockpckgs', 'stockpkgs', 'No. of Packages', 'no. of packages', 'No of Packages', 'packages', 'pkgs', 'quantity', 'qty']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'aweight' || key == 'bookedaweight' || key == 'stockaweight') {
      for (final a in ['aweight', 'bookedaweight', 'actual weight', 'actual wt', 'stockaweight', 'weight']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'cweight' || key == 'bookedcweight' || key == 'stockcweight') {
      for (final a in ['cweight', 'bookedcweight', 'charged weight', 'charged wt', 'stockcweight']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    } else if (key == 'Transit Days' || key == 'transit days' || key == 'transit_days') {
      final startStr = record['grdt *'] ?? record['grdt'] ?? record['stockdt'] ?? record['stockdt '] ?? '';
      final endStr = record['Valid Upto'] ?? record['validupto'] ?? record['ewb valid upto'] ?? record['ewb_valid_upto'] ?? '';
      if (startStr.isNotEmpty && endStr.isNotEmpty) {
        final d1 = _parseDdMmYyyy(startStr);
        final d2 = _parseDdMmYyyy(endStr);
        if (d1 != null && d2 != null) {
          final diff = d2.difference(d1).inDays;
          if (diff >= 0) return diff.toString();
        }
      }
      for (final a in ['Transit Days', 'transit days', 'transit_days']) {
        if (record.containsKey(a) && record[a] != null && record[a]!.trim().isNotEmpty) return record[a]!.trim();
      }
    }

    final cleanKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    for (final entry in record.entries) {
      final cleanEntry = entry.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
      if (cleanKey == cleanEntry && entry.value.trim().isNotEmpty) {
        return entry.value.trim();
      }
    }
    return '';
  }

  /// Returns true only when an LR has been successfully verified and all mandatory columns are valid.
  bool get isVerified {
    if (record['pending_verification'] == 'true' ||
        record['is_verified'] == 'false' ||
        record['is_cancelled'] == 'true') {
      return false;
    }
    if (record['is_verified'] == 'true') return true;
    for (final key in mandatoryKeys) {
      final val = resolveField(key);
      if (val.isEmpty || val == '-' || val.toLowerCase() == 'null' || val.toLowerCase() == 'none') {
        return false;
      }
    }
    return true;
  }

  /// True when this LR has been exported to Excel and not subsequently edited.
  bool get isExported =>
      exportedAt != null || record['is_exported'] == 'true';

  /// Returns list of missing mandatory field keys across all tabs.
  List<String> get missingMandatoryFields {
    final missing = <String>[];
    for (final key in mandatoryKeys) {
      final val = resolveField(key);
      if (val.isEmpty || val == '-' || val.toLowerCase() == 'null' || val.toLowerCase() == 'none') {
        missing.add(key);
      }
    }
    return missing;
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
    bool clearExportedAt = false,
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
      exportedAt: clearExportedAt ? null : (exportedAt ?? this.exportedAt),
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

  Map<String, dynamic> toCloudDoc() {
    return {
      'id': id,
      'filename': fileName,
      'saved_filename': record['saved_filename'] ?? fileName,
      'file_url': record['file_url'] ?? '',
      'preview_url': record['preview_url'] ?? '',
      'preview_image': record['preview_image'] ?? '',
      'preview_pages': record['preview_pages'] ?? '',
      'page_count': record['page_count'] ?? '1',
      'isVerified': isVerified,
      'is_verified': isVerified,
      'is_exported': isExported,
      'exportedAt': exportedAt?.toIso8601String(),
      'editedAt': editedAt?.toIso8601String(),
      'current_version': currentVersion,
      'versions': versions,
      'editHistory': editHistory,
      'imageHash': imageHash,
      'status': status.name,
      'data': record,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  Map<String, dynamic> toLocalJson() {
    return {
      'id': id,
      'imagePath': imagePath,
      'fileName': fileName,
      'status': status.name,
      'createdAt': createdAt.toIso8601String(),
      'processedAt': processedAt?.toIso8601String(),
      'editedAt': editedAt?.toIso8601String(),
      'exportedAt': exportedAt?.toIso8601String(),
      'deletedAt': deletedAt?.toIso8601String(),
      'editHistory': editHistory,
      'currentVersion': currentVersion,
      'versions': versions,
      'isDeleted': isDeleted,
      'record': record,
      'missingFields': missingFields,
      'rawOcrText': rawOcrText,
      'errorMessage': errorMessage,
      'tableHeaders': tableHeaders,
      'tableRows': tableRows,
      'structureType': structureType,
      'ocrEngine': ocrEngine,
      'imageHash': imageHash,
    };
  }

  static BatchItem fromLocalJson(Map<String, dynamic> json) {
    final rec = <String, String>{};
    if (json['record'] is Map) {
      (json['record'] as Map).forEach((k, v) {
        if (k != null && v != null) rec[k.toString()] = v.toString();
      });
    }
    final statusName = json['status']?.toString() ?? 'completed';
    final parsedStatus = BatchItemStatus.values.firstWhere(
      (s) => s.name == statusName,
      orElse: () => BatchItemStatus.completed,
    );
    final rawRows = json['tableRows'];
    final parsedRows = rawRows is List
        ? rawRows.whereType<List>().map((r) => r.map((c) => c.toString()).toList()).toList()
        : const <List<String>>[];

    return BatchItem(
      id: (json['id'] ?? '').toString(),
      imagePath: (json['imagePath'] ?? json['fileName'] ?? '').toString(),
      fileName: (json['fileName'] ?? 'LR Document').toString(),
      status: parsedStatus,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
      processedAt: DateTime.tryParse(json['processedAt']?.toString() ?? ''),
      editedAt: DateTime.tryParse(json['editedAt']?.toString() ?? ''),
      exportedAt: DateTime.tryParse(json['exportedAt']?.toString() ?? ''),
      deletedAt: DateTime.tryParse(json['deletedAt']?.toString() ?? ''),
      editHistory: json['editHistory'] is List
          ? (json['editHistory'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : const [],
      currentVersion: int.tryParse((json['currentVersion'] ?? 1).toString()) ?? 1,
      versions: json['versions'] is List
          ? (json['versions'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : const [],
      isDeleted: json['isDeleted'] == true,
      record: rec,
      missingFields: json['missingFields'] is List
          ? (json['missingFields'] as List).map((e) => e.toString()).toList()
          : const [],
      rawOcrText: json['rawOcrText']?.toString() ?? '',
      errorMessage: json['errorMessage']?.toString(),
      tableHeaders: json['tableHeaders'] is List
          ? (json['tableHeaders'] as List).map((e) => e.toString()).toList()
          : const [],
      tableRows: parsedRows,
      structureType: json['structureType']?.toString() ?? 'form',
      ocrEngine: json['ocrEngine']?.toString() ?? 'server',
      imageHash: json['imageHash']?.toString(),
    );
  }

  static BatchItem fromCloudDoc(Map<String, dynamic> doc) {
    final dataMap = <String, String>{};
    if (doc['data'] is Map) {
      (doc['data'] as Map).forEach((k, v) {
        if (k != null && v != null) {
          dataMap[k.toString()] = v.toString();
        }
      });
    }
    if (doc['preview_image'] != null && doc['preview_image'].toString().isNotEmpty) {
      dataMap['preview_image'] = doc['preview_image'].toString();
    }
    if (doc['preview_url'] != null && doc['preview_url'].toString().isNotEmpty) {
      dataMap['preview_url'] = doc['preview_url'].toString();
    }
    if (doc['preview_pages'] != null && doc['preview_pages'].toString().isNotEmpty) {
      dataMap['preview_pages'] = doc['preview_pages'] is List
          ? jsonEncode(doc['preview_pages'])
          : doc['preview_pages'].toString();
    }
    if (doc['page_count'] != null) {
      dataMap['page_count'] = doc['page_count'].toString();
    }
    if (doc['saved_filename'] != null && doc['saved_filename'].toString().isNotEmpty) {
      dataMap['saved_filename'] = doc['saved_filename'].toString();
    }
    if (doc['file_url'] != null && doc['file_url'].toString().isNotEmpty) {
      dataMap['file_url'] = doc['file_url'].toString();
    }

    if (!dataMap.containsKey('is_verified')) {
      if (doc['isVerified'] == true ||
          doc['is_verified'] == true ||
          doc['is_verified']?.toString() == 'true') {
        dataMap['is_verified'] = 'true';
      } else if (doc['isVerified'] == false ||
          doc['is_verified'] == false ||
          doc['is_verified']?.toString() == 'false') {
        dataMap['is_verified'] = 'false';
      }
    }
    if (!dataMap.containsKey('pending_verification') &&
        (doc['pending_verification'] == true ||
            doc['pending_verification']?.toString() == 'true')) {
      dataMap['pending_verification'] = 'true';
    }
    if (!dataMap.containsKey('is_cancelled') &&
        (doc['is_cancelled'] == true ||
            doc['is_cancelled']?.toString() == 'true')) {
      dataMap['is_cancelled'] = 'true';
    }

    final dt = DateTime.tryParse(
          (doc['createdAt'] ?? doc['created_at'] ?? '').toString(),
        ) ??
        DateTime.now();
    final editedDt = DateTime.tryParse(
      (doc['editedAt'] ?? doc['edited_at'] ?? dataMap['edited_at'] ?? '').toString(),
    );

    final rawExportedAt = doc['exportedAt'] ?? doc['exported_at'] ?? dataMap['exported_at'];
    DateTime? exportedDt =
        rawExportedAt != null ? DateTime.tryParse(rawExportedAt.toString()) : null;
    final explicitUnexported = doc['is_exported'] == false ||
        doc['is_exported']?.toString() == 'false' ||
        dataMap['is_exported'] == 'false';
    final isExportedFlag = doc['is_exported'] == true ||
        doc['is_exported']?.toString() == 'true' ||
        dataMap['is_exported'] == 'true';

    if (explicitUnexported) {
      exportedDt = null;
      dataMap['is_exported'] = 'false';
      dataMap.remove('exported_at');
    } else if (exportedDt != null || isExportedFlag) {
      exportedDt ??= dt;
      dataMap['is_exported'] = 'true';
      dataMap['exported_at'] = exportedDt.toIso8601String();
    }

    final currentVer = int.tryParse(
          (doc['current_version'] ?? doc['currentVersion'] ?? 1).toString(),
        ) ??
        1;
    final versionsList = doc['versions'] is List
        ? (doc['versions'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : const <Map<String, dynamic>>[];
    final historyList = doc['editHistory'] is List
        ? (doc['editHistory'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : const <Map<String, dynamic>>[];

    final id = (doc['id'] ?? doc['file_id'] ?? 'lr_${dt.millisecondsSinceEpoch}').toString();
    final fn = (doc['filename'] ?? doc['saved_filename'] ?? 'LR Document').toString();
    final imgPath = (doc['file_path'] ?? doc['preview_url'] ?? doc['imagePath'] ?? fn).toString();

    return BatchItem(
      id: id,
      imagePath: imgPath,
      fileName: fn,
      status: BatchItemStatus.completed,
      createdAt: dt,
      editedAt: editedDt,
      exportedAt: exportedDt,
      currentVersion: currentVer,
      versions: versionsList,
      editHistory: historyList,
      imageHash: doc['imageHash']?.toString(),
      record: dataMap,
      ocrEngine: 'cloud_sync',
    );
  }
}
