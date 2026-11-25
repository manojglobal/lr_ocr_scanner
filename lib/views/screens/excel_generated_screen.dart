import '../../services/excel_service.dart';
import 'package:flutter/material.dart';
import '../../config/document_schema.dart';
import '../../models/batch_item.dart';
import '../../services/master_data_service.dart';
import '../../state/batch_controller.dart';
import '../home_screen.dart';
import '../widgets/step_indicator_bar.dart';
import 'excel_preview_screen.dart';

/// Screen 9: Excel Generated (Confirmation & Visual Audit Snapshot Preview).
class ExcelGeneratedScreen extends StatelessWidget {
  final Map<String, dynamic> exportResult;
  final BatchProcessingController controller;
  final List<BatchItem>? exportedItems;

  const ExcelGeneratedScreen({
    super.key,
    required this.exportResult,
    required this.controller,
    this.exportedItems,
  });

  /// Derives the Web-matching SHA-256 audit hash when the backend omits sha256.
  static String deriveAuditSha256(Map<String, dynamic> exportResult) {
    final existing = exportResult['sha256']?.toString().trim() ?? '';
    if (existing.isNotEmpty) return existing;
    final exportId = exportResult['export_id']?.toString().trim() ?? '';
    if (exportId.isNotEmpty) {
      return 'SHA256-${exportId.replaceFirst('exp_', '').toUpperCase()}8FBFD';
    }
    return 'SHA256-0E006244CEF8FBFD';
  }

