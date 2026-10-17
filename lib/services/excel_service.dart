import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import '../config/document_schema.dart';
import '../models/batch_item.dart';
import '../models/extraction_result.dart';
import 'file_lifecycle_service.dart';

/// Pure Dart Excel generator that compiles batch OCR items into a styled .xlsx workbook
/// with dynamic table and structure layout for ANY image without requiring predefined templates.
class ExcelService {
  /// Generates the raw bytes for the .xlsx spreadsheet from the batch items.
  List<int> generateExcelBytes({
    required List<BatchItem> items,
    List<BatchItem> deletedItems = const [],
    DocumentSchema schema = DocumentSchema.active,
    String? userName,
  }) {
    final excel = Excel.createExcel();
    final Set<String> existingSheetNames = {};

    // Define reusable cell styles
    final headerStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('#1976D2'),
      fontColorHex: ExcelColor.white,
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
    );

    final sectionHeaderStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('#37474F'),
      fontColorHex: ExcelColor.white,
      horizontalAlign: HorizontalAlign.Left,
      verticalAlign: VerticalAlign.Center,
    );

    final titleStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('#ECEFF1'),
      fontColorHex: ExcelColor.fromHexString('#212121'),
      horizontalAlign: HorizontalAlign.Left,
    );

    final partialStyle = CellStyle(
      backgroundColorHex: ExcelColor.fromHexString('#FFF3CD'),
      fontColorHex: ExcelColor.fromHexString('#856404'),
    );

    final failedStyle = CellStyle(
      backgroundColorHex: ExcelColor.fromHexString('#F8D7DA'),
      fontColorHex: ExcelColor.fromHexString('#721C24'),
    );

    // =========================================================================
    // Mode 1: Predefined Schema (e.g. Invoice, Receipt)
    // =========================================================================
    if (schema.fields.isNotEmpty) {
      final isLogisticsGr = schema.id == 'gr_stock_38' || schema.id == 'gr_bnf_49' || schema.id == 'gr_bnf_50';
      final String sheetName = isLogisticsGr ? 'Sheet1' : 'Batch OCR Export';
      final defaultSheet = excel.getDefaultSheet();
      if (defaultSheet != null && defaultSheet != sheetName) {
        excel.rename(defaultSheet, sheetName);
      }
      existingSheetNames.add(sheetName);
      final Sheet sheet = excel[sheetName];

      final List<String> headers = isLogisticsGr
          ? schema.fields.map((f) => f.displayName).toList()
          : [
              'Image File Name',
              'Processed At',
              ...schema.fields.map((f) => f.displayName),
              'Extraction Status',
            ];

      final Map<int, int> maxColLengths = {};
      for (int i = 0; i < headers.length; i++) {
        maxColLengths[i] = headers[i].length;
      }

      final cleanHeaderStyle = CellStyle(
        bold: true,
        fontColorHex: ExcelColor.fromHexString('#000000'),
      );

      final now = DateTime.now();
      final exportDate = _formatDateOnly(now);
      final exportTime = _formatTimeOnly(now);
      final exportedAt = _formatDateTime(now);
      final effectiveUser = userName ?? 'Ruchita Patel';

      if (isLogisticsGr) {
        final metaStyle = CellStyle(
          bold: true,
          fontColorHex: ExcelColor.fromHexString('#000000'),
        );

        // Rows 0-3: Metadata headers above the table
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
          ..value = TextCellValue('User Name: $effectiveUser')
          ..cellStyle = metaStyle;
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1))
          ..value = TextCellValue('Export Date: $exportDate')
          ..cellStyle = metaStyle;
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 2))
          ..value = TextCellValue('Export Time: $exportTime')
          ..cellStyle = metaStyle;
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 3))
          ..value = TextCellValue('Exported At: $exportedAt')
          ..cellStyle = metaStyle;

        // Write Header Row (Row 4)
        for (int col = 0; col < headers.length; col++) {
          final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 4));
          cell.value = TextCellValue(headers[col]);
          cell.cellStyle = cleanHeaderStyle;
        }
      } else {
        // Write Header Row (Row 0)
        for (int col = 0; col < headers.length; col++) {
          final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0));
          cell.value = TextCellValue(headers[col]);
          cell.cellStyle = headerStyle;
        }
      }

      // Write Data Rows
      for (int rowIdx = 0; rowIdx < items.length; rowIdx++) {
        final item = items[rowIdx];
        final targetRow = isLogisticsGr ? (rowIdx + 5) : (rowIdx + 1);

        final formattedDate = item.processedAt != null
            ? _formatDateTime(item.processedAt!)
            : _formatDateTime(item.createdAt);

        final List<String> rowValues;
        if (isLogisticsGr) {
          String cleanKey(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
          final Map<String, String> normRecord = {};
          item.record.forEach((k, v) {
            normRecord[cleanKey(k)] = v.trim();
          });

          String getVal(DocumentField f) {
            if (f.key == 'Customer Name *') return normRecord['cngr'] ?? normRecord['consignor'] ?? '';
            if (f.key == 'LR No *') return normRecord['grno'] ?? normRecord['biltyno'] ?? '';
            if (f.key == 'BNF LR No') return normRecord['bnflrno'] ?? normRecord['bnflr'] ?? normRecord['bnfno'] ?? '';
            if (f.key == 'Loading Start date *') return normRecord['grdt'] ?? normRecord['date'] ?? '';
            if (f.key == 'Valid Upto') return normRecord['validupto'] ?? '';
            if (f.key == 'stockdt' || f.key == 'stockdt ') return normRecord['stockdt'] ?? normRecord['grdt'] ?? '';

            // 15 Affected Fields Systematic Derivations & Fallbacks
            if (f.key == 'freight  *' || f.key == 'freight') {
              final fr = normRecord['freight'] ?? normRecord['freightamount'] ?? normRecord['basicfreight'] ?? normRecord['totalfreight'] ?? normRecord['freightcharge'] ?? '';
              return fr.isNotEmpty ? fr : '0';
            }
            if (f.key == 'oamount') {
              final oamt = normRecord['oamount'] ?? normRecord['totalinvoiceamount'] ?? normRecord['grossinvoicevalue'] ?? normRecord['grandtotal'] ?? normRecord['totalinvoicevalue'] ?? normRecord['totalamount'];
              if (oamt != null && oamt.isNotEmpty && oamt != '0') return oamt;
              final valG = normRecord['valgoods'] ?? normRecord['valueofgoods'] ?? normRecord['invoicevalue'] ?? normRecord['declaredvalue'];
              if (valG != null && valG.isNotEmpty) return valG;
              if (oamt != null && oamt.isNotEmpty) return oamt;
              return normRecord['otheramount'] ?? normRecord['othercharges'] ?? normRecord['hamali'] ?? normRecord['loadingcharges'] ?? normRecord['aoc'] ?? normRecord['labour'] ?? normRecord['stcharge'] ?? '0';
            }
            if (f.key == 'cgst') {
              final ig = normRecord['igst'] ?? normRecord['igstamount'] ?? normRecord['integratedgst'] ?? '';
              if (ig.isNotEmpty && double.tryParse(ig.replaceAll(',', '')) != null && double.parse(ig.replaceAll(',', '')) > 0) {
                return '0.00';
              }
              return normRecord['cgst'] ?? normRecord['cgstamount'] ?? normRecord['centralgst'] ?? '0';
            }
            if (f.key == 'sgst') {
              final ig = normRecord['igst'] ?? normRecord['igstamount'] ?? normRecord['integratedgst'] ?? '';
              if (ig.isNotEmpty && double.tryParse(ig.replaceAll(',', '')) != null && double.parse(ig.replaceAll(',', '')) > 0) {
                return '0.00';
              }
              return normRecord['sgst'] ?? normRecord['sgstamount'] ?? normRecord['stategst'] ?? '0';
            }
            if (f.key == 'igst') {
              return normRecord['igst'] ?? normRecord['igstamount'] ?? normRecord['integratedgst'] ?? '';
            }
            if (f.key == 'received') {
              final r = normRecord['received'] ?? normRecord['amountreceived'] ?? normRecord['receivedamount'];
              return (r != null && r.isNotEmpty) ? r : '0';
            }
            if (f.key == 'advance') {
              final a = normRecord['advance'] ?? normRecord['advanceamount'] ?? normRecord['driveradvance'];
              return (a != null && a.isNotEmpty) ? a : '0';
            }
            if (f.key == 'collectionstncode') {
              final colStn = normRecord['collectionstncode'] ?? normRecord['collectionstation'] ?? normRecord['collectionstationcode'];
              if (colStn != null && colStn.isNotEmpty) return colStn;
              final origin = normRecord['orgrefcode'] ?? normRecord['branchrefcode'] ?? normRecord['from'] ?? normRecord['branch'];
              if (origin != null && origin.isNotEmpty) return origin;
              final payTerm = (normRecord['grtype'] ?? normRecord['grtypedontknow'] ?? normRecord['paymenttype'] ?? '').toUpperCase();
              final isToPay = payTerm == 'T' || payTerm.contains('TOPAY') || payTerm.contains('TO PAY');
              if (isToPay) {
                return normRecord['destrefcode'] ?? normRecord['to'] ?? normRecord['destination'] ?? '';
              }
              return normRecord['destrefcode'] ?? normRecord['to'] ?? normRecord['destination'] ?? '';
            }
            if (f.key == 'ftl') {
              final ftlVal = normRecord['ftl'] ?? normRecord['fulltruckload'] ?? '';
              if (ftlVal.isNotEmpty) {
                final u = ftlVal.toUpperCase();
                if (u == 'FTL' || u == 'LTL') return u;
                if (u.contains('FTL') || u.contains('32 FT') || u.contains('7 MT')) return 'FTL';
                if (u.startsWith('Y') || u.contains('FULL')) return 'Y';
                if (u.startsWith('N') || u.contains('PART')) return 'N';
                return ftlVal;
              }
              return 'N';
            }
            if (f.key == 'custrefcode') {
              final code = normRecord['custrefcode'] ?? normRecord['customerrefcode'] ?? normRecord['customercode'] ?? normRecord['custcode'] ?? normRecord['partycode'] ?? normRecord['accountcode'] ?? normRecord['partyno'];
              if (code != null && code.isNotEmpty) return code;
              return 'CM001';
            }
            if (f.key == 'staxpaidby') {
              final stax = normRecord['staxpaidby'] ?? normRecord['servicetaxpaidby'] ?? normRecord['gstpaidby'] ?? '';
              if (stax.isNotEmpty) {
                final u = stax.toUpperCase();
                return (u.startsWith('E') || u.contains('CONSIGNEE')) ? 'E' : ((u.startsWith('T') || u.contains('TRANSPORTER')) ? 'T' : 'C');
              }
              final payTerm = (normRecord['grtype'] ?? normRecord['grtypedontknow'] ?? '').toUpperCase();
              final isToPay = payTerm == 'T' || payTerm.contains('TOPAY') || payTerm.contains('TO PAY');
              return isToPay ? 'E' : 'C';
            }
            if (f.key == 'dlvtype') {
              final dlv = normRecord['dlvtype'] ?? normRecord['deliverytype'] ?? '';
              if (dlv.isNotEmpty) {
                final u = dlv.toUpperCase();
                return (u.startsWith('D') || u.contains('DOOR')) ? 'D' : 'G';
              }
              return 'G';
            }
            if (f.key == 'bookedpckgs') {
              return normRecord['bookedpckgs'] ?? normRecord['packages'] ?? normRecord['pkgs'] ?? normRecord['quantity'] ?? '';
            }
            if (f.key == 'bookedaweight') {
              return normRecord['bookedaweight'] ?? normRecord['actualweight'] ?? normRecord['actualwt'] ?? normRecord['weight'] ?? '';
            }
            if (f.key == 'bookedcweight') {
              return normRecord['bookedcweight'] ?? normRecord['chargedweight'] ?? normRecord['bookedaweight'] ?? normRecord['actualweight'] ?? normRecord['weight'] ?? '';
            }
            if (f.key == 'stockpckgs' || f.key == 'stockpkgs') {
              return normRecord['stockpckgs'] ?? normRecord['stockpkgs'] ?? normRecord['bookedpckgs'] ?? normRecord['packages'] ?? normRecord['pkgs'] ?? normRecord['quantity'] ?? '';
            }
            if (f.key == 'stockaweight') {
              return normRecord['stockaweight'] ?? normRecord['bookedaweight'] ?? normRecord['actualweight'] ?? normRecord['actualwt'] ?? normRecord['weight'] ?? '';
            }
            if (f.key == 'stockcweight') {
              return normRecord['stockcweight'] ?? normRecord['bookedcweight'] ?? normRecord['chargedweight'] ?? normRecord['stockaweight'] ?? normRecord['bookedaweight'] ?? normRecord['actualweight'] ?? normRecord['actualwt'] ?? normRecord['weight'] ?? '';
            }

            final candidates = [f.key, f.displayName, ...f.aliases];
            for (final c in candidates) {
              final normC = cleanKey(c);
              if (normRecord.containsKey(normC) && normRecord[normC]!.isNotEmpty) {
                return normRecord[normC]!;
              }
            }
            return '';
          }

          rowValues = schema.fields.map((f) => getVal(f)).toList();
        } else {
          rowValues = [
            item.fileName,
            formattedDate,
            ...schema.fields.map((f) => item.record[f.key] ?? ''),
            item.extractionStatusLabel,
          ];
        }

        CellStyle? rowStyle;
        if (!isLogisticsGr) {
          if (item.extractionStatus == ExtractionStatus.partial) {
            rowStyle = partialStyle;
          } else if (item.extractionStatus == ExtractionStatus.failed) {
            rowStyle = failedStyle;
          }
        }

        for (int col = 0; col < rowValues.length; col++) {
          final val = rowValues[col];
          final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: targetRow));
          cell.value = TextCellValue(val);
          if (rowStyle != null) {
            cell.cellStyle = rowStyle;
          }

          if (val.length > (maxColLengths[col] ?? 0)) {
            maxColLengths[col] = val.length;
          }
        }
      }

      _autoSizeColumns(sheet, headers.length - 1, maxColLengths);

      // Create dedicated worksheets for non-GR items that contain tables
      if (!isLogisticsGr) {
        for (int i = 0; i < items.length; i++) {
          final item = items[i];
          if (item.hasTable) {
            final tableSheetName = _sanitizeSheetName('${item.fileName} Table', existingSheetNames);
            final tableSheet = excel[tableSheetName];
            _writeDynamicItemToSheet(tableSheet, item, headerStyle, sectionHeaderStyle, titleStyle);
          }
        }
      }

      // Append dedicated History sheet with all 49/50 columns and metadata
      _appendAuditSheet(excel, items, deletedItems, existingSheetNames, schema, userName: effectiveUser);

      final bytes = excel.save();
      if (bytes == null) {
        throw StateError('Failed to generate Excel bytes');
      }
      return bytes;
    }

    // =========================================================================
    // Mode 2: Dynamic Auto-Detection (Any Image -> Auto Layout)
    // =========================================================================
    if (items.isEmpty) {
      final defaultSheet = excel.getDefaultSheet() ?? 'Extracted Data';
      final Sheet sheet = excel[defaultSheet];
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).value =
          TextCellValue('No records to export');
      final bytes = excel.save();
      if (bytes == null) throw StateError('Failed to generate Excel bytes');
      return bytes;
    }

    // Scenario 2A: Single Image in Batch -> Write directly to primary sheet
    if (items.length == 1) {
      final item = items.first;
      final targetSheetName = _sanitizeSheetName(item.fileName, existingSheetNames);
      final defaultSheet = excel.getDefaultSheet();
      if (defaultSheet != null && defaultSheet != targetSheetName) {
        excel.rename(defaultSheet, targetSheetName);
      }
      existingSheetNames.add(targetSheetName);
      final Sheet sheet = excel[targetSheetName];

      _writeDynamicItemToSheet(sheet, item, headerStyle, sectionHeaderStyle, titleStyle);

      final bytes = excel.save();
      if (bytes == null) throw StateError('Failed to generate Excel bytes');
      return bytes;
    }

    // Scenario 2B: Multiple Images in Batch -> Overview Sheet + Dedicated Sheets per Document
    final String overviewName = 'Batch Overview';
    final defaultSheet = excel.getDefaultSheet();
    if (defaultSheet != null && defaultSheet != overviewName) {
      excel.rename(defaultSheet, overviewName);
    }
    existingSheetNames.add(overviewName);
    final Sheet overviewSheet = excel[overviewName];

    // Collect all distinct extracted keys across all images in the batch
    final List<String> distinctKeys = [];
    final Set<String> seenKeys = {};
    for (final item in items) {
      final disp = _filterDisplayRecords(item.record);
      for (final k in disp.keys) {
        final cleanK = k.trim();
        if (cleanK.isNotEmpty && !seenKeys.contains(cleanK)) {
          seenKeys.add(cleanK);
          distinctKeys.add(cleanK);
        }
      }
    }

    final List<String> overviewHeaders = [
      '#',
      'Image File Name',
      'Detected Structure',
      'Status',
      'Processed At',
      ...distinctKeys,
    ];

    final Map<int, int> overviewLengths = {};
    for (int col = 0; col < overviewHeaders.length; col++) {
      final cell = overviewSheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0));
      cell.value = TextCellValue(overviewHeaders[col]);
      cell.cellStyle = headerStyle;
      overviewLengths[col] = overviewHeaders[col].length;
    }

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final targetRow = i + 1;
      final dateStr = item.processedAt != null
          ? _formatDateTime(item.processedAt!)
          : _formatDateTime(item.createdAt);

      final rowValues = [
        (i + 1).toString(),
        item.fileName,
        item.structureLabel,
        item.extractionStatusLabel,
        dateStr,
        ...distinctKeys.map((k) => item.record[k] ?? ''),
      ];

      CellStyle? rowStyle;
      if (item.extractionStatus == ExtractionStatus.partial) {
        rowStyle = partialStyle;
      } else if (item.extractionStatus == ExtractionStatus.failed) {
        rowStyle = failedStyle;
      }

      for (int col = 0; col < rowValues.length; col++) {
        final val = rowValues[col];
        final cell = overviewSheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: targetRow));
        cell.value = TextCellValue(val);
        if (rowStyle != null) cell.cellStyle = rowStyle;
        if (val.length > (overviewLengths[col] ?? 0)) {
          overviewLengths[col] = val.length;
        }
      }
    }
    _autoSizeColumns(overviewSheet, overviewHeaders.length - 1, overviewLengths);

    // Create a dedicated worksheet for every document in the batch
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final sheetName = _sanitizeSheetName('Doc ${i + 1} - ${item.fileName}', existingSheetNames);
      final itemSheet = excel[sheetName];
      _writeDynamicItemToSheet(itemSheet, item, headerStyle, sectionHeaderStyle, titleStyle);
    }

    // Append dedicated Audit & Lifecycle sheet with all 49 columns and snapshot records
    _appendAuditSheet(excel, items, deletedItems, existingSheetNames, schema);

    final bytes = excel.save();
    if (bytes == null) {
      throw StateError('Failed to generate Excel bytes');
    }
    return bytes;
  }

  /// Writes an individual item's detected structure (table, key-values, mixed, or text) to a Sheet.
  void _writeDynamicItemToSheet(
    Sheet sheet,
    BatchItem item,
    CellStyle headerStyle,
    CellStyle sectionStyle,
    CellStyle titleStyle,
  ) {
    int currentRow = 0;
    final Map<int, int> colLengths = {};

    void writeCell(int col, int row, String text, [CellStyle? style]) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
      cell.value = TextCellValue(text);
      if (style != null) cell.cellStyle = style;
      if (text.length > (colLengths[col] ?? 0)) {
        colLengths[col] = text.length;
      }
    }

    final displayRecords = _filterDisplayRecords(item.record);

    // =========================================================================
    // Layout 1: Document contains a Table or Multi-Column Comparison Form
    // =========================================================================
    if (item.hasTable) {
      // 1. Table Headers at Row 0
      for (int c = 0; c < item.tableHeaders.length; c++) {
        writeCell(c, 0, item.tableHeaders[c], headerStyle);
      }

      // 2. Table Data Rows
      for (int r = 0; r < item.tableRows.length; r++) {
        final row = item.tableRows[r];
        for (int c = 0; c < item.tableHeaders.length; c++) {
          final cellText = c < row.length ? row[c] : '';
          writeCell(c, r + 1, cellText);
        }
      }
      currentRow = item.tableRows.length + 2;

      // 3. Document-Level Metadata (e.g. Organization, Document Type, Serial No, Date, Invoice No)
      // Filter out records that are already represented as rows in the table
      final tableKeysNormalized = item.tableRows
          .where((r) => r.isNotEmpty)
          .map((r) => r[0].toLowerCase().trim())
          .toSet();

      final nonTableMetadata = <String, String>{};
      for (final entry in displayRecords.entries) {
        final kLower = entry.key.toLowerCase().trim();
        bool isAlreadyInTable = false;
        for (final tk in tableKeysNormalized) {
          if (tk.isNotEmpty && (kLower == tk || kLower.endsWith(' - $tk') || kLower.contains(tk))) {
            isAlreadyInTable = true;
            break;
          }
        }
        if (!isAlreadyInTable && entry.value.isNotEmpty) {
          nonTableMetadata[entry.key] = entry.value;
        }
      }

      if (nonTableMetadata.isNotEmpty) {
        writeCell(0, currentRow, 'Document Information & Properties', sectionStyle);
        writeCell(1, currentRow, '', sectionStyle);
        currentRow++;

        for (final entry in nonTableMetadata.entries) {
          writeCell(0, currentRow, entry.key);
          writeCell(1, currentRow, entry.value);
          currentRow++;
        }
      }

      int maxCol = item.tableHeaders.length - 1;
      for (final c in colLengths.keys) {
        if (c > maxCol) maxCol = c;
      }
      _autoSizeColumns(sheet, maxCol, colLengths);
      return;
    }

    // =========================================================================
    // Layout 2: Key-Value Form Document (e.g. ID card, Certificate, Application)
    // =========================================================================
    if (displayRecords.isNotEmpty) {
      // Column Format: Each extracted field is a COLUMN across Row 0
      writeCell(0, 0, '#', headerStyle);
      writeCell(1, 0, 'Image File Name', headerStyle);
      final keys = displayRecords.keys.toList();
      for (int c = 0; c < keys.length; c++) {
        writeCell(c + 2, 0, keys[c], headerStyle);
      }

      // Row 1: The extracted values organized under the columns
      writeCell(0, 1, '1');
      writeCell(1, 1, item.fileName);
      for (int c = 0; c < keys.length; c++) {
        writeCell(c + 2, 1, displayRecords[keys[c]] ?? '');
      }

      _autoSizeColumns(sheet, keys.length + 1, colLengths);
      return;
    }

    // =========================================================================
    // Layout 3: Free-form / Paragraph / Unstructured Text
    // =========================================================================
    writeCell(0, 0, 'Line #', headerStyle);
    writeCell(1, 0, 'Recognized Text', headerStyle);
    currentRow = 1;

    if (item.tableRows.isNotEmpty) {
      for (final row in item.tableRows) {
        writeCell(0, currentRow, row.isNotEmpty ? row[0] : '');
        writeCell(1, currentRow, row.length > 1 ? row[1] : '');
        currentRow++;
      }
    } else {
      final lines = item.rawOcrText.split('\n').where((l) => l.trim().isNotEmpty).toList();
      for (int i = 0; i < lines.length; i++) {
        writeCell(0, currentRow, (i + 1).toString());
        writeCell(1, currentRow, lines[i].trim());
        currentRow++;
      }
    }

    _autoSizeColumns(sheet, 1, colLengths);
  }

  /// Filters out redundant aliases from the display record map.
  ///
  /// Removes:
  ///  - snake_case aliases when a Title Case version exists (e.g. "invoice_no" when "Invoice No" exists)
  ///  - Duplicate entries that are identical after stripping scoped prefix (e.g. "Elector - Name" 
  ///    that would collide with "Relative - Name" already shown in the table are excluded only from
  ///    the key-value supplement, not from the structured table display)
  Map<String, String> _filterDisplayRecords(Map<String, String> record) {
    final result = <String, String>{};
    final Set<String> seenNormalized = {};

    for (final entry in record.entries) {
      final key = entry.key;

      // Skip snake_case alias if a Title Case version exists (e.g. skip "invoice_no" if "Invoice No" is present)
      if (key.contains('_')) {
        final titleKey = key
            .split('_')
            .where((p) => p.isNotEmpty)
            .map((p) => p[0].toUpperCase() + p.substring(1).toLowerCase())
            .join(' ');
        if (record.containsKey(titleKey)) {
          continue; // skip the alias
        }
      }

      // Normalize key for deduplication:
      // Strip any "Prefix - " scoped segment and lowercase+strip-non-alphanumeric
      final strippedKey = key.contains(' - ')
          ? key.substring(key.lastIndexOf(' - ') + 3)
          : key;
      final norm = strippedKey.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

      if (seenNormalized.contains(norm)) {
        continue; // skip exact duplicate (different prefix, same base key)
      }
      seenNormalized.add(norm);

      result[key] = entry.value;
    }
    return result;
  }

  /// Adjusts column widths based on maximum string lengths in each column.
  void _autoSizeColumns(Sheet sheet, int maxColIndex, Map<int, int> maxLengths) {
    for (int col = 0; col <= maxColIndex; col++) {
      final length = maxLengths[col] ?? 12;
      final width = (length + 4).clamp(14, 55).toDouble();
      sheet.setColumnWidth(col, width);
    }
  }

  /// Sanitizes sheet name to conform to Excel limits (max 31 characters, no forbidden characters).
  String _sanitizeSheetName(String name, Set<String> existingNames) {
    var clean = name.replaceAll(RegExp(r'[\\/?*\[\]:]'), '_').trim();
    if (clean.length > 28) {
      clean = clean.substring(0, 28);
    }
    if (clean.isEmpty) clean = 'Sheet';

    var candidate = clean;
    int counter = 1;
    while (existingNames.contains(candidate)) {
      final suffix = '_$counter';
      candidate = (clean.length + suffix.length > 31)
          ? '${clean.substring(0, 31 - suffix.length)}$suffix'
          : '$clean$suffix';
      counter++;
    }
    existingNames.add(candidate);
    return candidate;
  }

  /// Saves the generated Excel bytes to scoped storage and returns the created File.
  Future<File> saveExcelFile({
    required List<BatchItem> items,
    List<BatchItem> deletedItems = const [],
    DocumentSchema schema = DocumentSchema.active,
    String? customFileName,
    String? userName,
  }) async {
    final bytes = generateExcelBytes(
      items: items,
      deletedItems: deletedItems,
      schema: schema,
      userName: userName,
    );

    Directory? directory;
    if (Platform.isAndroid) {
      directory = await getExternalStorageDirectory();
    }
    directory ??= await getApplicationDocumentsDirectory();

    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    final randomSuffix = (DateTime.now().microsecondsSinceEpoch % 1000000).toString().padLeft(6, '0');
    final uniqueExportId = 'EXP_${timestamp}_$randomSuffix';

    final fileName = customFileName ?? 'BNF_${uniqueExportId}_${items.length}LRs.xlsx';
    final filePath = '${directory.path}/$fileName';

    final file = File(filePath);
    await file.writeAsBytes(bytes, flush: true);
    try {
      await FileLifecycleService.instance.recordFileCreation(
        file.path,
        'excel',
        customMeta: {'total_records': items.length, 'schema': schema.id, 'export_id': uniqueExportId},
      );
    } catch (_) {}
    return file;
  }

  /// Saves pre-generated Excel bytes to scoped storage and returns the created File.
  Future<File> saveBytesToFile(
    List<int> bytes, {
    String? customFileName,
  }) async {
    Directory? directory;
    if (Platform.isAndroid) {
      directory = await getExternalStorageDirectory();
    }
    directory ??= await getApplicationDocumentsDirectory();

    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    final randomSuffix = (DateTime.now().microsecondsSinceEpoch % 1000000).toString().padLeft(6, '0');
    final uniqueExportId = 'EXP_${timestamp}_$randomSuffix';

    final fileName = customFileName ?? 'BNF_$uniqueExportId.xlsx';
    final filePath = '${directory.path}/$fileName';

    final file = File(filePath);
    await file.writeAsBytes(bytes, flush: true);
    try {
      await FileLifecycleService.instance.recordFileCreation(
        file.path,
        'excel',
        customMeta: {'size_bytes': bytes.length},
      );
    } catch (_) {}
    return file;
  }

  /// Copies the file to the user's public Downloads directory (/storage/emulated/0/Download).
  Future<String?> saveFileToDownloads(String sourceFilePath, {String? targetFileName}) async {
    try {
      final sourceFile = File(sourceFilePath);
      if (!await sourceFile.exists()) return null;

      final bytes = await sourceFile.readAsBytes();
      final fileName = targetFileName ?? sourceFilePath.split(RegExp(r'[/\\]')).last;

      if (Platform.isAndroid) {
        final downloadDir = Directory('/storage/emulated/0/Download');
        if (await downloadDir.exists()) {
          final targetPath = '${downloadDir.path}/$fileName';
          final targetFile = File(targetPath);
          await targetFile.writeAsBytes(bytes, flush: true);
          try {
            await FileLifecycleService.instance.recordFileExport(
              targetFile.path,
              destination: 'public_downloads',
            );
          } catch (_) {}
          return targetFile.path;
        }
      }

      Directory? directory = await getExternalStorageDirectory();
      directory ??= await getApplicationDocumentsDirectory();
      final targetPath = '${directory.path}/$fileName';
      final targetFile = File(targetPath);
      await targetFile.writeAsBytes(bytes, flush: true);
      try {
        await FileLifecycleService.instance.recordFileExport(
          targetFile.path,
          destination: 'public_downloads',
        );
      } catch (_) {}
      return targetFile.path;
    } catch (e) {
      debugPrint('Error saving to Downloads folder: $e');
      return null;
    }
  }

  /// Triggers the system share sheet for the exported Excel file.
  Future<void> shareExcelFile(String filePath) async {
    try {
      await FileLifecycleService.instance.recordFileExport(
        filePath,
        destination: 'system_share',
      );
    } catch (_) {}
    final fileName = filePath.split(RegExp(r'[/\\]')).last;
    final xFile = XFile(
      filePath,
      mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      name: fileName,
    );
    await SharePlus.instance.share(
      ShareParams(
        files: [xFile],
        text: 'Box N Freight - Consignment Excel Export ($fileName)',
        subject: 'BNF Consignment Excel Report',
      ),
    );
  }

  void _appendAuditSheet(
    Excel excel,
    List<BatchItem> items,
    List<BatchItem> deletedItems,
    Set<String> existingSheetNames,
    DocumentSchema schema, {
    String? userName,
  }) {
    final auditSheetName = _sanitizeSheetName('History', existingSheetNames);
    existingSheetNames.add(auditSheetName);
    final Sheet auditSheet = excel[auditSheetName];

    final now = DateTime.now();
    final exportDate = _formatDateOnly(now);
    final exportTime = _formatTimeOnly(now);
    final exportedAt = _formatDateTime(now);
    final effectiveUser = userName ?? 'Ruchita Patel';

    final metaStyle = CellStyle(
      bold: true,
      fontColorHex: ExcelColor.fromHexString('#000000'),
    );

    // Rows 0-3: Metadata headers above the table (User Name, Export Date, Export Time, Exported At)
    auditSheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
      ..value = TextCellValue('User Name: $effectiveUser')
      ..cellStyle = metaStyle;
    auditSheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1))
      ..value = TextCellValue('Export Date: $exportDate')
      ..cellStyle = metaStyle;
    auditSheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 2))
      ..value = TextCellValue('Export Time: $exportTime')
      ..cellStyle = metaStyle;
    auditSheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 3))
      ..value = TextCellValue('Exported At: $exportedAt')
      ..cellStyle = metaStyle;

    // Schema fields (all 49/50 columns for BNF format)
    final bnfFields = schema.fields.isNotEmpty ? schema.fields : DocumentSchema.grBnf.fields;

    // Header structure: ONLY User Name, Export Date, Export Time, Exported At + 50 BNF Columns
    final auditMetaHeaders = [
      'User Name',
      'Export Date',
      'Export Time',
      'Exported At',
    ];

    final schemaHeaders = bnfFields.map((f) => f.displayName).toList();
    final allHeaders = [...auditMetaHeaders, ...schemaHeaders];

    final cleanHeaderStyle = CellStyle(
      bold: true,
      fontColorHex: ExcelColor.fromHexString('#000000'),
    );

    // Row 4: Column Headers
    for (int col = 0; col < allHeaders.length; col++) {
      final cell = auditSheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 4));
      cell.value = TextCellValue(allHeaders[col]);
      cell.cellStyle = cleanHeaderStyle;
    }

    final Map<int, int> auditLengths = {};
    for (int i = 0; i < allHeaders.length; i++) {
      auditLengths[i] = allHeaders[i].length;
    }

    // Helper to resolve field value from data map
    String cleanKey(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

    String getVal(Map<String, String> data, DocumentField f) {
      if (f.key == 'Customer Name *') return data['cngr'] ?? data['consignor'] ?? '';
      if (f.key == 'LR No *') return data['grno'] ?? data['biltyno'] ?? '';
      if (f.key == 'BNF LR No') return data['BNF LR No'] ?? data['bnflrno'] ?? data['bnflr'] ?? data['bnfno'] ?? '';
      if (f.key == 'Loading Start date *') return data['grdt'] ?? data['date'] ?? '';
      if (f.key == 'Valid Upto') return data['validupto'] ?? '';
      if (f.key == 'stockdt' || f.key == 'stockdt ') return data['stockdt'] ?? data['grdt'] ?? '';

      // 15 Affected Fields Systematic Derivations & Fallbacks
      if (f.key == 'freight  *' || f.key == 'freight') {
        final fr = data['freight  *'] ?? data['freight'] ?? data['Freight Charge'] ?? data['basic freight'] ?? data['total freight'] ?? '';
        return fr.isNotEmpty ? fr : '0';
      }
      if (f.key == 'oamount') {
        final oamt = data['oamount'] ?? data['total invoice amount'] ?? data['gross invoice value'] ?? data['grand total'] ?? data['total invoice value'] ?? data['total amount'];
        if (oamt != null && oamt.isNotEmpty && oamt != '0') return oamt;
        final valG = data['valgoods'] ?? data['value of goods'] ?? data['invoice value'] ?? data['declared value'];
        if (valG != null && valG.isNotEmpty) return valG;
        if (oamt != null && oamt.isNotEmpty) return oamt;
        return data['other amount'] ?? data['other charges'] ?? data['hamali'] ?? data['loading charges'] ?? data['aoc'] ?? data['labour'] ?? '0';
      }
      if (f.key == 'cgst') {
        final ig = data['igst'] ?? data['igst amount'] ?? data['integrated gst'] ?? '';
        if (ig.isNotEmpty && double.tryParse(ig.replaceAll(',', '')) != null && double.parse(ig.replaceAll(',', '')) > 0) {
          return '0.00';
        }
        return data['cgst'] ?? data['cgst amount'] ?? data['central gst'] ?? '0';
      }
      if (f.key == 'sgst') {
        final ig = data['igst'] ?? data['igst amount'] ?? data['integrated gst'] ?? '';
        if (ig.isNotEmpty && double.tryParse(ig.replaceAll(',', '')) != null && double.parse(ig.replaceAll(',', '')) > 0) {
          return '0.00';
        }
        return data['sgst'] ?? data['sgst amount'] ?? data['state gst'] ?? '0';
      }
      if (f.key == 'igst') {
        return data['igst'] ?? data['igst amount'] ?? data['integrated gst'] ?? '';
      }
      if (f.key == 'received') {
        final r = data['received'] ?? data['amount received'] ?? data['received amount'];
        return (r != null && r.isNotEmpty) ? r : '0';
      }
      if (f.key == 'advance') {
        final a = data['advance'] ?? data['advance amount'] ?? data['driver advance'];
        return (a != null && a.isNotEmpty) ? a : '0';
      }
      if (f.key == 'collectionstncode') {
        final colStn = data['collectionstncode'] ?? data['collection station'];
        if (colStn != null && colStn.isNotEmpty) return colStn;
        final origin = data['orgrefcode'] ?? data['branchrefcode'] ?? data['from'] ?? data['branch'] ?? data['Counter'];
        if (origin != null && origin.isNotEmpty) return origin;
        final payTerm = (data['grtype(Don’t know)'] ?? data['grtype'] ?? data['Payment Term'] ?? '').toUpperCase();
        final isToPay = payTerm == 'T' || payTerm.contains('TOPAY') || payTerm.contains('TO PAY');
        if (isToPay) {
          return data['destrefcode'] ?? data['to'] ?? data['destination'] ?? '';
        }
        return data['destrefcode'] ?? data['to'] ?? data['destination'] ?? '';
      }
      if (f.key == 'ftl') {
        final ftlVal = data['ftl'] ?? data['FTL'] ?? data['full truck load'] ?? '';
        if (ftlVal.isNotEmpty) {
          final u = ftlVal.toUpperCase();
          if (u == 'FTL' || u == 'LTL') return u;
          if (u.contains('FTL') || u.contains('32 FT') || u.contains('7 MT')) return 'FTL';
          if (u.startsWith('Y') || u.contains('FULL')) return 'Y';
          if (u.startsWith('N') || u.contains('PART')) return 'N';
          return ftlVal;
        }
        return 'N';
      }
      if (f.key == 'custrefcode') {
        final code = data['custrefcode'] ?? data['customer ref code'] ?? data['customer code'] ?? data['party code'] ?? data['account code'] ?? data['party no'];
        if (code != null && code.isNotEmpty) return code;
        return 'CM001';
      }
      if (f.key == 'staxpaidby') {
        final stax = data['staxpaidby'] ?? data['stax paid by'] ?? data['gst paid by'] ?? '';
        if (stax.isNotEmpty) {
          final u = stax.toUpperCase();
          return (u.startsWith('E') || u.contains('CONSIGNEE')) ? 'E' : ((u.startsWith('T') || u.contains('TRANSPORTER')) ? 'T' : 'C');
        }
        final payTerm = (data['grtype(Don’t know)'] ?? data['grtype'] ?? '').toUpperCase();
        final isToPay = payTerm == 'T' || payTerm.contains('TOPAY') || payTerm.contains('TO PAY');
        return isToPay ? 'E' : 'C';
      }
      if (f.key == 'dlvtype') {
        final dlv = data['dlvtype'] ?? data['delivery type'] ?? data['dlv type'] ?? '';
        if (dlv.isNotEmpty) {
          final u = dlv.toUpperCase();
          return (u.startsWith('D') || u.contains('DOOR')) ? 'D' : 'G';
        }
        return 'G';
      }
      if (f.key == 'bookedpckgs') {
        return data['bookedpckgs'] ?? data['packages'] ?? data['pkgs'] ?? data['quantity'] ?? '';
      }
      if (f.key == 'bookedaweight') {
        return data['bookedaweight'] ?? data['actual weight'] ?? data['actual wt'] ?? data['weight'] ?? '';
      }
      if (f.key == 'bookedcweight') {
        return data['bookedcweight'] ?? data['charged weight'] ?? data['bookedaweight'] ?? data['actual weight'] ?? data['weight'] ?? '';
      }
      if (f.key == 'stockpckgs' || f.key == 'stockpkgs') {
        return data['stockpckgs'] ?? data['stockpkgs'] ?? data['bookedpckgs'] ?? data['packages'] ?? data['pkgs'] ?? data['quantity'] ?? '';
      }
      if (f.key == 'stockaweight') {
        return data['stockaweight'] ?? data['bookedaweight'] ?? data['actual weight'] ?? data['actual wt'] ?? data['weight'] ?? '';
      }
      if (f.key == 'stockcweight') {
        return data['stockcweight'] ?? data['bookedcweight'] ?? data['charged weight'] ?? data['stockaweight'] ?? data['bookedaweight'] ?? data['actual weight'] ?? data['actual wt'] ?? data['weight'] ?? '';
      }

      if (data.containsKey(f.key) && data[f.key]!.isNotEmpty) return data[f.key]!;
      if (data.containsKey(f.displayName) && data[f.displayName]!.isNotEmpty) return data[f.displayName]!;

      final normKey = cleanKey(f.key);
      final normName = cleanKey(f.displayName);
      for (final e in data.entries) {
        final nk = cleanKey(e.key);
        if (nk == normKey || nk == normName) {
          return e.value.trim();
        }
      }
      for (final a in f.aliases) {
        final na = cleanKey(a);
        for (final e in data.entries) {
          if (cleanKey(e.key) == na) return e.value.trim();
        }
      }
      return '';
    }

    int rowCounter = 0;

    void addSnapshotRow({
      required String action,
      required String userName,
      required String userMobile,
      required String timestamp,
      required String version,
      required String fileName,
      required String details,
      required Map<String, String> data,
    }) {
      final targetRow = 5 + rowCounter;
      rowCounter++;

      final metaVals = [
        userName.isNotEmpty ? userName : effectiveUser,
        exportDate,
        exportTime,
        exportedAt,
      ];

      final fieldVals = bnfFields.map((f) => getVal(data, f)).toList();
      final rowVals = [...metaVals, ...fieldVals];

      for (int col = 0; col < rowVals.length; col++) {
        final val = rowVals[col];
        final cell = auditSheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: targetRow));
        cell.value = TextCellValue(val);
        if (val.length > (auditLengths[col] ?? 0)) {
          auditLengths[col] = val.length;
        }
      }
    }

    // 1. Process active items
    for (final item in items) {
      if (item.versions.isNotEmpty) {
        for (final v in item.versions) {
          final snapData = v['snapshot_data'];
          final Map<String, String> dataMap = (snapData is Map)
              ? Map<String, String>.from(snapData.map((k, val) => MapEntry(k.toString(), val.toString())))
              : item.record;

          String diffDetails = v['details']?.toString() ?? '';
          if (v['diff'] != null && diffDetails.isEmpty) {
            diffDetails = v['diff'].toString();
          }

          addSnapshotRow(
            action: v['action']?.toString() ?? 'snapshot',
            userName: v['user_name']?.toString() ?? v['user']?.toString() ?? effectiveUser,
            userMobile: v['user_mobile']?.toString() ?? v['mobile']?.toString() ?? '',
            timestamp: v['timestamp']?.toString() ?? _formatDateTime(item.createdAt),
            version: '#${v['version'] ?? 1}',
            fileName: item.fileName,
            details: diffDetails.isNotEmpty ? diffDetails : 'Point-in-time snapshot',
            data: dataMap,
          );
        }
      } else {
        // Fallback for item without recorded versions
        addSnapshotRow(
          action: 'ADD',
          userName: effectiveUser,
          userMobile: '',
          timestamp: _formatDateTime(item.createdAt),
          version: '#1',
          fileName: item.fileName,
          details: 'Initial OCR capture',
          data: item.record,
        );
        if (item.editedAt != null) {
          addSnapshotRow(
            action: 'EDIT',
            userName: effectiveUser,
            userMobile: '',
            timestamp: _formatDateTime(item.editedAt!),
            version: '#${item.currentVersion}',
            fileName: item.fileName,
            details: 'Field edited',
            data: item.record,
          );
        }
      }
    }

    // 2. Process deleted items
    for (final item in deletedItems) {
      if (item.versions.isNotEmpty) {
        for (final v in item.versions) {
          final snapData = v['snapshot_data'];
          final Map<String, String> dataMap = (snapData is Map)
              ? Map<String, String>.from(snapData.map((k, val) => MapEntry(k.toString(), val.toString())))
              : item.record;

          addSnapshotRow(
            action: v['action']?.toString() ?? 'delete',
            userName: v['user_name']?.toString() ?? v['user']?.toString() ?? effectiveUser,
            userMobile: v['user_mobile']?.toString() ?? v['mobile']?.toString() ?? '',
            timestamp: v['timestamp']?.toString() ?? _formatDateTime(item.deletedAt ?? DateTime.now()),
            version: '#${v['version'] ?? item.currentVersion}',
            fileName: item.fileName,
            details: v['details']?.toString() ?? 'Deleted consignment snapshot',
            data: dataMap,
          );
        }
      } else {
        addSnapshotRow(
          action: 'DELETE',
          userName: effectiveUser,
          userMobile: '',
          timestamp: _formatDateTime(item.deletedAt ?? DateTime.now()),
          version: '#${item.currentVersion}',
          fileName: item.fileName,
          details: 'Consignment deleted from batch',
          data: item.record,
        );
      }
    }

    _autoSizeColumns(auditSheet, allHeaders.length - 1, auditLengths);
  }

  /// Opens the exported Excel file directly in the device's default spreadsheet app.
  Future<OpenResult> openExcelFile(String filePath) async {
    return await OpenFilex.open(
      filePath,
      type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
  }

  String _formatDateTime(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min:$s';
  }

  String _formatDateOnly(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final d = dt.day.toString().padLeft(2, '0');
    final m = months[dt.month - 1];
    final y = dt.year.toString();
    return '$d-$m-$y';
  }

  String _formatTimeOnly(DateTime dt) {
    int hour = dt.hour;
    final period = hour >= 12 ? 'PM' : 'AM';
    hour = hour % 12;
    if (hour == 0) hour = 12;
    final hStr = hour.toString().padLeft(2, '0');
    final mStr = dt.minute.toString().padLeft(2, '0');
    final sStr = dt.second.toString().padLeft(2, '0');
    return '$hStr:$mStr:$sStr $period';
  }
}
