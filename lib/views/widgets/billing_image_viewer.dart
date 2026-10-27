import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
// In-app viewing only matching Web (no external apps)
import 'package:path_provider/path_provider.dart';
import '../../config/document_schema.dart';
import '../../models/batch_item.dart';
import '../../state/batch_controller.dart';
import '../screens/batch_queue_screen.dart';
import '../screens/edit_bilty_screen.dart';
import '../screens/excel_preview_screen.dart';
import '../screens/lr_preview_screen.dart';
import 'step_indicator_bar.dart';

/// Screen 6: Multi-Image Billing Document Viewer with pinch-to-zoom,
/// 90° rotation, thumbnail gallery strip, and 50-column Excel format overlay toggle.
class BillingImageViewer extends StatefulWidget {
  final List<BatchItem> items;
  final int initialIndex;
  final BatchProcessingController? controller;

  const BillingImageViewer({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.controller,
  });

  static Future<void> show(
    BuildContext context, {
    required List<BatchItem> items,
    int initialIndex = 0,
    BatchProcessingController? controller,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => BillingImageViewer(
          items: items,
          initialIndex: initialIndex,
          controller: controller,
        ),
      ),
    );
  }

  /// In-memory cache for decoded base64 preview bytes (prevents UI thread jank & decodes at most once)
  static final Map<String, Uint8List> _base64Cache = <String, Uint8List>{};

  /// Resolves decoded base64 bytes for a BatchItem or raw string, caching results in memory
  static Uint8List? resolveBase64Bytes(dynamic itemOrPath) {
    if (itemOrPath == null) return null;
    if (itemOrPath is String) {
      final rawPath = itemOrPath.trim();
      if (rawPath.startsWith('data:image/') && rawPath.contains('base64,')) {
        final cacheKey = 'str_${rawPath.length}_${rawPath.substring(0, rawPath.length > 30 ? 30 : rawPath.length)}';
        if (_base64Cache.containsKey(cacheKey)) return _base64Cache[cacheKey];
        try {
          final b64 = rawPath.split('base64,').last;
          final bytes = base64Decode(b64);
          _base64Cache[cacheKey] = bytes;
          return bytes;
        } catch (_) {}
      }
      return null;
    }
    if (itemOrPath is BatchItem) {
      if (_base64Cache.containsKey(itemOrPath.id)) {
        return _base64Cache[itemOrPath.id];
      }

      // 1. Check raw imagePath for data URL
      final rawPath = itemOrPath.imagePath.trim();
      if (rawPath.startsWith('data:image/') && rawPath.contains('base64,')) {
        try {
          final b64 = rawPath.split('base64,').last;
          final bytes = base64Decode(b64);
          _base64Cache[itemOrPath.id] = bytes;
          return bytes;
        } catch (_) {}
      }

      // 2. Check record attributes for preview_image or imageSrc
      String preview = (itemOrPath.record['preview_image'] ?? '').toString().trim();
      if (preview.isNotEmpty) {
        if (preview.contains('base64,')) {
          preview = preview.split('base64,').last.trim();
        }
        try {
          final bytes = base64Decode(preview);
          _base64Cache[itemOrPath.id] = bytes;
          return bytes;
        } catch (_) {}
      }

      final imgSrc = itemOrPath.record['imageSrc'] ?? '';
      if (imgSrc.startsWith('data:image/') && imgSrc.contains('base64,')) {
        try {
          final b64 = imgSrc.split('base64,').last;
          final bytes = base64Decode(b64);
          _base64Cache[itemOrPath.id] = bytes;
          return bytes;
        } catch (_) {}
      }
    }
    return null;
  }

  /// Extracts PDF preview pages from a BatchItem's metadata
  static List<String> getPdfPreviewPagesStatic(BatchItem item) {
    final rawPages = item.record['preview_pages'];
    if (rawPages != null && rawPages.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPages);
        if (decoded is List) {
          final list = decoded.map((e) => e.toString()).toList();
          if (list.isNotEmpty) return list;
        }
      } catch (_) {}
    }
    final purl = item.record['preview_url'];
    if (purl != null && purl.isNotEmpty) {
      return [purl];
    }
    return [];
  }

  /// Resolves relative preview URLs against the server URL
  static String? resolveFullUrlStatic(String? path, String? serverUrl) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final server = (serverUrl != null && serverUrl.trim().isNotEmpty) ? serverUrl.trim() : 'http://192.168.1.2:8000';
    final prefix = server.endsWith('/') ? server.substring(0, server.length - 1) : server;
    final relPath = path.startsWith('/') ? path : '/$path';
    return '$prefix$relPath';
  }

  /// Pre-warms base64 decoding and precaches rendered PDF pages before opening viewer
  static void prewarm(BatchItem item, [BuildContext? context, String? serverUrl]) {
    resolveBase64Bytes(item);
    if (context != null) {
      final pages = getPdfPreviewPagesStatic(item);
      for (final p in pages) {
        final full = resolveFullUrlStatic(p, serverUrl);
        if (full != null) {
          try {
            precacheImage(NetworkImage(full), context);
          } catch (_) {}
        }
      }
      final purl = (item.record['preview_url'] ?? '').toString().trim();
      if (purl.isNotEmpty) {
        final full = resolveFullUrlStatic(purl, serverUrl);
        if (full != null) {
          try {
            precacheImage(NetworkImage(full), context);
          } catch (_) {}
        }
      }
    }
  }

  @override
  State<BillingImageViewer> createState() => _BillingImageViewerState();
}