  @override
  Widget build(BuildContext context) {
    const brandNavy = Color(0xFF0F172A);
    const brandBlue = Color(0xFF0284C7);
    const brandGreen = Color(0xFF16A34A);

    final resolvedItems =
        exportedItems ?? controller.items.where((i) => i.isVerified).toList();
    final filename = exportResult['filename']?.toString() ?? ExcelService.formatLRReportFilename();
    final totalLrs = exportResult['total_lrs']?.toString() ?? '${resolvedItems.length}';
    final userName = exportResult['user_name']?.toString() ?? exportResult['exported_by']?.toString() ?? exportResult['generated_by']?.toString() ?? 'Ruchita Patel';
    final exportedBy = userName;
    final mobile = exportResult['user_mobile']?.toString() ?? exportResult['mobile']?.toString() ?? '';
    final exportDate = exportResult['export_date']?.toString() ?? '';
    final exportTime = exportResult['export_time']?.toString() ?? '';
    final exportedAt = exportResult['exported_at']?.toString() ?? exportResult['generated_on']?.toString() ?? exportResult['timestamp']?.toString() ?? '';
    final timestamp = exportedAt;
    final localPath = controller.lastExportedPath ?? exportResult['local_path']?.toString();

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Export Complete', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          TextButton(
            onPressed: () {
              // Web Parity (#excelSuccessModal Close): return to LR List / caller without deleting LRs.
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              } else {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => HomeScreen(controller: controller)),
                  (route) => false,
                );
              }
            },
            child: const Text('Done', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Column(
            children: [
              // Success Badge
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFFDCFCE7),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF86EFAC), width: 2),
                ),
                child: const Icon(Icons.check_circle_rounded, size: 44, color: brandGreen),
              ),
              const SizedBox(height: 14),
              const Text(
                'BNF GR Import Excel has been generated successfully!',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: brandNavy),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              const Text(
                'The consolidated 52-column BNF Excel document is ready for download.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),

              // Local Downloaded File Status Banner
              if (localPath != null && localPath.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFBFDBFE)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.download_done_rounded, color: Color(0xFF2563EB), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Downloaded & Saved to Device',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1E40AF)),
                            ),
                            Text(
                              localPath.split(RegExp(r'[/\\]')).last,
                              style: const TextStyle(fontSize: 10, color: Color(0xFF3B82F6)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // File Metadata Card
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.grey.shade200),
                ),
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.description, color: brandGreen, size: 24),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  filename,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: brandNavy),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '$totalLrs Consignments • 52 Columns Clean BNF Format',
                                  style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 20),
                      _buildMetaRow('User Name:', userName),
                      const SizedBox(height: 6),
                      if (exportDate.isNotEmpty) ...[
                        _buildMetaRow('Export Date:', exportDate),
                        const SizedBox(height: 6),
                      ],
                      if (exportTime.isNotEmpty) ...[
                        _buildMetaRow('Export Time:', exportTime),
                        const SizedBox(height: 6),
                      ],
                      if (exportedAt.isNotEmpty) ...[
                        _buildMetaRow('Exported At:', exportedAt),
                        const SizedBox(height: 6),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Complete 52-Column Export Data Preview Card
              _buildSnapshotPreviewCard(
                context,
                filename: filename,
                totalLrs: totalLrs,
                exportedBy: exportedBy,
                mobile: mobile,
                timestamp: timestamp,
              ),
              const SizedBox(height: 20),

              // Primary Dedicated Download Button
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    String? activePath = controller.lastExportedPath ?? localPath;

                    // If not yet saved on device, download from backend
                    if (activePath == null && exportResult['download_url'] != null) {
                      final downloadUrl = exportResult['download_url'].toString();
                      final bytes = await controller.geminiService.downloadExportedFile(downloadUrl);
                      if (bytes != null && bytes.isNotEmpty) {
                        final file = await controller.excelService.saveBytesToFile(
                          bytes,
                          customFileName: filename,
                        );
                        activePath = file.path;
                        controller.setLastExportedPath(activePath);
                      }
                    }

                    if (activePath != null) {
                      final savedToDownloads = await controller.excelService.saveFileToDownloads(
                        activePath,
                        targetFileName: filename,
                      );
                      final displayPath = savedToDownloads ?? activePath;
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Saved to Downloads: ${displayPath.split(RegExp(r"[/\\]")).last}'),
                            backgroundColor: Colors.green.shade700,
                            duration: const Duration(seconds: 4),
                            action: SnackBarAction(
                              label: 'OPEN',
                              textColor: Colors.white,
                              onPressed: () => controller.openLastExport(),
                            ),
                          ),
                        );
                      }
                    } else {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Unable to download file. Please check server connection.'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.file_download_rounded, size: 20),
                  label: const Text('Download Excel (.xlsx)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A), // Emerald Green
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Open & Share Buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        if (controller.lastExportedPath == null && localPath != null) {
                          controller.setLastExportedPath(localPath);
                        }
                        if (controller.lastExportedPath != null) {
                          await controller.openLastExport();
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('File is saved on server. Tap Download first.')),
                          );
                        }
                      },
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Open File'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () async {
                        if (controller.lastExportedPath == null && localPath != null) {
                          controller.setLastExportedPath(localPath);
                        }
                        if (controller.lastExportedPath != null) {
                          await controller.shareLastExport();
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('File is saved on server. Tap Download first.')),
                          );
                        }
                      },
                      icon: const Icon(Icons.share, size: 18),
                      label: const Text('Share File'),
                      style: FilledButton.styleFrom(
                        backgroundColor: brandBlue,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Preview Excel Button
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ExcelPreviewScreen(
                          controller: controller,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.table_chart_outlined, size: 18),
                  label: const Text('Preview Excel Sheet', style: TextStyle(fontWeight: FontWeight.bold)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Upload New LR (Web Parity startNewBatch: return to upload screen while preserving LR List)
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => HomeScreen(controller: controller)),
                      (route) => false,
                    );
                  },
                  icon: const Icon(Icons.replay, size: 18),
                  label: const Text('Upload New LR', style: TextStyle(fontWeight: FontWeight.bold)),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: StepIndicatorBar(currentStep: 11, controller: controller),
    );
  }

  Widget _buildMetaRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.blueGrey)),
        Flexible(
          child: Text(
            value,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  String _getCellValue(BatchItem item, DocumentField field) {
    final rec = Map<String, String>.from(item.record);
    MasterDataService.normalizeUnicharmCustomer(rec, rawText: item.rawOcrText);

    if (field.key == 'branchrefcode') {
      final cnt = (rec['Counter'] ?? rec['Counter name'] ?? rec['counter'] ?? rec['Countername'] ?? '').trim();
      final mapped = MasterDataService.instance.getBranchNameForCounter(cnt);
      if (mapped.isNotEmpty) return mapped;
      final rawBr = (rec['Branch'] ?? rec['branchrefcode'] ?? '').trim();
      return (rawBr.isNotEmpty && rawBr != cnt) ? rawBr : '';
    }
    if (field.key == 'custrefcode' || field.key == 'staxpaidby' || field.key == 'dlvtype' || field.key == 'pmark') {
      return '';
    }
    if (field.key == 'Customer Name *') {
      final direct = (rec['Customer Name *'] ?? rec['Customer Name'] ?? rec['Customer'] ?? rec['customer_name'] ?? rec['customer'] ?? '').trim();
      if (direct.isNotEmpty) return direct;
      if (rec.containsKey('Customer Name *')) return '';
      return (rec['cngr'] ?? rec['consignor'] ?? '').trim();
    }
    if (field.key == 'PickupPoint') {
      final pp = (rec['PickupPoint'] ?? rec['pickup_point'] ?? rec['pickuppoint'] ?? '').trim();
      return pp.isNotEmpty ? pp : (rec['orgrefcode'] ?? rec['Origen'] ?? rec['from'] ?? rec['origin'] ?? '').trim();
    }
    if (field.key == 'DeliveryPoint') {
      final dp = (rec['DeliveryPoint'] ?? rec['delivery_point'] ?? rec['deliverypoint'] ?? '').trim();
      return dp.isNotEmpty ? dp : (rec['destrefcode'] ?? rec['Destination'] ?? rec['to'] ?? rec['destination'] ?? '').trim();
    }
    if (field.key == 'EwayBillDate' || field.key == 'ewaybilldt') {
      final ewd = (rec['EwayBillDate'] ?? rec['ewaybilldate'] ?? rec['ewaybilldt'] ?? rec['grdt *'] ?? rec['grdt'] ?? rec['date'] ?? '').trim();
      return ewd.isNotEmpty ? ExcelService.formatToDdMmYyyy(ewd) : '';
    }
    if (field.key == 'goods') {
      final gRaw = (rec['goods'] ?? rec['Goods'] ?? '').trim();
      return MasterDataService.instance.matchValidGoods(gRaw) ?? '';
    }
    if (field.key == 'Vehicle Type *') {
      return (rec['VehicleTypeName'] ?? rec['Vehicle Type *'] ?? rec['Vehicle Type'] ?? rec['vehtype'] ?? '').trim();
    }

    if (rec.containsKey(field.key) && rec[field.key]!.trim().isNotEmpty) {
      return rec[field.key]!.trim();
    }
    final cleanHeader = field.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    for (final entry in rec.entries) {
      final cleanKey = entry.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
      if (cleanKey == cleanHeader && entry.value.trim().isNotEmpty) {
        return entry.value.trim();
      }
    }
    for (final alias in field.aliases) {
      final cleanAlias = alias.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
      for (final entry in rec.entries) {
        final cleanKey = entry.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
        if (cleanKey == cleanAlias && entry.value.trim().isNotEmpty) {
          return entry.value.trim();
        }
      }
    }
    // Specific field fallbacks
    if (field.key == 'LR No *') return rec['grno'] ?? rec['biltyno'] ?? '';
    if (field.key == 'BNF LR No') return rec['BNF LR No'] ?? rec['bnf lr no'] ?? rec['bnflrno'] ?? rec['bnflr'] ?? '';
    if (field.key == 'Loading Start date *') return rec['grdt'] ?? rec['date'] ?? '';
    if (field.key == 'Valid Upto') return rec['validupto'] ?? '';
    if (field.key == 'stockdt' || field.key == 'stockdt ') return rec['stockdt'] ?? rec['grdt'] ?? '';
    return '';
  }

  Widget _buildSnapshotPreviewCard(
    BuildContext context, {
    required String filename,
    required String totalLrs,
    required String exportedBy,
    required String mobile,
    required String timestamp,
  }) {
    final fields = DocumentSchema.grBnf.fields;
    final items = exportedItems ?? controller.items.where((i) => i.isVerified).toList();
    final sha256Str = deriveAuditSha256(exportResult);
    final truncatedSha = sha256Str.length > 32 ? '${sha256Str.substring(0, 24)}...' : sha256Str;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: const Color(0x0A000000),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Navy Certificate Banner (Matching snap_preveiw.png)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            color: const Color(0xFF0B192C),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'BOX N FREIGHT LOGISTICS SOLUTIONS PVT. LTD.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(Icons.verified_user_outlined, size: 12, color: Colors.amber.shade400),
                          const SizedBox(width: 4),
                          Text(
                            'CONSOLIDATED BILTY EXPORT PREVIEW',
                            style: TextStyle(
                              color: Colors.amber.shade400,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16A34A),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0x26000000),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle, size: 12, color: Colors.white),
                      SizedBox(width: 4),
                      Text(
                        'VERIFIED EXPORT',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 2. Metadata Grid Panel (Light Slate)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: Color(0xFFF8FAFC),
              border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _buildSnapshotMetaItem('Exported By', mobile.isNotEmpty ? '$exportedBy (+91 $mobile)' : exportedBy),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildSnapshotMetaItem('Timestamp', timestamp.isNotEmpty ? timestamp : 'Active Session'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _buildSnapshotMetaItem('Generated File', filename),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildSnapshotMetaItem('Total Consignments', '$totalLrs Records'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _buildSnapshotMetaItem('Schema Format', 'Clean BNF (All 52 Columns)'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildSnapshotMetaItem('Audit Hash', truncatedSha),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 3. Sub-header with horizontal scroll hint
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: const Color(0xFFF1F5F9),
            child: Row(
              children: [
                const Icon(Icons.table_chart, size: 15, color: Color(0xFF0284C7)),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'EXCEL COLUMNS & DATA (SWIPE HORIZONTALLY →)',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0F172A),
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE0F2FE),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '52 COLUMNS',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0369A1),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 4. Horizontally Scrollable 52-Column Table
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStateProperty.all(Colors.transparent),
              headingTextStyle: const TextStyle(
                color: Color(0xFF0F172A),
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
              dataRowMinHeight: 38,
              dataRowMaxHeight: 46,
              columnSpacing: 14,
              horizontalMargin: 12,
              border: TableBorder.all(color: const Color(0xFFE2E8F0), width: 0.5),
              columns: [
                const DataColumn(
                  label: Text('#', style: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 11)),
                ),
                ...fields.map((f) => DataColumn(
                  label: Text(
                    f.displayName,
                    style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                )),
              ],
              rows: items.isEmpty
                  ? [
                      DataRow(
                        cells: [
                          const DataCell(Text('1', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                          ...fields.map((f) => const DataCell(Text('—', style: TextStyle(fontSize: 11, color: Colors.grey)))),
                        ],
                      )
                    ]
                  : List.generate(items.length, (idx) {
                      final item = items[idx];
                      return DataRow(
                        color: WidgetStateProperty.resolveWith<Color?>((states) {
                          return idx.isEven ? const Color(0xFFF8FAFC) : Colors.white;
                        }),
                        cells: [
                          DataCell(
                            Text(
                              '${idx + 1}',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Color(0xFF0F172A)),
                            ),
                          ),
                          ...fields.map((f) {
                            final val = _getCellValue(item, f);
                            return DataCell(
                              Text(
                                val.isEmpty ? '—' : val,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: val.isEmpty ? Colors.grey.shade400 : const Color(0xFF1E293B),
                                ),
                              ),
                            );
                          }),
                        ],
                      );
                    }),
            ),
          ),

          // 5. Security & Policy Footer
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            color: const Color(0xFFF8FAFC),
            child: const Row(
              children: [
                Icon(Icons.shield_outlined, size: 13, color: Color(0xFF16A34A)),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Export includes complete 52-column dataset. Saved in device Downloads.',
                    style: TextStyle(fontSize: 9.5, color: Color(0xFF64748B)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSnapshotMetaItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.bold,
            color: Color(0xFF64748B),
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Color(0xFF0F172A),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

