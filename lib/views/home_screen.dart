import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/user_cloud_service.dart';
import '../models/batch_item.dart';
import '../state/batch_controller.dart';
import 'login_screen.dart';
import 'screens/batch_queue_screen.dart';
import 'screens/edit_bilty_screen.dart';
import 'screens/excel_preview_screen.dart';
import 'widgets/ocr_processing_dialog.dart';
import 'widgets/permission_dialog.dart';
import 'widgets/step_indicator_bar.dart';

/// Screen 2: Upload LR & Intake Screen (Multi-image upload enabled after OTP).
class HomeScreen extends StatefulWidget {
  final BatchProcessingController controller;

  const HomeScreen({super.key, required this.controller});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _userName = 'Logistics User';
  String _userMobile = '';
  List<Map<String, dynamic>> _persistedRecentLrs = [];

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
    _loadRecentUploads();
    widget.controller.addListener(_checkFallbackNotice);
    widget.controller.addListener(_checkDuplicateNotice);
    widget.controller.addListener(_syncRecentUploadsOnControllerChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_checkFallbackNotice);
    widget.controller.removeListener(_checkDuplicateNotice);
    widget.controller.removeListener(_syncRecentUploadsOnControllerChange);
    super.dispose();
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

  void _checkFallbackNotice() {
    if (!mounted) return;
    if (widget.controller.fallbackNotificationPending) {
      final msg = widget.controller.fallbackNoticeMessage ??
          'There is a technical issue with the server. You can contact the admin or continue. The results may be inaccurate.';
      widget.controller.acknowledgeFallbackNotice();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: const [
                Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 28),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Server Issue (Fallback Active)',
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
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Admin Support: +91 98765 43210 • admin@boxnfreight.com'),
                      duration: Duration(seconds: 5),
                    ),
                  );
                },
                child: const Text('Contact Admin'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                ),
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Continue'),
              ),
            ],
          ),
        );
      });
    }
  }

  Future<void> _deleteRecentUploadItem(int idx, Map<String, dynamic> itmData) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline, color: Color(0xFFDC2626), size: 24),
            SizedBox(width: 8),
            Text('Remove Consignment', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: const Text('Are you sure you want to remove this LR document?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final targetId = itmData['id']?.toString() ?? '';
    final fileName = itmData['fileName']?.toString() ?? '';

    // 1. Remove from active controller items if present
    final activeMatches = widget.controller.items
        .where((i) => (targetId.isNotEmpty && i.id == targetId) || (fileName.isNotEmpty && i.fileName == fileName))
        .toList();
    for (final item in activeMatches) {
      widget.controller.removeItem(item.id);
    }

    // 2. Remove from persisted recent uploads
    final prefs = await SharedPreferences.getInstance();
    _persistedRecentLrs.removeWhere(
      (r) => (targetId.isNotEmpty && r['id']?.toString() == targetId) || (fileName.isNotEmpty && r['fileName']?.toString() == fileName),
    );
    await prefs.setString('bnf_recent_uploaded_lrs', jsonEncode(_persistedRecentLrs));

    // 3. Notify backend API to soft-delete
    if (targetId.isNotEmpty) {
      final mobile = widget.controller.activeUserMobile ?? _userMobile;
      UserCloudService.instance.deleteCloudLr(
        mobile,
        [targetId],
        baseUrl: widget.controller.geminiService.serverUrl,
      ).catchError((_) => false);
    }

    if (mounted) setState(() {});
  }

  Future<void> _loadUserInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('bnf_user_name') ?? 'Logistics User';
    final mobile = prefs.getString('bnf_user_mobile') ?? '';
    final token = prefs.getString('bnf_user_token');
    if (mobile.isNotEmpty) {
      widget.controller.setActiveUser(mobile, name: name, sessionToken: token);
    }
    setState(() {
      _userName = name;
      _userMobile = mobile;
    });
  }

  void _syncRecentUploadsOnControllerChange() {
    if (widget.controller.items.isNotEmpty) {
      _saveRecentUploads(widget.controller.items);
    }
  }

  Future<void> _loadRecentUploads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('bnf_recent_uploaded_lrs');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final filtered = decoded
            .map((e) => Map<String, dynamic>.from(e as Map))
            .where((e) {
              final fn = (e['fileName'] ?? '').toString().toLowerCase();
              final id = (e['id'] ?? '').toString().toLowerCase();
              final lr = (e['lrNo'] ?? '').toString().toLowerCase();
              return !fn.contains('dummy') && !id.contains('dummy') && !lr.contains('dummy') &&
                     !fn.contains('nloiad273') && !id.contains('nloiad273') && !lr.contains('nloiad273');
            })
            .toList();
        await prefs.setString('bnf_recent_uploaded_lrs', jsonEncode(filtered));
        if (mounted) {
          setState(() {
            _persistedRecentLrs = filtered;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveRecentUploads(List<BatchItem> currentItems) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      Directory? docsDir;
      try {
        docsDir = await getApplicationDocumentsDirectory();
      } catch (_) {}

      final list = <Map<String, dynamic>>[];
      for (final item in currentItems) {
        final lr = (item.record['LR No *'] ?? item.record['grno'] ?? item.record['BNF LR No'] ?? '').toLowerCase();
        if (item.fileName.toLowerCase().contains('nloiad273') ||
            item.id.toLowerCase().contains('nloiad273') ||
            lr.contains('nloiad273')) {
          continue;
        }

        String previewPath = item.record['preview_path'] ?? '';
        final previewImg = item.record['preview_image'] ?? '';
        if (previewPath.isEmpty && docsDir != null && previewImg.startsWith('data:image/') && previewImg.contains('base64,')) {
          try {
            final targetDir = Directory('${docsDir.path}/lr_documents');
            if (!targetDir.existsSync()) targetDir.createSync(recursive: true);
            final pFile = File('${targetDir.path}/${item.fileName}_preview.jpg');
            if (!pFile.existsSync()) {
              final b64 = previewImg.split('base64,').last;
              pFile.writeAsBytesSync(base64Decode(b64));
            }
            previewPath = pFile.path;
          } catch (_) {}
        }

        list.add({
          'id': item.id,
          'fileName': item.fileName,
          'imagePath': item.imagePath,
          'lrNo': item.record['LR No *'] ?? item.record['grno'] ?? item.record['BNF LR No'] ?? '',
          'isPdf': item.fileName.toLowerCase().endsWith('.pdf') || item.imagePath.toLowerCase().endsWith('.pdf'),
          'createdAt': item.createdAt.toIso8601String(),
          'status': item.status.name,
          'preview_url': item.record['preview_url'] ?? '',
          'preview_path': previewPath,
          'record': item.record,
        });
      }
      for (final prev in _persistedRecentLrs) {
        if (!list.any((x) => x['imagePath'] == prev['imagePath'])) {
          list.add(prev);
        }
      }
      final toSave = list.take(20).toList();
      await prefs.setString('bnf_recent_uploaded_lrs', jsonEncode(toSave));
      if (mounted) {
        setState(() {
          _persistedRecentLrs = toSave;
        });
      }
    } catch (_) {}
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout?'),
        content: const Text('Are you sure you want to log out of your session?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final token = widget.controller.activeSessionToken;
      widget.controller.clearForLogout();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('bnf_user_name');
      await prefs.remove('bnf_user_mobile');
      await prefs.remove('bnf_user_token');
      widget.controller.geminiService.logout(sessionToken: token);
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => LoginScreen(controller: widget.controller)),
          (route) => false,
        );
      }
    }
  }

  Future<void> _handleCameraCapture() async {
    final countBefore = widget.controller.items.length;

    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => OcrProcessingDialog(controller: widget.controller),
      );
    }

    bool success = false;
    try {
      success = await widget.controller.addFromCamera();
    } finally {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    }

    if (!success && mounted) {
      final isPerm = await widget.controller.permissionService.isCameraPermanentlyDenied();
      if (isPerm) {
        PermissionRationaleDialog.show(
          context: context,
          title: 'Camera Permission Needed',
          message: 'Camera access is required to photograph documents directly for text recognition.',
          icon: Icons.camera_alt,
          isPermanent: true,
          onRetryOrSettings: () => widget.controller.permissionService.openSettings(),
        );
      }
      return;
    }

    // If new item was added, automatically open Screen 4: Edit View
    if (mounted && widget.controller.items.length > countBefore) {
      final newItem = widget.controller.items[countBefore];
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EditBiltyScreen(
            item: newItem,
            controller: widget.controller,
          ),
        ),
      );
    }
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

  Future<void> _handleGalleryUpload() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf', 'webp'],
      );

      if (files.isEmpty) return;

      // Validate maximum size of 10 MB per file
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

      final countBefore = widget.controller.items.length;

      if (mounted) {
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => OcrProcessingDialog(controller: widget.controller),
        );
      }

      try {
        await widget.controller.addFilePaths(validPaths);
      } finally {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      }

      // If new item(s) were added, open Step 2: LR & Master Verification
      if (mounted && widget.controller.items.length > countBefore) {
        final newItem = widget.controller.items[countBefore];
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => EditBiltyScreen(
              item: newItem,
              controller: widget.controller,
            ),
          ),
        );
      }
    } catch (_) {
      // Fallback to ImagePicker single gallery
      final countBefore = widget.controller.items.length;
      if (mounted) {
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => OcrProcessingDialog(controller: widget.controller),
        );
      }
      bool success = false;
      try {
        success = await widget.controller.addFromGallerySingle();
      } finally {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      }

      if (!success && mounted) {
        final isPerm = await widget.controller.permissionService.isGalleryPermanentlyDenied();
        if (isPerm) {
          PermissionRationaleDialog.show(
            context: context,
            title: 'Photo Access Needed',
            message: 'Gallery access is required to select image for text recognition.',
            icon: Icons.photo_library,
            isPermanent: true,
            onRetryOrSettings: () => widget.controller.permissionService.openSettings(),
          );
        }
        return;
      }

      if (mounted && widget.controller.items.length > countBefore) {
        final newItem = widget.controller.items[countBefore];
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => EditBiltyScreen(
              item: newItem,
              controller: widget.controller,
            ),
          ),
        );
      }
    }
  }

  Widget _buildRecentItemThumbnail({
    required bool isPdf,
    required String imagePath,
    required String fileName,
    required String previewImage,
    required String previewPath,
    required String previewUrl,
  }) {
    // PDF files: Display clean PDF icon with filename
    if (isPdf) {
      return Container(
        width: double.infinity,
        height: double.infinity,
        color: const Color(0xFFFEF2F2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.picture_as_pdf, color: Color(0xFFDC2626), size: 24),
            const SizedBox(height: 3),
            Text(
              fileName,
              style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // 1. Try saved/resolved preview path on local disk
    if (previewPath.isNotEmpty && File(previewPath).existsSync()) {
      return Image.file(
        File(previewPath),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildFallbackIcon(isPdf),
      );
    }

    // 2. For PDFs, try conventional local preview file in lr_documents folder
    if (isPdf && (fileName.isNotEmpty || imagePath.isNotEmpty)) {
      try {
        final clean = _normalizeFilePath(imagePath);
        if (clean.isNotEmpty) {
          final candPreview = File(clean.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '_preview.jpg'));
          if (candPreview.existsSync()) {
            return Image.file(
              candPreview,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _buildFallbackIcon(isPdf),
            );
          }
        }
      } catch (_) {}
    }

    // 3. For images, try local image file
    if (!isPdf && imagePath.isNotEmpty) {
      final clean = _normalizeFilePath(imagePath);
      if (clean.isNotEmpty && File(clean).existsSync()) {
        return Image.file(
          File(clean),
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _buildFallbackIcon(isPdf),
        );
      }
    }

    // 4. Try base64 decoded bytes from previewImage
    if (previewImage.startsWith('data:image/') && previewImage.contains('base64,')) {
      try {
        final b64 = previewImage.split('base64,').last;
        final bytes = base64Decode(b64);
        return Image.memory(
          bytes,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _buildFallbackIcon(isPdf),
        );
      } catch (_) {}
    }

    // 5. Try network URL if valid
    if (previewUrl.isNotEmpty) {
      String fullUrl = previewUrl;
      if (fullUrl.startsWith('/') && widget.controller.geminiService.serverUrl.isNotEmpty) {
        fullUrl = '${widget.controller.geminiService.serverUrl}$fullUrl';
      }
      if (fullUrl.startsWith('http://') || fullUrl.startsWith('https://')) {
        return Image.network(
          fullUrl,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _buildFallbackIcon(isPdf),
        );
      }
    }

    // 6. Fallback icon
    return _buildFallbackIcon(isPdf);
  }

  String _normalizeFilePath(String raw) {
    String clean = raw.trim();
    if (clean.startsWith('file://')) {
      try {
        clean = Uri.parse(clean).toFilePath();
      } catch (_) {
        clean = clean.substring(7);
      }
    }
    return clean;
  }

  Widget _buildFallbackIcon(bool isPdf) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: isPdf ? const Color(0xFFFEF2F2) : const Color(0xFFF1F5F9),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isPdf ? Icons.picture_as_pdf : Icons.image,
            size: 28,
            color: isPdf ? Colors.red.shade600 : const Color(0xFF0284C7),
          ),
          const SizedBox(height: 2),
          Text(
            isPdf ? 'PDF' : 'IMAGE',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: isPdf ? Colors.red.shade700 : const Color(0xFF0369A1),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const brandNavy = Color(0xFF0F172A);
    const brandBlue = Color(0xFF0284C7);

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final items = widget.controller.items;
        final isProcessing = widget.controller.isProcessing;
        final displayRecent = items.isNotEmpty
            ? items
                .where((i) {
                  final fn = i.fileName.toLowerCase();
                  final id = i.id.toLowerCase();
                  final lr = (i.record['LR No *'] ?? i.record['grno'] ?? i.record['BNF LR No'] ?? '').toLowerCase();
                  return !fn.contains('dummy') && !id.contains('dummy') &&
                         !fn.contains('nloiad273') && !id.contains('nloiad273') && !lr.contains('nloiad273');
                })
                .map((i) => {
                  'id': i.id,
                  'fileName': i.fileName,
                  'imagePath': i.imagePath,
                  'lrNo': i.record['LR No *'] ?? i.record['grno'] ?? i.record['BNF LR No'] ?? '',
                  'isPdf': i.fileName.toLowerCase().endsWith('.pdf') || i.imagePath.toLowerCase().endsWith('.pdf'),
                  'createdAt': i.createdAt.toIso8601String(),
                  'status': i.status.name,
                  'preview_image': i.record['preview_image'] ?? '',
                  'preview_url': i.record['preview_url'] ?? '',
                  'preview_path': i.record['preview_path'] ?? '',
                  'item': i,
                }).toList()
            : _persistedRecentLrs
                .where((e) {
                  final fn = (e['fileName'] ?? '').toString().toLowerCase();
                  final id = (e['id'] ?? '').toString().toLowerCase();
                  final lr = (e['lrNo'] ?? '').toString().toLowerCase();
                  return !fn.contains('dummy') && !id.contains('dummy') &&
                         !fn.contains('nloiad273') && !id.contains('nloiad273') && !lr.contains('nloiad273');
                })
                .toList();

        return Scaffold(
          backgroundColor: const Color(0xFFF1F5F9),
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 1,
            titleSpacing: 8,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: brandNavy,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('BNF', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13)),
                ),
                const SizedBox(width: 6),
                const Flexible(
                  child: Text(
                    'BOX N FREIGHT',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: brandNavy),
                  ),
                ),
              ],
            ),
            actions: [
              // Server Status button
              IconButton(
                icon: Icon(
                  widget.controller.useGeminiBackend ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                  color: widget.controller.useGeminiBackend ? Colors.green : Colors.grey,
                  size: 18,
                ),
                tooltip: 'Server Settings',
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () => _showServerConfigDialog(context),
              ),
              const SizedBox(width: 4),

              // History Button in Top Navbar
              OutlinedButton.icon(
                key: const Key('navbar_history_btn'),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ExcelPreviewScreen(controller: widget.controller, initialTab: 1),
                    ),
                  );
                },
                icon: const Icon(Icons.history_outlined, size: 15, color: brandBlue),
                label: const Text(
                  'History',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
                ),
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xFFF1F5F9),
                  side: const BorderSide(color: Color(0xFFCBD5E1)),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  minimumSize: const Size(0, 30),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 6),

              // User Info & Profile Section [Ruchita Patel • +91 XXXXXXXX Logout]
              PopupMenuButton<String>(
                tooltip: 'User Profile',
                onSelected: (val) {
                  if (val == 'logout') _logout();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.check_circle_outline, size: 13, color: Color(0xFF16A34A)),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 80),
                        child: Text(
                          _userName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Color(0xFF334155)),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.arrow_drop_down, size: 14, color: Colors.blueGrey),
                    ],
                  ),
                ),
                itemBuilder: (ctx) => [
                  PopupMenuItem(
                    enabled: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_userName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black87)),
                        if (_userMobile.isNotEmpty)
                          Text('+91 $_userMobile', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'logout',
                    child: Row(
                      children: [
                        Icon(Icons.logout, size: 16, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Logout', style: TextStyle(color: Colors.red, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            children: [
              if (isProcessing) ...[
                const LinearProgressIndicator(
                  backgroundColor: Color(0xFFE0F2FE),
                  color: brandBlue,
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: const Color(0xFFF0F9FF),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: brandBlue),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Uploading & Processing LR: ${widget.controller.processingFileIndex}/${widget.controller.processingTotalFiles} ${widget.controller.currentProcessingFileName.isNotEmpty ? "(${widget.controller.currentProcessingFileName})" : ""}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0369A1)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Upload Consignment Notes (LRs)',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: brandNavy),
                      ),
                      const SizedBox(height: 16),

                      // Interactive Drag & Drop / Intake Card
                      Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                          side: BorderSide(color: Colors.blue.shade100, width: 1.5),
                        ),
                        color: Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                          child: Column(
                            children: [
                              Container(
                                width: 68,
                                height: 68,
                                decoration: const BoxDecoration(
                                  color: brandBlue,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.camera_alt, size: 34, color: Colors.white),
                              ),
                              const SizedBox(height: 14),
                              const Text(
                                'Capture or Upload LR Image',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: brandNavy),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Supported formats: JPG, PNG, PDF • Max size: 10 MB',
                                style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 20),
                              if (isProcessing) ...[
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF0F9FF),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(color: const Color(0xFF38BDF8), width: 1.5),
                                  ),
                                  child: const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2.5, color: brandBlue),
                                      ),
                                      SizedBox(width: 10),
                                      Text(
                                        'Uploading & Processing LR document...',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0369A1)),
                                      ),
                                    ],
                                  ),
                                ),
                              ] else ...[
                                Row(
                                  children: [
                                    Expanded(
                                      child: FilledButton.icon(
                                        onPressed: _handleCameraCapture,
                                        icon: const Icon(Icons.camera_alt, size: 18),
                                        label: const Text('Capture Image', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                        style: FilledButton.styleFrom(
                                          backgroundColor: brandBlue,
                                          padding: const EdgeInsets.symmetric(vertical: 13),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        onPressed: _handleGalleryUpload,
                                        icon: const Icon(Icons.folder_open, size: 18, color: brandBlue),
                                        label: const Text('Select Image', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: brandNavy)),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFFE0F2FE),
                                          padding: const EdgeInsets.symmetric(vertical: 13),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                          elevation: 0,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),

                      // Recently / Previously Uploaded Horizontal Strip (Slide 2: Upload LR)
                      if (displayRecent.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.history, size: 16, color: Color(0xFF0284C7)),
                                SizedBox(width: 6),
                                Text(
                                  'Previously Uploaded LRs',
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: brandNavy),
                                ),
                              ],
                            ),
                            Text(
                              '${displayRecent.length} files',
                              style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 140,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: displayRecent.length,
                            separatorBuilder: (_, _) => const SizedBox(width: 10),
                            itemBuilder: (ctx, idx) {
                              final itmData = displayRecent[idx];
                              final isPdf = itmData['isPdf'] == true;
                              final fileName = itmData['fileName']?.toString() ?? 'LR Document';
                              final lrNo = itmData['lrNo']?.toString() ?? '';
                              final imagePath = itmData['imagePath']?.toString() ?? '';
                              final itemObj = itmData['item'] is BatchItem ? (itmData['item'] as BatchItem) : null;
                              final rawRec = itmData['record'];
                              final recMap = (rawRec is Map) ? rawRec.map((k, v) => MapEntry(k.toString(), v.toString())) : <String, String>{};
                              final isVerified = itemObj != null ? itemObj.isVerified : (BatchItem(id: 'temp', imagePath: '', fileName: '', createdAt: DateTime.now(), record: recMap).isVerified);
                              final dt = DateTime.tryParse(itmData['createdAt']?.toString() ?? '') ?? DateTime.now();
                              final previewImg = (itmData['preview_image'] ?? itmData['record']?['preview_image'])?.toString() ?? '';
                              final previewPath = (itmData['preview_path'] ?? itmData['record']?['preview_path'])?.toString() ?? '';
                              final previewUrl = (itmData['preview_url'] ?? itmData['record']?['preview_url'])?.toString() ?? '';

                              return InkWell(
                                onTap: () async {
                                  BatchItem targetItem;
                                  if (itmData['item'] != null) {
                                    targetItem = itmData['item'] as BatchItem;
                                  } else {
                                    String cleanPath = imagePath.trim();
                                    if (cleanPath.startsWith('file://')) {
                                      try {
                                        cleanPath = Uri.parse(cleanPath).toFilePath();
                                      } catch (_) {
                                        cleanPath = cleanPath.substring(7);
                                      }
                                    }
                                    if (!File(cleanPath).existsSync() && !cleanPath.startsWith('data:image/')) {
                                      try {
                                        final docsDir = await getApplicationDocumentsDirectory();
                                        final cand = File('${docsDir.path}/lr_documents/$fileName');
                                        if (cand.existsSync()) {
                                          cleanPath = cand.path;
                                        } else {
                                          final lrDir = Directory('${docsDir.path}/lr_documents');
                                          if (lrDir.existsSync()) {
                                            final matches = lrDir.listSync().whereType<File>().where((f) => f.path.endsWith(fileName));
                                            if (matches.isNotEmpty) {
                                              cleanPath = matches.first.path;
                                            }
                                          }
                                        }
                                      } catch (_) {}
                                    }
                                    final rawRecord = itmData['record'];
                                    final recordMap = (rawRecord is Map) ? rawRecord.map((k, v) => MapEntry(k.toString(), v.toString())) : <String, String>{};
                                    if (lrNo.isNotEmpty && !recordMap.containsKey('LR No *')) {
                                      recordMap['LR No *'] = lrNo;
                                    }
                                    if (previewImg.isNotEmpty && !recordMap.containsKey('preview_image')) {
                                      recordMap['preview_image'] = previewImg;
                                    }
                                    if (previewUrl.isNotEmpty && !recordMap.containsKey('preview_url')) {
                                      recordMap['preview_url'] = previewUrl;
                                    }
                                    if (previewPath.isNotEmpty && !recordMap.containsKey('preview_path')) {
                                      recordMap['preview_path'] = previewPath;
                                    }
                                    targetItem = BatchItem(
                                      id: itmData['id']?.toString() ?? 'prev_$idx',
                                      imagePath: cleanPath,
                                      fileName: fileName,
                                      status: isVerified ? BatchItemStatus.completed : BatchItemStatus.pending,
                                      createdAt: dt,
                                      record: recordMap,
                                    );
                                  }
                                  final existingIdx = widget.controller.items.indexWhere((i) => i.id == targetItem.id);
                                  if (existingIdx == -1) {
                                    widget.controller.items.add(targetItem);
                                  } else {
                                    targetItem = widget.controller.items[existingIdx];
                                  }
                                  if (context.mounted) {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => EditBiltyScreen(
                                          item: targetItem,
                                          controller: widget.controller,
                                          initialTab: 0,
                                        ),
                                      ),
                                    );
                                  }
                                },
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  width: 140,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: const Color(0xFFE2E8F0)),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x0A000000),
                                        blurRadius: 4,
                                        offset: Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        // Top Visual Thumbnail Section (72px)
                                        SizedBox(
                                          height: 72,
                                          width: double.infinity,
                                          child: Stack(
                                            children: [
                                              Positioned.fill(
                                                child: _buildRecentItemThumbnail(
                                                  isPdf: isPdf,
                                                  imagePath: imagePath,
                                                  fileName: fileName,
                                                  previewImage: previewImg,
                                                  previewPath: previewPath,
                                                  previewUrl: previewUrl,
                                                ),
                                              ),
                                              // Status Badge & Delete Button (Top-Right)
                                              Positioned(
                                                top: 4,
                                                right: 4,
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                                      decoration: BoxDecoration(
                                                        color: (isVerified ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2)).withAlpha(240),
                                                        borderRadius: BorderRadius.circular(4),
                                                        border: Border.all(
                                                          color: isVerified ? const Color(0xFF86EFAC) : const Color(0xFFFCA5A5),
                                                          width: 0.8,
                                                        ),
                                                      ),
                                                      child: Text(
                                                        isVerified ? 'Verified' : 'Unverified',
                                                        style: TextStyle(
                                                          fontSize: 8.5,
                                                          fontWeight: FontWeight.bold,
                                                          color: isVerified ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 4),
                                                    GestureDetector(
                                                      onTap: () => _deleteRecentUploadItem(idx, itmData),
                                                      child: Container(
                                                        padding: const EdgeInsets.all(2.5),
                                                        decoration: BoxDecoration(
                                                          color: Colors.white.withAlpha(240),
                                                          shape: BoxShape.circle,
                                                          border: Border.all(color: const Color(0xFFCBD5E1), width: 0.8),
                                                        ),
                                                        child: const Icon(Icons.close, size: 10, color: Color(0xFF64748B)),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              // PDF indicator badge if PDF
                                              if (isPdf)
                                                Positioned(
                                                  top: 4,
                                                  left: 4,
                                                  child: Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
                                                    decoration: BoxDecoration(
                                                      color: Colors.red.shade700.withAlpha(235),
                                                      borderRadius: BorderRadius.circular(3),
                                                    ),
                                                    child: const Text(
                                                      'PDF',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 8,
                                                        fontWeight: FontWeight.bold,
                                                        letterSpacing: 0.3,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        // Bottom Metadata Section
                                        Expanded(
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                Text(
                                                  lrNo.isNotEmpty ? 'LR: $lrNo' : fileName,
                                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: brandNavy),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  '${dt.day}/${dt.month} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}',
                                                  style: const TextStyle(fontSize: 8.5, color: Colors.grey),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // Bottom Intake & Export Bar
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(20),
                      blurRadius: 6,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: SafeArea(
                  child: Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: isProcessing ? null : _handleCameraCapture,
                        icon: const Icon(Icons.camera_alt, size: 18),
                        label: const Text('Camera'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: isProcessing ? null : _handleGalleryUpload,
                        icon: const Icon(Icons.photo_library, size: 18),
                        label: const Text('Gallery'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: items.isEmpty
                              ? null
                              : () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => BatchQueueScreen(controller: widget.controller),
                                    ),
                                  );
                                },
                          icon: const Icon(Icons.table_view, size: 18),
                          label: Text(
                            items.isEmpty ? 'Queue (0)' : 'Review & Export (${items.length})',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: brandBlue,
                            padding: const EdgeInsets.symmetric(vertical: 13),
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
          bottomNavigationBar: StepIndicatorBar(currentStep: 1, controller: widget.controller),
        );
      },
    );
  }

  void _showServerConfigDialog(BuildContext context) {
    final textController = TextEditingController(text: widget.controller.geminiService.serverUrl);
    bool isPinging = false;
    String? pingResult;
    bool? isOnline;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.hub_outlined, color: Colors.indigo),
              SizedBox(width: 8),
              Text('Extraction Server', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use Cloud Extraction Server', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Sends images to FastAPI backend for automated document extraction'),
                  value: widget.controller.useGeminiBackend,
                  onChanged: (val) {
                    widget.controller.setUseGeminiBackend(val);
                    setDialogState(() {});
                  },
                ),
                const Divider(height: 20),
                const Text('Server Base URL:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 6),
                TextField(
                  controller: textController,
                  decoration: const InputDecoration(
                    hintText: 'http://192.168.1.2:8000',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: isPinging
                          ? null
                          : () async {
                              setDialogState(() {
                                isPinging = true;
                                pingResult = null;
                                isOnline = null;
                              });
                              await widget.controller.geminiService.updateServerUrl(textController.text);
                              final ok = await widget.controller.geminiService.checkHealth();
                              setDialogState(() {
                                isPinging = false;
                                isOnline = ok;
                                pingResult = ok ? 'Connected!' : 'Connection failed.';
                              });
                            },
                      icon: isPinging
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.wifi_tethering, size: 16),
                      label: const Text('Test Connection'),
                    ),
                    const SizedBox(width: 8),
                    if (pingResult != null)
                      Expanded(
                        child: Text(
                          pingResult!,
                          style: TextStyle(
                            fontSize: 11,
                            color: isOnline == true ? Colors.green.shade700 : Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                await widget.controller.geminiService.updateServerUrl(textController.text);
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Saved Server URL: ${widget.controller.geminiService.serverUrl}')),
                  );
                }
              },
              child: const Text('Save URL'),
            ),
          ],
        ),
      ),
    );
  }
}
