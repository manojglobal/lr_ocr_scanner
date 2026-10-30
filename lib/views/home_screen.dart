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
import 'screens/camera_scan_screen.dart';
import 'widgets/billing_image_viewer.dart';
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
  Set<String> _dismissedRecentLrs = {};

  bool _isItemDismissed(dynamic itemOrId) {
    if (itemOrId == null) return false;
    const generic = {'lr document', 'document', 'item', 'null', 'none', 'undefined', ''};
    if (itemOrId is String) {
      final s = itemOrId.trim();
      return s.isNotEmpty && !generic.contains(s.toLowerCase()) && _dismissedRecentLrs.contains(s);
    }
    if (itemOrId is BatchItem) {
      if (_dismissedRecentLrs.contains(itemOrId.id)) return true;
      final fn = itemOrId.fileName.trim();
      if (fn.isNotEmpty && !generic.contains(fn.toLowerCase()) && _dismissedRecentLrs.contains(fn)) return true;
      final saved = itemOrId.record['saved_filename']?.toString().trim();
      if (saved != null && saved.isNotEmpty && !generic.contains(saved.toLowerCase()) && _dismissedRecentLrs.contains(saved)) return true;
      return false;
    }
    if (itemOrId is Map) {
      final id = (itemOrId['id'] ?? itemOrId['file_id'] ?? '').toString().trim();
      final fn = (itemOrId['fileName'] ?? itemOrId['filename'] ?? '').toString().trim();
      final saved = (itemOrId['saved_filename'] ?? (itemOrId['record'] is Map ? itemOrId['record']['saved_filename'] : null) ?? '').toString().trim();
      return (id.isNotEmpty && !generic.contains(id.toLowerCase()) && _dismissedRecentLrs.contains(id)) ||
             (fn.isNotEmpty && !generic.contains(fn.toLowerCase()) && _dismissedRecentLrs.contains(fn)) ||
             (saved.isNotEmpty && !generic.contains(saved.toLowerCase()) && _dismissedRecentLrs.contains(saved));
    }
    return false;
  }

  Map<String, dynamic> _cleanItemForStorage(Map<String, dynamic> raw) {
    final clean = Map<String, dynamic>.from(raw);
    clean.remove('preview_image');
    clean.remove('image_preview');
    clean.remove('imageSrc');
    clean.remove('thumbnail');
    clean.remove('image_data');
    clean.remove('base64');
    clean.remove('file_bytes');
    clean.removeWhere((k, v) => v is String && v.length > 500 && (v.startsWith('data:image') || !v.contains(' ')));
    if (clean['record'] is Map) {
      final rec = Map<String, dynamic>.from(clean['record'] as Map);
      rec.remove('preview_image');
      rec.remove('image_preview');
      rec.remove('imageSrc');
      rec.remove('thumbnail');
      rec.remove('image_data');
      rec.remove('base64');
      rec.remove('file_bytes');
      rec.removeWhere((k, v) => v is String && v.length > 500 && (v.startsWith('data:image') || !v.contains(' ')));
      clean['record'] = rec;
    }
    return clean;
  }

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

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.controller.acknowledgeDuplicateNotice();
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
    final rec = (itmData['record'] is Map)
        ? (itmData['record'] as Map)
        : (itmData['data'] is Map ? itmData['data'] as Map : null);
    final lrLabel = (rec?['LR No *'] ??
            rec?['grno'] ??
            rec?['BNF LR No'] ??
            itmData['lrNo'] ??
            itmData['fileName'] ??
            itmData['filename'] ??
            '')
        .toString()
        .trim();
    final hasSpecificLabel = lrLabel.isNotEmpty && lrLabel.toLowerCase() != 'lr document';
    final dynamicMessage = hasSpecificLabel
        ? 'Are you sure you want to remove LR "$lrLabel" from Previously Uploaded history? It will remain available in your LR List.'
        : 'Are you sure you want to remove this consignment LR from Previously Uploaded history? It will remain available in your LR List.';

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with Red Warning Icon & Title (Matches Web Modal)
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFFECACA), width: 1.2),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.warning_amber_rounded,
                        color: Color(0xFFDC2626),
                        size: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'Remove LR',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'WARNING',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFEF4444),
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Dynamic Body Message
              Text(
                dynamicMessage,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF334155),
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 20),
              // Action Buttons: Cancel and Confirm
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF334155),
                      side: const BorderSide(color: Color(0xFFCBD5E1)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      elevation: 0,
                    ),
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('Confirm', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true) return;

    final targetId = (itmData['id'] ?? '').toString().trim();
    final fileName = (itmData['fileName'] ?? itmData['filename'] ?? '').toString().trim();
    final savedFilename = (itmData['saved_filename'] ?? (itmData['record'] is Map ? itmData['record']['saved_filename'] : null) ?? '').toString().trim();

    // NOTE: Active controller items (LR List) are intentionally KEPT INTACT.
    // We do NOT remove the item from widget.controller.items.

    // 1. Remove from persisted recent uploads & update controller cache
    final prefs = await SharedPreferences.getInstance();
    _persistedRecentLrs.removeWhere(
      (r) => (targetId.isNotEmpty && (r['id']?.toString() == targetId || r['file_id']?.toString() == targetId)) ||
             (fileName.isNotEmpty && (r['fileName']?.toString() == fileName || r['filename']?.toString() == fileName)) ||
             (savedFilename.isNotEmpty && (r['saved_filename']?.toString() == savedFilename || (r['record'] is Map && r['record']['saved_filename']?.toString() == savedFilename))),
    );
    await prefs.setString('bnf_recent_uploaded_lrs', jsonEncode(_persistedRecentLrs));
    widget.controller.setPreviousUploadsCache(_persistedRecentLrs);

    // 2. Track dismissed history items in-memory and persistently
    const generic = {'lr document', 'document', 'item', 'null', 'none', 'undefined', ''};
    if (targetId.isNotEmpty && !generic.contains(targetId.toLowerCase())) _dismissedRecentLrs.add(targetId);
    if (fileName.isNotEmpty && !generic.contains(fileName.toLowerCase())) _dismissedRecentLrs.add(fileName);
    if (savedFilename.isNotEmpty && !generic.contains(savedFilename.toLowerCase())) _dismissedRecentLrs.add(savedFilename);
    await prefs.setStringList('bnf_dismissed_recent_lrs', _dismissedRecentLrs.toList());

    // 3. Notify backend API to dismiss from uploaded_lrs (history) ONLY in cloud DB
    final mobile = widget.controller.activeUserMobile ?? _userMobile;
    final idsToSend = [targetId, fileName, savedFilename]
        .where((s) => s.isNotEmpty && !generic.contains(s.toLowerCase()))
        .toList();
    if (idsToSend.isNotEmpty) {
      UserCloudService.instance.deleteCloudUploadHistory(
        mobile,
        idsToSend,
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

  bool _isItemVerified(Map<String, dynamic> itmData) {
    if (itmData['item'] is BatchItem) {
      return (itmData['item'] as BatchItem).isVerified;
    }
    if (itmData['isVerified'] == true) return true;
    final status = (itmData['status'] ?? '').toString().toLowerCase();
    if (status == 'completed' || status == 'verified') {
      final rawRec = itmData['record'] ?? itmData['data'];
      if (rawRec is Map && rawRec.isNotEmpty) {
        final recMap = rawRec.map((k, v) => MapEntry(k.toString(), v.toString()));
        return BatchItem(id: 'temp', imagePath: '', fileName: '', createdAt: DateTime.now(), record: recMap).isVerified;
      }
      return true;
    }
    final rawRec = itmData['record'] ?? itmData['data'];
    if (rawRec is Map && rawRec.isNotEmpty) {
      final recMap = rawRec.map((k, v) => MapEntry(k.toString(), v.toString()));
      return BatchItem(id: 'temp', imagePath: '', fileName: '', createdAt: DateTime.now(), record: recMap).isVerified;
    }
    return false;
  }

  bool _isSameLrUpload(Map<String, dynamic> a, Map<String, dynamic> b) {
    const genericStrings = {'lr document', 'document', 'item', 'image', 'photo', 'camera', 'upload', 'null', 'none', 'undefined', ''};
    const genericLrs = {'-', '0', 'null', 'none', 'n/a', '', 'undefined'};

    // 1. Direct ID match
    final idA = (a['id'] ?? '').toString().trim();
    final idB = (b['id'] ?? '').toString().trim();
    if (idA.isNotEmpty && idB.isNotEmpty && idA == idB) return true;

    // 2. Saved filename match (e.g. from server / snapshots)
    final savedA = (a['saved_filename'] ?? (a['record'] is Map ? a['record']['saved_filename'] : null) ?? '').toString().trim().toLowerCase();
    final savedB = (b['saved_filename'] ?? (b['record'] is Map ? b['record']['saved_filename'] : null) ?? '').toString().trim().toLowerCase();
    if (savedA.isNotEmpty && savedB.isNotEmpty && !genericStrings.contains(savedA) && !genericStrings.contains(savedB) && savedA == savedB) return true;

    // 3. File name match
    final fnA = (a['fileName'] ?? a['filename'] ?? '').toString().trim().toLowerCase();
    final fnB = (b['fileName'] ?? b['filename'] ?? '').toString().trim().toLowerCase();
    if (fnA.isNotEmpty && fnB.isNotEmpty && !genericStrings.contains(fnA) && !genericStrings.contains(fnB) && fnA == fnB) return true;

    // 4. File stem match (handles prefixes e.g. 1730000_doc.jpg vs doc.jpg cleanly without substring collision)
    if (fnA.isNotEmpty && fnB.isNotEmpty && !genericStrings.contains(fnA) && !genericStrings.contains(fnB)) {
      final cleanStemA = fnA.split('.').first.replaceFirst(RegExp(r'^\d+_'), '');
      final cleanStemB = fnB.split('.').first.replaceFirst(RegExp(r'^\d+_'), '');
      if (cleanStemA.isNotEmpty && cleanStemB.isNotEmpty && !genericStrings.contains(cleanStemA) && !genericStrings.contains(cleanStemB) && cleanStemA == cleanStemB) {
        return true;
      }
    }

    // 5. Image path match
    final pathA = (a['imagePath'] ?? a['file_path'] ?? '').toString().trim();
    final pathB = (b['imagePath'] ?? b['file_path'] ?? '').toString().trim();
    if (pathA.isNotEmpty && pathB.isNotEmpty && pathA == pathB) return true;

    final baseA = pathA.isNotEmpty ? pathA.split(RegExp(r'[/\\]')).last.toLowerCase() : fnA;
    final baseB = pathB.isNotEmpty ? pathB.split(RegExp(r'[/\\]')).last.toLowerCase() : fnB;
    if (baseA.isNotEmpty && baseB.isNotEmpty && !genericStrings.contains(baseA) && !genericStrings.contains(baseB) && (baseA == baseB || baseA == fnB || fnA == baseB)) {
      return true;
    }

    // 6. Preview URL match
    final urlA = (a['preview_url'] ?? '').toString().trim().toLowerCase();
    final urlB = (b['preview_url'] ?? '').toString().trim().toLowerCase();
    if (urlA.isNotEmpty && urlB.isNotEmpty && !urlA.contains('dummy') && urlA == urlB) return true;

    // 7. LR No match
    final lrA = (a['lrNo'] ?? (a['record'] is Map ? (a['record']['LR No *'] ?? a['record']['grno'] ?? a['record']['BNF LR No'] ?? '') : '')).toString().trim().toLowerCase();
    final lrB = (b['lrNo'] ?? (b['record'] is Map ? (b['record']['LR No *'] ?? b['record']['grno'] ?? b['record']['BNF LR No'] ?? '') : '')).toString().trim().toLowerCase();
    if (lrA.isNotEmpty && lrB.isNotEmpty && !genericLrs.contains(lrA) && !genericLrs.contains(lrB) && lrA == lrB) return true;

    return false;
  }

  List<Map<String, dynamic>> _deduplicateUploadList(List<Map<String, dynamic>> rawList) {
    final result = <Map<String, dynamic>>[];
    for (final item in rawList) {
      final fn = (item['fileName'] ?? item['filename'] ?? '').toString().toLowerCase();
      final id = (item['id'] ?? '').toString().toLowerCase();
      final lr = (item['lrNo'] ?? '').toString().toLowerCase();
      if (fn.contains('dummy') || id.contains('dummy') || lr.contains('dummy') ||
          fn.contains('nloiad273') || id.contains('nloiad273') || lr.contains('nloiad273')) {
        continue;
      }
      final existingIdx = result.indexWhere((existing) => _isSameLrUpload(existing, item));
      if (existingIdx < 0) {
        result.add(Map<String, dynamic>.from(item));
      } else {
        final existing = result[existingIdx];

        // 1. Maintain or adopt active item reference
        if (existing['item'] == null && item['item'] != null) {
          existing['item'] = item['item'];
        }

        // 2. Unify stable ID
        if ((existing['id'] ?? '').toString().isEmpty && (item['id'] ?? '').toString().isNotEmpty) {
          existing['id'] = item['id'];
        }

        // 3. Status & verified state preservation
        final existingVerified = existing['isVerified'] == true || existing['status'] == 'completed';
        final itemVerified = item['isVerified'] == true || item['status'] == 'completed';
        if (itemVerified || existingVerified) {
          existing['status'] = 'completed';
          existing['isVerified'] = true;
        }

        // 4. Merge record data so verified fields are preserved
        final existingRec = existing['record'] is Map
            ? Map<String, dynamic>.from(existing['record'] as Map)
            : <String, dynamic>{};
        final itemRec = item['record'] is Map
            ? Map<String, dynamic>.from(item['record'] as Map)
            : (item['data'] is Map ? Map<String, dynamic>.from(item['data'] as Map) : <String, dynamic>{});
        existingRec.addAll(itemRec);
        if (existingRec.isNotEmpty) {
          existing['record'] = existingRec;
        }

        // 5. Update preview & LR identifiers
        if ((existing['preview_path'] ?? '').toString().isEmpty && (item['preview_path'] ?? '').toString().isNotEmpty) {
          existing['preview_path'] = item['preview_path'];
        }
        if ((existing['preview_image'] ?? '').toString().isEmpty && (item['preview_image'] ?? '').toString().isNotEmpty) {
          existing['preview_image'] = item['preview_image'];
        }
        if ((existing['preview_url'] ?? '').toString().isEmpty && (item['preview_url'] ?? '').toString().isNotEmpty) {
          existing['preview_url'] = item['preview_url'];
        }
        if ((existing['lrNo'] ?? '').toString().isEmpty && (item['lrNo'] ?? '').toString().isNotEmpty) {
          existing['lrNo'] = item['lrNo'];
        }
      }
    }
    return result;
  }

  Future<void> _loadRecentUploads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dismissedList = prefs.getStringList('bnf_dismissed_recent_lrs') ?? <String>[];
      const generic = {'lr document', 'document', 'item', 'null', 'none', 'undefined', ''};
      _dismissedRecentLrs = Set<String>.from(dismissedList.where((s) => !generic.contains(s.trim().toLowerCase())));

      final mob = widget.controller.activeUserMobile ?? prefs.getString('bnf_user_mobile') ?? _userMobile;
      if (mob.isNotEmpty) {
        final cloudData = await UserCloudService.instance.fetchUserCloudData(mob, baseUrl: widget.controller.geminiService.serverUrl);
        if (cloudData != null && cloudData['dismissed_uploads'] is List) {
          final srvDismissed = (cloudData['dismissed_uploads'] as List)
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty && !generic.contains(s.toLowerCase()));
          _dismissedRecentLrs.addAll(srvDismissed);
          await prefs.setStringList('bnf_dismissed_recent_lrs', _dismissedRecentLrs.toList());
        }
      }

      final raw = prefs.getString('bnf_recent_uploaded_lrs');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final rawMaps = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        final filtered = rawMaps.where((m) => !_isItemDismissed(m)).toList();
        final deduped = _deduplicateUploadList(filtered).map(_cleanItemForStorage).toList();
        await prefs.setString('bnf_recent_uploaded_lrs', jsonEncode(deduped));
        widget.controller.setPreviousUploadsCache(deduped);
        if (mounted) {
          setState(() {
            _persistedRecentLrs = deduped;
          });
        }
      }
      // Async sync from server /api/previous-uploads (respecting dismissed history items)
      widget.controller.syncPreviousUploadsFromServer().then((uploads) async {
        if (uploads.isNotEmpty && mounted) {
          _syncLoadedUploads(uploads);
        }
      }).catchError((_) {});
    } catch (_) {}
  }

  void _syncLoadedUploads(List<Map<String, dynamic>> uploads, {Set<String>? dismissed}) {
    try {
      final list = <Map<String, dynamic>>[];
      for (final srv in uploads) {
        final fn = (srv['filename'] ?? srv['fileName'] ?? '').toString();
        final id = (srv['id'] ?? srv['file_id'] ?? '').toString();
        if (fn.toLowerCase().contains('dummy') || id.toLowerCase().contains('dummy')) continue;
        if (_isItemDismissed(srv) || _isItemDismissed(id) || _isItemDismissed(fn)) continue;
        if (dismissed != null && (dismissed.contains(id) || dismissed.contains(fn))) continue;
        list.add({
          'id': id,
          'fileName': fn,
          'saved_filename': srv['saved_filename'] ?? '',
          'imagePath': srv['file_path'] ?? srv['preview_url'] ?? fn,
          'lrNo': srv['lr_no'] ?? srv['lrNo'] ?? '',
          'isPdf': _toBoolean(srv['isPdf']) || fn.toLowerCase().endsWith('.pdf'),
          'createdAt': srv['createdAt'] ?? DateTime.now().toIso8601String(),
          'status': srv['status'] ?? 'completed',
          'isVerified': srv['isVerified'] == true || (srv['status'] ?? '') == 'completed',
          'preview_url': srv['preview_url'] ?? '',
          'preview_path': '',
          'preview_image': srv['preview_image'] ?? '',
          'record': srv['data'] ?? srv['record'] ?? {},
        });
      }
      final combined = <Map<String, dynamic>>[];
      combined.addAll(_persistedRecentLrs.where((r) => !_isItemDismissed(r)));
      combined.addAll(list);
      final deduped = _deduplicateUploadList(combined).map(_cleanItemForStorage).take(25).toList();
      widget.controller.setPreviousUploadsCache(deduped);
      SharedPreferences.getInstance().then((p) {
        p.setString('bnf_recent_uploaded_lrs', jsonEncode(deduped));
      });
      if (mounted) {
        setState(() {
          _persistedRecentLrs = deduped;
        });
      }
    } catch (_) {}
  }

  bool _toBoolean(dynamic val) {
    if (val == null) return false;
    if (val is bool) return val;
    return val.toString().toLowerCase() == 'true';
  }

  Future<void> _saveRecentUploads(List<BatchItem> currentItems) async {
    try {
      if (currentItems.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      Directory? docsDir;
      try {
        docsDir = await getApplicationDocumentsDirectory();
      } catch (_) {}

      final list = <Map<String, dynamic>>[];
      final toUndismiss = <String>{};
      for (final item in currentItems) {
        // Active upload/verified session item: clear any prior dismissal so it appears in history
        _dismissedRecentLrs.remove(item.id);
        _dismissedRecentLrs.remove(item.fileName);
        toUndismiss.add(item.id);
        toUndismiss.add(item.fileName);
        final sv = item.record['saved_filename']?.toString();
        if (sv != null && sv.isNotEmpty) {
          _dismissedRecentLrs.remove(sv);
          toUndismiss.add(sv);
        }
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
          'saved_filename': item.record['saved_filename'] ?? '',
          'imagePath': item.imagePath,
          'lrNo': item.record['LR No *'] ?? item.record['grno'] ?? item.record['BNF LR No'] ?? '',
          'isPdf': item.fileName.toLowerCase().endsWith('.pdf') || item.imagePath.toLowerCase().endsWith('.pdf'),
          'createdAt': item.createdAt.toIso8601String(),
          'status': item.status.name,
          'isVerified': item.isVerified,
          'preview_url': item.record['preview_url'] ?? '',
          'preview_path': previewPath,
          'record': _cleanItemForStorage(item.record)['record'] ?? _cleanItemForStorage(item.record),
        });
      }

      await prefs.setStringList('bnf_dismissed_recent_lrs', _dismissedRecentLrs.toList());
      final mob = widget.controller.activeUserMobile ?? _userMobile;
      if (mob.isNotEmpty && toUndismiss.isNotEmpty) {
        UserCloudService.instance.undismissCloudUpload(
          mob,
          toUndismiss.toList(),
          baseUrl: widget.controller.geminiService.serverUrl,
        ).catchError((_) => false);
      }

      final combined = [...list, ..._persistedRecentLrs.where((r) => !_isItemDismissed(r))];
      final toSave = _deduplicateUploadList(combined).map(_cleanItemForStorage).take(25).toList();
      await prefs.setString('bnf_recent_uploaded_lrs', jsonEncode(toSave));
      widget.controller.setPreviousUploadsCache(toSave);
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
    final hasPerm = await widget.controller.permissionService.requestCameraPermission();
    if (!hasPerm) {
      if (mounted) {
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
      }
      return;
    }

    if (!mounted) return;
    final List<String>? capturedPages = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => const CameraScanScreen(),
      ),
    );

    if (capturedPages == null || capturedPages.isEmpty) {
      return;
    }

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
      success = await widget.controller.addMultiPageScan(capturedPages);
    } finally {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    }

    if (!success) {
      return;
    }

    // If new item was added, automatically open Screen 4: Edit View
    if (mounted && widget.controller.items.length > countBefore) {
      final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
      if (!isCurrent) return;
      final newItem = widget.controller.items.last;
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
      // Enforce upload of only 1 LR at a time matching Web
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf', 'webp'],
      );

      if (file == null) return;

      // Validate maximum size of 10 MB per file matching Web showFileSizeValidationModal
      final size = file.lengthSync() ?? (await file.length()) ?? (file.path != null && File(file.path!).existsSync() ? File(file.path!).lengthSync() : 0);
      if (size > 10 * 1024 * 1024) {
        if (mounted) {
          final sizeMb = (size / (1024 * 1024)).toStringAsFixed(2);
          showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 28),
                  SizedBox(width: 8),
                  Text('File Size Validation', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Limit Exceeded',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'File "${file.name}" ($sizeMb MB) exceeds the allowed limit of 10 MB per file. Please choose a file smaller than 10 MB.',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0F172A)),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
        return;
      }

      final path = await _resolvePlatformFilePath(file);
      if (path == null || path.isEmpty) return;

      final countBefore = widget.controller.items.length;

      if (mounted) {
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => OcrProcessingDialog(controller: widget.controller),
        );
      }

      try {
        await widget.controller.addFilePaths([path]);
      } finally {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      }

      // If new item was added, open Step 2: LR & Master Verification
      if (mounted && widget.controller.items.length > countBefore) {
        final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
        if (!isCurrent) return;
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
        final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
        if (!isCurrent) return;
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
    // 1. Try base64 decoded bytes from previewImage (instant 300 DPI preview)
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

    // 2. Try network URL (300 DPI preview from server)
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

    // 3. Try saved/resolved preview path on local disk
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
        final List<Map<String, dynamic>> rawDisplayList = [];
        // 1. Current active batch items (skipping any dismissed from history strip)
        for (final i in items) {
          if (_isItemDismissed(i)) continue;
          final fn = i.fileName.toLowerCase();
          final id = i.id.toLowerCase();
          final lr = (i.record['LR No *'] ?? i.record['grno'] ?? i.record['BNF LR No'] ?? '').toLowerCase();
          if (!fn.contains('dummy') && !id.contains('dummy') &&
              !fn.contains('nloiad273') && !id.contains('nloiad273') && !lr.contains('nloiad273')) {
            rawDisplayList.add({
              'id': i.id,
              'fileName': i.fileName,
              'imagePath': i.imagePath,
              'lrNo': i.record['LR No *'] ?? i.record['grno'] ?? i.record['BNF LR No'] ?? '',
              'isPdf': i.fileName.toLowerCase().endsWith('.pdf') || i.imagePath.toLowerCase().endsWith('.pdf'),
              'createdAt': i.createdAt.toIso8601String(),
              'status': i.status.name,
              'isVerified': i.isVerified,
              'preview_image': i.record['preview_image'] ?? '',
              'preview_url': i.record['preview_url'] ?? '',
              'preview_path': i.record['preview_path'] ?? '',
              'item': i,
              'record': i.record,
            });
          }
        }
        // 2. Merged with persisted & server previous uploads (skipping dismissed)
        rawDisplayList.addAll(_persistedRecentLrs.where((r) => !_isItemDismissed(r)));
        final displayRecent = _deduplicateUploadList(rawDisplayList);

        return Scaffold(
          backgroundColor: const Color(0xFFF1F5F9),
          drawer: Drawer(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                UserAccountsDrawerHeader(
                  decoration: const BoxDecoration(color: brandNavy),
                  accountName: Text(
                    'User: $_userName',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  accountEmail: Text(
                    _userMobile.isNotEmpty ? _userMobile : 'Logistics User',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  currentAccountPicture: GestureDetector(
                    onLongPress: () {
                      Navigator.of(context).pop();
                      _showServerConfigDialog(context);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: const Center(
                        child: Text('BNF', style: TextStyle(color: brandNavy, fontWeight: FontWeight.w900, fontSize: 20)),
                      ),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.home_outlined, color: brandNavy),
                  title: const Text('Home', style: TextStyle(fontWeight: FontWeight.w600)),
                  onTap: () => Navigator.of(context).pop(),
                ),
                ListTile(
                  leading: const Icon(Icons.history_outlined, color: brandBlue),
                  title: const Text('LR History', style: TextStyle(fontWeight: FontWeight.w600)),
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ExcelPreviewScreen(controller: widget.controller, initialTab: 1),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.format_list_bulleted, color: Color(0xFF059669)),
                  title: const Text('LR List', style: TextStyle(fontWeight: FontWeight.w600)),
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => BatchQueueScreen(controller: widget.controller),
                      ),
                    );
                  },
                ),
                const Divider(),
                ListTile(
                  key: const Key('drawer_logout_btn'),
                  leading: const Icon(Icons.logout, color: Colors.red),
                  title: const Text(
                    'Logout',
                    style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    _logout();
                  },
                ),
              ],
            ),
          ),
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 1,
            titleSpacing: 0,
            leading: Builder(
              builder: (ctx) => IconButton(
                key: const Key('hamburger_menu_btn'),
                icon: const Icon(Icons.menu, color: brandNavy),
                tooltip: 'Navigation Menu',
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
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
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(42),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Row(
                  children: [
                    // History Button directly below page title
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
                  ],
                ),
              ),
            ),
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
                        'Upload LR',
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
                                'Supported formats: JPG, PNG, PDF',
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
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x06000000),
                                blurRadius: 6,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Fixed Section Heading & Count Badge at Top
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Row(
                                      children: [
                                        Icon(Icons.history, size: 16, color: Color(0xFF0284C7)),
                                        SizedBox(width: 6),
                                        Text(
                                          'Previously Uploaded LRs',
                                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: brandNavy),
                                        ),
                                      ],
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF1F5F9),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: const Color(0xFFCBD5E1)),
                                      ),
                                      child: Text(
                                        '${displayRecent.length} files',
                                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF475569)),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F9)),
                              // Internally Scrollable Horizontal Card List
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                child: SizedBox(
                                  height: 154,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(horizontal: 12),
                                    physics: const BouncingScrollPhysics(),
                                    itemCount: displayRecent.length,
                                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                                    itemBuilder: (ctx, idx) {
                                      final itmData = displayRecent[idx];
                                      final isPdf = itmData['isPdf'] == true;
                                      final fileName = itmData['fileName']?.toString() ?? 'LR Document';
                                      final lrNo = itmData['lrNo']?.toString() ?? '';
                                      final imagePath = itmData['imagePath']?.toString() ?? '';
                                      final isVerified = _isItemVerified(itmData);
                                      final dt = DateTime.tryParse(itmData['createdAt']?.toString() ?? '') ?? DateTime.now();
                                      final previewImg = (itmData['preview_image'] ?? itmData['record']?['preview_image'])?.toString() ?? '';
                                      final previewPath = (itmData['preview_path'] ?? itmData['record']?['preview_path'])?.toString() ?? '';
                                      final previewUrl = (itmData['preview_url'] ?? itmData['record']?['preview_url'])?.toString() ?? '';

                                      return InkWell(
                                        onTap: () async {
                                  BatchItem targetItem;
                                  if (itmData['item'] is BatchItem) {
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
                                    final rawRecord = itmData['record'] ?? itmData['data'];
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
                                    if (itmData['preview_pages'] != null && !recordMap.containsKey('preview_pages')) {
                                      recordMap['preview_pages'] = itmData['preview_pages'] is List
                                          ? jsonEncode(itmData['preview_pages'])
                                          : itmData['preview_pages'].toString();
                                    }
                                    if (itmData['page_count'] != null && !recordMap.containsKey('page_count')) {
                                      recordMap['page_count'] = itmData['page_count'].toString();
                                    }
                                    if (itmData['saved_filename'] != null && !recordMap.containsKey('saved_filename')) {
                                      recordMap['saved_filename'] = itmData['saved_filename'].toString();
                                    }
                                    if (itmData['file_url'] != null && !recordMap.containsKey('file_url')) {
                                      recordMap['file_url'] = itmData['file_url'].toString();
                                    }

                                    final stableId = (itmData['id'] ?? '').toString().trim().isNotEmpty
                                        ? itmData['id'].toString().trim()
                                        : 'prev_${dt.millisecondsSinceEpoch}';
                                    itmData['id'] = stableId;

                                    targetItem = BatchItem(
                                      id: stableId,
                                      imagePath: cleanPath,
                                      fileName: fileName,
                                      status: isVerified ? BatchItemStatus.completed : BatchItemStatus.pending,
                                      createdAt: dt,
                                      record: recordMap,
                                    );
                                    itmData['item'] = targetItem;
                                  }

                                  // Web Parity (openPreviousUploadPreview): Match existing item to avoid duplicate LR records
                                  final existingIdx = widget.controller.items.indexWhere((i) {
                                    if (targetItem.id.isNotEmpty && i.id == targetItem.id) return true;
                                    if (targetItem.fileName.isNotEmpty && i.fileName.toLowerCase() == targetItem.fileName.toLowerCase()) return true;
                                    final tSaved = targetItem.record['saved_filename'];
                                    final iSaved = i.record['saved_filename'];
                                    if (tSaved != null && tSaved.isNotEmpty && tSaved == iSaved) return true;
                                    final tLr = targetItem.resolveField('LR No *');
                                    final iLr = i.resolveField('LR No *');
                                    if (tLr.isNotEmpty && tLr == iLr) return true;
                                    return false;
                                  });

                                  if (existingIdx != -1) {
                                    // Enrich existing item with any missing preview URLs or image data
                                    final existing = widget.controller.items[existingIdx];
                                    final mergedRecord = Map<String, String>.from(existing.record);
                                    for (final entry in targetItem.record.entries) {
                                      if (entry.value.trim().isNotEmpty && (!mergedRecord.containsKey(entry.key) || mergedRecord[entry.key]!.trim().isEmpty)) {
                                        mergedRecord[entry.key] = entry.value.trim();
                                      }
                                    }
                                    final enrichedItem = existing.copyWith(
                                      record: mergedRecord,
                                      status: (isVerified || existing.isVerified) ? BatchItemStatus.completed : existing.status,
                                      imagePath: (existing.imagePath.isEmpty || !File(existing.imagePath).existsSync()) && targetItem.imagePath.isNotEmpty && File(targetItem.imagePath).existsSync()
                                          ? targetItem.imagePath
                                          : existing.imagePath,
                                    );
                                    widget.controller.updateItem(enrichedItem);
                                    targetItem = enrichedItem;
                                    itmData['item'] = enrichedItem;
                                  } else {
                                    widget.controller.addItemDirectly(targetItem);
                                    itmData['item'] = targetItem;
                                  }

                                  // Synchronize in-place with _persistedRecentLrs
                                  final pIdx = _persistedRecentLrs.indexWhere((p) => _isSameLrUpload(p, itmData));
                                  if (pIdx != -1) {
                                    _persistedRecentLrs[pIdx]['item'] = targetItem;
                                    _persistedRecentLrs[pIdx]['id'] = targetItem.id;
                                    if (isVerified) {
                                      _persistedRecentLrs[pIdx]['status'] = 'completed';
                                      _persistedRecentLrs[pIdx]['isVerified'] = true;
                                    }
                                  }

                                  if (context.mounted) {
                                    // Pre-warm preview image and open directly into Step 2: LR & Master Verification
                                    BillingImageViewer.prewarm(
                                      targetItem,
                                      context,
                                      widget.controller.geminiService.serverUrl,
                                    );
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
                                          height: 154,
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
                                                // Top Visual Thumbnail Section (80px)
                                                SizedBox(
                                                  height: 80,
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
                                                      // Delete Button ONLY (Top-Right, Unobstructed)
                                                      Positioned(
                                                        top: 5,
                                                        right: 5,
                                                        child: GestureDetector(
                                                          behavior: HitTestBehavior.opaque,
                                                          onTap: () => _deleteRecentUploadItem(idx, itmData),
                                                          child: Container(
                                                            padding: const EdgeInsets.all(4.0),
                                                            decoration: BoxDecoration(
                                                              color: Colors.white.withAlpha(240),
                                                              shape: BoxShape.circle,
                                                              border: Border.all(color: const Color(0xFFCBD5E1), width: 0.8),
                                                              boxShadow: const [
                                                                BoxShadow(color: Color(0x1A000000), blurRadius: 2),
                                                              ],
                                                            ),
                                                            child: const Icon(Icons.close, size: 14, color: Color(0xFF475569)),
                                                          ),
                                                        ),
                                                      ),
                                                      // PDF Type Indicator Badge (Top-Left)
                                                      if (isPdf)
                                                        Positioned(
                                                          top: 5,
                                                          left: 5,
                                                          child: Container(
                                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                                            decoration: BoxDecoration(
                                                              color: Colors.red.shade700.withAlpha(235),
                                                              borderRadius: BorderRadius.circular(4),
                                                            ),
                                                            child: const Text(
                                                              'PDF',
                                                              style: TextStyle(
                                                                color: Colors.white,
                                                                fontSize: 8.5,
                                                                fontWeight: FontWeight.bold,
                                                                letterSpacing: 0.3,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      // Status Badge (Bottom-Right of Thumbnail, Zero Collision)
                                                      Positioned(
                                                        bottom: 5,
                                                        right: 5,
                                                        child: Container(
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
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                // Bottom Metadata Section (74px)
                                                Expanded(
                                                  child: Padding(
                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                                    child: Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                      children: [
                                                        Column(
                                                          crossAxisAlignment: CrossAxisAlignment.start,
                                                          children: [
                                                            Text(
                                                              lrNo.isNotEmpty ? (lrNo.startsWith('LR') ? lrNo : 'LR: $lrNo') : fileName,
                                                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: brandNavy),
                                                              maxLines: 1,
                                                              overflow: TextOverflow.ellipsis,
                                                            ),
                                                            const SizedBox(height: 1),
                                                            Text(
                                                              fileName,
                                                              style: const TextStyle(fontSize: 9.5, color: Color(0xFF64748B)),
                                                              maxLines: 1,
                                                              overflow: TextOverflow.ellipsis,
                                                            ),
                                                          ],
                                                        ),
                                                        Text(
                                                          '${dt.day}/${dt.month} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}',
                                                          style: const TextStyle(fontSize: 8.5, color: Color(0xFF94A3B8)),
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
                              ),
                            ],
                          ),
                        ),
                      ],
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
                    hintText: 'http://192.168.1.5:8000',
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
