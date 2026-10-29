import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

/// Fullscreen live camera screen designed for continuous multi-page LR document capture.
///
/// Features:
/// - Continuous in-camera session (does NOT exit between shots).
/// - Document framing overlay with guidance.
/// - Live page counter badge and thumbnail preview of captured pages.
/// - Add Page directly on the camera screen.
/// - In-camera thumbnail sheet to preview, reorder, or delete pages.
/// - OK / Done button to immediately finish and return ordered pages.
/// - Graceful fallback to continuous native picker if hardware camera is unavailable.
class CameraScanScreen extends StatefulWidget {
  final List<String> initialPages;
  final List<CameraDescription>? cameras;
  final ImagePicker? imagePicker;

  const CameraScanScreen({
    super.key,
    this.initialPages = const [],
    this.cameras,
    this.imagePicker,
  });

  @override
  State<CameraScanScreen> createState() => _CameraScanScreenState();
}

class _CameraScanScreenState extends State<CameraScanScreen> with WidgetsBindingObserver {
  static const Color brandBlue = Color(0xFF0284C7);
  static const Color brandGreen = Color(0xFF16A34A);

  CameraController? _controller;
  List<CameraDescription> _availableCameras = [];
  int _selectedCameraIndex = 0;
  FlashMode _currentFlashMode = FlashMode.auto;

  bool _isInitializing = true;
  bool _isCapturing = false;
  bool _isFallbackMode = false;
  bool _showShutterFlash = false;