class _BillingImageViewerState extends State<BillingImageViewer> {
  late int _currentIndex;
  late final PageController _pageController;
  final Map<int, int> _rotations = {}; // itemIndex -> rotation turns (0, 1, 2, 3)
  final Map<int, int> _pdfCurrentPages = {}; // itemIndex -> pageIndex (0, 1, 2...)
  final TransformationController _transformController = TransformationController();
  final Map<int, File?> _discoveredFiles = {};
  bool _showExcelFormat = false;

  final List<String> _bnf49Columns = DocumentSchema.grBnf.fields.map((f) => f.key).toList();

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, (widget.items.length - 1).clamp(0, 9999));
    _pageController = PageController(initialPage: _currentIndex);
    _resolveAllItemFiles();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadImages();
    });
  }

  void _preloadImages() {
    if (!mounted) return;
    // 1. Prioritize and precache the current document first
    if (widget.items.isNotEmpty && _currentIndex < widget.items.length) {
      final current = widget.items[_currentIndex];
      BillingImageViewer.resolveBase64Bytes(current);
      final currentPages = _getPdfPreviewPages(current);
      for (final p in currentPages) {
        final full = _resolveFullUrl(p);
        if (full != null) {
          try {
            precacheImage(NetworkImage(full), context);
          } catch (_) {}
        }
      }
      final curUrl = _resolvePreviewUrl(current);
      if (curUrl != null) {
        try {
          precacheImage(NetworkImage(curUrl), context);
        } catch (_) {}
      }
    }

    // 2. Precache remaining documents in background
    for (int i = 0; i < widget.items.length; i++) {
      if (i == _currentIndex) continue;
      final it = widget.items[i];
      BillingImageViewer.resolveBase64Bytes(it);
      final pages = _getPdfPreviewPages(it);
      for (final p in pages) {
        final full = _resolveFullUrl(p);
        if (full != null) {
          try {
            precacheImage(NetworkImage(full), context);
          } catch (_) {}
        }
      }
      final purl = _resolvePreviewUrl(it);
      if (purl != null) {
        try {
          precacheImage(NetworkImage(purl), context);
        } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _transformController.dispose();
    super.dispose();
  }

  Future<void> _resolveAllItemFiles() async {
    Directory? docsDir;
    Directory? tempDir;
    Directory? supportDir;
    try {
      docsDir = await getApplicationDocumentsDirectory();
    } catch (_) {}
    try {
      tempDir = await getTemporaryDirectory();
    } catch (_) {}
    try {
      supportDir = await getApplicationSupportDirectory();
    } catch (_) {}

    final searchDirs = <Directory>[
      ?docsDir,
      ?tempDir,
      ?supportDir,
    ];

    for (int i = 0; i < widget.items.length; i++) {
      final item = widget.items[i];
      File? found = _resolveLocalFile(item.imagePath, item.fileName);
      if (found == null) {
        for (final dir in searchDirs) {
          final target1 = File('${dir.path}/lr_documents/${item.fileName}');
          if (await target1.exists()) {
            found = target1;
            break;
          }
          final target2 = File('${dir.path}/snapshots/${item.fileName}');
          if (await target2.exists()) {
            found = target2;
            break;
          }
          final target3 = File('${dir.path}/${item.fileName}');
          if (await target3.exists()) {
            found = target3;
            break;
          }
        }
      }

      // 4. If item is PDF and has base64 data, persist to tempDir for external viewer
      if (found == null && tempDir != null && (item.fileName.toLowerCase().endsWith('.pdf') || item.imagePath.startsWith('data:application/pdf'))) {
        final b64 = _extractBase64String(item.imagePath) ?? _extractBase64String(item.record['pdf_base64'] ?? '');
        if (b64 != null) {
          try {
            final bytes = base64Decode(b64);
            final target = File('${tempDir.path}/${item.fileName}');
            await target.writeAsBytes(bytes);
            found = target;
          } catch (_) {}
        }
      }

      if (found != null) {
        _discoveredFiles[i] = found;
      }
    }
    if (mounted) setState(() {});
  }

  String? _extractBase64String(String str) {
    if (str.isEmpty) return null;
    if (str.contains('base64,')) {
      return str.split('base64,').last.trim();
    }
    return null;
  }

  File? _resolveLocalFile(String rawPath, String fileName) {
    if (rawPath.isEmpty && fileName.isEmpty) return null;
    String clean = rawPath.trim();
    if (clean.startsWith('file://')) {
      try {
        clean = Uri.parse(clean).toFilePath();
      } catch (_) {
        clean = clean.substring(7);
      }
    }
    if (clean.isNotEmpty) {
      final f = File(clean);
      if (f.existsSync()) return f;
    }
    if (fileName.isNotEmpty) {
      final fName = File(fileName);
      if (fName.existsSync()) return fName;
    }
    return null;
  }

  List<String> _getPdfPreviewPages(BatchItem item) => BillingImageViewer.getPdfPreviewPagesStatic(item);

  String? _resolveFullUrl(String? path) => BillingImageViewer.resolveFullUrlStatic(path, widget.controller?.geminiService.serverUrl);

  String? _resolvePreviewUrl(BatchItem item) {
    final purl = (item.record['preview_url'] ?? '').toString().trim();
    if (purl.isEmpty) return null;
    return _resolveFullUrl(purl);
  }

  Uint8List? _resolveBase64Bytes(dynamic itemOrPath) => BillingImageViewer.resolveBase64Bytes(itemOrPath);

  void _rotateCurrent() {
    setState(() {
      final current = _rotations[_currentIndex] ?? 0;
      _rotations[_currentIndex] = (current + 1) % 4;
      _transformController.value = Matrix4.identity();
    });
  }

  void _resetZoom() {
    setState(() {
      _transformController.value = Matrix4.identity();
    });
  }

  void _zoomBy(double factor) {
    setState(() {
      final matrix = _transformController.value.clone();
      final scaleMatrix = Matrix4.diagonal3Values(factor, factor, 1.0);
      _transformController.value = matrix * scaleMatrix;
    });
  }

  void _goToIndex(int index) {
    if (index >= 0 && index < widget.items.length) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
      setState(() {
        _currentIndex = index;
        _transformController.value = Matrix4.identity();
      });
    }
  }

  String _getFieldValue(BatchItem item, String header) {
    if (item.record.containsKey(header) && item.record[header]!.trim().isNotEmpty) {
      return item.record[header]!.trim();
    }
    final cleanHeader = header.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    for (final entry in item.record.entries) {
      final cleanKey = entry.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
      if (cleanKey == cleanHeader && entry.value.trim().isNotEmpty) {
        return entry.value.trim();
      }
    }
    if (header == 'BNF LR No') {
      return item.record['BNF LR No'] ?? item.record['bnf lr no'] ?? item.record['bnflrno'] ?? '';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    const brandNavy = Color(0xFF0F172A);
    const brandGreen = Color(0xFF16A34A);

    if (widget.items.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: const Center(
          child: Text('No billing documents available', style: TextStyle(color: Colors.white70)),
        ),
      );
    }

    final currentItem = widget.items[_currentIndex];
    final lrNo = _getFieldValue(currentItem, 'LR No *').isNotEmpty
        ? _getFieldValue(currentItem, 'LR No *')
        : (_getFieldValue(currentItem, 'grno').isNotEmpty ? _getFieldValue(currentItem, 'grno') : currentItem.fileName);
    final vehNo = _getFieldValue(currentItem, 'Vehicle No *').isNotEmpty
        ? _getFieldValue(currentItem, 'Vehicle No *')
        : '—';

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              color: Colors.black.withAlpha(220),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 22),
                    tooltip: 'Close Viewer',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Flexible(
                              child: Text(
                                'View LR Image',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0284C7),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${_currentIndex + 1} of ${widget.items.length}',
                                style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          'LR: $lrNo • Veh: $vehNo • ${currentItem.fileName}',
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),

                  // Zoom In / Out Buttons
                  IconButton(
                    icon: const Icon(Icons.zoom_in, color: Colors.white, size: 20),
                    tooltip: 'Zoom In',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _zoomBy(1.2),
                  ),
                  IconButton(
                    icon: const Icon(Icons.zoom_out, color: Colors.white, size: 20),
                    tooltip: 'Zoom Out',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _zoomBy(0.8),
                  ),
                  // Rotate Button
                  IconButton(
                    icon: const Icon(Icons.rotate_right, color: Colors.white, size: 20),
                    tooltip: 'Rotate 90°',
                    visualDensity: VisualDensity.compact,
                    onPressed: _rotateCurrent,
                  ),
                  // Reset Zoom Button
                  IconButton(
                    icon: const Icon(Icons.restart_alt, color: Colors.white, size: 20),
                    tooltip: 'Reset View',
                    visualDensity: VisualDensity.compact,
                    onPressed: _resetZoom,
                  ),


                ],
              ),
            ),

            // Main Interactive Viewport: Image or 50-Column Excel Format Table
            Expanded(
              child: Stack(
                children: [
                  if (!_showExcelFormat)
                    PageView.builder(
                      controller: _pageController,
                      itemCount: widget.items.length,
                      onPageChanged: (idx) {
                        setState(() {
                          _currentIndex = idx;
                          _transformController.value = Matrix4.identity();
                        });
                      },
                      itemBuilder: (context, index) {
                        final item = widget.items[index];
                        final rot = _rotations[index] ?? 0;
                        final isPdf = item.imagePath.toLowerCase().endsWith('.pdf') || item.fileName.toLowerCase().endsWith('.pdf');
                        final resolvedFile = _resolveLocalFile(item.imagePath, item.fileName) ?? _discoveredFiles[index];
                        final base64Bytes = _resolveBase64Bytes(item);
                        final pdfPages = _getPdfPreviewPages(item);
                        final curPdfPage = (_pdfCurrentPages[index] ?? 0).clamp(0, (pdfPages.length - 1).clamp(0, 999));
                        final currentPdfPageUrl = pdfPages.isNotEmpty ? _resolveFullUrl(pdfPages[curPdfPage]) : _resolvePreviewUrl(item);

                        Widget contentWidget;
                        if (isPdf) {
                          // Page 0: Render instant 0ms memory preview from base64 if available
                          if (curPdfPage == 0 && base64Bytes != null) {
                            contentWidget = Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Image.memory(
                                    base64Bytes,
                                    fit: BoxFit.contain,
                                    gaplessPlayback: true,
                                  ),
                                ),
                                if (pdfPages.length > 1) ...[
                                  const SizedBox(height: 8),
                                  _buildPdfPageNav(index, curPdfPage, pdfPages.length),
                                ],
                              ],
                            );
                          } else if (currentPdfPageUrl != null) {
                            contentWidget = Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Image.network(
                                    currentPdfPageUrl,
                                    fit: BoxFit.contain,
                                    gaplessPlayback: true,
                                    frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                                      if (wasSynchronouslyLoaded || frame != null) return child;
                                      if (base64Bytes != null && curPdfPage == 0) {
                                        return Image.memory(base64Bytes, fit: BoxFit.contain, gaplessPlayback: true);
                                      }
                                      return const Center(
                                        child: SizedBox(
                                          width: 28,
                                          height: 28,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                                        ),
                                      );
                                    },
                                    errorBuilder: (context, error, stackTrace) =>
                                        (base64Bytes != null && curPdfPage == 0)
                                            ? Image.memory(base64Bytes, fit: BoxFit.contain, gaplessPlayback: true)
                                            : _buildPdfCard(item, resolvedFile, index),
                                  ),
                                ),
                                if (pdfPages.length > 1) ...[
                                  const SizedBox(height: 8),
                                  _buildPdfPageNav(index, curPdfPage, pdfPages.length),
                                ],
                              ],
                            );
                          } else if (base64Bytes != null) {
                            contentWidget = Image.memory(
                              base64Bytes,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                              errorBuilder: (context, error, stackTrace) => _buildPdfCard(item, resolvedFile, index),
                            );
                          } else if (resolvedFile != null && resolvedFile.path.toLowerCase().endsWith('.pdf')) {
                            contentWidget = _buildPdfCard(item, resolvedFile, index);
                          } else {
                            contentWidget = _buildPdfCard(item, resolvedFile, index);
                          }
                        } else if (base64Bytes != null) {
                          contentWidget = Image.memory(
                            base64Bytes,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            errorBuilder: (context, error, stackTrace) => _buildPdfCard(item, resolvedFile, index),
                          );
                        } else if (isPdf && resolvedFile != null && resolvedFile.path.toLowerCase().endsWith('.pdf')) {
                          contentWidget = _buildPdfCard(item, resolvedFile, index);
                        } else if (resolvedFile != null && resolvedFile.existsSync()) {
                          contentWidget = Image.file(
                            resolvedFile,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) => const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.broken_image, color: Colors.white54, size: 48),
                                SizedBox(height: 8),
                                Text('Could not load image', style: TextStyle(color: Colors.white54)),
                              ],
                            ),
                          );
                        } else if (item.imagePath.startsWith('http://') || item.imagePath.startsWith('https://')) {
                          contentWidget = Image.network(
                            item.imagePath,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) => const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.broken_image, color: Colors.white54, size: 48),
                                SizedBox(height: 8),
                                Text('Could not load network image', style: TextStyle(color: Colors.white54)),
                              ],
                            ),
                          );
                        } else {
                          contentWidget = Container(
                            constraints: const BoxConstraints(maxWidth: 360),
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: const Color(0xFF334155)),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.image_not_supported_outlined, color: Colors.amber, size: 44),
                                SizedBox(height: 12),
                                Text(
                                  item.fileName,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  'Image file is not locally stored on this device.',
                                  style: TextStyle(color: Colors.white60, fontSize: 11),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 16),
                                if (widget.controller != null)
                                  OutlinedButton.icon(
                                    onPressed: () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => LrPreviewScreen(item: item, controller: widget.controller!),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.receipt_long, size: 14),
                                    label: const Text('View Voucher Details', style: TextStyle(fontSize: 12)),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFF38BDF8),
                                      side: const BorderSide(color: Color(0xFF38BDF8)),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        }

                        return Stack(
                          alignment: Alignment.center,
                          children: [
                            InteractiveViewer(
                              transformationController: index == _currentIndex ? _transformController : null,
                              minScale: 0.8,
                              maxScale: 4.5,
                              child: Center(
                                child: RotatedBox(
                                  quarterTurns: rot,
                                  child: contentWidget,
                                ),
                              ),
                            ),

                          ],
                        );
                      },
                    )
                  else
                    // 50-Column Excel Spreadsheet Format Viewport (Matching Web snapshotExcelGridContainer)
                    Container(
                      color: Colors.white,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFDCFCE7),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Icon(Icons.table_chart, size: 16, color: brandGreen),
                                    ),
                                    const SizedBox(width: 8),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Spreadsheet View: $lrNo',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: brandNavy),
                                        ),
                                        const Text(
                                          'All 49 BNF logistics columns captured from this document',
                                          style: TextStyle(fontSize: 10, color: Colors.grey),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFDCFCE7),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: const Color(0xFF86EFAC)),
                                  ),
                                  child: const Text(
                                    '49 BNF Columns',
                                    style: TextStyle(color: brandGreen, fontWeight: FontWeight.bold, fontSize: 10),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(12),
                              child: Table(
                                columnWidths: const {
                                  0: FixedColumnWidth(36),
                                  1: FlexColumnWidth(1.4),
                                  2: FlexColumnWidth(2.0),
                                  3: FixedColumnWidth(74),
                                },
                                border: TableBorder.all(color: Colors.grey.shade200, width: 1),
                                children: [
                                  TableRow(
                                    decoration: const BoxDecoration(color: Color(0xFF1E293B)),
                                    children: const [
                                      Padding(
                                        padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                                        child: Text('#', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11), textAlign: TextAlign.center),
                                      ),
                                      Padding(
                                        padding: EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                                        child: Text('Column Name', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                                      ),
                                      Padding(
                                        padding: EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                                        child: Text('Extracted Value', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                                      ),
                                      Padding(
                                        padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                                        child: Text('Status', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11), textAlign: TextAlign.center),
                                      ),
                                    ],
                                  ),
                                  ...List.generate(_bnf49Columns.length, (colIdx) {
                                    final colName = _bnf49Columns[colIdx];
                                    final val = _getFieldValue(currentItem, colName);
                                    final hasVal = val.isNotEmpty;

                                    return TableRow(
                                      decoration: BoxDecoration(
                                        color: colIdx % 2 == 0 ? Colors.white : const Color(0xFFF8FAFC),
                                      ),
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                                          child: Text('${colIdx + 1}', style: const TextStyle(fontSize: 10, color: Colors.grey), textAlign: TextAlign.center),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                                          child: Text(colName, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF334155))),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                                          child: Text(
                                            hasVal ? val : '—',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontFamily: 'monospace',
                                              fontWeight: hasVal ? FontWeight.w600 : FontWeight.normal,
                                              color: hasVal ? const Color(0xFF0F172A) : Colors.grey.shade400,
                                            ),
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                                          child: Center(
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                              decoration: BoxDecoration(
                                                color: hasVal ? const Color(0xFFDCFCE7) : const Color(0xFFF1F5F9),
                                                borderRadius: BorderRadius.circular(4),
                                                border: Border.all(color: hasVal ? const Color(0xFF86EFAC) : const Color(0xFFE2E8F0)),
                                              ),
                                              child: Text(
                                                hasVal ? 'Captured' : 'Blank',
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.bold,
                                                  color: hasVal ? brandGreen : Colors.grey.shade500,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    );
                                  }),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Left (Prev) Arrow
                  if (!_showExcelFormat && _currentIndex > 0)
                    Positioned(
                      left: 12,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: CircleAvatar(
                          backgroundColor: Colors.black.withAlpha(160),
                          radius: 20,
                          child: IconButton(
                            icon: const Icon(Icons.chevron_left, color: Colors.white, size: 24),
                            onPressed: () => _goToIndex(_currentIndex - 1),
                          ),
                        ),
                      ),
                    ),

                  // Right (Next) Arrow
                  if (!_showExcelFormat && _currentIndex < widget.items.length - 1)
                    Positioned(
                      right: 12,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: CircleAvatar(
                          backgroundColor: Colors.black.withAlpha(160),
                          radius: 20,
                          child: IconButton(
                            icon: const Icon(Icons.chevron_right, color: Colors.white, size: 24),
                            onPressed: () => _goToIndex(_currentIndex + 1),
                          ),
                        ),
                      ),
                    ),

                ],
              ),
            ),

            // Horizontal Thumbnail Gallery Strip (Shows ALL Uploaded Images)
            if (widget.items.length > 1)
              Container(
                height: 86,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                color: const Color(0xFF0F172A),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'All Uploaded Bilties (${widget.items.length}) - Tap to View:',
                      style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: widget.items.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, idx) {
                          final item = widget.items[idx];
                          final isSelected = idx == _currentIndex;
                          final isThumbPdf = item.imagePath.toLowerCase().endsWith('.pdf') || item.fileName.toLowerCase().endsWith('.pdf');
                          final rFile = _resolveLocalFile(item.imagePath, item.fileName) ?? _discoveredFiles[idx];
                          final b64Bytes = _resolveBase64Bytes(item);

                          final previewUrl = _resolvePreviewUrl(item);
                          Widget thumbWidget;
                          if (b64Bytes != null) {
                            thumbWidget = Image.memory(b64Bytes, fit: BoxFit.cover, gaplessPlayback: true);
                          } else if (previewUrl != null) {
                            thumbWidget = Image.network(
                              previewUrl,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) => Container(
                                color: const Color(0xFF7F1D1D),
                                child: const Center(
                                  child: Icon(Icons.picture_as_pdf, size: 22, color: Colors.white),
                                ),
                              ),
                            );
                          } else if (rFile != null && rFile.existsSync() && !isThumbPdf) {
                            thumbWidget = Image.file(rFile, fit: BoxFit.cover);
                          } else if (isThumbPdf) {
                            thumbWidget = Container(
                              color: const Color(0xFF7F1D1D),
                              child: const Center(
                                child: Icon(Icons.picture_as_pdf, size: 22, color: Colors.white),
                              ),
                            );
                          } else {
                            thumbWidget = Container(
                              color: Colors.grey.shade900,
                              child: const Icon(Icons.image, size: 18, color: Colors.white38),
                            );
                          }

                          return GestureDetector(
                            onTap: () => _goToIndex(idx),
                            child: Container(
                              width: 52,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected ? Colors.lightBlueAccent : Colors.white24,
                                  width: isSelected ? 2.5 : 1,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  thumbWidget,
                                  if (isSelected)
                                    Container(
                                      color: Colors.blue.withAlpha(40),
                                    ),
                                  Positioned(
                                    bottom: 2,
                                    left: 2,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withAlpha(180),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        '#${idx + 1}',
                                        style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),

            // Bottom Actions Bar Matching Web Screen 6 (Edit LR, Excel View Toggle, Preview Excel, Batch Queue)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0xFF1E293B),
                border: Border(top: BorderSide(color: Colors.white12)),
              ),
              child: Row(
                children: [
                  // 1. Edit LR
                  OutlinedButton.icon(
                    onPressed: () {
                      final ctrl = widget.controller;
                      if (ctrl != null) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => EditBiltyScreen(item: currentItem, controller: ctrl),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.edit_outlined, size: 14, color: Colors.white),
                    label: const Text('Edit LR', style: TextStyle(color: Colors.white, fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white30),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 6),

                  // 2. View in Excel Format Toggle
                  ElevatedButton.icon(
                    onPressed: () => setState(() => _showExcelFormat = !_showExcelFormat),
                    icon: Icon(_showExcelFormat ? Icons.image_outlined : Icons.table_chart_outlined, size: 14),
                    label: Text(
                      _showExcelFormat ? 'View Image' : 'Excel Format',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _showExcelFormat ? const Color(0xFF0284C7) : brandGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const Spacer(),

                  // 3. Preview Excel
                  if (widget.controller != null) ...[
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ExcelPreviewScreen(controller: widget.controller!),
                          ),
                        );
                      },
                      icon: const Icon(Icons.table_view, size: 14, color: Color(0xFF38BDF8)),
                      label: const Text('Excel', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold)),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      ),
                    ),
                    const SizedBox(width: 4),

                    // 4. Next (Renamed from Batch Queue)
                    FilledButton.icon(
                      onPressed: () {
                        showDialog<void>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            title: const Text('Confirmation', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            content: const Text('Are you sure you want to continue?', style: TextStyle(fontSize: 14)),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => BatchQueueScreen(controller: widget.controller!),
                                    ),
                                  );
                                },
                                child: const Text('Continue'),
                              ),
                            ],
                          ),
                        );
                      },
                      icon: const Icon(Icons.arrow_forward, size: 14),
                      label: const Text('Next', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFEA580C),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // Step Indicator Flow Bar (Step 6)
            StepIndicatorBar(
              currentStep: 6,
              controller: widget.controller,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPdfPageNav(int itemIndex, int curPdfPage, int totalPages) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, color: Colors.white, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: curPdfPage > 0
                ? () => setState(() => _pdfCurrentPages[itemIndex] = curPdfPage - 1)
                : null,
          ),
          const SizedBox(width: 8),
          Text(
            'Page ${curPdfPage + 1} of $totalPages',
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.chevron_right, color: Colors.white, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: curPdfPage < totalPages - 1
                ? () => setState(() => _pdfCurrentPages[itemIndex] = curPdfPage + 1)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildPdfCard(BatchItem item, File? resolvedFile, int index) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF334155)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.picture_as_pdf,
                  color: Color(0xFFDC2626),
                  size: 42,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                item.fileName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Text(
                (resolvedFile != null && resolvedFile.existsSync())
                    ? '${(resolvedFile.lengthSync() / (1024 * 1024)).toStringAsFixed(2)} MB • In-App PDF Preview'
                    : 'PDF Consignment Document',
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.visibility, size: 16, color: Color(0xFF38BDF8)),
                    SizedBox(width: 8),
                    Text(
                      'High-Resolution Preview Rendered',
                      style: TextStyle(color: Color(0xFFE2E8F0), fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
