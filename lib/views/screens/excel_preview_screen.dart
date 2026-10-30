import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../config/document_schema.dart';
import '../../models/batch_item.dart';
import '../../state/batch_controller.dart';
import '../widgets/step_indicator_bar.dart';

/// Screen 8: Excel Preview (BNF GR Import Format - 49 Columns).
class ExcelPreviewScreen extends StatefulWidget {
  final BatchProcessingController controller;
  final int initialTab;

  const ExcelPreviewScreen({
    super.key,
    required this.controller,
    this.initialTab = 0,
  });

  @override
  State<ExcelPreviewScreen> createState() => _ExcelPreviewScreenState();
}

class _ExcelPreviewScreenState extends State<ExcelPreviewScreen> {
  late int _activeSheetIndex;
  bool _isGenerating = false;
  bool _isDownloadingAll = false;
  List<Map<String, dynamic>> _exportHistory = [];
  bool _isLoadingHistory = false;
  // ignore: unused_field
  String _userName = 'Logistics User';
  String _userMobile = '';

  @override
  void initState() {
    super.initState();
    _activeSheetIndex = widget.initialTab;
    _loadUserInfo();
    _fetchExportHistory();
  }

  @override
  void didUpdateWidget(ExcelPreviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _activeSheetIndex = widget.initialTab;
    }
  }

  Future<void> _loadUserInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final name = widget.controller.activeUserName ?? prefs.getString('bnf_user_name') ?? 'Logistics User';
    final mobile = widget.controller.activeUserMobile ?? prefs.getString('bnf_user_mobile') ?? '';
    if (mounted) {
      setState(() {
        _userName = name;
        _userMobile = mobile;
      });
    }
  }

  Future<void> _fetchExportHistory() async {
    setState(() {
      _isLoadingHistory = true;
    });
    try {
      final history = await widget.controller.geminiService.getExportHistory(
        mobile: widget.controller.activeUserMobile ?? _userMobile,
        sessionToken: widget.controller.sessionToken,
      );
      if (mounted) {
        setState(() {
          _exportHistory = history;
          _isLoadingHistory = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingHistory = false;
        });
      }
    }
  }

  Future<void> _handleDownloadAllUserExports() async {
    final mobile = widget.controller.activeUserMobile;
    if (mobile == null || mobile.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in with your mobile number to download your exports.')),
      );
      return;
    }

    setState(() => _isDownloadingAll = true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Preparing consolidated Excel with all your exported LRs...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      final bytes = await widget.controller.geminiService.downloadAllUserExports(
        mobile,
        sessionToken: widget.controller.sessionToken,
      );
      if (bytes != null && bytes.isNotEmpty) {
        final filename = 'All_Exported_LRs_${mobile}_${DateTime.now().millisecondsSinceEpoch}.xlsx';
        final file = await widget.controller.excelService.saveBytesToFile(bytes, customFileName: filename);
        final savedToDownloads = await widget.controller.excelService.saveFileToDownloads(file.path, targetFileName: filename);
        final displayPath = savedToDownloads ?? file.path;

        if (mounted) {
          widget.controller.setLastExportedPath(file.path);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Saved: ${displayPath.split(RegExp(r"[/\\]")).last}'),
              backgroundColor: const Color(0xFF16A34A),
              duration: const Duration(seconds: 4),
              action: SnackBarAction(
                label: 'OPEN',
                textColor: Colors.white,
                onPressed: () => widget.controller.openLastExport(),
              ),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to download consolidated exports from server.'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error downloading all exports: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isDownloadingAll = false);
    }
  }

  Future<void> _downloadHistoryFile(Map<String, dynamic> exportItem) async {
    final filename = exportItem['filename']?.toString() ??
        exportItem['file_name']?.toString() ??
        'BNF_Consignment_Export_${exportItem['export_id']}.xlsx';
    final downloadUrl = exportItem['download_url']?.toString() ?? '/api/download-export/$filename';

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Downloading $filename...'),
          duration: const Duration(seconds: 1),
        ),
      );
    }

    final bytes = await widget.controller.geminiService.downloadExportedFile(downloadUrl);
    if (bytes != null && bytes.isNotEmpty) {
      final file = await widget.controller.excelService.saveBytesToFile(
        bytes,
        customFileName: filename,
      );
      final savedToDownloads = await widget.controller.excelService.saveFileToDownloads(
        file.path,
        targetFileName: filename,
      );
      final displayPath = savedToDownloads ?? file.path;
      if (mounted) {
        widget.controller.setLastExportedPath(file.path);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved: ${displayPath.split(RegExp(r"[/\\]")).last}'),
            backgroundColor: const Color(0xFF16A34A),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'OPEN',
              textColor: Colors.white,
              onPressed: () => widget.controller.openLastExport(),
            ),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to download Excel file from server.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  // The exact 49 columns of BNF GR Import format
  final List<String> _headers = DocumentSchema.grBnf.fields.map((f) => f.key).toList();

  String _getCellValue(BatchItem item, String header) {
    if (item.record.containsKey(header)) {
      return item.record[header] ?? '';
    }
    final cleanHeader = header.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    for (final entry in item.record.entries) {
      final cleanKey = entry.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
      if (cleanKey == cleanHeader) {
        return entry.value;
      }
    }
    if (header == 'BNF LR No') {
      return item.record['BNF LR No'] ?? item.record['bnf lr no'] ?? item.record['bnflrno'] ?? item.record['bnflr'] ?? '';
    }
    return '';
  }

  void _confirmAndGenerateExcel() {
    final allItems = widget.controller.items;
    final verifiedItems = allItems.where((i) => i.isVerified).toList();
    final verifiedCount = verifiedItems.length;

    if (verifiedCount == 0) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 24),
              SizedBox(width: 8),
              Text('Download Excel', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
          content: const Text(
            'No verified LRs available for download.',
            style: TextStyle(fontSize: 14),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final unverifiedCount = allItems.length - verifiedCount;
    final message = unverifiedCount > 0
        ? 'Generate Excel with $verifiedCount Verified consignment note(s)?\n\nNote: $unverifiedCount Unverified LR(s) will be excluded because mandatory (*) fields are not complete.'
        : 'Are you sure you want to generate the Excel sheet with $verifiedCount verified consignment note(s)?';

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Generate Excel', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        content: Text(message, style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF059669)),
            onPressed: () {
              Navigator.of(ctx).pop();
              _handleGenerateExcel();
            },
            child: Text('Generate ($verifiedCount LRs)'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleGenerateExcel() async {
    setState(() => _isGenerating = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final userName = prefs.getString('bnf_user_name') ?? 'Logistics User';
      final userMobile = prefs.getString('bnf_user_mobile') ?? '';
      final userToken = prefs.getString('bnf_user_token');

      final allItems = widget.controller.items;
      final items = allItems.where((i) => i.isVerified).toList();
      if (items.isEmpty) return;
      final exportIso = DateTime.now().toIso8601String();
      final docs = items.map((i) {
        return {
          'filename': i.fileName,
          'document_title': 'Consignment Note',
          'data': Map<String, String>.from(i.record),
          'created_at': i.createdAt.toIso8601String(),
          'edited_at': i.editedAt?.toIso8601String(),
          'exported_at': exportIso,
          'edit_history': i.editHistory,
        };
      }).toList();

      Map<String, dynamic> result;

      if (widget.controller.useGeminiBackend) {
        result = await widget.controller.geminiService.exportExcelWithSnapshot(
          documents: docs,
          formatType: 'gr_bnf_49',
          userName: userName,
          userMobile: userMobile,
          sessionToken: userToken,
        );

        if (result['success'] == true) {
          final downloadUrl = result['download_url']?.toString();
          final filename = result['filename']?.toString() ?? 'BNF_Bilty_Export.xlsx';

          String? savedFilePath;
          // Download generated Excel file from server directly to device storage
          if (downloadUrl != null && downloadUrl.isNotEmpty) {
            final bytes = await widget.controller.geminiService.downloadExportedFile(downloadUrl);
            if (bytes != null && bytes.isNotEmpty) {
              final file = await widget.controller.excelService.saveBytesToFile(
                bytes,
                customFileName: filename,
              );
              savedFilePath = file.path;
              // Also copy to public Downloads directory
              final publicDlPath = await widget.controller.excelService.saveFileToDownloads(
                savedFilePath,
                targetFileName: filename,
              );
              if (publicDlPath != null) {
                savedFilePath = publicDlPath;
              }
              widget.controller.setLastExportedPath(savedFilePath);
            }
          }

          // Fallback: If network download failed, generate locally via ExcelService with grBnf schema
          if (savedFilePath == null) {
            savedFilePath = await widget.controller.exportToExcel(schema: DocumentSchema.grBnf, itemsToExport: items);
            if (savedFilePath != null) {
              await widget.controller.excelService.saveFileToDownloads(
                savedFilePath,
                targetFileName: filename,
              );
            }
          }

          result['local_path'] = savedFilePath;
        }
      } else {
        // Fallback to local on-device export with 49-column BNF schema
        final filePath = await widget.controller.exportToExcel(schema: DocumentSchema.grBnf, itemsToExport: items);
        final defaultFilename = filePath?.split(RegExp(r'[/\\]')).last ?? 'BNF_Bilty_Export.xlsx';
        if (filePath != null) {
          await widget.controller.excelService.saveFileToDownloads(
            filePath,
            targetFileName: defaultFilename,
          );
        }
        result = {
          'success': filePath != null,
          'filename': defaultFilename,
          'total_lrs': items.length,
          'exported_by': userName,
          'user_mobile': userMobile,
          'generated_on': DateTime.now().toString(),
          'file_size_kb': 28.5,
          'local_path': filePath,
        };
      }

      if (!mounted) return;

      if (result['success'] == true) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.check_circle, color: Color(0xFF059669), size: 24),
                SizedBox(width: 8),
                Text('Excel Generated!', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('File: ${result['filename']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 6),
                Text('Total LRs: ${result['total_lrs']}', style: const TextStyle(fontSize: 13)),
                if (result['local_path'] != null) ...[
                  const SizedBox(height: 6),
                  Text('Saved to: ${result['local_path']}', style: const TextStyle(fontSize: 11, color: Colors.blueGrey)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
              if (widget.controller.lastExportedPath != null) ...[
                OutlinedButton.icon(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await widget.controller.shareLastExport();
                  },
                  icon: const Icon(Icons.share, size: 16),
                  label: const Text('Share'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF059669)),
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await widget.controller.openLastExport();
                  },
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open'),
                ),
              ],
            ],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['error']?.toString() ?? 'Excel generation failed.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('Error generating Excel: $e\n$stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error generating Excel: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allItems = widget.controller.items;
    final verifiedItems = allItems.where((i) => i.isVerified).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        titleSpacing: 14,
        title: Text(_activeSheetIndex == 1 ? 'History' : 'Excel Preview', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        actions: const [],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sheet Tabs Switcher (Only visible in Excel Preview section, removed from History section)
          if (_activeSheetIndex == 0)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
              ),
              child: Row(
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      setState(() {
                        _activeSheetIndex = 0;
                      });
                    },
                    icon: const Icon(Icons.table_view_outlined, size: 15),
                    label: const Text(
                      'Sheet 1: BNF Import Format (49 Columns)',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      elevation: 1,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const Spacer(),
                  Chip(
                    key: const Key('excel_preview_record_count_chip'),
                    label: Text('${verifiedItems.length} LRs', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                    backgroundColor: const Color(0xFFE0F2FE),
                    side: BorderSide.none,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),

          Expanded(
            child: _activeSheetIndex == 0
                ? _buildSheet1BnfTable(verifiedItems)
                : _buildSheet2AuditTable(allItems),
          ),

          // Bottom Action Bar: Generate Excel only when on Sheet 0 (Excel Preview) and verifiedItems is not empty
          if (_activeSheetIndex == 0 && verifiedItems.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(15),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isGenerating ? null : _confirmAndGenerateExcel,
                    icon: _isGenerating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.table_chart_outlined, size: 18),
                    label: Text(
                      _isGenerating
                          ? 'Generating Excel...'
                          : 'Generate Excel (${verifiedItems.length} LRs)',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7), // sky-600
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 2,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: StepIndicatorBar(currentStep: 10, controller: widget.controller),
    );
  }

  Widget _buildSheet1BnfTable(List<BatchItem> items) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  color: Color(0xFFFEF3C7),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.info_outline, color: Color(0xFFD97706), size: 28),
              ),
              const SizedBox(height: 14),
              const Text(
                'No Verified LRs Available',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
              ),
              const SizedBox(height: 6),
              const Text(
                'Only verified consignments appear in Preview LR.\nPlease review and verify pending LRs from the LR List first.',
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B), height: 1.4),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('Back to LR List'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sheet 1 Header Toolbar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE0F2FE),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.table_chart, color: Color(0xFF0284C7), size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Flexible(
                            child: Text(
                              'Sheet 1: BNF Import Format (49 Columns)',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE0F2FE),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text(
                              '49 Columns',
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF0369A1)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Consignment data preview ready to export to Excel (.xlsx)',
                        style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          // Scrollable 49-Column Data Table (Full BNF Format)
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(const Color(0xFF0F172A)),
                headingTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                dataRowMinHeight: 42,
                dataRowMaxHeight: 50,
                columnSpacing: 14,
                horizontalMargin: 10,
                columns: [
                  const DataColumn(label: Text('#')),
                  ..._headers.map((h) => DataColumn(label: Text(h))),
                ],
                rows: List.generate(items.length, (rowIdx) {
                  final item = items[rowIdx];
                  return DataRow(
                    color: WidgetStateProperty.resolveWith<Color?>((states) {
                      return rowIdx.isEven ? const Color(0xFFF8FAFC) : Colors.white;
                    }),
                    cells: [
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${rowIdx + 1}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                            if (item.isFallbackOcr) ...[
                              const SizedBox(width: 4),
                              const Tooltip(
                                message: 'Fallback results',
                                child: Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xFFD97706)),
                              ),
                            ],
                          ],
                        ),
                      ),
                      ..._headers.map((h) {
                        final val = _getCellValue(item, h);
                        return DataCell(
                          Text(
                            val.isEmpty ? '—' : val,
                            style: TextStyle(
                              fontSize: 11,
                              color: val.isEmpty ? Colors.grey.shade400 : Colors.black87,
                            ),
                          ),
                        );
                      }),
                    ],
                  );
                }),
              ),
            ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildSheet2AuditTable(List<BatchItem> items) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildExportHistorySection(),
        ],
      ),
    );
  }
  Widget _buildExportHistorySection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFFF8FAFC),
              borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
              border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.table_chart_rounded, color: Color(0xFF16A34A), size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Generated Excel Exports History',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDCFCE7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${_exportHistory.length} Exports',
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF15803D)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'History of generated Excel workbooks • Auto-purged after 30 days',
                        style: TextStyle(fontSize: 10, color: Colors.blueGrey),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  color: const Color(0xFF0284C7),
                  tooltip: 'Refresh Export History',
                  onPressed: _fetchExportHistory,
                ),
              ],
            ),
          ),

          // Download All My Exported LRs Action Bar
          if (_exportHistory.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: const Color(0xFFF0FDF4),
              child: Row(
                children: [
                  const Icon(Icons.cloud_download_outlined, size: 16, color: Color(0xFF16A34A)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Download all of your exported LRs as a single Excel file',
                      style: TextStyle(fontSize: 11, color: Color(0xFF166534), fontWeight: FontWeight.w500),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _isDownloadingAll ? null : _handleDownloadAllUserExports,
                    icon: _isDownloadingAll
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.download_rounded, size: 14),
                    label: Text(
                      _isDownloadingAll ? 'Downloading...' : 'Download All (.xlsx)',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                      minimumSize: const Size(0, 32),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),

          // Content
          if (_isLoadingHistory)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            )
          else if (_exportHistory.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Center(
                child: Text(
                  'No Excel exports generated yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _exportHistory.length,
              separatorBuilder: (_, _) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
              itemBuilder: (context, idx) {
                final item = _exportHistory[idx];
                final filename = item['filename']?.toString() ??
                    item['file_name']?.toString() ??
                    'BNF_Consignment_Export.xlsx';
                final timestamp = item['timestamp']?.toString() ??
                    item['generated_on']?.toString() ??
                    item['created_at']?.toString() ??
                    '';
                final user = item['user']?.toString() ??
                    item['exported_by']?.toString() ??
                    item['user_name']?.toString() ??
                    'Logistics User';
                final mobile = item['mobile']?.toString() ?? item['user_mobile']?.toString() ?? '';
                final lrCount = item['lr_count'] ?? item['total_lrs'] ?? 1;

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.description_outlined, size: 16, color: Color(0xFF16A34A)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              filename,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF0F172A)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE0F2FE),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '$lrCount LRs',
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF0284C7)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.access_time, size: 12, color: Colors.grey),
                          const SizedBox(width: 4),
                          Text(
                            timestamp,
                            style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
                          ),
                          const SizedBox(width: 12),
                          const Icon(Icons.person_outline, size: 12, color: Colors.grey),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '$user${mobile.isNotEmpty ? ' ($mobile)' : ''}',
                              style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'Retained: 30 Days',
                              style: TextStyle(fontSize: 9.5, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                            ),
                          ),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed: () => _downloadHistoryFile(item),
                            icon: const Icon(Icons.download_rounded, size: 14),
                            label: const Text('Download Excel', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF16A34A),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                              minimumSize: const Size(0, 32),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
