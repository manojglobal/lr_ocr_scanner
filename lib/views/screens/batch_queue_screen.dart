import '../../services/excel_service.dart';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../config/document_schema.dart';

import '../../models/batch_item.dart';

import '../../state/batch_controller.dart';

import '../home_screen.dart';
import '../widgets/lr_notice_dialogs.dart';

import '../widgets/step_indicator_bar.dart';

import 'camera_scan_screen.dart';
import 'edit_bilty_screen.dart';

import 'excel_generated_screen.dart';
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
  bool _isShowingPageLimitDialog = false;
  bool _isShowingMultipleLrsDialog = false;
  bool _isShowingInvalidLrDialog = false;
  bool _isShowingConnectionErrorDialog = false;
  bool _isShowingDuplicateDialog = false;
  bool _isOcrDialogOpen = false;

  @override
  void initState() {
    super.initState();

    widget.controller.addListener(_checkDuplicateNotice);
    widget.controller.addListener(_checkPageLimitNotice);
    widget.controller.addListener(_checkMultipleLrsNotice);
    widget.controller.addListener(_checkInvalidLrNotice);
    widget.controller.addListener(_checkConnectionErrorNotice);

    if (widget.autoOpenAddMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _navigateToAddMoreLR();
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_checkDuplicateNotice);
    widget.controller.removeListener(_checkPageLimitNotice);
    widget.controller.removeListener(_checkMultipleLrsNotice);
    widget.controller.removeListener(_checkInvalidLrNotice);
    widget.controller.removeListener(_checkConnectionErrorNotice);

    _searchController.dispose();

    _customerController.dispose();

    _vehicleController.dispose();

    super.dispose();
  }

  void _showPageLimitExceededDialog([String? customMsg]) {
    if (!mounted || _isShowingPageLimitDialog) return;
    _isShowingPageLimitDialog = true;

    final msg = customMsg ??
        'Maximum 15 pages are allowed per upload. Please upload documents containing 15 pages or fewer.';

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 28),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Page Limit Exceeded',
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              _isShowingPageLimitDialog = false;
              Navigator.of(ctx).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    ).then((_) {
      _isShowingPageLimitDialog = false;
    }).catchError((_) {
      _isShowingPageLimitDialog = false;
    });
  }

  bool get _canHandleNotices =>
      mounted && !_isOcrDialogOpen && (ModalRoute.of(context)?.isCurrent ?? true);

  void _drainPendingNotices() {
    if (!_canHandleNotices) return;
    _checkPageLimitNotice(immediate: true);
    _checkMultipleLrsNotice(immediate: true);
    _checkInvalidLrNotice(immediate: true);
    _checkDuplicateNotice(immediate: true);
    _checkConnectionErrorNotice(immediate: true);
  }

  void _checkPageLimitNotice({bool immediate = false}) {
    if (!_canHandleNotices) return;
    if (widget.controller.pageLimitNoticePending) {
      final msg = widget.controller.pageLimitNoticeMessage ??
          defaultPageLimitMessage;
      widget.controller.acknowledgePageLimitNotice();

      presentNoticeDialog(
        immediate: immediate,
        show: () {
          if (!mounted) return;
          _showPageLimitExceededDialog(msg);
        },
      );
    }
  }

  void _checkMultipleLrsNotice({bool immediate = false}) {
    if (!_canHandleNotices) return;
    if (widget.controller.multipleLrsNoticePending) {
      final msg = widget.controller.multipleLrsNoticeMessage ??
          defaultMultipleLrsMessage;
      widget.controller.acknowledgeMultipleLrsNotice();

      if (_isShowingMultipleLrsDialog) return;
      _isShowingMultipleLrsDialog = true;

      presentNoticeDialog(
        immediate: immediate,
        show: () {
          if (!mounted) {
            _isShowingMultipleLrsDialog = false;
            return;
          }
          showMultipleLrsNotAllowedDialog(
            context,
            message: msg,
            onDismissed: () {
              _isShowingMultipleLrsDialog = false;
            },
          );
        },
      );
    }
  }

  void _checkInvalidLrNotice({bool immediate = false}) {
    if (!_canHandleNotices) return;
    if (widget.controller.invalidLrNoticePending) {
      final msg = widget.controller.invalidLrNoticeMessage ??
          defaultInvalidLrMessage;
      widget.controller.acknowledgeInvalidLrNotice();

      if (_isShowingInvalidLrDialog) return;
      _isShowingInvalidLrDialog = true;

      presentNoticeDialog(
        immediate: immediate,
        show: () {
          if (!mounted) {
            _isShowingInvalidLrDialog = false;
            return;
          }
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 28),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Invalid LR',
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
                  onPressed: () {
                    _isShowingInvalidLrDialog = false;
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('OK'),
                ),
              ],
            ),
          ).whenComplete(() {
            _isShowingInvalidLrDialog = false;
          });
        },
      );
    }
  }

  void _checkConnectionErrorNotice({bool immediate = false}) {
    if (!_canHandleNotices) return;
    if (widget.controller.connectionErrorNoticePending) {
      final msg = widget.controller.connectionErrorNoticeMessage ??
          'Unable to reach the validation server. Please check your network connection and try again.';
      widget.controller.acknowledgeConnectionErrorNotice();

      if (_isShowingConnectionErrorDialog) return;
      _isShowingConnectionErrorDialog = true;

      presentNoticeDialog(
        immediate: immediate,
        show: () {
          if (!mounted) {
            _isShowingConnectionErrorDialog = false;
            return;
          }
          showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.wifi_off_rounded, color: Colors.redAccent, size: 28),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Connection Notice',
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
                  onPressed: () {
                    _isShowingConnectionErrorDialog = false;
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('OK'),
                ),
              ],
            ),
          ).whenComplete(() {
            _isShowingConnectionErrorDialog = false;
          });
        },
      );
    }
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

  @visibleForTesting
  void setDateRangeForTesting(DateTime? from, DateTime? to) {
    setState(() {
      _dateFrom = from;
      _dateTo = to;
    });
  }

  @visibleForTesting
  void setShowFiltersForTesting(bool show) {
    setState(() {
      _showFilters = show;
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

  void _checkDuplicateNotice({bool immediate = false}) {
    if (!_canHandleNotices) return;

    if (widget.controller.duplicateNoticePending) {
      final msg =
          widget.controller.duplicateNoticeMessage ??
          'This LR already exists. You cannot add the same LR multiple times.';
      widget.controller.acknowledgeDuplicateNotice();

      if (_isShowingDuplicateDialog) return;
      _isShowingDuplicateDialog = true;

      presentNoticeDialog(
        immediate: immediate,
        show: () {
          if (!mounted) {
            _isShowingDuplicateDialog = false;
            return;
          }

          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: const [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.amber,
                    size: 28,
                  ),
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
                  onPressed: () {
                    _isShowingDuplicateDialog = false;
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('OK'),
                ),
              ],
            ),
          ).whenComplete(() {
            _isShowingDuplicateDialog = false;
          });
        },
      );
    }
  }

  String _getField(BatchItem item, String key, [String fallback = '—']) {
    final record = item.record;

    if (record.containsKey(key) && record[key]!.trim().isNotEmpty) {
      return record[key]!.trim();
    }

    final cleanKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();

    for (final entry in record.entries) {
      final cEntry = entry.key
          .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
          .toLowerCase();

      if (cleanKey == cEntry && entry.value.trim().isNotEmpty) {
        return entry.value.trim();
      }
    }

    return fallback;
  }

  void _navigateToAddMoreLR() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => HomeScreen(controller: widget.controller),
        ),
        (route) => false,
      );
    }
  }

  // ignore: unused_element
  void _showAddMoreDialog() {
    showModalBottomSheet<void>(
      context: context,

      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),

      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),

          child: Column(
            mainAxisSize: MainAxisSize.min,

            crossAxisAlignment: CrossAxisAlignment.stretch,

            children: [
              const Text(
                'Add More Consignments',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),

              const SizedBox(height: 6),

              const Text(
                'Choose intake source for adding more LRs to this batch:',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),

              const SizedBox(height: 6),

              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F9FF),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFBAE6FD)),
                ),
                child: const Text(
                  'Maximum upload limit: 15 pages.',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0284C7),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFE0F2FE),

                  child: Icon(Icons.camera_alt, color: Color(0xFF0284C7)),
                ),

                title: const Text(
                  'Capture with Camera',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),

                subtitle: const Text(
                  'Photograph consignment note directly',
                  style: TextStyle(fontSize: 11),
                ),

                onTap: () async {
                  Navigator.of(ctx).pop();

                  final hasPerm = await widget.controller.permissionService.requestCameraPermission();
                  if (!hasPerm) return;

                  if (!mounted) return;
                  final List<String>? capturedPages = await Navigator.of(context).push<List<String>>(
                    MaterialPageRoute(
                      builder: (_) => const CameraScanScreen(),
                    ),
                  );

                  if (capturedPages == null || capturedPages.isEmpty) return;

                  _isOcrDialogOpen = true;
                  try {
                    if (mounted) {
                      await runWithOcrProcessingRoute<bool>(
                        context: context,
                        controller: widget.controller,
                        action: () => widget.controller.addMultiPageScan(capturedPages),
                      );
                    }
                  } finally {
                    _isOcrDialogOpen = false;
                    _drainPendingNotices();
                  }
                },
              ),

              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFFEF3C7),

                  child: Icon(Icons.photo_library, color: Color(0xFFD97706)),
                ),

                title: const Text(
                  'Upload Images from Gallery',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),

                subtitle: const Text(
                  'Select multiple photos from device album',
                  style: TextStyle(fontSize: 11),
                ),

                onTap: () async {
                  Navigator.of(ctx).pop();

                  await _pickAndAddGalleryImages();
                },
              ),

              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFFEE2E2),

                  child: Icon(Icons.picture_as_pdf, color: Color(0xFFDC2626)),
                ),

                title: const Text(
                  'Upload PDF Document',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),

                subtitle: const Text(
                  'Select PDF bilty documents or invoices',
                  style: TextStyle(fontSize: 11),
                ),

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

                title: const Text(
                  'Upload Any Document or Image',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),

                subtitle: const Text(
                  'Select JPG, PNG or PDF consignment files',
                  style: TextStyle(fontSize: 11),
                ),

                onTap: () async {
                  Navigator.of(ctx).pop();

                  await _pickAndAddFiles(
                    allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf', 'webp'],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _processQueuePaths(List<String> paths) async {
    if (paths.isEmpty || !mounted) return;
    if (!await validatePathFileSizes(context, paths)) return;

    final totalPages = await countTotalUploadPages(paths);
    if (totalPages > 15) {
      if (mounted) _showPageLimitExceededDialog();
      return;
    }

    final countBefore = widget.controller.items.length;

    bool added = false;
    _isOcrDialogOpen = true;
    try {
      if (mounted) {
        added = await runWithOcrProcessingRoute<bool>(
          context: context,
          controller: widget.controller,
          action: () => paths.length > 1
              ? widget.controller.addMultipleFilesAsSingleLr(paths)
              : widget.controller.addFilePaths([paths.first]),
        );
      }
    } finally {
      _isOcrDialogOpen = false;
      _drainPendingNotices();
    }

    if (!added) return;

    // Automatically open Step 2: LR & Master Verification for the uploaded file
    final newItem = widget.controller.lastUploadedItem ??
        (widget.controller.items.length > countBefore
            ? widget.controller.items.last
            : null);
    if (mounted && newItem != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              EditBiltyScreen(item: newItem, controller: widget.controller),
        ),
      );
    }
  }

  Future<void> _pickAndAddGalleryImages() async {
    try {
      final paths = await widget.controller.imageService.pickMultipleImages();
      await _processQueuePaths(paths);
    } catch (_) {
      await _pickAndAddFiles(allowedExtensions: ['jpg', 'jpeg', 'png', 'webp']);
    }
  }

  Future<void> _pickAndAddPdfs() async {
    await _pickAndAddFiles(allowedExtensions: ['pdf']);
  }

  Future<void> _pickAndAddFiles({List<String>? allowedExtensions}) async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions:
            allowedExtensions ?? ['jpg', 'jpeg', 'png', 'pdf', 'webp'],
      );

      if (files.isEmpty) return;

      if (mounted && !await validatePickedFileSizes(context, files)) {
        return;
      }

      final paths = <String>[];
      for (int i = 0; i < files.length; i++) {
        final path = await resolvePickedPlatformFilePath(files[i], index: i);
        if (path != null && path.isNotEmpty) {
          paths.add(path);
        }
      }

      await _processQueuePaths(paths);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open file picker: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleDirectDownloadExcel() async {
    final allItems = widget.controller.items;
    final allVerifiedItems = allItems.where((i) => i.isVerified).toList();
    final unexportedVerified = widget.controller.getExportableVerifiedItems(
      includeAlreadyExported: false,
    );
    final unverifiedCount = allItems.where((i) => !i.isVerified).length;

    // Web Parity: If no verified LRs are available, show alert modal
    if (allVerifiedItems.isEmpty) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFFD97706),
                size: 24,
              ),
              SizedBox(width: 8),
              Text(
                'Download Excel',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
          content: const Text(
            'No verified LRs available for download.',
            style: TextStyle(fontSize: 14),
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
      return;
    }

    final isReExport = unexportedVerified.isEmpty;
    final verifiedItems = isReExport ? allVerifiedItems : unexportedVerified;
    final verifiedCount = verifiedItems.length;

    final String message;
    final String dialogTitle;
    final String confirmLabel;
    if (isReExport) {
      dialogTitle = 'Re-Export Verified LRs?';
      confirmLabel = 'Re-Export ($verifiedCount LRs)';
      message = unverifiedCount > 0
          ? 'All $verifiedCount verified LR(s) have already been exported to Excel.\n\nDo you want to re-export them again?\n\nNote: $unverifiedCount Unverified LR(s) will be excluded because mandatory (*) fields are not complete.'
          : 'All $verifiedCount verified LR(s) have already been exported to Excel.\n\nDo you want to re-export them again?';
    } else {
      dialogTitle = 'Download Excel';
      confirmLabel = 'Download ($verifiedCount LRs)';
      message = unverifiedCount > 0
          ? 'Download $verifiedCount Verified consignment note(s)?\n\nNote: $unverifiedCount Unverified LR(s) will be excluded because mandatory (*) fields are not complete.'
          : 'Are you sure you want to download $verifiedCount verified consignment note(s)?';
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              isReExport ? Icons.refresh_rounded : Icons.file_download,
              color: const Color(0xFF0284C7),
              size: 24,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                dialogTitle,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        ),
        content: Text(message, style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF059669),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.download, size: 16),
            label: Text(confirmLabel),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isExporting = true);

    try {
      final prefs = await SharedPreferences.getInstance();

      final userName =
          widget.controller.activeUserName ??
          prefs.getString('bnf_user_name') ??
          'Logistics User';

      final userMobile =
          widget.controller.activeUserMobile ??
          prefs.getString('bnf_user_mobile') ??
          '';

      final userToken =
          widget.controller.sessionToken ?? prefs.getString('bnf_user_token');

      final exportTime = DateTime.now();
      final exportIso = exportTime.toIso8601String();

      final docs = verifiedItems.map((i) {
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

      String? finalPath;
      String? defaultFilename;
      Map<String, dynamic>? backendResult;

      if (widget.controller.useGeminiBackend) {
        final result = await widget.controller.geminiService
            .exportExcelWithSnapshot(
              documents: docs,
              formatType: 'gr_bnf_49',
              userName: userName,
              userMobile: userMobile,
              sessionToken: userToken,
            );
        backendResult = result;

        if (result['success'] == true) {
          final downloadUrl = result['download_url']?.toString();

          defaultFilename =
              result['filename']?.toString() ?? ExcelService.formatLRReportFilename();

          if (downloadUrl != null && downloadUrl.isNotEmpty) {
            final bytes = await widget.controller.geminiService
                .downloadExportedFile(downloadUrl);

            if (bytes != null && bytes.isNotEmpty) {
              final file = await widget.controller.excelService.saveBytesToFile(
                bytes,
                customFileName: defaultFilename,
              );

              final publicDlPath = await widget.controller.excelService
                  .saveFileToDownloads(
                    file.path,
                    targetFileName: defaultFilename,
                  );

              finalPath = publicDlPath ?? file.path;

              widget.controller.setLastExportedPath(finalPath);
            }
          }
        }
      }

      // Fallback: If network export failed or backend not used, generate locally via ExcelService
      if (finalPath == null) {
        final filePath = await widget.controller.exportToExcel(
          schema: DocumentSchema.grBnf,
          itemsToExport: verifiedItems,
        );

        if (filePath != null) {
          defaultFilename ??= filePath.split(RegExp(r'[/\\]')).last;

          final savedPath = await widget.controller.excelService
              .saveFileToDownloads(filePath, targetFileName: defaultFilename);

          finalPath = savedPath ?? filePath;

          widget.controller.setLastExportedPath(finalPath);
        }
      }

      if (!mounted) return;

      if (finalPath != null) {
        defaultFilename ??= finalPath.split(RegExp(r'[/\\]')).last;

        await widget.controller.markItemsAsExported(
          verifiedItems.map((i) => i.id).toList(),
          exportedAt: exportTime,
        );

        final exportResult = <String, dynamic>{
          if (backendResult != null && backendResult['success'] == true)
            ...backendResult,
          'success': true,
          'filename': defaultFilename,
          'total_lrs': verifiedItems.length,
          'unverified_excluded': unverifiedCount,
          'exported_by': backendResult?['exported_by'] ?? userName,
          'user_name': backendResult?['user_name'] ?? userName,
          'user_mobile': backendResult?['user_mobile'] ?? userMobile,
          'generated_on': backendResult?['generated_on'] ?? exportIso,
          'exported_at': backendResult?['exported_at'] ?? exportIso,
          'local_path': finalPath,
        };
        exportResult['sha256'] = ExcelGeneratedScreen.deriveAuditSha256(exportResult);

        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ExcelGeneratedScreen(
              exportResult: exportResult,
              controller: widget.controller,
              exportedItems: verifiedItems,
            ),
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
        final allItems = widget.controller.items
            .where((i) => i.isVerified && i.status != BatchItemStatus.pending && i.status != BatchItemStatus.processing)
            .toList();
        final verifiedCount = allItems.length;

        final filteredItems = allItems.where((item) {

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
            final cust =
                '${_getField(item, 'Customer Name *', '')} ${_getField(item, 'cngr *', '')}'
                    .toLowerCase();

            if (!cust.contains(_customerQuery.toLowerCase())) return false;
          }

          // 3. Vehicle No Filter

          if (_vehicleQuery.isNotEmpty) {
            final veh = _getField(
              item,
              'Vehicle No *',
              '',
            ).replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();

            final vq = _vehicleQuery
                .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
                .toLowerCase();

            if (!veh.contains(vq)) return false;
          }

          // 4. Date Range Filter (Using actual LR Date only; never item.createdAt)
          final isDateRangeInvalid =
              _dateFrom != null && _dateTo != null && _dateFrom!.isAfter(_dateTo!);

          if ((_dateFrom != null || _dateTo != null) && !isDateRangeInvalid) {
            final rawDateStr = _getField(item, 'grdt *', '').isNotEmpty
                ? _getField(item, 'grdt *', '')
                : (_getField(item, 'grdt', '').isNotEmpty
                    ? _getField(item, 'grdt', '')
                    : (_getField(item, 'stockdt ', '').isNotEmpty
                        ? _getField(item, 'stockdt ', '')
                        : (_getField(item, 'stockdt', '').isNotEmpty
                            ? _getField(item, 'stockdt', '')
                            : _getField(item, 'date', ''))));

            final lrDate = _parseRecordDate(rawDateStr);
            if (lrDate == null) return false;

            final normLr = DateTime(lrDate.year, lrDate.month, lrDate.day);

            if (_dateFrom != null) {
              final normFrom =
                  DateTime(_dateFrom!.year, _dateFrom!.month, _dateFrom!.day);
              if (normLr.isBefore(normFrom)) return false;
            }

            if (_dateTo != null) {
              final normTo =
                  DateTime(_dateTo!.year, _dateTo!.month, _dateTo!.day);
              if (normLr.isAfter(normTo)) return false;
            }
          }

          return true;
        }).toList();

        final hasActiveFilters =
            _searchQuery.isNotEmpty ||
            _customerQuery.isNotEmpty ||
            _vehicleQuery.isNotEmpty ||
            _dateFrom != null ||
            _dateTo != null;

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),

          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 1,
            titleSpacing: 14,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Color(0xFF0F172A)),
              tooltip: 'Back to Upload LR',
              onPressed: () {
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                } else {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => HomeScreen(controller: widget.controller),
                    ),
                  );
                }
              },
            ),
            title: const Text(
              'LR List (For Excel Export)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            actions: const [],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(44),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    // Add More LR (Web Parity) placed directly below page title
                    InkWell(
                      key: const Key('batch_queue_add_more_lr_btn'),
                      onTap: _navigateToAddMoreLR,
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: brandBlue,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, size: 14, color: Colors.white),
                            SizedBox(width: 4),
                            Text(
                              'Add More LR',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    // Excel Preview Button placed directly below page title
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        minimumSize: const Size(0, 30),
                        side: const BorderSide(color: Color(0xFFFDE68A)),
                        backgroundColor: const Color(0xFFFEF3C7),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      icon: const Icon(
                        Icons.table_view_outlined,
                        color: Color(0xFFD97706),
                        size: 15,
                      ),
                      label: const Text(
                        'Excel Preview',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFB45309),
                        ),
                      ),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ExcelPreviewScreen(
                              controller: widget.controller,
                              initialTab: 0,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 6),
                    // History Button placed directly below page title
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        minimumSize: const Size(0, 30),
                        side: const BorderSide(color: Color(0xFFBAE6FD)),
                        backgroundColor: const Color(0xFFF0F9FF),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      icon: const Icon(
                        Icons.history,
                        color: brandBlue,
                        size: 15,
                      ),
                      label: const Text(
                        'History',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: brandBlue,
                        ),
                      ),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ExcelPreviewScreen(
                              controller: widget.controller,
                              initialTab: 1,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          body: Column(
            children: [
              // Web-Matching Multi-Filter Bar

              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),

                color: Colors.white,

                child: Column(
                  children: [
                    // Row 1: Text Search with Clear (x) and Filter Toggle Button

                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchController,

                            onChanged: (val) =>
                                setState(() => _searchQuery = val.trim()),

                            style: const TextStyle(fontSize: 12),

                            decoration: InputDecoration(
                              hintText: 'Search LR, Route, City, Goods...',

                              prefixIcon: const Icon(
                                Icons.search,
                                size: 16,
                                color: Colors.blueGrey,
                              ),

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

                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),

                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(width: 8),

                        IconButton(
                          icon: Icon(
                            _showFilters
                                ? Icons.filter_alt
                                : Icons.filter_alt_outlined,

                            color: hasActiveFilters
                                ? brandBlue
                                : Colors.blueGrey,

                            size: 20,
                          ),

                          tooltip: 'Filters',

                          onPressed: () =>
                              setState(() => _showFilters = !_showFilters),
                        ),

                        if (hasActiveFilters)
                          TextButton.icon(
                            onPressed: _resetBatchFilters,

                            icon: const Icon(
                              Icons.refresh,
                              size: 14,
                              color: Colors.blueGrey,
                            ),

                            label: const Text(
                              'Reset',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.blueGrey,
                              ),
                            ),

                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
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

                              onChanged: (val) =>
                                  setState(() => _customerQuery = val.trim()),

                              style: const TextStyle(fontSize: 11),

                              decoration: InputDecoration(
                                hintText: 'Customer...',

                                prefixIcon: const Icon(
                                  Icons.business_outlined,
                                  size: 14,
                                  color: Colors.blueGrey,
                                ),

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

                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),

                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  borderSide: const BorderSide(
                                    color: Color(0xFFE2E8F0),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(width: 8),

                          // Vehicle No Filter
                          Expanded(
                            child: TextField(
                              controller: _vehicleController,

                              onChanged: (val) =>
                                  setState(() => _vehicleQuery = val.trim()),

                              style: const TextStyle(fontSize: 11),

                              decoration: InputDecoration(
                                hintText: 'Vehicle No...',

                                prefixIcon: const Icon(
                                  Icons.local_shipping_outlined,
                                  size: 14,
                                  color: Colors.blueGrey,
                                ),

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

                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),

                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  borderSide: const BorderSide(
                                    color: Color(0xFFE2E8F0),
                                  ),
                                ),
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
                                final last = _dateTo ?? DateTime(2035);
                                final initial = _dateFrom ??
                                    (_dateTo != null && DateTime.now().isAfter(_dateTo!)
                                        ? _dateTo!
                                        : DateTime.now());
                                final safeInitial = initial.isAfter(last)
                                    ? last
                                    : (initial.isBefore(DateTime(2020))
                                        ? DateTime(2020)
                                        : initial);
                                final d = await showDatePicker(
                                  context: context,

                                  initialDate: safeInitial,

                                  firstDate: DateTime(2020),

                                  lastDate: last,
                                );

                                if (d != null) setState(() => _dateFrom = d);
                              },

                              icon: const Icon(Icons.calendar_today, size: 12),

                              label: Text(
                                _dateFrom != null
                                    ? '${_dateFrom!.day}/${_dateFrom!.month}/${_dateFrom!.year}'
                                    : 'From Date',

                                style: const TextStyle(fontSize: 10.5),
                              ),

                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 8,
                                ),

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
                                final first = _dateFrom ?? DateTime(2020);
                                final initial = _dateTo ??
                                    (_dateFrom != null && DateTime.now().isBefore(_dateFrom!)
                                        ? _dateFrom!
                                        : DateTime.now());
                                final safeInitial = initial.isBefore(first)
                                    ? first
                                    : (initial.isAfter(DateTime(2035))
                                        ? DateTime(2035)
                                        : initial);
                                final d = await showDatePicker(
                                  context: context,

                                  initialDate: safeInitial,

                                  firstDate: first,

                                  lastDate: DateTime(2035),
                                );

                                if (d != null) setState(() => _dateTo = d);
                              },

                              icon: const Icon(Icons.calendar_today, size: 12),

                              label: Text(
                                _dateTo != null
                                    ? '${_dateTo!.day}/${_dateTo!.month}/${_dateTo!.year}'
                                    : 'To Date',

                                style: const TextStyle(fontSize: 10.5),
                              ),

                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 8,
                                ),

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

                      // Date Range Validation Message Banner
                      if (_dateFrom != null &&
                          _dateTo != null &&
                          _dateFrom!.isAfter(_dateTo!)) ...[
                        const SizedBox(height: 8),
                        Container(
                          key: const Key('dateRangeValidationBanner'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF2F2),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFFFECACA)),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 14,
                                color: Color(0xFFDC2626),
                              ),
                              SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Invalid date range: From Date cannot be later than To Date.',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFFDC2626),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),

              // Filter Stats Badge Matching Web (Total: N LRs or Showing X of N LRs)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),

                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,

                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),

                      decoration: BoxDecoration(
                        color: hasActiveFilters
                            ? const Color(0xFFF0F9FF)
                            : const Color(0xFFF1F5F9),

                        borderRadius: BorderRadius.circular(6),

                        border: Border.all(
                          color: hasActiveFilters
                              ? const Color(0xFFBAE6FD)
                              : const Color(0xFFE2E8F0),
                        ),
                      ),

                      child: Text(
                        hasActiveFilters
                            ? 'Showing ${filteredItems.length} of ${allItems.length} Verified LRs'
                            : 'Total: ${allItems.length} Verified ${allItems.length == 1 ? 'LR' : 'LRs'}',

                        style: TextStyle(
                          fontSize: 11,

                          fontWeight: FontWeight.bold,

                          color: hasActiveFilters
                              ? const Color(0xFF0369A1)
                              : const Color(0xFF475569),
                        ),
                      ),
                    ),

                    Text(
                      '${allItems.length} Verified',

                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF16A34A),
                      ),
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
                            const Icon(
                              Icons.layers_clear_outlined,
                              size: 54,
                              color: Colors.grey,
                            ),

                            const SizedBox(height: 12),

                            Text(
                              _searchQuery.isNotEmpty
                                  ? 'No LRs match "$_searchQuery"'
                                  : 'Empty LR',

                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.blueGrey,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),

                        itemCount: filteredItems.length,

                        itemBuilder: (context, idx) {
                          final item = filteredItems[idx];

                          final lrNo = _getField(
                            item,
                            'LR No *',
                            _getField(item, 'grno', item.fileName),
                          );

                          final vehNo = _getField(item, 'Vehicle No *', '—');

                          final cust = _getField(item, 'Customer Name *', '—');

                          final route =
                              '${_getField(item, 'orgrefcode', '—')} -> ${_getField(item, 'destrefcode', '—')}';

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
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,

                                    children: [
                                      Expanded(
                                        child: Row(
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 2,
                                                  ),

                                              decoration: BoxDecoration(
                                                color: Colors.blue.shade50,

                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),

                                              child: Text(
                                                '#${idx + 1}',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.blue.shade800,
                                                ),
                                              ),
                                            ),

                                            const SizedBox(width: 8),

                                            Flexible(
                                              child: Text(
                                                lrNo,

                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                  color: Color(0xFF0F172A),
                                                ),

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
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 2,
                                                  ),

                                              decoration: BoxDecoration(
                                                color: const Color(0xFFFEF3C7),

                                                borderRadius:
                                                    BorderRadius.circular(6),

                                                border: Border.all(
                                                  color: const Color(
                                                    0xFFF59E0B,
                                                  ),
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

                                                      fontWeight:
                                                          FontWeight.bold,

                                                      color: Color(0xFFB45309),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),

                                            const SizedBox(width: 6),
                                          ],

                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),

                                            decoration: BoxDecoration(
                                              color: item.isVerified
                                                  ? const Color(0xFFDCFCE7)
                                                  : const Color(0xFFFEE2E2),

                                              borderRadius:
                                                  BorderRadius.circular(10),

                                              border: Border.all(
                                                color: item.isVerified
                                                    ? const Color(0xFF86EFAC)
                                                    : const Color(0xFFFCA5A5),
                                              ),
                                            ),

                                            child: Text(
                                              item.isVerified
                                                  ? 'Verified'
                                                  : 'Unverified',

                                              style: TextStyle(
                                                fontSize: 10,

                                                fontWeight: FontWeight.bold,

                                                color: item.isVerified
                                                    ? const Color(0xFF16A34A)
                                                    : const Color(0xFFDC2626),
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

                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF475569),
                                    ),

                                    maxLines: 1,

                                    overflow: TextOverflow.ellipsis,
                                  ),

                                  Text(
                                    'Route: $route',

                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey,
                                    ),

                                    maxLines: 1,

                                    overflow: TextOverflow.ellipsis,
                                  ),

                                  const SizedBox(height: 4),

                                  Row(
                                    children: [
                                      Text(
                                        'Created: ${item.createdAt.day.toString().padLeft(2, '0')}/${item.createdAt.month.toString().padLeft(2, '0')} ${item.createdAt.hour.toString().padLeft(2, '0')}:${item.createdAt.minute.toString().padLeft(2, '0')}',

                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey.shade600,
                                          fontFamily: 'monospace',
                                        ),
                                      ),

                                      const SizedBox(width: 8),

                                      Text(
                                        '•',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey.shade400,
                                        ),
                                      ),

                                      const SizedBox(width: 8),

                                      Text(
                                        item.editedAt != null
                                            ? 'Edited: ${item.editedAt!.hour.toString().padLeft(2, '0')}:${item.editedAt!.minute.toString().padLeft(2, '0')}'
                                            : '',

                                        style: TextStyle(
                                          fontSize: 10,

                                          color: item.editedAt != null
                                              ? Colors.amber.shade900
                                              : Colors.grey.shade500,

                                          fontWeight: item.editedAt != null
                                              ? FontWeight.bold
                                              : FontWeight.normal,
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
                                              builder: (_) => EditBiltyScreen(
                                                item: item,
                                                controller: widget.controller,
                                              ),
                                            ),
                                          );
                                        },

                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          size: 15,
                                        ),

                                        label: const Text(
                                          'Edit',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),

                                        style: TextButton.styleFrom(
                                          foregroundColor: brandBlue,

                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ),

                                      const SizedBox(width: 8),

                                      IconButton(
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          size: 16,
                                          color: Colors.red,
                                        ),

                                        tooltip: 'Delete',

                                        visualDensity: VisualDensity.compact,

                                        onPressed: () {
                                          showDialog<void>(
                                            context: context,

                                            builder: (ctx) => AlertDialog(
                                              title: const Text(
                                                'Remove Consignment?',
                                              ),

                                              content: Text(
                                                'Remove consignment "${_getField(item, 'LR No *', item.fileName)}" from this batch?',
                                              ),

                                              actions: [
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.of(ctx).pop(),
                                                  child: const Text('Cancel'),
                                                ),

                                                FilledButton(
                                                  style: FilledButton.styleFrom(
                                                    backgroundColor: Colors.red,
                                                  ),

                                                  onPressed: () async {
                                                    final messenger =
                                                        ScaffoldMessenger.of(context);
                                                    Navigator.of(ctx).pop();
                                                    final ok = await widget.controller
                                                        .deleteItemWithCloudSync(item.id);
                                                    if (!ok && mounted) {
                                                      messenger.showSnackBar(
                                                        const SnackBar(
                                                          content: Text(
                                                            'Failed to delete LR from server. Local queue preserved.',
                                                          ),
                                                          backgroundColor: Colors.red,
                                                        ),
                                                      );
                                                    }
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

                                    content: const Text(
                                      'This will remove all consignment notes from the current batch queue.',
                                    ),

                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(),
                                        child: const Text('Cancel'),
                                      ),

                                      FilledButton(
                                        style: FilledButton.styleFrom(
                                          backgroundColor: Colors.red,
                                        ),

                                        onPressed: () async {
                                          final messenger =
                                              ScaffoldMessenger.of(context);
                                          Navigator.of(ctx).pop();
                                          final ok = await widget.controller
                                              .clearAllWithCloudSync();
                                          if (!ok && mounted) {
                                            messenger.showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  'Failed to clear queue on server. Local LRs preserved.',
                                                ),
                                                backgroundColor: Colors.red,
                                              ),
                                            );
                                          }
                                        },

                                        child: const Text('Clear All'),
                                      ),
                                    ],
                                  ),
                                );
                              },

                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,

                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),

                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),

                        child: const Text('Clear All'),
                      ),

                      const SizedBox(width: 8),

                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('direct_download_excel_btn'),

                          onPressed: _isExporting
                              ? null
                              : _handleDirectDownloadExcel,

                          icon: _isExporting
                              ? const SizedBox(
                                  width: 14,

                                  height: 14,

                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.download, size: 16),

                          label: Text(
                            _isExporting
                                ? 'Exporting...'
                                : 'Download Excel ($verifiedCount LRs)',

                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),

                            overflow: TextOverflow.ellipsis,
                          ),

                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(
                              0xFF059669,
                            ), // Emerald Green matching Web

                            foregroundColor: Colors.white,

                            padding: const EdgeInsets.symmetric(
                              vertical: 14,
                              horizontal: 8,
                            ),

                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          bottomNavigationBar: StepIndicatorBar(
            currentStep: 3,
            controller: widget.controller,
          ),
        );
      },
    );
  }
}
