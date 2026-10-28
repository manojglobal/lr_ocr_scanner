import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Screen allowing users to continuously photograph and review multiple pages of a single LR document.
/// Users can review, reorder, delete, and add pages before submitting them together as one unified LR.
class MultiPageScanScreen extends StatefulWidget {
  final List<String> initialPages;
  final ImagePicker? imagePicker;

  const MultiPageScanScreen({
    super.key,
    required this.initialPages,
    this.imagePicker,
  });

  @override
  State<MultiPageScanScreen> createState() => _MultiPageScanScreenState();
}

class _MultiPageScanScreenState extends State<MultiPageScanScreen> {
  static const Color brandBlue = Color(0xFF0284C7);
  static const Color brandEmerald = Color(0xFF10B981);

  late final ImagePicker _picker;
  late final List<String> _pages;
  int _selectedIndex = 0;
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    _picker = widget.imagePicker ?? ImagePicker();
    _pages = List<String>.from(widget.initialPages);
    if (_pages.isEmpty) {
      _selectedIndex = 0;
    } else {
      _selectedIndex = _pages.length - 1;
    }
  }

  Future<void> _captureNextPage() async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);

    try {
      final photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 92,
      );

      if (photo != null && mounted) {
        setState(() {
          _pages.add(photo.path);
          _selectedIndex = _pages.length - 1;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to capture photo: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
      }
    }
  }

  void _movePage(int fromIndex, int toIndex) {
    if (toIndex < 0 || toIndex >= _pages.length || fromIndex == toIndex) return;
    setState(() {
      final page = _pages.removeAt(fromIndex);
      _pages.insert(toIndex, page);
      _selectedIndex = toIndex;
    });
  }

  void _deleteCurrentPage() {
    if (_pages.isEmpty) return;
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Page?'),
        content: Text('Remove Page ${_selectedIndex + 1} from this scan session?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true && mounted) {
        setState(() {
          _pages.removeAt(_selectedIndex);
          if (_selectedIndex >= _pages.length) {
            _selectedIndex = _pages.isNotEmpty ? _pages.length - 1 : 0;
          }
        });
        if (_pages.isEmpty) {
          Navigator.of(context).pop(<String>[]);
        }
      }
    });
  }

  Future<bool> _onWillPop() async {
    if (_pages.isEmpty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard Scan Session?'),
        content: const Text('Are you sure you want to discard the captured pages?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Continue Scanning'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  void _submitAllPages() {
    if (_pages.isEmpty) return;
    Navigator.of(context).pop(_pages);
  }

  @override
  Widget build(BuildContext context) {
    final pageCount = _pages.length;
    final hasPages = pageCount > 0;

    return PopScope(
      canPop: !hasPages,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 1,
          iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Multi-Page LR Scan',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0F172A),
                ),
              ),
              Text(
                hasPages ? '$pageCount ${pageCount == 1 ? 'Page' : 'Pages'} Captured' : 'No Pages',
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ],
          ),
          actions: [
            if (hasPages)
              TextButton.icon(
                key: const Key('multi_page_clear_btn'),
                onPressed: () async {
                  final pop = await _onWillPop();
                  if (pop && mounted) Navigator.of(context).pop();
                },
                icon: const Icon(Icons.close, size: 18, color: Color(0xFF64748B)),
                label: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B))),
              ),
          ],
        ),
        body: !hasPages
            ? _buildEmptyState()
            : SafeArea(
                child: Column(
                  children: [
                    // Unified Guidance Banner
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFBBF7D0)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, size: 18, color: brandEmerald),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'All captured pages will be combined into a single LR document with one LR number.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF166534),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Main Viewer & Preview
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: _buildMainPreview(),
                      ),
                    ),

                    // Page Reorder & Delete Strip
                    _buildPageControlsRow(),

                    // Thumbnail Strip
                    _buildThumbnailStrip(),

                    // Bottom Action Bar
                    _buildBottomBar(),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.document_scanner_outlined, size: 64, color: Color(0xFF94A3B8)),
          const SizedBox(height: 12),
          const Text(
            'No photos captured yet',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            key: const Key('empty_capture_btn'),
            style: ElevatedButton.styleFrom(
              backgroundColor: brandBlue,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _captureNextPage,
            icon: const Icon(Icons.camera_alt, color: Colors.white),
            label: const Text('Take First Photo', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildMainPreview() {
    final pagePath = _pages[_selectedIndex];
    final file = File(pagePath);

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            offset: Offset(0, 4),
            blurRadius: 12,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          file.existsSync()
              ? Image.file(
                  file,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Center(
                    child: Icon(Icons.broken_image, size: 48, color: Colors.white54),
                  ),
                )
              : const Center(
                  child: Icon(Icons.broken_image, size: 48, color: Colors.white54),
                ),

          // Page Badge Overlay (Top Left)
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white24),
              ),
              child: Text(
                'Page ${_selectedIndex + 1} of ${_pages.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),

          // Previous Page Overlay (Left Arrow)
          if (_selectedIndex > 0)
            Positioned(
              left: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton(
                  key: const Key('prev_preview_page_btn'),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black45,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.chevron_left, size: 28),
                  onPressed: () => setState(() => _selectedIndex--),
                ),
              ),
            ),

          // Next Page Overlay (Right Arrow)
          if (_selectedIndex < _pages.length - 1)
            Positioned(
              right: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton(
                  key: const Key('next_preview_page_btn'),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black45,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.chevron_right, size: 28),
                  onPressed: () => setState(() => _selectedIndex++),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPageControlsRow() {
    final canMoveLeft = _selectedIndex > 0;
    final canMoveRight = _selectedIndex < _pages.length - 1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              OutlinedButton.icon(
                key: const Key('move_page_left_btn'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: canMoveLeft ? () => _movePage(_selectedIndex, _selectedIndex - 1) : null,
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('Move Left', style: TextStyle(fontSize: 11)),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const Key('move_page_right_btn'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: canMoveRight ? () => _movePage(_selectedIndex, _selectedIndex + 1) : null,
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text('Move Right', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          TextButton.icon(
            key: const Key('delete_page_btn'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
            onPressed: _deleteCurrentPage,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Delete Page', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnailStrip() {
    return Container(
      height: 72,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: _pages.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final isSelected = index == _selectedIndex;
          final file = File(_pages[index]);

          return GestureDetector(
            key: Key('thumb_page_$index'),
            onTap: () => setState(() => _selectedIndex = index),
            child: Container(
              width: 54,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected ? brandBlue : const Color(0xFFCBD5E1),
                  width: isSelected ? 2.5 : 1.0,
                ),
                color: Colors.white,
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  file.existsSync()
                      ? Image.file(file, fit: BoxFit.cover)
                      : Container(color: const Color(0xFFE2E8F0)),
                  Positioned(
                    top: 2,
                    left: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: isSelected ? brandBlue : Colors.black87,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBottomBar() {
    final pageCount = _pages.length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Row(
        children: [
          // Add Another Page Button
          Expanded(
            flex: 2,
            child: OutlinedButton.icon(
              key: const Key('add_another_page_btn'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                side: const BorderSide(color: brandBlue),
                foregroundColor: brandBlue,
              ),
              onPressed: _isCapturing ? null : _captureNextPage,
              icon: _isCapturing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_a_photo_outlined, size: 20),
              label: const Text(
                '+ Add Page',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Upload / Scan All Pages Button
          Expanded(
            flex: 3,
            child: ElevatedButton.icon(
              key: const Key('upload_all_pages_btn'),
              style: ElevatedButton.styleFrom(
                backgroundColor: brandBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 2,
              ),
              onPressed: pageCount > 0 ? _submitAllPages : null,
              icon: const Icon(Icons.document_scanner, size: 20),
              label: Text(
                'Scan $pageCount ${pageCount == 1 ? 'Page' : 'Pages'} as 1 LR',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
