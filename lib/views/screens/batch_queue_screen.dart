import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../config/document_schema.dart';
import '../../models/batch_item.dart';
import '../../state/batch_controller.dart';
import '../widgets/ocr_processing_dialog.dart';
import '../widgets/step_indicator_bar.dart';
import 'edit_bilty_screen.dart';
import 'excel_preview_screen.dart';

/// Screen 7: LR Batch Queue List (For Consolidated Excel Export).
class BatchQueueScreen extends StatefulWidget {
  final BatchProcessingController controller;
  final bool autoOpenAddMore;

  const BatchQueueScreen({
    super.key,
    required this.controller,
    this.autoOpenAddMore = false,
  });

  @override
  State<BatchQueueScreen> createState() => _BatchQueueScreenState();
}

class _BatchQueueScreenState extends State<BatchQueueScreen> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _customerController = TextEditingController();
  final TextEditingController _vehicleController = TextEditingController();
  DateTime? _dateFrom;
  DateTime? _dateTo;
  String _searchQuery = '';
  String _customerQuery = '';
  String _vehicleQuery = '';
  bool _isExporting = false;
  bool _showFilters = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_checkDuplicateNotice);
    if (widget.autoOpenAddMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAddMoreDialog();
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_checkDuplicateNotice);
    _searchController.dispose();
    _customerController.dispose();
    _vehicleController.dispose();
    super.dispose();
  }

  void _resetBatchFilters() {
    setState(() {
      _searchController.clear();
      _customerController.clear();
      _vehicleController.clear();
      _searchQuery = '';
      _customerQuery = '';
      _vehicleQuery = '';
      _dateFrom = null;
      _dateTo = null;
    });
  }

  DateTime? _parseRecordDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final clean = raw.trim().split(RegExp(r'[\sT]'))[0];
    final parts = clean.split(RegExp(r'[\/\-\.]'));
    if (parts.length == 3) {
      final d = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      var y = int.tryParse(parts[2]);
      if (d != null && m != null && y != null) {
        if (y < 100) y += 2000;
        return DateTime(y, m, d);
      }
    }
    return DateTime.tryParse(clean);
  }

  void _checkDuplicateNotice() {
    if (!mounted) return;
    if (widget.controller.duplicateNoticePending) {
      final msg = widget.controller.duplicateNoticeMessage ??
          'This LR already exists. You cannot add the same LR multiple times.';
      widget.controller.acknowledgeDuplicateNotice();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: const [
                Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 28),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Duplicate LR',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: Text(
              msg,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
            actions: [
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                ),
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      });
    }
  }

  String _getField(BatchItem item, String key, [String fallback = '—']) {
    final record = item.record;
    if (record.containsKey(key) && record[key]!.trim().isNotEmpty) {
      return record[key]!.trim();
    }
    final cleanKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    for (final entry in record.entries) {
      final cEntry = entry.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
      if (cleanKey == cEntry && entry.value.trim().isNotEmpty) {
        return entry.value.trim();
      }
    }
    return fallback;
  }

  void _showAddMoreDialog() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Add More Consignments', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text('Choose intake source for adding more LRs to this batch:', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 16),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFE0F2FE),
                  child: Icon(Icons.camera_alt, color: Color(0xFF0284C7)),
                ),
                title: const Text('Capture with Camera', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Photograph consignment note directly', style: TextStyle(fontSize: 11)),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => OcrProcessingDialog(controller: widget.controller),
                  );
                  await widget.controller.addFromCamera();
                  if (mounted && Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFFEF3C7),
                  child: Icon(Icons.photo_library, color: Color(0xFFD97706)),
                ),
                title: const Text('Upload Images from Gallery', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Select multiple photos from device album', style: TextStyle(fontSize: 11)),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await _pickAndAddFiles(allowedExtensions: ['jpg', 'jpeg', 'png', 'webp']);
                },
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFFEE2E2),
                  child: Icon(Icons.picture_as_pdf, color: Color(0xFFDC2626)),
                ),
                title: const Text('Upload PDF Document', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Select PDF bilty documents or invoices', style: TextStyle(fontSize: 11)),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await _pickAndAddPdfs();
                },
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFE0E7FF),
                  child: Icon(Icons.file_copy, color: Color(0xFF4F46E5)),
                ),
                title: const Text('Upload Any Document or Image', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Select JPG, PNG or PDF consignment files', style: TextStyle(fontSize: 11)),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await _pickAndAddFiles(allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf', 'webp']);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _resolvePlatformFilePath(PlatformFile file) async {
    if (file.path != null && file.path!.isNotEmpty && File(file.path!).existsSync()) {
      return file.path!;
    }
    try {
      if (file.xFile.path.isNotEmpty && File(file.xFile.path).existsSync()) {
        return file.xFile.path;
      }
    } catch (_) {}
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) {
        final tmp = await getTemporaryDirectory();
        final safeName = file.name.isNotEmpty ? file.name : 'upload_${DateTime.now().millisecondsSinceEpoch}.pdf';
        final localFile = File('${tmp.path}/$safeName');
        await localFile.writeAsBytes(bytes, flush: true);
        return localFile.path;
      }
    } catch (_) {}
    try {
      final bytes = await file.xFile.readAsBytes();
      if (bytes.isNotEmpty) {
        final tmp = await getTemporaryDirectory();
        final safeName = file.name.isNotEmpty ? file.name : 'upload_${DateTime.now().millisecondsSinceEpoch}.pdf';
        final localFile = File('${tmp.path}/$safeName');
        await localFile.writeAsBytes(bytes, flush: true);
        return localFile.path;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _pickAndAddPdfs() async {
    await _pickAndAddFiles(allowedExtensions: ['pdf']);
  }

  Future<void> _pickAndAddFiles({List<String>? allowedExtensions}) async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: allowedExtensions ?? ['jpg', 'jpeg', 'png', 'pdf', 'webp'],
      );
      if (files.isEmpty) return;
      final validPaths = <String>[];
      for (final file in files) {
        final size = file.lengthSync() ?? (await file.length()) ?? 0;
        if (size > 10 * 1024 * 1024) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('File "${file.name}" exceeds 10 MB limit. Please select files under 10 MB.'),
                backgroundColor: Colors.red.shade700,
              ),
            );
          }
          continue;
        }
        final path = await _resolvePlatformFilePath(file);
        if (path != null && path.isNotEmpty) {
          validPaths.add(path);
        }
      }
      if (validPaths.isEmpty) return;

      if (mounted) {
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => OcrProcessingDialog(controller: widget.controller),
        );
      }
      await widget.controller.addFilePaths(validPaths);
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open file picker: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _handleDirectDownloadExcel() async {
    final allItems = widget.controller.items;
    final verifiedItems = allItems.where((i) => i.isVerified).toList();
    final verifiedCount = verifiedItems.length;

    // Web Parity: If no verified LRs are available, show alert modal
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
        ? 'Download $verifiedCount Verified consignment note(s)?\n\nNote: $unverifiedCount Unverified LR(s) will be excluded because mandatory (*) fields are not complete.'
        : 'Are you sure you want to download $verifiedCount verified consignment note(s)?';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.file_download, color: Color(0xFF0284C7), size: 24),
            SizedBox(width: 8),
            Text('Download Excel', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Text(
          message,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF059669)),
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.download, size: 16),
            label: Text('Download ($verifiedCount LRs)'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isExporting = true);
    try {
      final filePath = await widget.controller.exportToExcel(
        schema: DocumentSchema.grBnf,
        itemsToExport: verifiedItems,
      );
      if (!mounted) return;

      if (filePath != null) {
        final defaultFilename = filePath.split(RegExp(r'[/\\]')).last;
        final savedPath = await widget.controller.excelService.saveFileToDownloads(
          filePath,
          targetFileName: defaultFilename,
        );
        final finalPath = savedPath ?? filePath;
        widget.controller.setLastExportedPath(finalPath);
        if (!mounted) return;

        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.check_circle, color: Color(0xFF059669), size: 24),
                SizedBox(width: 8),
                Text('Excel Downloaded!', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('File: $defaultFilename', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 6),
                Text('Verified LRs Exported: $verifiedCount', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF16A34A))),
                if (unverifiedCount > 0) ...[
                  const SizedBox(height: 4),
                  Text('Unverified LRs Excluded: $unverifiedCount', style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
                ],
                const SizedBox(height: 6),
                Text('Saved to: $filePath', style: const TextStyle(fontSize: 11, color: Colors.blueGrey)),
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
          const SnackBar(
            content: Text('Excel export failed. Please verify LR records.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error downloading Excel: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const brandBlue = Color(0xFF0284C7);

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final allItems = widget.controller.items;
        final filteredItems = allItems.where((item) {
          final d = item.record;

          // 1. Text Search across LR, Route, City, Goods, Vehicle, Customer, Filename
          if (_searchQuery.isNotEmpty) {
            final q = _searchQuery.toLowerCase();
            final allText = [
              item.fileName,
              _getField(item, 'LR No *', ''),
              _getField(item, 'grno', ''),
              _getField(item, 'Vehicle No *', ''),
              _getField(item, 'Customer Name *', ''),
              _getField(item, 'cngr *', ''),
              _getField(item, 'cnge *', ''),
              _getField(item, 'from', ''),
              _getField(item, 'to', ''),
              _getField(item, 'descgoods', ''),
            ].join(' ').toLowerCase();
            if (!allText.contains(q)) return false;
          }

          // 2. Customer Filter
          if (_customerQuery.isNotEmpty) {
            final cust = '${_getField(item, 'Customer Name *', '')} ${_getField(item, 'cngr *', '')}'.toLowerCase();
            if (!cust.contains(_customerQuery.toLowerCase())) return false;
          }

          // 3. Vehicle No Filter
          if (_vehicleQuery.isNotEmpty) {
            final veh = _getField(item, 'Vehicle No *', '').replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
            final vq = _vehicleQuery.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
            if (!veh.contains(vq)) return false;
          }

          // 4. Date Range Filter
          if (_dateFrom != null || _dateTo != null) {
            final dtCandidates = [
              _parseRecordDate(d['grdt *']),
              _parseRecordDate(d['stockdt ']),
              _parseRecordDate(d['Loading Start date *']),
              _parseRecordDate(d['date']),
              item.createdAt,
            ].whereType<DateTime>().toList();

            if (dtCandidates.isEmpty) return false;
            final matched = dtCandidates.any((dt) {
              if (_dateFrom != null && dt.isBefore(_dateFrom!)) return false;
              if (_dateTo != null && dt.isAfter(_dateTo!.add(const Duration(days: 1)))) return false;
              return true;
            });
            if (!matched) return false;
          }

          return true;
        }).toList();

        final hasActiveFilters = _searchQuery.isNotEmpty ||
            _customerQuery.isNotEmpty ||
            _vehicleQuery.isNotEmpty ||
            _dateFrom != null ||
            _dateTo != null;

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          appBar: AppBar(
            titleSpacing: 8,
            title: const Text('LR List (For Excel Export)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            actions: [
              // Excel Preview Button (Web Parity)
              IconButton(
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(Icons.table_view_outlined, color: Color(0xFFD97706), size: 20),
                tooltip: 'Excel Preview',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ExcelPreviewScreen(controller: widget.controller, initialTab: 0),
                    ),
                  );
                },
              ),
              // History Button (Web Parity)
              IconButton(
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(Icons.history, color: brandBlue, size: 20),
                tooltip: 'History',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ExcelPreviewScreen(controller: widget.controller, initialTab: 1),
                    ),
                  );
                },
              ),
              // Add More LR (Web Parity)
              InkWell(
                onTap: _showAddMoreDialog,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: brandBlue,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 14, color: Colors.white),
                      SizedBox(width: 4),
                      Text('Add More LR', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            children: [
              // Web-Matching Multi-Filter Bar
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                color: Colors.white,
                child: Column(
                  children: [
                    // Row 1: Text Search with Clear (x) and Filter Toggle Button
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            onChanged: (val) => setState(() => _searchQuery = val.trim()),
                            style: const TextStyle(fontSize: 12),
                            decoration: InputDecoration(
                              hintText: 'Search LR, Route, City, Goods...',
                              prefixIcon: const Icon(Icons.search, size: 16, color: Colors.blueGrey),
                              suffixIcon: _searchQuery.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.close, size: 14),
                                      onPressed: () {
                                        _searchController.clear();
                                        setState(() => _searchQuery = '');
                                      },
                                    )
                                  : null,
                              filled: true,
                              fillColor: const Color(0xFFF1F5F9),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: Icon(
                            _showFilters ? Icons.filter_alt : Icons.filter_alt_outlined,
                            color: hasActiveFilters ? brandBlue : Colors.blueGrey,
                            size: 20,
                          ),
                          tooltip: 'Filters',
                          onPressed: () => setState(() => _showFilters = !_showFilters),
                        ),
                        if (hasActiveFilters)
                          TextButton.icon(
                            onPressed: _resetBatchFilters,
                            icon: const Icon(Icons.refresh, size: 14, color: Colors.blueGrey),
                            label: const Text('Reset', style: TextStyle(fontSize: 11, color: Colors.blueGrey)),
                            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                          ),
                      ],
                    ),

                    // Expandable Multi-Filter Drawer (Customer, Vehicle No, Date Range)
                    if (_showFilters) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          // Customer Filter
                          Expanded(
                            child: TextField(
                              controller: _customerController,
                              onChanged: (val) => setState(() => _customerQuery = val.trim()),
                              style: const TextStyle(fontSize: 11),
                              decoration: InputDecoration(
                                hintText: 'Customer...',
                                prefixIcon: const Icon(Icons.business_outlined, size: 14, color: Colors.blueGrey),
                                suffixIcon: _customerQuery.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.close, size: 12),
                                        onPressed: () {
                                          _customerController.clear();
                                          setState(() => _customerQuery = '');
                                        },
                                      )
                                    : null,
                                filled: true,
                                fillColor: const Color(0xFFF8FAFC),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Vehicle No Filter
                          Expanded(
                            child: TextField(
                              controller: _vehicleController,
                              onChanged: (val) => setState(() => _vehicleQuery = val.trim()),
                              style: const TextStyle(fontSize: 11),
                              decoration: InputDecoration(
                                hintText: 'Vehicle No...',
                                prefixIcon: const Icon(Icons.local_shipping_outlined, size: 14, color: Colors.blueGrey),
                                suffixIcon: _vehicleQuery.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.close, size: 12),
                                        onPressed: () {
                                          _vehicleController.clear();
                                          setState(() => _vehicleQuery = '');
                                        },
                                      )
                                    : null,
                                filled: true,
                                fillColor: const Color(0xFFF8FAFC),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Date Range Pickers (From & To)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final d = await showDatePicker(
                                  context: context,
                                  initialDate: _dateFrom ?? DateTime.now(),
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime(2035),
                                );
                                if (d != null) setState(() => _dateFrom = d);
                              },
                              icon: const Icon(Icons.calendar_today, size: 12),
                              label: Text(
                                _dateFrom != null ? '${_dateFrom!.day}/${_dateFrom!.month}/${_dateFrom!.year}' : 'From Date',
                                style: const TextStyle(fontSize: 10.5),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ),
                          if (_dateFrom != null)
                            IconButton(
                              icon: const Icon(Icons.close, size: 12),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => setState(() => _dateFrom = null),
                            ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final d = await showDatePicker(
                                  context: context,
                                  initialDate: _dateTo ?? DateTime.now(),
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime(2035),
                                );
                                if (d != null) setState(() => _dateTo = d);
                              },
                              icon: const Icon(Icons.calendar_today, size: 12),
                              label: Text(
                                _dateTo != null ? '${_dateTo!.day}/${_dateTo!.month}/${_dateTo!.year}' : 'To Date',
                                style: const TextStyle(fontSize: 10.5),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ),
                          if (_dateTo != null)
                            IconButton(
                              icon: const Icon(Icons.close, size: 12),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => setState(() => _dateTo = null),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // Filter Stats Badge Matching Web (Total: N LRs or Showing X of N LRs)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: hasActiveFilters ? const Color(0xFFF0F9FF) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: hasActiveFilters ? const Color(0xFFBAE6FD) : const Color(0xFFE2E8F0),
                        ),
                      ),
                      child: Text(
                        hasActiveFilters
                            ? 'Showing ${filteredItems.length} of ${allItems.length} LRs'
                            : 'Total: ${allItems.length} ${allItems.length == 1 ? 'LR' : 'LRs'}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: hasActiveFilters ? const Color(0xFF0369A1) : const Color(0xFF475569),
                        ),
                      ),
                    ),
                    Text(
                      '${allItems.where((i) => i.isVerified).length} Verified',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF16A34A)),
                    ),
                  ],
                ),
              ),

              // Item Cards List
              Expanded(
                child: filteredItems.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.layers_clear_outlined, size: 54, color: Colors.grey),
                            const SizedBox(height: 12),
                            Text(
                              _searchQuery.isNotEmpty ? 'No LRs match "$_searchQuery"' : 'No consignment notes in batch',
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.blueGrey),
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(
                              onPressed: _showAddMoreDialog,
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('Add LRs Now'),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        itemCount: filteredItems.length,
                        itemBuilder: (context, idx) {
                          final item = filteredItems[idx];
                          final lrNo = _getField(item, 'LR No *', _getField(item, 'grno', item.fileName));
                          final vehNo = _getField(item, 'Vehicle No *', '—');
                          final cust = _getField(item, 'Customer Name *', '—');
                          final route = '${_getField(item, 'orgrefcode', '—')} -> ${_getField(item, 'destrefcode', '—')}';

                          return Card(
                            elevation: 0,
                            margin: const EdgeInsets.only(bottom: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(color: Colors.grey.shade200),
                            ),
                            color: Colors.white,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: Colors.blue.shade50,
                                                borderRadius: BorderRadius.circular(6),
                                              ),
                                              child: Text('#${idx + 1}', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.blue.shade800)),
                                            ),
                                            const SizedBox(width: 8),
                                            Flexible(
                                              child: Text(
                                                lrNo,
                                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (item.isFallbackOcr) ...[
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFFEF3C7),
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(
                                                  color: const Color(0xFFF59E0B),
                                                ),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: const [
                                                  Icon(
                                                    Icons.warning_amber_rounded,
                                                    size: 11,
                                                    color: Color(0xFFB45309),
                                                  ),
                                                  SizedBox(width: 3),
                                                  Text(
                                                    'Fallback',
                                                    style: TextStyle(
                                                      fontSize: 9.5,
                                                      fontWeight: FontWeight.bold,
                                                      color: Color(0xFFB45309),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                          ],
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: item.isVerified ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
                                              borderRadius: BorderRadius.circular(10),
                                              border: Border.all(
                                                color: item.isVerified ? const Color(0xFF86EFAC) : const Color(0xFFFCA5A5),
                                              ),
                                            ),
                                            child: Text(
                                              item.isVerified ? 'Verified' : 'Unverified',
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: item.isVerified ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Vehicle: $vehNo • Customer: $cust',
                                    style: const TextStyle(fontSize: 12, color: Color(0xFF475569)),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    'Route: $route',
                                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Text(
                                        'Created: ${item.createdAt.day.toString().padLeft(2, '0')}/${item.createdAt.month.toString().padLeft(2, '0')} ${item.createdAt.hour.toString().padLeft(2, '0')}:${item.createdAt.minute.toString().padLeft(2, '0')}',
                                        style: TextStyle(fontSize: 10, color: Colors.grey.shade600, fontFamily: 'monospace'),
                                      ),
                                      const SizedBox(width: 8),
                                      Text('•', style: TextStyle(fontSize: 10, color: Colors.grey.shade400)),
                                      const SizedBox(width: 8),
                                      Text(
                                        item.editedAt != null
                                            ? 'Edited: ${item.editedAt!.hour.toString().padLeft(2, '0')}:${item.editedAt!.minute.toString().padLeft(2, '0')}'
                                            : 'Never edited',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: item.editedAt != null ? Colors.amber.shade900 : Colors.grey.shade500,
                                          fontWeight: item.editedAt != null ? FontWeight.bold : FontWeight.normal,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  const Divider(height: 1),
                                  const SizedBox(height: 4),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      TextButton.icon(
                                        onPressed: () {
                                          Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => EditBiltyScreen(item: item, controller: widget.controller),
                                            ),
                                          );
                                        },
                                        icon: const Icon(Icons.edit_outlined, size: 15),
                                        label: const Text('Edit', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                        style: TextButton.styleFrom(
                                          foregroundColor: brandBlue,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                                        tooltip: 'Delete',
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () {
                                          showDialog<void>(
                                            context: context,
                                            builder: (ctx) => AlertDialog(
                                              title: const Text('Remove Consignment?'),
                                              content: Text('Remove consignment "${_getField(item, 'LR No *', item.fileName)}" from this batch?'),
                                              actions: [
                                                TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
                                                FilledButton(
                                                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                                  onPressed: () {
                                                    widget.controller.removeItem(item.id);
                                                    Navigator.of(ctx).pop();
                                                  },
                                                  child: const Text('Delete'),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),

              // Bottom Sticky Action Bar
              Container(
                padding: const EdgeInsets.all(16),
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
                  child: Row(
                    children: [
                      OutlinedButton(
                        onPressed: allItems.isEmpty
                            ? null
                            : () {
                                showDialog<void>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Clear All LRs?'),
                                    content: const Text('This will remove all consignment notes from the current batch queue.'),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
                                      FilledButton(
                                        style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                        onPressed: () {
                                          widget.controller.clearQueue();
                                          Navigator.of(ctx).pop();
                                        },
                                        child: const Text('Clear All'),
                                      ),
                                    ],
                                  ),
                                );
                              },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Clear All'),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('direct_download_excel_btn'),
                          onPressed: _isExporting ? null : _handleDirectDownloadExcel,
                          icon: _isExporting
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.download, size: 16),
                          label: Text(
                            _isExporting
                                ? 'Exporting...'
                                : 'Download Excel (${allItems.where((i) => i.isVerified).length} LRs)',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF059669), // Emerald Green matching Web
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: StepIndicatorBar(currentStep: 3, controller: widget.controller),
        );
      },
    );
  }
}