  late final List<String> _capturedPages;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _capturedPages = List<String>.from(widget.initialPages);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      _controller = null;
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCameraController(cameraController.description);
    }
  }

  Future<void> _initCamera() async {
    try {
      if (widget.cameras != null) {
        _availableCameras = widget.cameras!;
      } else {
        _availableCameras = await availableCameras();
      }

      if (_availableCameras.isEmpty) {
        if (mounted) {
          setState(() {
            _isFallbackMode = true;
            _isInitializing = false;
          });
        }
        return;
      }

      // Default to rear camera
      _selectedCameraIndex = _availableCameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      if (_selectedCameraIndex == -1) _selectedCameraIndex = 0;

      await _initCameraController(_availableCameras[_selectedCameraIndex]);
    } catch (_) {
      if (mounted) {
        setState(() {
          _isFallbackMode = true;
          _isInitializing = false;
        });
      }
    }
  }

  Future<void> _initCameraController(CameraDescription cameraDescription) async {
    final controller = CameraController(
      cameraDescription,
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    _controller = controller;

    try {
      await controller.initialize();
      await controller.setFlashMode(_currentFlashMode);
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _isFallbackMode = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isFallbackMode = true;
          _isInitializing = false;
        });
      }
    }
  }

  Future<void> _toggleCamera() async {
    if (_availableCameras.length < 2 || _isCapturing) return;
    _selectedCameraIndex = (_selectedCameraIndex + 1) % _availableCameras.length;
    setState(() => _isInitializing = true);
    await _controller?.dispose();
    await _initCameraController(_availableCameras[_selectedCameraIndex]);
  }

  Future<void> _toggleFlash() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    FlashMode next;
    switch (_currentFlashMode) {
      case FlashMode.off:
        next = FlashMode.auto;
        break;
      case FlashMode.auto:
        next = FlashMode.always;
        break;
      case FlashMode.always:
        next = FlashMode.torch;
        break;
      case FlashMode.torch:
        next = FlashMode.off;
        break;
    }
    try {
      await _controller!.setFlashMode(next);
      if (mounted) {
        setState(() => _currentFlashMode = next);
      }
    } catch (_) {}
  }

  IconData _getFlashIcon() {
    switch (_currentFlashMode) {
      case FlashMode.off:
        return Icons.flash_off;
      case FlashMode.auto:
        return Icons.flash_auto;
      case FlashMode.always:
        return Icons.flash_on;
      case FlashMode.torch:
        return Icons.highlight;
    }
  }

  Future<void> _capturePhoto() async {
    if (_isCapturing || _isInitializing) return;
    setState(() => _isCapturing = true);

    try {
      HapticFeedback.mediumImpact();
      if (_isFallbackMode || _controller == null || !_controller!.value.isInitialized) {
        // Fallback to ImagePicker
        final picker = widget.imagePicker ?? ImagePicker();
        final photo = await picker.pickImage(
          source: ImageSource.camera,
          maxWidth: 2400,
          maxHeight: 2400,
          imageQuality: 92,
        );
        if (photo != null && mounted) {
          setState(() {
            _capturedPages.add(photo.path);
          });
        }
      } else {
        // Flash animation
        setState(() => _showShutterFlash = true);
        Future.delayed(const Duration(milliseconds: 70), () {
          if (mounted) setState(() => _showShutterFlash = false);
        });

        final XFile photo = await _controller!.takePicture();
        if (mounted) {
          setState(() {
            _capturedPages.add(photo.path);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not capture page: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
      }
    }
  }

  Future<bool> _onWillPop() async {
    if (_capturedPages.isEmpty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 26),
            SizedBox(width: 8),
            Text('Discard Scan Session?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Text(
          'Are you sure you want to discard ${_capturedPages.length} captured page${_capturedPages.length == 1 ? '' : 's'}? All photos from this session will be lost.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep Scanning'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  Future<void> _finishAndSubmit() async {
    if (_isCapturing) {
      int waited = 0;
      while (_isCapturing && waited < 30) {
        await Future.delayed(const Duration(milliseconds: 100));
        waited++;
      }
    }
    if (!mounted || _capturedPages.isEmpty) return;
    Navigator.of(context).pop(_capturedPages);
  }

  void _openPageReviewSheet() {
    if (_capturedPages.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Container(
            height: MediaQuery.of(context).size.height * 0.65,
            decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(top: BorderSide(color: Colors.white24)),
            ),
            child: Column(
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.photo_library, color: brandBlue, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'Captured Pages (${_capturedPages.length})',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),

                // Horizontal Carousel of Pages
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    scrollDirection: Axis.horizontal,
                    itemCount: _capturedPages.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (c, idx) {
                      final path = _capturedPages[idx];
                      final file = File(path);

                      return Container(
                        width: 220,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white24),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            file.existsSync()
                                ? Image.file(file, fit: BoxFit.contain)
                                : const Center(child: Icon(Icons.broken_image, color: Colors.white54)),
                            // Page Badge
                            Positioned(
                              top: 8,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.black87,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.white30),
                                ),
                                child: Text(
                                  'Page ${idx + 1}',
                                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                            // Action controls (Move Left, Move Right, Delete)
                            Positioned(
                              bottom: 8,
                              left: 8,
                              right: 8,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  if (idx > 0)
                                    CircleAvatar(
                                      radius: 16,
                                      backgroundColor: Colors.black87,
                                      child: IconButton(
                                        padding: EdgeInsets.zero,
                                        icon: const Icon(Icons.arrow_back, color: Colors.white, size: 16),
                                        onPressed: () {
                                          setState(() {
                                            final item = _capturedPages.removeAt(idx);
                                            _capturedPages.insert(idx - 1, item);
                                          });
                                          setSheetState(() {});
                                        },
                                      ),
                                    )
                                  else
                                    const SizedBox(width: 32),
                                  CircleAvatar(
                                    radius: 16,
                                    backgroundColor: Colors.red.shade900,
                                    child: IconButton(
                                      padding: EdgeInsets.zero,
                                      icon: const Icon(Icons.delete_outline, color: Colors.white, size: 16),
                                      onPressed: () {
                                        setState(() {
                                          _capturedPages.removeAt(idx);
                                        });
                                        setSheetState(() {});
                                        if (_capturedPages.isEmpty) {
                                          Navigator.of(ctx).pop();
                                        }
                                      },
                                    ),
                                  ),
                                  if (idx < _capturedPages.length - 1)
                                    CircleAvatar(
                                      radius: 16,
                                      backgroundColor: Colors.black87,
                                      child: IconButton(
                                        padding: EdgeInsets.zero,
                                        icon: const Icon(Icons.arrow_forward, color: Colors.white, size: 16),
                                        onPressed: () {
                                          setState(() {
                                            final item = _capturedPages.removeAt(idx);
                                            _capturedPages.insert(idx + 1, item);
                                          });
                                          setSheetState(() {});
                                        },
                                      ),
                                    )
                                  else
                                    const SizedBox(width: 32),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                // Done Button in Bottom Sheet
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white30),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Back to Camera'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _isCapturing
                              ? null
                              : () {
                                  Navigator.of(ctx).pop();
                                  _finishAndSubmit();
                                },
                          style: FilledButton.styleFrom(
                            backgroundColor: brandGreen,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: const Icon(Icons.check, size: 18),
                          label: Text(
                            'OK / Done (${_capturedPages.length})',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pageCount = _capturedPages.length;
    final hasPages = pageCount > 0;

    return PopScope(
      canPop: !hasPages,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Camera Live Viewport or Fallback
            if (_isInitializing)
              const Center(
                child: CircularProgressIndicator(color: brandBlue),
              )
            else if (_isFallbackMode || _controller == null || !_controller!.value.isInitialized)
              _buildFallbackView()
            else
              _buildLiveCameraView(),

            // 2. White shutter flash animation overlay
            if (_showShutterFlash)
              Container(color: Colors.white.withAlpha(200)),

            // 3. Top Action Controls (Cancel, Flash, Switch Camera)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Cancel Button
                      GestureDetector(
                        key: const Key('camera_close_btn'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () async {
                          final shouldPop = await _onWillPop();
                          if (shouldPop && context.mounted) Navigator.of(context).pop();
                        },
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close, color: Colors.white, size: 22),
                        ),
                      ),

                      // Document Scan Session Badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              hasPages ? Icons.check_circle : Icons.camera_alt,
                              color: hasPages ? const Color(0xFF4ADE80) : Colors.white70,
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              hasPages ? '$pageCount ${pageCount == 1 ? 'Page' : 'Pages'} Captured' : 'Document Camera',
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),

                      // Flash & Switch Camera Actions
                      Row(
                        children: [
                          if (!_isFallbackMode)
                            GestureDetector(
                              key: const Key('camera_flash_btn'),
                              behavior: HitTestBehavior.opaque,
                              onTap: _toggleFlash,
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(_getFlashIcon(), color: Colors.white, size: 20),
                              ),
                            ),
                          if (!_isFallbackMode && _availableCameras.length > 1) ...[
                            const SizedBox(width: 8),
                            GestureDetector(
                              key: const Key('camera_switch_btn'),
                              behavior: HitTestBehavior.opaque,
                              onTap: _toggleCamera,
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.flip_camera_ios, color: Colors.white, size: 20),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 4. Bottom Controls (Thumbnail + Page Count | Shutter/Add Page | OK/Done)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.transparent, Colors.black87, Colors.black],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Left: Thumbnail preview & Page Count
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: hasPages ? _buildThumbnailButton() : const SizedBox(width: 64),
                        ),
                      ),

                      // Center: Capture / Add Page Button
                      GestureDetector(
                        key: const Key('camera_shutter_btn'),
                        behavior: HitTestBehavior.opaque,
                        onTap: (_isCapturing || _isInitializing) ? null : _capturePhoto,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              key: hasPages ? const Key('camera_add_page_btn') : null,
                              width: 78,
                              height: 78,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 4),
                                color: Colors.transparent,
                              ),
                              padding: const EdgeInsets.all(4),
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: hasPages ? brandBlue : Colors.white,
                                ),
                                child: _isCapturing
                                    ? const Center(
                                        child: SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                                        ),
                                      )
                                    : Icon(
                                        hasPages ? Icons.add_a_photo : Icons.camera_alt,
                                        color: hasPages ? Colors.white : Colors.black87,
                                        size: 32,
                                      ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              hasPages ? '+ Add Page' : 'Capture',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Right: OK / Done Button
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: hasPages
                              ? ElevatedButton.icon(
                                  key: const Key('camera_done_btn'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: brandGreen,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                    elevation: 4,
                                  ),
                                  onPressed: _finishAndSubmit,
                                  icon: const Icon(Icons.check, size: 20),
                                  label: Text(
                                    'Done ($pageCount)',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                )
                              : const SizedBox(width: 64),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveCameraView() {
    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_controller!),

        // Document framing overlay
        Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 90),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.lightBlueAccent.withAlpha(200),
                width: 2,
              ),
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(160),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Align Consignment Note within border',
                  style: TextStyle(color: Colors.lightBlueAccent, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFallbackView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.document_scanner, size: 64, color: Colors.lightBlueAccent),
            const SizedBox(height: 16),
            const Text(
              'Continuous Multi-Page Scanner',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _capturedPages.isEmpty
                  ? 'Capture consignment note photos one by one. All pages will be combined into 1 multi-page PDF.'
                  : '${_capturedPages.length} page${_capturedPages.length == 1 ? '' : 's'} added. Tap "+ Add Page" to photograph the next page, or "Done" to scan as 1 LR.',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnailButton() {
    final lastPath = _capturedPages.last;
    final file = File(lastPath);

    return GestureDetector(
      key: const Key('camera_thumbnail_btn'),
      behavior: HitTestBehavior.opaque,
      onTap: _openPageReviewSheet,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white, width: 2),
              color: Colors.grey.shade900,
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                file.existsSync()
                    ? Image.file(file, fit: BoxFit.cover)
                    : const Icon(Icons.image, color: Colors.white54, size: 24),
                Positioned(
                  bottom: 2,
                  right: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${_capturedPages.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Pages',
            style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
