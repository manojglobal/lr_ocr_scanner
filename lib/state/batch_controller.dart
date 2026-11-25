import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/user_cloud_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../config/document_schema.dart';
import '../models/batch_item.dart';
import '../models/extraction_result.dart';
import '../services/excel_service.dart';
import '../services/format_parser.dart';
import '../services/gemini_backend_service.dart';
import '../services/image_service.dart';
import '../services/image_preprocessor.dart';
import '../services/lr_multi_page_validator.dart';
import '../services/ocr_service.dart';
import '../services/permission_service.dart';
import '../services/file_lifecycle_service.dart';
import '../services/master_data_service.dart';
import '../services/pdf_assembler_service.dart';
import '../services/app_config_service.dart';

/// Central state management controller for the multi-image OCR-to-Excel pipeline.
class BatchProcessingController extends ChangeNotifier {
  final PermissionService _permissionService;
  final ImageService _imageService;
  final OcrService _ocrService;
  final FormatParserService _parserService;
  final ExcelService _excelService;
  final GeminiBackendService _geminiService;
  final Uuid _uuid;

  List<BatchItem> _items = [];
  bool _isProcessing = false;
  bool _useGeminiBackend = false;
  DocumentSchema _currentSchema = DocumentSchema.active;
  String? _lastExportedPath;
  String? _statusMessage;
  bool _isDisposed = false;
  final List<BatchItem> _deletedItems = [];
  String? _activeUserMobile;
  String? _activeUserName;
  String? _activeSessionToken;
  Timer? _cloudSyncTimer;
  Completer<void>? _processingCompleter;
  final Set<String> _completedItemIds = {};

  /// Normalizes user identifier (mobile digits preferred, falling back to userId).
  static String resolveUserKey(String? mobile, {String? userId}) {
    final cleanMob = (mobile ?? '').replaceAll(RegExp(r'\D'), '');
    if (cleanMob.isNotEmpty) return cleanMob;
    final cleanId = (userId ?? '').trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return cleanId;
  }

  /// Scopes a SharedPreferences cache key by the active user's mobile/userId.
  static String scopedStorageKey(String baseKey, String? mobile, {String? userId}) {
    final userKey = resolveUserKey(mobile, userId: userId);
    if (userKey.isEmpty) return baseKey;
    return '${baseKey}_$userKey';
  }

  bool _canReadLegacyUnscoped(SharedPreferences prefs, String userKey) {
    if (userKey.isEmpty) return true;
    final owner = prefs.getString('bnf_cache_owner_mobile') ?? '';
    if (owner.isNotEmpty) return owner == userKey;
    final savedMob = resolveUserKey(prefs.getString('bnf_user_mobile'));
    return savedMob.isEmpty || savedMob == userKey;
  }

  BatchProcessingController({
    PermissionService? permissionService,
    ImageService? imageService,
    OcrService? ocrService,
    FormatParserService? parserService,
    ExcelService? excelService,
    GeminiBackendService? geminiService,
    Uuid? uuid,
    bool useGeminiBackend = true,
  })  : _permissionService = permissionService ?? PermissionService(),
        _imageService = imageService ?? ImageService(),
        _ocrService = ocrService ?? OcrService(),
        _parserService = parserService ?? FormatParserService(),
        _excelService = excelService ?? ExcelService(),
        _geminiService = geminiService ?? GeminiBackendService(),
        _uuid = uuid ?? const Uuid(),
        // ignore: prefer_initializing_formals
        _useGeminiBackend = useGeminiBackend {
    // Automated 30-day snapshot and data retention purge
    FileLifecycleService.instance.purgeLocalSnapshotsOlderThan(days: 30);
    _purgeOldItems();
    _loadSavedSession();
    MasterDataService.instance.fetchMasterDataFromBackend(baseUrl: AppConfigService.instance.baseUrl);
  }

  void _purgeOldItems() {
    final now = DateTime.now();
    _items.removeWhere((i) => now.difference(i.createdAt).inDays >= 30);
    _deletedItems.removeWhere((i) => now.difference(i.createdAt).inDays >= 30);
  }

  bool _fallbackNotificationPending = false;
  String? _fallbackNoticeMessage;
  bool _invalidLrNoticePending = false;
  String? _invalidLrNoticeMessage;
  bool _multipleLrsNoticePending = false;
  String? _multipleLrsNoticeMessage;
  bool _pageLimitNoticePending = false;
  String? _pageLimitNoticeMessage;

  bool get multipleLrsNoticePending => _multipleLrsNoticePending;
  String? get multipleLrsNoticeMessage => _multipleLrsNoticeMessage;
  bool get pageLimitNoticePending => _pageLimitNoticePending;
  String? get pageLimitNoticeMessage => _pageLimitNoticeMessage;

  void triggerPageLimitNotice([String? message]) {
    _pageLimitNoticePending = true;
    _pageLimitNoticeMessage = message ?? 'Maximum 15 pages are allowed per upload. Please upload documents containing 15 pages or fewer.';
    notifyListeners();
  }

  void acknowledgePageLimitNotice() {
    _pageLimitNoticePending = false;
    _pageLimitNoticeMessage = null;
  }

  void triggerMultipleLrsNotice([String? message]) {
    _multipleLrsNoticePending = true;
    _multipleLrsNoticeMessage = message ?? 'Multiple LR documents detected. Please upload documents belonging to only one LR at a time.';
    notifyListeners();
  }

  void acknowledgeMultipleLrsNotice() {
    _multipleLrsNoticePending = false;
    _multipleLrsNoticeMessage = null;
  }
  String? _lastInvalidLrId;
  String? _lastInvalidLrFileName;
  bool _connectionErrorNoticePending = false;
  String? _connectionErrorNoticeMessage;

  bool get invalidLrNoticePending => _invalidLrNoticePending;
  String? get invalidLrNoticeMessage => _invalidLrNoticeMessage;
  String? get lastInvalidLrId => _lastInvalidLrId;
  String? get lastInvalidLrFileName => _lastInvalidLrFileName;
  bool get connectionErrorNoticePending => _connectionErrorNoticePending;
  String? get connectionErrorNoticeMessage => _connectionErrorNoticeMessage;

  void triggerInvalidLrNotice(String message, {String? rejectedId, String? rejectedFileName}) {
    _invalidLrNoticePending = true;
    _invalidLrNoticeMessage = message;
    _lastInvalidLrId = rejectedId;
    _lastInvalidLrFileName = rejectedFileName;
    notifyListeners();
  }

  void acknowledgeInvalidLrNotice() {
    _invalidLrNoticePending = false;
    _invalidLrNoticeMessage = null;
    _lastInvalidLrId = null;
    _lastInvalidLrFileName = null;
  }

  /// Removes an invalid, rejected, or discarded upload from local history caches,
  /// SharedPreferences, and temp storage.
  void purgeFromPreviousUploads({
    String? id,
    String? fileName,
    String? imagePath,
    String? savedFilename,
  }) {
    final cleanId = id?.trim().toLowerCase() ?? '';
    final cleanFn = fileName?.trim().toLowerCase() ?? '';
    final cleanPath = imagePath?.trim().toLowerCase() ?? '';
    final cleanSaved = savedFilename?.trim().toLowerCase() ?? '';

    _previousUploadsCache.removeWhere((r) {
      final rId = (r['id'] ?? r['file_id'] ?? '').toString().trim().toLowerCase();
      final rFn = (r['fileName'] ?? r['filename'] ?? '').toString().trim().toLowerCase();
      final rPath = (r['imagePath'] ?? r['file_path'] ?? '').toString().trim().toLowerCase();
      final rSv = (r['saved_filename'] ?? '').toString().trim().toLowerCase();

      if (cleanId.isNotEmpty && rId.isNotEmpty && cleanId == rId) return true;
      if (cleanFn.isNotEmpty && rFn.isNotEmpty && cleanFn == rFn) return true;
      if (cleanPath.isNotEmpty && rPath.isNotEmpty && cleanPath == rPath) return true;
      if (cleanSaved.isNotEmpty && rSv.isNotEmpty && cleanSaved == rSv) return true;
      return false;
    });

    SharedPreferences.getInstance().then((p) {
      final userKey = resolveUserKey(_activeUserMobile ?? p.getString('bnf_user_mobile'));
      final recentKey = scopedStorageKey('bnf_recent_uploaded_lrs', userKey);
      p.setString(recentKey, jsonEncode(_previousUploadsCache));
    }).catchError((_) {});

    try {
      if (imagePath != null && imagePath.isNotEmpty) {
        if (cleanPath.contains('scans') && cleanPath.endsWith('.pdf')) {
          final f = File(imagePath);
          if (f.existsSync()) {
            f.deleteSync();
          }
        }
      }
    } catch (_) {}
  }

  /// Removes an unverified or pending LR record from active batch items (_items)
  /// and previous uploads cache. Guarantees that:
  /// 1. Unverified LRs are completely removed from Step 2 (EditBiltyScreen).
  /// 2. Already verified LRs (in Step 3 LR List) are strictly preserved and never deleted.
  /// 3. Returns true if an unverified item was matched and removed.
  bool removeUnverifiedItem({
    String? id,
    String? fileName,
    String? savedFilename,
    String? lrNo,
  }) {
    final cleanId = id?.trim().toLowerCase() ?? '';
    final cleanFn = fileName?.trim().toLowerCase() ?? '';
    final cleanSaved = savedFilename?.trim().toLowerCase() ?? '';
    final cleanLr = lrNo != null && lrNo.trim().isNotEmpty ? normalizeLrNo(lrNo) : '';

    const genericFns = {'lr document', 'document', 'item', 'image', 'upload', 'null', 'undefined', ''};

    // Find and remove matching UNVERIFIED item from _items
    final matchIndex = _items.indexWhere((item) {
      if (item.isVerified) return false; // Strictly protect verified LRs!

      final itemId = item.id.trim().toLowerCase();
      final itemFn = item.fileName.trim().toLowerCase();
      final itemSaved = (item.record['saved_filename'] ?? '').toString().trim().toLowerCase();
      final itemLr = normalizeLrNo(extractLrNoFromRecord(item.record));

      if (cleanId.isNotEmpty && itemId.isNotEmpty && cleanId == itemId) return true;
      if (cleanSaved.isNotEmpty && itemSaved.isNotEmpty && cleanSaved == itemSaved) return true;
      if (cleanFn.isNotEmpty && itemFn.isNotEmpty && !genericFns.contains(cleanFn) && cleanFn == itemFn) return true;
      if (cleanLr.isNotEmpty && itemLr.isNotEmpty && cleanLr == itemLr) return true;
      return false;
    });

    String? removedPath;
    if (matchIndex != -1) {
      final removed = _items.removeAt(matchIndex);
      removedPath = removed.imagePath;
    }

    purgeFromPreviousUploads(
      id: id,
      fileName: fileName,
      imagePath: removedPath,
      savedFilename: savedFilename,
    );

    notifyListeners();
    return matchIndex != -1;
  }

  void triggerConnectionErrorNotice(String message) {
    _connectionErrorNoticePending = true;
    _connectionErrorNoticeMessage = message;
    notifyListeners();
  }

  void acknowledgeConnectionErrorNotice() {
    _connectionErrorNoticePending = false;
    _connectionErrorNoticeMessage = null;
    notifyListeners();
  }
bool _duplicateNoticePending = false;
  String? _duplicateNoticeMessage;
  List<Map<String, dynamic>> _previousUploadsCache = [];

  int _currentOcrStep = 1;
  String _currentProcessingFileName = '';
  int _processingFileIndex = 1;
  int _processingTotalFiles = 1;
  bool _isProcessingMultiPage = false;
  BatchItem? _lastUploadedItem;

  // Getters
  List<BatchItem> get items => List.unmodifiable(_items);
  List<BatchItem> get deletedItems => List.unmodifiable(_deletedItems);
  List<Map<String, dynamic>> get previousUploadsCache => List.unmodifiable(_previousUploadsCache);
  bool get isProcessing => _isProcessing;
  bool get isProcessingMultiPage => _isProcessingMultiPage;
  BatchItem? get lastUploadedItem => _lastUploadedItem;
  bool get useGeminiBackend => _useGeminiBackend;
  bool get fallbackNotificationPending => _fallbackNotificationPending;
  String? get fallbackNoticeMessage => _fallbackNoticeMessage;
  bool get duplicateNoticePending => _duplicateNoticePending;
  String? get duplicateNoticeMessage => _duplicateNoticeMessage;
  int get currentOcrStep => _currentOcrStep;
  String get currentProcessingFileName => _currentProcessingFileName;
  int get processingFileIndex => _processingFileIndex;
  int get processingTotalFiles => _processingTotalFiles;

  void acknowledgeFallbackNotice() {
    _fallbackNotificationPending = false;
    _fallbackNoticeMessage = null;
    notifyListeners();
  }

  void triggerDuplicateNotice([String? message]) {
    _duplicateNoticePending = true;
    _duplicateNoticeMessage = message ?? 'This LR already exists. You cannot add the same LR multiple times.';
    notifyListeners();
  }

  void acknowledgeDuplicateNotice() {
    _duplicateNoticePending = false;
    _duplicateNoticeMessage = null;
    notifyListeners();
  }

  void setPreviousUploadsCache(List<Map<String, dynamic>> list) {
    _previousUploadsCache = list
        .where((m) =>
          m['error_code'] != 'INVALID_LR' &&
          m['isInvalidLr'] != true &&
          m['status'] != 'failed' &&
          m['status'] != 'pending'
        )
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// Computes a SHA-256 hash string for an image file.
  String computeImageHash(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        return sha256.convert(bytes).toString();
      }
    } catch (_) {}
    return path.split(RegExp(r'[/\\]')).last.toLowerCase();
  }

  /// Normalizes an LR number string for reliable duplicate detection:
  /// trims whitespace, removes non-alphanumeric punctuation, and converts to lowercase.
  static String normalizeLrNo(String? val) {
    if (val == null) return '';
    return val.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
  }

  /// Extracts the most prominent LR number candidate from an extracted record.
  static String extractLrNoFromRecord(Map<String, String>? record) {
    if (record == null || record.isEmpty) return '';
    final candidates = [
      record['LR No *'],
      record['grno (*)'],
      record['grno'],
      record['BNF LR No'],
      record['LR No'],
      record['lr_no'],
      record['lr no'],
      record['bilty no'],
      record['c note no'],
    ];
    for (final c in candidates) {
      if (c != null &&
          c.trim().isNotEmpty &&
          c.trim() != '-' &&
          c.trim().toLowerCase() != 'pending') {
        return c.trim();
      }
    }

    // Dynamic schema fuzzy key match
    for (final entry in record.entries) {
      final cleanK = entry.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
      if (cleanK == 'lrno' || cleanK == 'grno' || cleanK == 'bnflrno' || cleanK == 'lr' || cleanK == 'biltyno' || cleanK == 'lrnumber') {
        final val = entry.value.trim();
        if (val.isNotEmpty && val != '-' && val.toLowerCase() != 'pending') {
          return val;
        }
      }
    }
    return '';
  }

  static bool _isGenericFileName(String fn) {
    final lower = fn.trim().toLowerCase();
    if (lower.isEmpty) return true;
    if (lower.startsWith('image_picker') || lower.startsWith('scaled_')) {
      return true;
    }
    const genericNames = {
      'lr document',
      'document',
      'item',
      'image',
      'photo',
      'camera',
      'upload',
      'null',
      'none',
      'undefined',
    };
    return genericNames.contains(lower);
  }

  /// Determines whether a cached upload entry represents an explicitly verified LR.
  /// Unverified, pending, cancelled, or incomplete entries return false (Web parity).
  bool _isPreviousUploadVerified(Map<String, dynamic> prev) {
    if (prev['is_deleted'] == true || prev['isDeleted'] == true) return false;
    final status = (prev['status'] ?? '').toString().trim().toLowerCase();
    if (status == 'pending' || status == 'failed' || status == 'error') {
      return false;
    }
    if (prev['is_cancelled'] == true ||
        prev['is_cancelled']?.toString().toLowerCase() == 'true' ||
        prev['pending_verification'] == true ||
        prev['pending_verification']?.toString().toLowerCase() == 'true' ||
        prev['isVerified'] == false ||
        prev['is_verified'] == false ||
        prev['is_verified']?.toString().toLowerCase() == 'false') {
      return false;
    }

    final prevId = (prev['id'] ?? prev['file_id'] ?? '').toString().trim();
    final prevSaved = (prev['saved_filename'] ??
            (prev['record'] is Map ? prev['record']['saved_filename'] : null) ??
            '')
        .toString()
        .trim()
        .toLowerCase();
    final prevFn = (prev['fileName'] ?? prev['filename'] ?? '').toString().trim().toLowerCase();
    final prevLr = normalizeLrNo(
      (prev['lrNo'] ??
              prev['lr_no'] ??
              prev['grno'] ??
              (prev['record'] is Map
                  ? (prev['record']['LR No *'] ?? prev['record']['grno'] ?? '')
                  : '') ??
              (prev['data'] is Map
                  ? (prev['data']['LR No *'] ?? prev['data']['grno'] ?? '')
                  : ''))
          .toString(),
    );

    // Cross-check active batch items: if present in _items, trust live verification state.
    for (final item in _items) {
      if (item.isDeleted) continue;
      final itemSaved = (item.record['saved_filename'] ?? '').trim().toLowerCase();
      final itemFn = item.fileName.trim().toLowerCase();
      final itemLr = normalizeLrNo(extractLrNoFromRecord(item.record));
      final matches = (prevId.isNotEmpty && item.id == prevId) ||
          (prevSaved.isNotEmpty && itemSaved.isNotEmpty && prevSaved == itemSaved) ||
          (prevFn.isNotEmpty && !_isGenericFileName(prevFn) && prevFn == itemFn) ||
          (prevLr.isNotEmpty && prevLr != '0' && itemLr.isNotEmpty && prevLr == itemLr);
      if (matches) {
        return item.isVerified;
      }
    }

    final rawRec = prev['record'] is Map
        ? prev['record'] as Map
        : (prev['data'] is Map ? prev['data'] as Map : null);
    final explicitVerifiedFlag = prev['isVerified'] == true ||
        prev['is_verified'] == true ||
        prev['is_verified']?.toString().toLowerCase() == 'true';

    if (rawRec != null && rawRec.isNotEmpty) {
      final recMap = rawRec.map((k, v) => MapEntry(k.toString(), (v ?? '').toString()));
      if (recMap['pending_verification'] == 'true' ||
          recMap['is_verified'] == 'false' ||
          recMap['is_cancelled'] == 'true') {
        return false;
      }
      if (recMap['is_verified'] == 'true' || explicitVerifiedFlag) {
        return true;
      }
      return BatchItem(
        id: prevId.isNotEmpty ? prevId : 'prev_check',
        imagePath: '',
        fileName: '',
        createdAt: DateTime.now(),
        record: recMap,
      ).isVerified;
    }

    return explicitVerifiedFlag;
  }

  /// Removes stale matching UNVERIFIED items when the same unverified LR is re-uploaded.
  /// Strictly preserves all verified items.
  void _removeMatchingUnverifiedItems({
    String? excludeItemId,
    String? lrNo,
    String? imagePath,
    String? imageHash,
    String? fileName,
    String? savedFilename,
  }) {
    final normLr = normalizeLrNo(lrNo);
    final cleanLr = normLr == '0' ? '' : normLr;
    final cleanHash = (imageHash ?? '').trim();
    final cleanFn = (fileName ?? '').trim().toLowerCase();
    final cleanSaved = (savedFilename ?? '').trim().toLowerCase();
    final cleanPath = (imagePath ?? '').trim();

    _items.removeWhere((item) {
      if (excludeItemId != null && item.id == excludeItemId) return false;
      if (item.isVerified) return false;

      if (cleanLr.isNotEmpty) {
        final itemLr = normalizeLrNo(extractLrNoFromRecord(item.record));
        if (itemLr.isNotEmpty && itemLr != '0' && itemLr == cleanLr) {
          return true;
        }
      }
      if (cleanHash.isNotEmpty) {
        final itemHash = item.imageHash ?? computeImageHash(item.imagePath);
        if (itemHash.isNotEmpty && itemHash == cleanHash) {
          return true;
        }
      }
      final itemSaved = (item.record['saved_filename'] ?? '').trim().toLowerCase();
      if (cleanSaved.isNotEmpty && itemSaved.isNotEmpty && cleanSaved == itemSaved) {
        return true;
      }
      if (cleanFn.isNotEmpty && !_isGenericFileName(cleanFn)) {
        final itemFn = item.fileName.trim().toLowerCase();
        if (itemFn == cleanFn || (itemSaved.isNotEmpty && itemSaved == cleanFn)) {
          return true;
        }
      }
      if (cleanPath.isNotEmpty && item.imagePath == cleanPath) {
        return true;
      }
      return false;
    });
  }

  /// Checks whether a given LR number, image hash, or core details already exists
  /// among verified LRs in the active batch or previously uploaded verified LRs (Web parity).
  bool isDuplicate({
    String? lrNo,
    String? imagePath,
    String? imageHash,
    String? fileName,
    Map<String, String>? record,
    String? excludeItemId,
  }) {
    // 1. Resolve candidate LR No (exclude '0' so unnumbered LRs do not block each other).
    final rawCandidateLr = normalizeLrNo(lrNo ?? extractLrNoFromRecord(record));
    final candidateLr = rawCandidateLr == '0' ? '' : rawCandidateLr;

    // 2. Resolve candidate image hash
    final candidateHash = imageHash ?? (imagePath != null ? computeImageHash(imagePath) : '');

    // 3. Resolve candidate file name
    final candidateFileName = (fileName ?? (imagePath != null ? imagePath.split(RegExp(r'[/\\]')).last : '')).toLowerCase();

    // 4. Extract core composite fields
    final candidateCust = (record?['Customer Name *'] ?? record?['cngr *'] ?? '').trim().toLowerCase();
    final candidateCnge = (record?['cnge *'] ?? '').trim().toLowerCase();
    final candidateVeh = (record?['Vehicle No *'] ?? '').trim().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();

    // A. Check active batch items (skip deleted, self, and unverified/pending/cancelled items)
    for (final item in _items) {
      if (item.isDeleted) continue;
      if (excludeItemId != null && item.id == excludeItemId) continue;
      if (!item.isVerified) continue;

      // Tier 1: Check normalized LR number (most reliable)
      if (candidateLr.isNotEmpty) {
        final existingLr = normalizeLrNo(extractLrNoFromRecord(item.record));
        if (existingLr.isNotEmpty && existingLr != '0' && existingLr == candidateLr) {
          return true;
        }
      }

      // Tier 2: Check image content hash
      if (candidateHash.isNotEmpty) {
        final existingHash = item.imageHash ?? computeImageHash(item.imagePath);
        if (existingHash.isNotEmpty && existingHash == candidateHash) {
          return true;
        }
      }

      // Tier 3: Check identical file name or path
      if (candidateFileName.isNotEmpty && !_isGenericFileName(candidateFileName)) {
        final existingFn = item.fileName.toLowerCase();
        final existingSaved = (item.record['saved_filename'] ?? '').toLowerCase();
        if (existingFn == candidateFileName || (existingSaved.isNotEmpty && existingSaved == candidateFileName)) {
          return true;
        }
      }
      if (imagePath != null && imagePath.isNotEmpty && item.imagePath == imagePath) {
        return true;
      }

      // Tier 4: Core composite details (fallback if LR No is missing)
      if (candidateLr.isEmpty && candidateCust.isNotEmpty && candidateCnge.isNotEmpty) {
        final itemCust = (item.record['Customer Name *'] ?? item.record['cngr *'] ?? '').trim().toLowerCase();
        final itemCnge = (item.record['cnge *'] ?? '').trim().toLowerCase();
        final itemVeh = (item.record['Vehicle No *'] ?? '').trim().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();

        bool custMatch = itemCust.isNotEmpty && (itemCust == candidateCust || itemCust.contains(candidateCust) || candidateCust.contains(itemCust));
        bool cngeMatch = itemCnge.isNotEmpty && (itemCnge == candidateCnge || itemCnge.contains(candidateCnge) || candidateCnge.contains(itemCnge));
        bool vehMatch = candidateVeh.isNotEmpty && itemVeh.isNotEmpty && candidateVeh == itemVeh;

        if (custMatch && cngeMatch && (vehMatch || candidateVeh.isEmpty)) {
          return true;
        }
      }
    }

    // B. Check verified entries in previous uploads cache
    BatchItem? excludedItem;
    if (excludeItemId != null) {
      for (final i in _items) {
        if (i.id == excludeItemId) {
          excludedItem = i;
          break;
        }
      }
    }
    for (final prev in _previousUploadsCache) {
      if (excludeItemId != null) {
        final prevId = (prev['id'] ?? prev['file_id'] ?? '').toString();
        if (prevId == excludeItemId) continue;
        final exclSaved = (excludedItem?.record['saved_filename'] ?? '').trim().toLowerCase();
        final prevSaved = (prev['saved_filename'] ??
                (prev['record'] is Map ? prev['record']['saved_filename'] : '') ??
                '')
            .toString()
            .trim()
            .toLowerCase();
        if (exclSaved.isNotEmpty && prevSaved.isNotEmpty && exclSaved == prevSaved) {
          continue;
        }
      }
      if (!_isPreviousUploadVerified(prev)) continue;

      // Tier 1: Check LR number
      if (candidateLr.isNotEmpty) {
        final prevLr = normalizeLrNo((prev['lrNo'] ?? prev['lr_no'] ?? prev['grno'] ?? (prev['record'] is Map ? (prev['record']['LR No *'] ?? prev['record']['grno'] ?? '') : '')).toString());
        if (prevLr.isNotEmpty && prevLr != '0' && prevLr == candidateLr) {
          return true;
        }
      }

      // Tier 2: Check file name / saved filename / basename
      if (candidateFileName.isNotEmpty && !_isGenericFileName(candidateFileName)) {
        final prevFn = (prev['fileName'] ?? prev['filename'] ?? '').toString().toLowerCase();
        final prevSaved = (prev['saved_filename'] ?? (prev['record'] is Map ? prev['record']['saved_filename'] : '') ?? '').toString().toLowerCase();
        final prevPath = (prev['imagePath'] ?? prev['file_path'] ?? '').toString();
        final prevBase = prevPath.isNotEmpty ? prevPath.split(RegExp(r'[/\\]')).last.toLowerCase() : '';
        if (prevFn.isNotEmpty && (prevFn == candidateFileName || (prevSaved.isNotEmpty && prevSaved == candidateFileName))) {
          return true;
        }
        if (prevBase.isNotEmpty && !_isGenericFileName(prevBase) && prevBase == candidateFileName) {
          return true;
        }
      }

      // Tier 3: Check image path
      if (imagePath != null && imagePath.isNotEmpty) {
        final prevPath = (prev['imagePath'] ?? prev['file_path'] ?? '').toString();
        if (prevPath.isNotEmpty && prevPath == imagePath) {
          return true;
        }
      }
    }

    return false;
  }

  GeminiBackendService get geminiService => _geminiService;
  ExcelService get excelService => _excelService;
  DocumentSchema get currentSchema => _currentSchema;
  String? get lastExportedPath => _lastExportedPath;
  String? get statusMessage => _statusMessage;
  String? get activeUserMobile => _activeUserMobile;
  String? get activeUserName => _activeUserName;
  String? get activeSessionToken => _activeSessionToken;
  String? get sessionToken => _activeSessionToken;

  Future<void> _persistActiveBatchCache([String? explicitMobile]) async {
    final userKey = resolveUserKey(explicitMobile ?? _activeUserMobile);
    if (userKey.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bnf_cache_owner_mobile', userKey);
      final key = scopedStorageKey('bnf_active_batch', userKey);
      final encoded = _items.map((i) => i.toLocalJson()).toList();
      await prefs.setString(key, jsonEncode(encoded));
    } catch (_) {}
  }

  Future<void> _persistCompletedItemsCache([String? explicitMobile]) async {
    final userKey = resolveUserKey(explicitMobile ?? _activeUserMobile);
    if (userKey.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bnf_cache_owner_mobile', userKey);
      final key = scopedStorageKey('bnf_completed_items', userKey);
      await prefs.setStringList(key, _completedItemIds.toList());
    } catch (_) {}
  }

  Future<void> _persistRecentUploadsCache([String? explicitMobile]) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userKey = resolveUserKey(
        explicitMobile ?? _activeUserMobile ?? prefs.getString('bnf_user_mobile'),
      );
      final key = scopedStorageKey('bnf_recent_uploaded_lrs', userKey);
      if (userKey.isNotEmpty) {
        await prefs.setString('bnf_cache_owner_mobile', userKey);
      }
      await prefs.setString(key, jsonEncode(_previousUploadsCache));
    } catch (_) {}
  }

  Future<Set<String>> _readDismissedSet(SharedPreferences prefs, String mob) async {
    const generic = {'lr document', 'document', 'item', 'null', 'none', 'undefined', ''};
    final userKey = resolveUserKey(mob);
    final dismissedKey = scopedStorageKey('bnf_dismissed_recent_lrs', mob);
    final rawList = prefs.getStringList(dismissedKey) ??
        (_canReadLegacyUnscoped(prefs, userKey)
            ? (prefs.getStringList('bnf_dismissed_recent_lrs') ?? <String>[])
            : <String>[]);
    return rawList.where((s) => !generic.contains(s.trim().toLowerCase())).toSet();
  }

  Future<void> _addDismissedIdentifiers(Iterable<String> rawIds, {String? mobile}) async {
    const generic = {'lr document', 'document', 'item', 'null', 'none', 'undefined', ''};
    final cleaned = rawIds
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && !generic.contains(s.toLowerCase()))
        .toList();
    if (cleaned.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final mob = mobile ?? _activeUserMobile ?? prefs.getString('bnf_user_mobile') ?? '';
      final dismissedKey = scopedStorageKey('bnf_dismissed_recent_lrs', mob);
      final existing = (prefs.getStringList(dismissedKey) ?? <String>[]).toSet();
      existing.addAll(cleaned);
      await prefs.setStringList(dismissedKey, existing.toList());
    } catch (_) {}
  }

  Future<void> _loadScopedCachesFromPrefs(
    SharedPreferences prefs,
    String mob, {
    required bool allowLegacyMigration,
  }) async {
    final userKey = resolveUserKey(mob);
    if (userKey.isNotEmpty) {
      await prefs.setString('bnf_cache_owner_mobile', userKey);
    }

    // 1. Load completed/exported LR IDs
    final completedKey = scopedStorageKey('bnf_completed_items', mob);
    final completedList = prefs.getStringList(completedKey) ??
        (allowLegacyMigration && _canReadLegacyUnscoped(prefs, userKey)
            ? (prefs.getStringList('bnf_completed_items') ?? <String>[])
            : <String>[]);
    _completedItemIds
      ..clear()
      ..addAll(completedList);

    // 2. Load local active batch items (preserves exportedAt, editedAt, versions offline)
    final batchKey = scopedStorageKey('bnf_active_batch', mob);
    final batchRaw = prefs.getString(batchKey) ??
        (allowLegacyMigration && _canReadLegacyUnscoped(prefs, userKey)
            ? prefs.getString('bnf_active_batch')
            : null);
    if (batchRaw != null && batchRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(batchRaw) as List<dynamic>;
        final restored = <BatchItem>[];
        for (final entry in decoded) {
          if (entry is Map) {
            final item = BatchItem.fromLocalJson(Map<String, dynamic>.from(entry));
            if (!item.isDeleted && item.id.isNotEmpty && !_items.any((e) => e.id == item.id)) {
              if (item.isExported) _completedItemIds.add(item.id);
              restored.add(item);
            }
          }
        }
        if (restored.isNotEmpty) {
          _items.addAll(restored);
          _purgeOldItems();
        }
      } catch (_) {}
    }

    // 3. Load recent uploaded LRs cache
    final recentKey = scopedStorageKey('bnf_recent_uploaded_lrs', mob);
    final recentRaw = prefs.getString(recentKey) ??
        (allowLegacyMigration && _canReadLegacyUnscoped(prefs, userKey)
            ? prefs.getString('bnf_recent_uploaded_lrs')
            : null);
    if (recentRaw != null && recentRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(recentRaw) as List<dynamic>;
        _previousUploadsCache = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (_) {}
    }
  }

  /// True if the given LR has been exported and not subsequently modified.
  bool isItemExported(BatchItem item) {
    return item.isExported || _completedItemIds.contains(item.id);
  }

  /// Returns verified items eligible for Excel export.
  /// By default only unexported verified LRs are returned matching Web.
  List<BatchItem> getExportableVerifiedItems({bool includeAlreadyExported = false}) {
    return _items.where((item) {
      if (item.isDeleted || !item.isVerified) return false;
      if (includeAlreadyExported) return true;
      return !isItemExported(item);
    }).toList();
  }

  /// Marks the specified LR IDs as exported with a timestamp and syncs to storage & cloud.
  Future<void> markItemsAsExported(
    List<String> itemIds, {
    DateTime? exportedAt,
  }) async {
    if (itemIds.isEmpty) return;
    final targetIds = itemIds.toSet();
    final ts = exportedAt ?? DateTime.now();
    final iso = ts.toIso8601String();
    bool changed = false;

    for (int i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (targetIds.contains(item.id)) {
        final rec = Map<String, String>.from(item.record);
        rec['is_exported'] = 'true';
        rec['exported_at'] = iso;
        _items[i] = item.copyWith(record: rec, exportedAt: ts);
        _completedItemIds.add(item.id);
        changed = true;
      }
    }

    if (changed) {
      if (!_isDisposed) notifyListeners();
      await _persistCompletedItemsCache();
      await _persistActiveBatchCache();
      triggerCloudSync();
    }
  }

  bool _recordsDiffer(Map<String, String> a, Map<String, String> b) {
    const ignored = {'is_exported', 'exported_at', 'edited_at'};
    final keys = {...a.keys, ...b.keys}.where((k) => !ignored.contains(k));
    for (final k in keys) {
      if ((a[k] ?? '') != (b[k] ?? '')) return true;
    }
    return false;
  }

  Future<void> _loadSavedSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mob = prefs.getString('bnf_user_mobile');
      final name = prefs.getString('bnf_user_name');
      final token = prefs.getString('bnf_user_token') ?? prefs.getString('bnf_session_token');
      if (mob != null && mob.trim().isNotEmpty) {
        _activeUserMobile = mob.trim();
        _activeUserName = name ?? _activeUserName;
        _activeSessionToken = token;
        await _loadScopedCachesFromPrefs(prefs, _activeUserMobile!, allowLegacyMigration: true);
        if (!_isDisposed) notifyListeners();
        await hydrateFromCloud();
      }
    } catch (_) {}
  }


  Map<String, dynamic> _cleanDocForStorage(Map<String, dynamic> doc) {
    final clean = Map<String, dynamic>.from(doc);
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

  bool _matchesIdentifierSet(Map<String, dynamic> doc, Set<String> identifiers) {
    if (identifiers.isEmpty) return false;
    final lowerSet = identifiers.map((s) => s.trim().toLowerCase()).toSet();
    final id = (doc['id'] ?? doc['file_id'] ?? '').toString().trim();
    final fn = (doc['filename'] ?? doc['fileName'] ?? '').toString().trim();
    final sv = (doc['saved_filename'] ?? '').toString().trim();
    const generic = {'lr document', 'document', 'item', 'null', 'none', 'undefined', ''};
    if (id.isNotEmpty && !generic.contains(id.toLowerCase()) && (identifiers.contains(id) || lowerSet.contains(id.toLowerCase()))) return true;
    if (fn.isNotEmpty && !generic.contains(fn.toLowerCase()) && (identifiers.contains(fn) || lowerSet.contains(fn.toLowerCase()))) return true;
    if (sv.isNotEmpty && !generic.contains(sv.toLowerCase()) && (identifiers.contains(sv) || lowerSet.contains(sv.toLowerCase()))) return true;
    return false;
  }

  /// Resolves timestamp/version/verification conflicts between local and cloud BatchItem.
  BatchItem _resolveCloudConflict(BatchItem local, BatchItem cloud) {
    final localTs = local.editedAt ?? local.createdAt;
    final cloudTs = cloud.editedAt ?? cloud.createdAt;

    BatchItem winner;
    if (cloudTs.isAfter(localTs)) {
      winner = cloud;
    } else if (localTs.isAfter(cloudTs)) {
      winner = local;
    } else if (cloud.currentVersion != local.currentVersion) {
      winner = cloud.currentVersion > local.currentVersion ? cloud : local;
    } else if (cloud.isVerified != local.isVerified) {
      winner = cloud.isVerified ? cloud : local;
    } else {
      winner = local;
    }

    // Preserve exportedAt if either side exported more recently than the winner's last edit
    final winnerEdited = winner.editedAt ?? winner.createdAt;
    DateTime? latestValidExport = winner.exportedAt;
    for (final candidate in [local, cloud]) {
      final exp = candidate.exportedAt;
      if (exp != null && !exp.isBefore(winnerEdited)) {
        if (latestValidExport == null || exp.isAfter(latestValidExport)) {
          latestValidExport = exp;
        }
      }
    }

    if (latestValidExport != null && winner.exportedAt == null && winner.record['is_exported'] != 'false') {
      final mergedRec = Map<String, String>.from(winner.record);
      mergedRec['is_exported'] = 'true';
      mergedRec['exported_at'] = latestValidExport.toIso8601String();
      return winner.copyWith(record: mergedRec, exportedAt: latestValidExport);
    }
    return winner;
  }

  /// Hydrates active batch and previous uploads from shared cloud JSON DB (/api/user-cloud-storage)
  Future<void> hydrateFromCloud() async {
    final mob = _activeUserMobile;
    if (mob == null || mob.trim().isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final userKey = resolveUserKey(mob);
      if (userKey.isNotEmpty) {
        await prefs.setString('bnf_cache_owner_mobile', userKey);
      }

      final cloudData = await UserCloudService.instance.fetchUserCloudData(mob, baseUrl: _geminiService.serverUrl);
      if (_isDisposed || _activeUserMobile != mob) return;
      if (cloudData != null) {
        // Synchronize dismissed tombstones first (scoped by active user)
        const generic = {'lr document', 'document', 'item', 'null', 'none', 'undefined', ''};
        final dismissedKey = scopedStorageKey('bnf_dismissed_recent_lrs', mob);
        final dismissed = await _readDismissedSet(prefs, mob);
        if (cloudData['dismissed_uploads'] is List) {
          final serverDismissed = (cloudData['dismissed_uploads'] as List)
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty && !generic.contains(s.toLowerCase()));
          dismissed.addAll(serverDismissed);
          await prefs.setStringList(dismissedKey, dismissed.toList());
        }

        // Sync completed exported IDs if provided by cloud
        if (cloudData['completed_items'] is List) {
          for (final cid in (cloudData['completed_items'] as List)) {
            final clean = cid.toString().trim();
            if (clean.isNotEmpty) _completedItemIds.add(clean);
          }
        }

        // 1. Hydrate active batch with conflict resolution & deleted filtering
        bool pushLocalWinnerToCloud = false;
        if (cloudData['active_batch'] is List) {
          final cloudList = (cloudData['active_batch'] as List);
          bool batchChanged = false;
          for (final rawDoc in cloudList) {
            if (rawDoc is Map) {
              final docMap = Map<String, dynamic>.from(rawDoc);
              if (docMap['is_deleted'] == true || docMap['isDeleted'] == true) {
                continue;
              }
              final cloudItem = BatchItem.fromCloudDoc(docMap);
              if (_deletedItems.any((d) => d.id == cloudItem.id)) {
                continue;
              }
              final existingIdx = _items.indexWhere((i) =>
                  i.id == cloudItem.id ||
                  (cloudItem.record['saved_filename'] != null &&
                      cloudItem.record['saved_filename']!.isNotEmpty &&
                      i.record['saved_filename'] == cloudItem.record['saved_filename']));
              if (existingIdx == -1) {
                _items.add(cloudItem);
                if (cloudItem.isExported) {
                  _completedItemIds.add(cloudItem.id);
                }
                batchChanged = true;
              } else {
                final localItem = _items[existingIdx];
                final resolved = _resolveCloudConflict(localItem, cloudItem);
                if (!identical(resolved, localItem)) {
                  _items[existingIdx] = resolved;
                  if (resolved.isExported) {
                    _completedItemIds.add(resolved.id);
                  } else {
                    _completedItemIds.remove(resolved.id);
                  }
                  batchChanged = true;
                } else if (localItem.editedAt != null &&
                    (cloudItem.editedAt == null || localItem.editedAt!.isAfter(cloudItem.editedAt!))) {
                  pushLocalWinnerToCloud = true;
                }
              }
            }
          }
          if (batchChanged) {
            await _persistActiveBatchCache(mob);
            await _persistCompletedItemsCache(mob);
            if (!_isDisposed) notifyListeners();
          }
          if (pushLocalWinnerToCloud) {
            triggerCloudSync();
          }
        }

        // 2. Cache uploaded LRs from cloud into user-scoped SharedPreferences
        if (cloudData['uploaded_lrs'] is List && (cloudData['uploaded_lrs'] as List).isNotEmpty) {
          final cloudUploads = (cloudData['uploaded_lrs'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final filteredCloud = cloudUploads.where((u) => !_matchesIdentifierSet(u, dismissed)).toList();

          final mergedUploads = <Map<String, dynamic>>[...filteredCloud];
          for (final local in _previousUploadsCache) {
            if (_matchesIdentifierSet(local, dismissed)) continue;
            final lId = (local['id'] ?? local['file_id'] ?? '').toString().trim();
            final lFn = (local['fileName'] ?? local['filename'] ?? '').toString().trim().toLowerCase();
            final lSv = (local['saved_filename'] ?? '').toString().trim().toLowerCase();
            final matchIdx = mergedUploads.indexWhere((m) {
              final mId = (m['id'] ?? m['file_id'] ?? '').toString().trim();
              final mSv = (m['saved_filename'] ?? '').toString().trim().toLowerCase();
              final mFn = (m['filename'] ?? m['fileName'] ?? '').toString().trim().toLowerCase();
              if (lId.isNotEmpty && mId.isNotEmpty && lId == mId) return true;
              if (lSv.isNotEmpty && mSv.isNotEmpty && lSv == mSv) return true;
              if (lFn.isNotEmpty && mFn.isNotEmpty && !generic.contains(lFn) && !generic.contains(mFn) && lFn == mFn) return true;
              return false;
            });
            if (matchIdx == -1) {
              mergedUploads.add(local);
            } else {
              // Timestamp/version resolution for uploaded_lrs metadata too
              final cloudEntry = mergedUploads[matchIdx];
              final lTs = DateTime.tryParse((local['editedAt'] ?? local['edited_at'] ?? local['createdAt'] ?? '').toString());
              final cTs = DateTime.tryParse((cloudEntry['editedAt'] ?? cloudEntry['edited_at'] ?? cloudEntry['createdAt'] ?? '').toString());
              final lVer = int.tryParse((local['current_version'] ?? 1).toString()) ?? 1;
              final cVer = int.tryParse((cloudEntry['current_version'] ?? 1).toString()) ?? 1;
              if ((lTs != null && (cTs == null || lTs.isAfter(cTs))) || (lTs == cTs && lVer > cVer)) {
                mergedUploads[matchIdx] = local;
              }
            }
          }
          final cleanMerged = mergedUploads.map(_cleanDocForStorage).toList();
          _previousUploadsCache = cleanMerged;
          await _persistRecentUploadsCache(mob);
        }

        // 3. Cache generated Excel exports scoped by user
        if (cloudData['generated_excels'] is List && (cloudData['generated_excels'] as List).isNotEmpty) {
          final exportedKey = scopedStorageKey('bnf_exported_batches', mob);
          await prefs.setString(exportedKey, jsonEncode(cloudData['generated_excels']));
        }
      }
    } catch (e) {
      debugPrint('[BatchController] Cloud hydration notice: $e');
    }
  }

  /// Synchronizes previous uploads from backend server (/api/previous-uploads)
  Future<List<Map<String, dynamic>>> syncPreviousUploadsFromServer() async {
    try {
      final uploads = await _geminiService.getPreviousUploads(
        userMobile: _activeUserMobile,
        sessionToken: _activeSessionToken,
      );
      if (uploads.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        final mob = _activeUserMobile ?? prefs.getString('bnf_user_mobile') ?? '';
        const generic = {'lr document', 'document', 'item', 'null', 'none', 'undefined', ''};
        final dismissed = await _readDismissedSet(prefs, mob);

        final filteredUploads = uploads.where((u) => !_matchesIdentifierSet(u, dismissed)).toList();

        final mergedUploads = <Map<String, dynamic>>[...filteredUploads];
        for (final local in _previousUploadsCache) {
          if (_matchesIdentifierSet(local, dismissed)) continue;
          final lId = (local['id'] ?? local['file_id'] ?? '').toString().trim();
          final lFn = (local['fileName'] ?? local['filename'] ?? '').toString().trim().toLowerCase();
          final lSv = (local['saved_filename'] ?? '').toString().trim().toLowerCase();
          final exists = mergedUploads.any((m) {
            final mId = (m['id'] ?? m['file_id'] ?? '').toString().trim();
            final mSv = (m['saved_filename'] ?? '').toString().trim().toLowerCase();
            final mFn = (m['filename'] ?? m['fileName'] ?? '').toString().trim().toLowerCase();
            if (lId.isNotEmpty && mId.isNotEmpty && lId == mId) return true;
            if (lSv.isNotEmpty && mSv.isNotEmpty && lSv == mSv) return true;
            if (lFn.isNotEmpty && mFn.isNotEmpty && !generic.contains(lFn) && !generic.contains(mFn) && lFn == mFn) return true;
            return false;
          });
          if (!exists) mergedUploads.add(local);
        }
        final cleanMerged = mergedUploads.map(_cleanDocForStorage).toList();
        _previousUploadsCache = cleanMerged;
        await _persistRecentUploadsCache(mob);
        return cleanMerged;
      }
      return uploads;
    } catch (e) {
      debugPrint('[BatchController] syncPreviousUploadsFromServer notice: $e');
      return [];
    }
  }

  /// Pushes active batch items to shared cloud JSON DB with debouncing
  void triggerCloudSync() {
    final mob = _activeUserMobile;
    if (mob == null || mob.trim().isEmpty) return;
    _cloudSyncTimer?.cancel();
    _cloudSyncTimer = Timer(const Duration(milliseconds: 400), () async {
      try {
        await UserCloudService.instance.saveActiveBatch(
          mob,
          _items,
          userName: _activeUserName,
          baseUrl: _geminiService.serverUrl,
        );
      } catch (e) {
        debugPrint('[BatchController] Cloud sync push notice: $e');
      }
    });
  }

  /// Sets active user session and guarantees complete data isolation between logins
  void setActiveUser(String? mobile, {String? name, String? sessionToken}) {
    final bool userChanged = _activeUserMobile != mobile;
    final bool sessionChanged = (sessionToken != null && _activeSessionToken != sessionToken) ||
        userChanged;

    if (sessionChanged) {
      final previousMobile = _activeUserMobile;
      _cloudSyncTimer?.cancel();
      _items.clear();
      _deletedItems.clear();
      _previousUploadsCache.clear();
      _completedItemIds.clear();
      _lastExportedPath = null;
      _statusMessage = null;
      _activeUserMobile = mobile;
      _activeUserName = name ?? (userChanged ? null : _activeUserName);
      _activeSessionToken = sessionToken;
      if (!_isDisposed) notifyListeners();
      _switchUserStorageAndHydrate(mobile, previousMobile: previousMobile);
      MasterDataService.instance.fetchMasterDataFromBackend(baseUrl: _geminiService.serverUrl);
    } else {
      bool changed = false;
      if (name != null && _activeUserName != name) {
        _activeUserName = name;
        changed = true;
      }
      if (sessionToken != null && _activeSessionToken != sessionToken) {
        _activeSessionToken = sessionToken;
        changed = true;
      }
      if (changed && !_isDisposed) notifyListeners();
    }
  }

  Future<void> _switchUserStorageAndHydrate(String? mobile, {String? previousMobile}) async {
    try {
      if (mobile == null || mobile.trim().isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final prevKey = resolveUserKey(previousMobile);
      final newKey = resolveUserKey(mobile);
      final switchedAccounts = prevKey.isNotEmpty && prevKey != newKey;
      if (switchedAccounts) {
        // Clear legacy unscoped globals so previous user's data cannot leak into new account,
        // while keeping previous user's scoped keys untouched.
        await _removeLegacyUnscopedKeys(prefs);
      }
      if (_isDisposed || _activeUserMobile != mobile) return;
      await _loadScopedCachesFromPrefs(
        prefs,
        mobile,
        allowLegacyMigration: !switchedAccounts,
      );
      if (!_isDisposed) notifyListeners();
      await hydrateFromCloud();
    } catch (_) {}
  }

  Future<void> _removeLegacyUnscopedKeys(SharedPreferences prefs) async {
    await prefs.remove('bnf_active_batch');
    await prefs.remove('bnf_recent_uploaded_lrs');
    await prefs.remove('bnf_dismissed_recent_lrs');
    await prefs.remove('bnf_exported_batches');
    await prefs.remove('bnf_completed_items');
    await prefs.remove('bnf_cache_owner_mobile');
  }

  /// Clears ONLY the active user's local caches on logout without affecting server records or other users.
  Future<void> clearUserCachesOnLogout({String? mobile, String? userId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final targetMobile = mobile ?? prefs.getString('bnf_user_mobile') ?? '';
      final userKey = resolveUserKey(targetMobile, userId: userId);
      if (userKey.isNotEmpty) {
        await prefs.remove(scopedStorageKey('bnf_active_batch', userKey));
        await prefs.remove(scopedStorageKey('bnf_recent_uploaded_lrs', userKey));
        await prefs.remove(scopedStorageKey('bnf_dismissed_recent_lrs', userKey));
        await prefs.remove(scopedStorageKey('bnf_exported_batches', userKey));
        await prefs.remove(scopedStorageKey('bnf_completed_items', userKey));
      }
      final owner = prefs.getString('bnf_cache_owner_mobile') ?? '';
      if (userKey.isEmpty || owner == userKey || owner.isEmpty) {
        await _removeLegacyUnscopedKeys(prefs);
      }
    } catch (_) {}
  }

  /// Clears in-memory batch and user session upon logout to prevent any data leak
  void clearForLogout() {
    final prevMobile = _activeUserMobile;
    _cloudSyncTimer?.cancel();
    _items.clear();
    _deletedItems.clear();
    _previousUploadsCache.clear();
    _completedItemIds.clear();
    _lastExportedPath = null;
    _statusMessage = null;
    _activeUserMobile = null;
    _activeUserName = null;
    _activeSessionToken = null;
    if (!_isDisposed) notifyListeners();
    if (prevMobile != null && prevMobile.trim().isNotEmpty) {
      clearUserCachesOnLogout(mobile: prevMobile);
    }
  }

  /// Sets the path of the last exported Excel file.
  void setLastExportedPath(String? path) {
    _lastExportedPath = path;
    notifyListeners();
  }

  int get totalCount => _items.length;
  int get completedCount =>
      _items.where((i) => i.status == BatchItemStatus.completed).length;
  int get errorCount =>
      _items.where((i) => i.status == BatchItemStatus.error).length;

  bool get canExport =>
      _items.isNotEmpty &&
      !_isProcessing &&
      _items.any((i) =>
          i.status == BatchItemStatus.completed ||
          i.extractionStatus == ExtractionStatus.partial);

  /// Checks whether an individual item has all mandatory (*) fields filled.
  bool isItemVerified(BatchItem item) {
    return item.isVerified;
  }

  /// True if all consignment notes in the batch have all mandatory fields filled.
  bool get allItemsVerified {
    if (_items.isEmpty) return false;
    return _items.every((i) => isItemVerified(i));
  }

  /// Returns items that are not fully verified.
  List<BatchItem> get unverifiedItems {
    return _items.where((i) => !isItemVerified(i)).toList();
  }

  PermissionService get permissionService => _permissionService;
  ImageService get imageService => _imageService;
  OcrService get ocrService => _ocrService;

  /// Toggles between Gemini Cloud Backend (main.py) and On-Device ML Kit OCR.
  void setUseGeminiBackend(bool value) {
    _useGeminiBackend = value;
    notifyListeners();
  }

  /// Changes active document schema and optionally re-parses existing raw OCR texts.
  void setSchema(DocumentSchema newSchema, {bool reparseExisting = true}) {
    _currentSchema = newSchema;
    if (reparseExisting) {
      _items = _items.map((item) {
        if (item.rawOcrText.isNotEmpty) {
          final lines = item.rawOcrText.split('\n');
          final result = _parserService.parseLines(
            lines,
            schema: _currentSchema,
            rawText: item.rawOcrText,
          );
          return item.copyWith(
            record: result.data,
            missingFields: result.missingFields,
            tableHeaders: result.tableHeaders,
            tableRows: result.tableRows,
            structureType: result.structureType,
          );
        }
        return item;
      }).toList();
    }
    notifyListeners();
  }

  /// Safely persists camera/gallery/picker files into the permanent app documents directory.
  /// Prevents Android OS cache cleanups from removing LR images across app restarts.
  /// Pass [uniqueSubdir] for multi-file batches so distinct files with matching basenames never collide.
  Future<String> _ensurePermanentFile(String originalPath, {String? uniqueSubdir}) async {
    try {
      final srcFile = File(originalPath);
      if (!await srcFile.exists()) return originalPath;

      Directory? docsDir;
      try {
        docsDir = await getApplicationDocumentsDirectory();
      } catch (_) {
        return originalPath; // Headless unit test fallback
      }

      final baseSub = (uniqueSubdir != null && uniqueSubdir.isNotEmpty)
          ? 'lr_documents/$uniqueSubdir'
          : 'lr_documents';
      final targetDir = Directory('${docsDir.path}/$baseSub');
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      if (srcFile.parent.path == targetDir.path) {
        return originalPath;
      }

      final fileName = originalPath.split(RegExp(r'[/\\]')).last;
      final safeFileName = fileName.isEmpty ? 'doc_${DateTime.now().millisecondsSinceEpoch}.jpg' : fileName;
      final targetPath = '${targetDir.path}/$safeFileName';
      final targetFile = File(targetPath);

      if (!await targetFile.exists() || await targetFile.length() != await srcFile.length()) {
        await srcFile.copy(targetPath);
      }
      return targetPath;
    } catch (e) {
      debugPrint('[BatchController] Permanent file save notice: $e');
      return originalPath;
    }
  }

  /// Adds a single captured photo from the camera to the queue and starts processing.
  Future<bool> addFromCamera() async {
    final hasPermission = await _permissionService.requestCameraPermission();
    if (!hasPermission) {
      _statusMessage = 'Camera permission was denied.';
      notifyListeners();
      return false;
    }

    final path = await _imageService.captureFromCamera();
    if (path == null) return false;

    return addMultiPageScan([path]);
  }

  /// Adds a multi-page scan session (multiple photos of a single LR) to the queue as ONE single LR item.
  Future<bool> addMultiPageScan(List<String> paths) async {
    if (paths.isEmpty) return false;
    if (paths.length > 15) {
      triggerPageLimitNotice();
      return false;
    }

    _lastUploadedItem = null;
    _isProcessingMultiPage = paths.length > 1;
    notifyListeners();

    // Ensure permanent copies of each captured page without filename collisions
    final scanTag = DateTime.now().microsecondsSinceEpoch;
    final permanentPaths = <String>[];
    for (int i = 0; i < paths.length; i++) {
      final subdir = paths.length > 1 ? 'scan_${scanTag}_$i' : null;
      permanentPaths.add(await _ensurePermanentFile(paths[i], uniqueSubdir: subdir));
    }

    final auditedPaths = await _orientAndAuditImagesForMultiLr(permanentPaths);
    if (auditedPaths == null) {
      return false;
    }

    String submissionFilePath;
    String submissionFileName;
    String? imageHash;

    try {
      // Assemble all captured pages in session into a single PDF document dossier
      Directory? appDir;
      try {
        appDir = await getApplicationDocumentsDirectory();
      } catch (_) {
        try {
          appDir = await getTemporaryDirectory();
        } catch (_) {}
      }
      final basePath = appDir?.path ?? Directory.systemTemp.path;
      final scansDir = Directory('$basePath/scans');
      if (!scansDir.existsSync()) scansDir.createSync(recursive: true);

      final docId = _uuid.v4();
      final pdfPath = '${scansDir.path}/lr_scan_$docId.pdf';
      final pdfFile = await PdfAssemblerService.assembleImagesToPdf(
        imagePaths: auditedPaths,
        outputPath: pdfPath,
      );
      submissionFilePath = pdfFile.path;
      submissionFileName = submissionFilePath.split(RegExp(r'[/\\]')).last;
      imageHash = computeImageHash(submissionFilePath);
    } catch (e) {
      debugPrint('[BatchController] PDF assembly notice: $e');
      if (auditedPaths.length > 1) {
        // Web parity: send all captured images directly to /extract-handwriting if PDF assembly fails
        return await addMultipleFilesAsSingleLr(auditedPaths);
      }
      submissionFilePath = auditedPaths.first;
      submissionFileName = submissionFilePath.split(RegExp(r'[/\\]')).last;
      imageHash = computeImageHash(submissionFilePath);
    }

    // Pre-OCR duplicate check (verified LRs only)
    if (isDuplicate(imagePath: submissionFilePath, imageHash: imageHash, fileName: submissionFileName)) {
      _isProcessingMultiPage = false;
      triggerDuplicateNotice('This LR already exists. You cannot add the same LR multiple times.');
      return false;
    }

    _removeMatchingUnverifiedItems(
      imagePath: submissionFilePath,
      imageHash: imageHash,
      fileName: submissionFileName,
    );

    final docId = _uuid.v4();
    final item = BatchItem(
      id: docId,
      imagePath: submissionFilePath,
      fileName: submissionFileName.isEmpty ? 'document_${_items.length + 1}.pdf' : submissionFileName,
      status: BatchItemStatus.pending,
      createdAt: DateTime.now(),
      imageHash: imageHash,
      record: {
        'preview_pages': jsonEncode(permanentPaths),
        'page_count': permanentPaths.length.toString(),
      },
    );

    _items.add(item);
    notifyListeners();

    await _processQueue();
    return _items.any((i) => i.id == docId);
  }

  /// Adds selected photos from the gallery; multi-photo selections are validated as one LR (Web parity).
  Future<bool> addFromGallery() async {
    final hasPermission = await _permissionService.requestGalleryPermission();
    if (!hasPermission) {
      _statusMessage = 'Gallery permission was denied.';
      notifyListeners();
      return false;
    }

    final paths = await _imageService.pickMultipleImages();
    if (paths.isEmpty) return false;
    if (paths.length > 1) {
      return addMultipleFilesAsSingleLr(paths);
    }
    return addFilePaths([paths.first]);
  }

  /// Performs on-device upright orientation normalization and consignment-note multi-LR check.
  /// Returns upright file paths if valid, or null after triggering [triggerMultipleLrsNotice].
  Future<List<String>?> _orientAndAuditImagesForMultiLr(List<String> paths) async {
    final orientedPaths = <String>[];
    final analyses = <ConsignmentPageAnalysis>[];

    for (final p in paths) {
      if (p.toLowerCase().endsWith('.pdf')) {
        orientedPaths.add(p);
        continue;
      }

      final recognized = await _ocrService.recognizeTextQuick(p);
      if (recognized != null) {
        analyses.add(LrMultiPageValidator.analyzeRecognizedText(recognized));
        final cwRot = LrMultiPageValidator.detectClockwiseRotationDegrees(recognized);
        if (cwRot != 0) {
          orientedPaths.add(await ImagePreprocessor.orientImageUprightIfNeeded(p, cwRot));
        } else {
          orientedPaths.add(p);
        }
      } else {
        orientedPaths.add(p);
      }
    }

    final outcome = LrMultiPageValidator.evaluatePageAnalyses(analyses);
    if (outcome.hasMultipleLrs) {
      _isProcessing = false;
      _isProcessingMultiPage = false;
      triggerMultipleLrsNotice(outcome.message);
      return null;
    }

    return orientedPaths;
  }

  /// Unified Web-parity post-OCR enrichment for both single-file and multi-file uploads.
  void _enrichExtractedRecord(
    Map<String, String> data, {
    bool isOrangeYellow = false,
    String rawText = '',
  }) {
    if (isOrangeYellow) {
      data['BNF LR No'] = '';
    }

    // 1. Web Unicharm -> "Global Marketing" Customer default
    MasterDataService.normalizeUnicharmCustomer(data, rawText: rawText);

    // 2. Ensure driver details remain empty if absent in OCR (driver_master auto-fill disabled)
    for (final drvKey in ['Driver Name *', 'Mobile no   *', 'Liscense No *', 'Valid Up to *']) {
      data.putIfAbsent(drvKey, () => '');
    }

    // 3. Strip whitespace in GSTINs and auto-lookup blank GSTs from Party Master / known brands
    for (final gstKey in ['cngrgstno *', 'cngrgstno', 'cngrgst', 'consignorgst', 'consignorgstin', 'cngegstno *', 'cngegstno', 'cngegst', 'consigneegst', 'consigneegstin']) {
      if (data.containsKey(gstKey)) {
        data[gstKey] = data[gstKey]!.replaceAll(RegExp(r'\s+'), '').toUpperCase();
      }
    }
    final curCngrGst = (data['cngrgstno *'] ?? data['cngrgstno'] ?? '').trim();
    if (curCngrGst.isEmpty) {
      final matchedCngrGst = MasterDataService.instance.matchPartyGst(data['cngr *'] ?? data['cngr'] ?? '') ??
          MasterDataService.instance.matchPartyGst(data['Customer Name *'] ?? data['customer'] ?? '');
      if (matchedCngrGst != null && matchedCngrGst.isNotEmpty) {
        data['cngrgstno *'] = matchedCngrGst;
        data['cngrgstno'] = matchedCngrGst;
      }
    }
    final curCngeGst = (data['cngegstno *'] ?? data['cngegstno'] ?? '').trim();
    if (curCngeGst.isEmpty) {
      final matchedCngeGst = MasterDataService.instance.matchPartyGst(data['cnge *'] ?? data['cnge'] ?? '');
      if (matchedCngeGst != null && matchedCngeGst.isNotEmpty) {
        data['cngegstno *'] = matchedCngeGst;
        data['cngegstno'] = matchedCngeGst;
      }
    }

    // 4. Freight mandatory manual entry, PMark blank on initial load, blank 3 BNF fields
    data['freight  *'] = '';
    data['freight'] = '';
    data['pmark'] = '';
    data['Private Mark'] = '';
    data['custrefcode'] = '';
    data['staxpaidby'] = '';
    data['dlvtype'] = '';

    // 5. GoodsMaster strict filtering (clear unmatched extracted Goods when master is loaded)
    final rawGoods = (data['goods'] ?? data['Goods'] ?? '').trim();
    if (rawGoods.isNotEmpty && MasterDataService.instance.goodsList.isNotEmpty) {
      final matchedGoods = MasterDataService.instance.matchValidGoods(rawGoods) ?? '';
      data['goods'] = matchedGoods;
      data['Goods'] = matchedGoods;
    }

    // 6. Product Code vs Product Type separation
    const prodTypeOptions = {'Surface-FTL', 'Surface-PTL', 'Global-TT', 'Global-MT', 'AIR'};
    final pCode = (data['productcode'] ?? '').trim();
    if (prodTypeOptions.contains(pCode)) {
      data['productcode'] = '';
    }
    if ((data['product_type'] ?? '').trim().isEmpty) {
      data['product_type'] = 'Surface-FTL';
      data['Product Type'] = 'Surface-FTL';
    }

    // 7. Auto-detect Department, Counter & resolve Branch via BookingCounterMast
    final custName = (data['Customer Name *'] ?? data['customer'] ?? data['cngr *'] ?? '').trim();
    final rawOrg = (data['orgrefcode'] ?? data['Origen'] ?? data['from'] ?? data['origin'] ?? '').trim();
    final rawDest = (data['destrefcode'] ?? data['Destination'] ?? data['to'] ?? data['destination'] ?? '').trim();
    final rawDept = (data['Depatment Name'] ?? data['department'] ?? '').trim();

    final detectedDept = MasterDataService.instance.autoDetectDepartment(
      originCity: rawOrg,
      customer: custName,
      deptRaw: rawDept,
    );
    data['Depatment Name'] = detectedDept;
    data['department'] = detectedDept;

    final rawCounter = (data['Counter'] ?? data['Counter name'] ?? data['counter'] ?? '').trim();
    final rawBranch = (data['Branch'] ?? data['branchrefcode'] ?? data['branch'] ?? '').trim();
    final detectedCounter = MasterDataService.instance.autoDetectCounter(
      originCity: rawOrg,
      counterRaw: rawCounter,
      branchRaw: rawBranch,
    );
    if (detectedCounter.isNotEmpty) {
      final mappedBranch = MasterDataService.instance.getBranchNameForCounter(detectedCounter);
      data['Counter'] = detectedCounter;
      data['Counter name'] = detectedCounter;
      data['counter'] = detectedCounter;
      if (mappedBranch.isNotEmpty) {
        data['Branch'] = mappedBranch;
        data['branchrefcode'] = mappedBranch;
      } else {
        data['Branch'] = (rawBranch.isNotEmpty && rawBranch != detectedCounter) ? rawBranch : '';
        data['branchrefcode'] = data['Branch']!;
      }
    } else {
      data['Counter'] = '';
      data['Counter name'] = '';
      data['counter'] = '';
      data['Branch'] = '';
      data['branchrefcode'] = '';
    }

    // 8. Standardize date fields strictly to DD-MM-YYYY
    for (final dk in ['grdt', 'grdt *', 'stockdt', 'Loading Start date *', 'invoiedt', 'Valid Upto', 'Valid Up to *', 'EwayBillDate', 'ewaybilldt']) {
      if ((data[dk] ?? '').trim().isNotEmpty) {
        data[dk] = ExcelService.formatToDdMmYyyy(data[dk]);
      }
    }

    // 9. Mirror defaults for PickupPoint, DeliveryPoint & EwayBillDate
    final grdtFmt = (data['grdt *'] ?? data['grdt'] ?? '').trim();
    if ((data['ewaybilldt'] ?? data['EwayBillDate'] ?? '').trim().isEmpty && grdtFmt.isNotEmpty) {
      data['ewaybilldt'] = grdtFmt;
      data['EwayBillDate'] = grdtFmt;
    }
    if ((data['PickupPoint'] ?? data['pickup_point'] ?? '').trim().isEmpty && rawOrg.isNotEmpty) {
      data['PickupPoint'] = rawOrg;
    }
    if ((data['DeliveryPoint'] ?? data['delivery_point'] ?? '').trim().isEmpty && rawDest.isNotEmpty) {
      data['DeliveryPoint'] = rawDest;
    }

    // 10. Pending verification status
    data['pending_verification'] = 'true';
    data['is_verified'] = 'false';
  }

  /// Uploads multiple files (PDFs, images, or mixed) belonging to the same LR in a single operation.
  /// If multiple different LR numbers are detected, rejects with triggerMultipleLrsNotice.
  /// If valid, creates exactly ONE BatchItem in _items and returns true.
  Future<void> _recordUploadInRecentHistory(BatchItem item) async {
    try {
      final completedDoc = _cleanDocForStorage({
        'id': item.id,
        'fileName': item.fileName,
        'saved_filename': item.record['saved_filename'] ?? '',
        'imagePath': item.imagePath,
        'lrNo': extractLrNoFromRecord(item.record),
        'isPdf': item.fileName.toLowerCase().endsWith('.pdf') || item.imagePath.toLowerCase().endsWith('.pdf'),
        'createdAt': item.createdAt.toIso8601String(),
        'editedAt': item.editedAt?.toIso8601String(),
        'status': 'completed',
        'isVerified': item.isVerified,
        'is_exported': item.isExported,
        'exportedAt': item.exportedAt?.toIso8601String(),
        'preview_url': item.record['preview_url'] ?? '',
        'preview_path': item.record['preview_path'] ?? '',
        'preview_image': '',
        'record': _cleanDocForStorage(item.record),
      });
      const genericFns = {'lr document', 'document', 'item', 'image', 'upload', 'null', 'undefined', ''};
      final curId = completedDoc['id']?.toString().trim() ?? '';
      final curFn = completedDoc['fileName']?.toString().trim().toLowerCase() ?? '';
      final curSv = (completedDoc['saved_filename'] ?? '').toString().trim().toLowerCase();

      _previousUploadsCache.removeWhere((r) {
        final rId = (r['id'] ?? r['file_id'] ?? '').toString().trim();
        final rFn = (r['fileName'] ?? r['filename'] ?? '').toString().trim().toLowerCase();
        final rSv = (r['saved_filename'] ?? '').toString().trim().toLowerCase();
        if (curId.isNotEmpty && rId.isNotEmpty && curId == rId) return true;
        if (curSv.isNotEmpty && rSv.isNotEmpty && curSv == rSv) return true;
        if (curFn.isNotEmpty && rFn.isNotEmpty && !genericFns.contains(curFn) && curFn == rFn) return true;
        return false;
      });
      _previousUploadsCache.insert(0, completedDoc);

      await _persistRecentUploadsCache();
      final p = await SharedPreferences.getInstance();
      final mob = _activeUserMobile ?? p.getString('bnf_user_mobile') ?? '';
      final dismissedKey = scopedStorageKey('bnf_dismissed_recent_lrs', mob);
      final toRemove = {curId, curFn, curSv}..removeWhere((s) => s.isEmpty || genericFns.contains(s.toLowerCase()));
      final dismissed = p.getStringList(dismissedKey);
      if (dismissed != null && dismissed.isNotEmpty && toRemove.isNotEmpty) {
        final updated = dismissed
            .where((s) => !toRemove.contains(s.trim().toLowerCase()) && !toRemove.contains(s.trim()))
            .toList();
        if (updated.length != dismissed.length) {
          await p.setStringList(dismissedKey, updated);
        }
      }
      if (mob.isNotEmpty && toRemove.isNotEmpty) {
        UserCloudService.instance
            .undismissCloudUpload(
              mob,
              toRemove.toList(),
              baseUrl: _geminiService.serverUrl,
            )
            .catchError((_) => false);
      }
    } catch (_) {}
  }

  Future<bool> addMultipleFilesAsSingleLr(List<String> paths) async {
    if (paths.isEmpty) return false;
    _lastUploadedItem = null;

    // Check maximum 15 pages limit across all combined files
    int totalPages = 0;
    for (final p in paths) {
      if (p.toLowerCase().endsWith('.pdf')) {
        totalPages += await PdfAssemblerService.countPdfPages(p);
      } else {
        totalPages += 1;
      }
    }
    if (totalPages > 15) {
      triggerPageLimitNotice();
      return false;
    }

    _isProcessing = true;
    _isProcessingMultiPage = totalPages > 1 || paths.length > 1;
    _statusMessage = 'Reading Consignment (${paths.length} files)...';
    notifyListeners();

    try {
      final batchTag = DateTime.now().microsecondsSinceEpoch;
      final permanentPaths = <String>[];
      for (int i = 0; i < paths.length; i++) {
        permanentPaths.add(await _ensurePermanentFile(paths[i], uniqueSubdir: 'batch_${batchTag}_$i'));
      }

      final auditedPaths = await _orientAndAuditImagesForMultiLr(permanentPaths);
      if (auditedPaths == null) {
        return false;
      }

      final result = await _geminiService.extractMultipleFiles(
        auditedPaths,
        userMobile: _activeUserMobile,
        userName: _activeUserName,
        sessionToken: _activeSessionToken,
      );

      if (result.isPageLimitExceeded || result.errorCode == 'PAGE_LIMIT_EXCEEDED') {
        _isProcessing = false;
        _isProcessingMultiPage = false;
        triggerPageLimitNotice(result.message);
        return false;
      }

      if (result.isMultipleLrs || result.errorCode == 'MULTIPLE_LRS') {
        _isProcessing = false;
        _isProcessingMultiPage = false;
        triggerMultipleLrsNotice(result.message);
        return false;
      }

      if (result.isInvalidLr || result.status == ExtractionStatus.failed) {
        _isProcessing = false;
        _isProcessingMultiPage = false;
        if (result.isInvalidLr) {
          triggerInvalidLrNotice('Invalid LR – Please upload a valid LR document.');
        } else {
          triggerConnectionErrorNotice(result.message ?? 'Server error during extraction.');
        }
        return false;
      }

      // Check post-OCR duplicate against verified LRs only (exclude '0' and unverified LRs)
      final rawCandidateLr = normalizeLrNo(extractLrNoFromRecord(result.data));
      final candidateLr = rawCandidateLr == '0' ? '' : rawCandidateLr;
      final primaryHash = computeImageHash(permanentPaths.first);
      if (isDuplicate(
        lrNo: candidateLr.isNotEmpty ? candidateLr : null,
        imagePath: permanentPaths.first,
        imageHash: primaryHash,
        record: result.data,
      )) {
        _isProcessing = false;
        _isProcessingMultiPage = false;
        triggerDuplicateNotice('This LR already exists. You cannot add the same LR multiple times.');
        return false;
      }

      final rec = Map<String, String>.from(result.data);
      _enrichExtractedRecord(rec, rawText: result.rawText);

      final docId = _uuid.v4();
      final primaryFn = permanentPaths.first.split(RegExp(r'[/\\]')).last;
      final displayName = '$primaryFn (+${permanentPaths.length - 1} files)';

      // Replace any matching stale unverified items cleanly before inserting
      _removeMatchingUnverifiedItems(
        lrNo: extractLrNoFromRecord(rec),
        imagePath: permanentPaths.first,
        imageHash: primaryHash,
        fileName: displayName,
        savedFilename: rec['saved_filename']?.toString(),
      );
      for (final p in permanentPaths) {
        _removeMatchingUnverifiedItems(
          imagePath: p,
          imageHash: computeImageHash(p),
          fileName: p.split(RegExp(r'[/\\]')).last,
        );
      }

      final now = DateTime.now();
      final detailsLabel = 'Consignment added (${permanentPaths.length} files combined)';
      final initialVersions = [
        {
          'version': 1,
          'timestamp': now.toIso8601String(),
          'action': 'add',
          'user_name': _activeUserName ?? 'Logistics User',
          'user_mobile': _activeUserMobile ?? '',
          'ocr_engine': 'server',
          'details': detailsLabel,
          'diff': null,
          'snapshot_data': Map<String, String>.from(rec),
        }
      ];
      final initialHistory = [
        {
          'timestamp': now.toIso8601String(),
          'user': _activeUserName ?? 'Logistics User',
          'mobile': _activeUserMobile ?? '',
          'action': 'add',
          'version': 1,
          'ocr_engine': 'server',
          'details': detailsLabel,
        }
      ];

      final item = BatchItem(
        id: docId,
        imagePath: permanentPaths.first,
        fileName: displayName,
        status: BatchItemStatus.completed,
        createdAt: now,
        processedAt: now,
        imageHash: primaryHash,
        record: rec,
        versions: initialVersions,
        editHistory: initialHistory,
        structureType: result.structureType,
        tableHeaders: result.tableHeaders,
        tableRows: result.tableRows,
      );

      _items.add(item);
      _lastUploadedItem = item;

      _isProcessing = false;
      _isProcessingMultiPage = false;
      if (!_isDisposed) notifyListeners();

      // Record in history cache, undismiss if needed, persist local batch & trigger Cloud Sync
      await _recordUploadInRecentHistory(item);
      await _persistActiveBatchCache();
      triggerCloudSync();
      return true;
    } catch (e) {
      _isProcessing = false;
      _isProcessingMultiPage = false;
      triggerConnectionErrorNotice('Extraction failed: $e');
      return false;
    }
  }


  /// Adds a single selected photo from the gallery to the queue and starts processing.
  Future<bool> addFromGallerySingle() async {
    final hasPermission = await _permissionService.requestGalleryPermission();
    if (!hasPermission) {
      _statusMessage = 'Gallery permission was denied.';
      notifyListeners();
      return false;
    }

    final single = await _imageService.pickSingleImage();
    String? path = single;
    if (path == null || path.isEmpty) {
      final paths = await _imageService.pickMultipleImages();
      if (paths.length > 1) {
        return addMultipleFilesAsSingleLr(paths);
      }
      if (paths.isNotEmpty) path = paths.first;
    }
    if (path == null || path.isEmpty) return false;
    return addFilePaths([path]);
  }

  /// Direct item ingestion helper (useful for testing or state recovery).
  void addItemDirectly(BatchItem item) {
    _items.add(item);
    notifyListeners();
  }

  /// Manually add an image path (useful for testing or direct ingestion).
  void addImagePath(String path) {
    if (_addItemFromPath(path)) {
      _processQueue();
    }
    // Also copy to permanent documents storage in background
    _ensurePermanentFile(path).then((perm) {
      if (perm != path) {
        final idx = _items.indexWhere((i) => i.imagePath == path);
        if (idx != -1) {
          _items[idx] = _items[idx].copyWith(imagePath: perm);
          notifyListeners();
        }
      }
    });
  }

  /// Ingests files (images, PDFs). Multi-file selections are validated as a single LR dossier (Web parity).
  Future<bool> addFilePaths(List<String> paths) async {
    if (paths.isEmpty) return false;
    _lastUploadedItem = null;
    if (paths.length > 1) {
      return addMultipleFilesAsSingleLr(paths);
    }
    int totalPages = 0;
    for (final p in paths) {
      if (p.toLowerCase().endsWith('.pdf')) {
        totalPages += await PdfAssemblerService.countPdfPages(p);
      } else {
        totalPages += 1;
      }
    }
    if (totalPages > 15) {
      triggerPageLimitNotice();
      return false;
    }

    bool anyAdded = false;
    final permanentPaths = <String>[];
    for (final path in paths) {
      permanentPaths.add(await _ensurePermanentFile(path));
    }
    final auditedPaths = await _orientAndAuditImagesForMultiLr(permanentPaths);
    if (auditedPaths == null) {
      return false;
    }
    for (final path in auditedPaths) {
      if (_addItemFromPath(path)) {
        anyAdded = true;
      }
    }
    if (anyAdded) {
      await _processQueue();
      return _items.any((i) => i.status == BatchItemStatus.completed && i.id == _lastUploadedItem?.id);
    }
    return anyAdded;
  }

  /// Recovers and processes any lost camera capture after Android killed the app in the background.
  Future<void> checkLostData() async {
    try {
      final path = await _imageService.retrieveLostData();
      if (path != null && path.isNotEmpty) {
        final permanentPath = await _ensurePermanentFile(path);
        if (_addItemFromPath(permanentPath)) {
          await _processQueue();
        }
      }
    } catch (_) {}
  }

  bool _addItemFromPath(String path) {
    final imageHash = computeImageHash(path);
    final fileName = path.split(RegExp(r'[/\\]')).last;
    if (isDuplicate(imagePath: path, imageHash: imageHash, fileName: fileName)) {
      triggerDuplicateNotice('This LR already exists. You cannot add the same LR multiple times.');
      return false;
    }
    _removeMatchingUnverifiedItems(
      imagePath: path,
      imageHash: imageHash,
      fileName: fileName,
    );
    final file = File(path);
    if (file.existsSync() && file.lengthSync() > 10 * 1024 * 1024) {
      final sizeMb = (file.lengthSync() / (1024 * 1024)).toStringAsFixed(2);
      _statusMessage = 'File "$fileName" ($sizeMb MB) exceeds the allowed limit of 10 MB.';
      notifyListeners();
      return false;
    }
    final item = BatchItem(
      id: _uuid.v4(),
      imagePath: path,
      fileName: fileName.isEmpty ? 'document_${_items.length + 1}.jpg' : fileName,
      status: BatchItemStatus.pending,
      createdAt: DateTime.now(),
      imageHash: imageHash,
    );
    _items.add(item);
    notifyListeners();
    return true;
  }

  /// Sequential processing of all pending queue items.
  /// After all items complete, automatically saves an Excel file so the user
  /// always has an up-to-date export without needing to manually tap "Export".
  Future<void> processQueue() => _processQueue();

  Future<void> _processQueue() async {
    if (_isProcessing) {
      await _processingCompleter?.future;
      return;
    }
    _isProcessing = true;
    _processingCompleter = Completer<void>();
    _statusMessage = 'Processing images...';
    final pendingCount = _items.where((i) => i.status == BatchItemStatus.pending).length;
    _processingTotalFiles = pendingCount > 0 ? pendingCount : 1;
    _processingFileIndex = 0;
    notifyListeners();

    try {
      while (true) {
        final pendingIndex =
            _items.indexWhere((i) => i.status == BatchItemStatus.pending);
        if (pendingIndex == -1) break;

        _processingFileIndex++;
        final item = _items[pendingIndex];
        _currentProcessingFileName = item.fileName;
        int itemPages = 1;
        if (item.imagePath.toLowerCase().endsWith('.pdf')) {
          try {
            itemPages = await PdfAssemblerService.countPdfPages(item.imagePath);
          } catch (_) {}
        }
        final pageCountStr = item.record['page_count'];
        if (itemPages <= 1 && pageCountStr != null) {
          itemPages = int.tryParse(pageCountStr) ?? 1;
        }
        _isProcessingMultiPage = itemPages > 1;
        _currentOcrStep = 1; // Step 1: Image(s) Uploaded

        // Transition to processing
        _items[pendingIndex] = item.copyWith(
          status: BatchItemStatus.processing,
        );
        notifyListeners();

        try {
          ExtractionResult? parseResult;
          String rawOcrText = '';
          String activeOcrEngine = 'server';

          // Step 2: Reading LR Document
          _currentOcrStep = 2;
          notifyListeners();

          // Detect document image type (orange/yellow handwritten bilty vs white printed page)
          final isOrangeYellow = await ImagePreprocessor.isOrangeYellowImage(item.imagePath);

          // Step 3: Extracting Consignment Details
          _currentOcrStep = 3;
          notifyListeners();

          // 1. Primary Method: Server-side OCR (Gemini Cloud API)
          if (_useGeminiBackend) {
            _statusMessage = 'Reading consignment via server (${item.fileName})...';
            notifyListeners();

            try {
              final serverResult = await _geminiService
                  .extractHandwriting(
                    item.imagePath,
                    originalFileName: item.fileName,
                    userMobile: _activeUserMobile,
                    userName: _activeUserName,
                    sessionToken: _activeSessionToken,
                  )
                  .timeout(const Duration(seconds: 240));

                if (serverResult.status != ExtractionStatus.failed) {
                parseResult = serverResult;
                rawOcrText = serverResult.rawText;
                activeOcrEngine = 'server';
              } else if (serverResult.isMultipleLrs || serverResult.errorCode == 'MULTIPLE_LRS') {
                debugPrint('Multiple LRs rejected by server for item. Discarding.');
                final rejectedId = item.id;
                final rejectedFn = item.fileName;
                final rejectedPath = item.imagePath;
                final rejectedSaved = item.record['saved_filename']?.toString() ?? '';
                _items.removeWhere((i) => i.id == item.id);
                purgeFromPreviousUploads(
                  id: rejectedId,
                  fileName: rejectedFn,
                  imagePath: rejectedPath,
                  savedFilename: rejectedSaved,
                );
                triggerMultipleLrsNotice(
                  serverResult.message ??
                      'Multiple LR documents detected. Please upload documents belonging to only one LR at a time.',
                );
                continue;
              } else if (serverResult.isInvalidLr || serverResult.errorCode == 'INVALID_LR') {
                debugPrint('Invalid LR rejected by server for item . Discarding.');
                final rejectedId = item.id;
                final rejectedFn = item.fileName;
                final rejectedPath = item.imagePath;
                final rejectedSaved = item.record['saved_filename']?.toString() ?? '';
                _items.removeWhere((i) => i.id == item.id);
                purgeFromPreviousUploads(
                  id: rejectedId,
                  fileName: rejectedFn,
                  imagePath: rejectedPath,
                  savedFilename: rejectedSaved,
                );
                triggerInvalidLrNotice(
                  'Invalid LR – Please upload a valid LR document.',
                  rejectedId: rejectedId,
                  rejectedFileName: rejectedFn,
                );
                continue;
              } else if (serverResult.isPageLimitExceeded || serverResult.errorCode == 'PAGE_LIMIT_EXCEEDED') {
                debugPrint('Page limit exceeded for item. Discarding.');
                final rejectedId = item.id;
                final rejectedFn = item.fileName;
                final rejectedPath = item.imagePath;
                final rejectedSaved = item.record['saved_filename']?.toString() ?? '';
                _items.removeWhere((i) => i.id == item.id);
                purgeFromPreviousUploads(
                  id: rejectedId,
                  fileName: rejectedFn,
                  imagePath: rejectedPath,
                  savedFilename: rejectedSaved,
                );
                triggerPageLimitNotice(
                  serverResult.message ??
                      'Maximum 15 pages are allowed per upload. Please upload documents containing 15 pages or fewer.',
                );
                continue;
              } else {
                debugPrint('Server validation failed: . Discarding item.');
                final rejectedId = item.id;
                final rejectedFn = item.fileName;
                final rejectedPath = item.imagePath;
                final rejectedSaved = item.record['saved_filename']?.toString() ?? '';
                _items.removeWhere((i) => i.id == item.id);
                purgeFromPreviousUploads(
                  id: rejectedId,
                  fileName: rejectedFn,
                  imagePath: rejectedPath,
                  savedFilename: rejectedSaved,
                );
                triggerConnectionErrorNotice('Unable to reach the validation server. Please check your network connection and try again.');
                notifyListeners();
                continue;
              }
            } catch (serverErr) {
              debugPrint('Server OCR unavailable (). Discarding item.');
              final rejectedId = item.id;
              final rejectedFn = item.fileName;
              final rejectedPath = item.imagePath;
              final rejectedSaved = item.record['saved_filename']?.toString() ?? '';
              _items.removeWhere((i) => i.id == item.id);
              purgeFromPreviousUploads(
                id: rejectedId,
                fileName: rejectedFn,
                imagePath: rejectedPath,
                savedFilename: rejectedSaved,
              );
              triggerConnectionErrorNotice('Unable to reach the validation server. Please check your network connection and try again.');
              notifyListeners();
              continue;
            }
          }

          if (parseResult == null) {
            final rejectedId = item.id;
            final rejectedFn = item.fileName;
            final rejectedPath = item.imagePath;
            final rejectedSaved = item.record['saved_filename']?.toString() ?? '';
            _items.removeWhere((i) => i.id == item.id);
            purgeFromPreviousUploads(
              id: rejectedId,
              fileName: rejectedFn,
              imagePath: rejectedPath,
              savedFilename: rejectedSaved,
            );
            triggerConnectionErrorNotice('Unable to reach the validation server. Please check your network connection and try again.');
            notifyListeners();
            continue;
          }
          // Retain multi-page scan metadata and preserve original local device photos
          if (item.record['preview_pages'] != null) {
            parseResult.data['local_preview_pages'] = item.record['preview_pages']!;
          }
          if (item.record['preview_pages'] != null && !parseResult.data.containsKey('preview_pages')) {
            parseResult.data['preview_pages'] = item.record['preview_pages']!;
          }
          if (item.record['page_count'] != null && !parseResult.data.containsKey('page_count')) {
            parseResult.data['page_count'] = item.record['page_count']!;
          }

          // Step 4: Mapping with BNF 49-Column Format
          _currentOcrStep = 4;
          notifyListeners();

          // Post-OCR Duplicate Check
          if (isDuplicate(
            record: parseResult.data,
            imageHash: item.imageHash,
            fileName: item.fileName,
            excludeItemId: item.id,
          )) {
            debugPrint('Duplicate LR detected post-OCR for item . Rejecting.');
            final dupId = item.id;
            final dupFn = item.fileName;
            final dupPath = item.imagePath;
            final dupSaved = item.record['saved_filename']?.toString() ?? '';
            _items.removeWhere((i) => i.id == item.id);
            purgeFromPreviousUploads(
              id: dupId,
              fileName: dupFn,
              imagePath: dupPath,
              savedFilename: dupSaved,
            );
            triggerDuplicateNotice('This LR already exists. You cannot add the same LR multiple times.');
            notifyListeners();
            continue;
          }

          // Step 5: Validating Data & Preserving Blanks (Web-parity enrichment)
          _currentOcrStep = 5;
          notifyListeners();

          _enrichExtractedRecord(
            parseResult.data,
            isOrangeYellow: isOrangeYellow,
            rawText: rawOcrText,
          );

          _removeMatchingUnverifiedItems(
            excludeItemId: item.id,
            lrNo: extractLrNoFromRecord(parseResult.data),
            imagePath: item.imagePath,
            imageHash: item.imageHash,
            fileName: item.fileName,
            savedFilename: parseResult.data['saved_filename'],
          );

          // Find current index after asynchronous gap
          final currentIndex = _items.indexWhere((i) => i.id == item.id);
          if (currentIndex != -1) {
            final now = DateTime.now();

            final detailsLabel = activeOcrEngine == 'ml_fallback'
                ? 'Consignment added (Fallback results)'
                : 'Consignment added (Server results)';
            final initialVersions = [
              {
                'version': 1,
                'timestamp': now.toIso8601String(),
                'action': 'add',
                'user_name': _activeUserName ?? 'Logistics User',
                'user_mobile': _activeUserMobile ?? '',
                'ocr_engine': activeOcrEngine,
                'details': detailsLabel,
                'diff': null,
                'snapshot_data': Map<String, String>.from(parseResult.data),
              }
            ];
            final initialHistory = [
              {
                'timestamp': now.toIso8601String(),
                'user': _activeUserName ?? 'Logistics User',
                'mobile': _activeUserMobile ?? '',
                'action': 'add',
                'version': 1,
                'ocr_engine': activeOcrEngine,
                'details': detailsLabel,
              }
            ];

            final completedItem = _items[currentIndex].copyWith(
              status: BatchItemStatus.completed,
              processedAt: now,
              record: parseResult.data,
              missingFields: parseResult.missingFields,
              rawOcrText: rawOcrText,
              errorMessage: null,
              tableHeaders: parseResult.tableHeaders,
              tableRows: parseResult.tableRows,
              structureType: parseResult.structureType,
              ocrEngine: activeOcrEngine,
              versions: initialVersions,
              editHistory: initialHistory,
            );
            _items[currentIndex] = completedItem;
            _lastUploadedItem = completedItem;

            // Record completed LR into user-scoped history cache & cloud sync immediately
            await _recordUploadInRecentHistory(completedItem);
            await _persistActiveBatchCache();
          }
        } catch (e) {
          final currentIndex = _items.indexWhere((i) => i.id == item.id);
          if (currentIndex != -1) {
            _items[currentIndex] = _items[currentIndex].copyWith(
              status: BatchItemStatus.error,
              errorMessage: e.toString(),
              processedAt: DateTime.now(),
            );
          }
        }

        notifyListeners();
      }
    } finally {
      _isProcessing = false;
      _isProcessingMultiPage = false;
      if (_processingCompleter != null && !_processingCompleter!.isCompleted) {
        _processingCompleter!.complete();
      }
      _processingCompleter = null;
      _statusMessage = 'Processing complete. Saving Excel...';
      notifyListeners();
      triggerCloudSync();

      // AUTO-SAVE: silently write a fresh Excel file after every batch.
      _autoSaveExcel();
    }
  }

  /// Auto-saves the Excel file after every processing batch without blocking the UI.
  /// Uses Future.microtask so Excel generation yields to the event loop first.
  Future<void> _autoSaveExcel() async {
    final completedItems = _items
        .where((i) =>
            i.status == BatchItemStatus.completed ||
            i.extractionStatus == ExtractionStatus.partial)
        .toList();
    if (completedItems.isEmpty) return;

    try {
      // generateExcelBytes is pure Dart — no native calls, runs quickly.
      // Future.microtask yields to event loop before executing.
      final bytes = await Future.microtask(
        () => _excelService.generateExcelBytes(
          items: completedItems,
          schema: _currentSchema,
        ),
      );

      final file = await _excelService.saveBytesToFile(bytes);
      _lastExportedPath = file.path;
      _statusMessage = 'Auto-saved: ${file.path.split(RegExp(r'[/\\]')).last}';
    } catch (e) {
      // Non-fatal: user can still manually export from Review screen.
      _statusMessage = 'Processing complete.';
    }
    if (!_isDisposed) notifyListeners();
  }

  /// Updates a single key:value field in a batch item's record (e.g. from user edit in ReviewScreen).
  void updateRecordField(String itemId, String fieldKey, String newValue) {
    final index = _items.indexWhere((i) => i.id == itemId);
    if (index == -1) return;

    final item = _items[index];
    final updatedRecord = Map<String, String>.from(item.record);
    updatedRecord[fieldKey] = newValue;

    // Sync snake_case alias if present
    final snake = fieldKey.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    if (snake.isNotEmpty && snake != fieldKey && updatedRecord.containsKey(snake)) {
      updatedRecord[snake] = newValue;
    }

    // Recalculate missing fields
    final updatedMissing = item.missingFields.where((k) => k != fieldKey || newValue.trim().isEmpty).toList();
    if (newValue.trim().isNotEmpty && updatedMissing.contains(fieldKey)) {
      updatedMissing.remove(fieldKey);
    }

    final oldVal = item.record[fieldKey] ?? '';
    final now = DateTime.now();
    final updatedHistory = List<Map<String, dynamic>>.from(item.editHistory);
    final updatedVersions = List<Map<String, dynamic>>.from(item.versions);
    int newVer = item.currentVersion;

    if (oldVal != newValue) {
      newVer = item.currentVersion + 1;
      final diffMap = {'field': fieldKey, 'old': oldVal, 'new': newValue};

      if (updatedVersions.isEmpty) {
        updatedVersions.add({
          'version': 1,
          'timestamp': item.createdAt.toIso8601String(),
          'action': 'add',
          'user_name': _activeUserName ?? 'Logistics User',
          'user_mobile': _activeUserMobile ?? '',
          'details': 'Initial OCR extraction',
          'diff': null,
          'snapshot_data': Map<String, String>.from(item.record),
        });
      }

      updatedVersions.add({
        'version': newVer,
        'timestamp': now.toIso8601String(),
        'action': 'edit',
        'user_name': _activeUserName ?? 'Logistics User',
        'user_mobile': _activeUserMobile ?? '',
        'diff': diffMap,
        'snapshot_data': Map<String, String>.from(updatedRecord),
      });

      updatedHistory.add({
        'timestamp': now.toIso8601String(),
        'user': _activeUserName ?? 'Logistics User',
        'mobile': _activeUserMobile ?? '',
        'action': 'edit',
        'field': fieldKey,
        'old': oldVal,
        'new': newValue,
        'version': newVer,
        'details': '$fieldKey: "$oldVal" -> "$newValue"',
      });

      try {
        FileLifecycleService.instance.recordFileEdit(
          item.fileName,
          action: 'field_edit',
          details: '$fieldKey: "$oldVal" -> "$newValue"',
          diff: diffMap,
          newData: updatedRecord,
        );
      } catch (_) {}
    }

    final bool wasExportedChanged = oldVal != newValue && isItemExported(item);
    if (wasExportedChanged) {
      updatedRecord['is_exported'] = 'false';
      updatedRecord.remove('exported_at');
      _completedItemIds.remove(item.id);
    }

    _items[index] = item.copyWith(
      record: updatedRecord,
      missingFields: updatedMissing,
      editedAt: now,
      clearExportedAt: wasExportedChanged,
      editHistory: updatedHistory,
      currentVersion: newVer,
      versions: updatedVersions,
    );
    notifyListeners();
    if (wasExportedChanged) {
      _persistCompletedItemsCache();
    }
    _persistActiveBatchCache();
    triggerCloudSync();
  }

  /// Updates a single cell within a batch item's detected 2D table grid.
  void updateTableCell(String itemId, int rowIndex, int colIndex, String newValue) {
    final index = _items.indexWhere((i) => i.id == itemId);
    if (index == -1) return;

    final item = _items[index];
    if (rowIndex < 0 || rowIndex >= item.tableRows.length) return;

    final updatedRows = item.tableRows.map((r) => List<String>.from(r)).toList();
    while (updatedRows[rowIndex].length <= colIndex) {
      updatedRows[rowIndex].add('');
    }
    updatedRows[rowIndex][colIndex] = newValue;

    _items[index] = item.copyWith(tableRows: updatedRows);
    notifyListeners();
  }

  /// Updates a column header within a batch item's detected 2D table grid.
  void updateTableHeader(String itemId, int colIndex, String newHeader) {
    final index = _items.indexWhere((i) => i.id == itemId);
    if (index == -1) return;

    final item = _items[index];
    if (colIndex < 0 || colIndex >= item.tableHeaders.length) return;

    final updatedHeaders = List<String>.from(item.tableHeaders);
    updatedHeaders[colIndex] = newHeader;

    _items[index] = item.copyWith(tableHeaders: updatedHeaders);
    notifyListeners();
  }

  /// Replaces an existing batch item in the queue with an updated version.
  /// Automatically resets exportedAt when an already-exported LR is modified.
  void updateItem(BatchItem item) {
    final index = _items.indexWhere((i) => i.id == item.id);
    if (index != -1) {
      final existing = _items[index];
      BatchItem normalized = item;
      final editedAfterExport = _recordsDiffer(existing.record, item.record) &&
          (isItemExported(existing) || isItemExported(item)) &&
          (item.exportedAt == null ||
              (existing.exportedAt != null && !item.exportedAt!.isAfter(existing.exportedAt!)));

      if (editedAfterExport || item.record['is_exported'] == 'false') {
        final rec = Map<String, String>.from(item.record);
        rec['is_exported'] = 'false';
        rec.remove('exported_at');
        _completedItemIds.remove(item.id);
        final bumpedVer = item.currentVersion > existing.currentVersion
            ? item.currentVersion
            : existing.currentVersion + 1;
        normalized = item.copyWith(
          record: rec,
          clearExportedAt: true,
          editedAt: item.editedAt ?? DateTime.now(),
          currentVersion: bumpedVer,
        );
        _persistCompletedItemsCache();
      } else if (normalized.isExported) {
        _completedItemIds.add(normalized.id);
        _persistCompletedItemsCache();
      }

      _items[index] = normalized;
      if (normalized.status == BatchItemStatus.completed) {
        final cacheIdx = _previousUploadsCache.indexWhere((r) {
          final rId = (r['id'] ?? r['file_id'] ?? '').toString().trim();
          final rSv = (r['saved_filename'] ?? '').toString().trim().toLowerCase();
          final itemSv = (normalized.record['saved_filename'] ?? '').trim().toLowerCase();
          if (rId.isNotEmpty && rId == normalized.id) return true;
          if (itemSv.isNotEmpty && rSv.isNotEmpty && itemSv == rSv) return true;
          return false;
        });
        if (cacheIdx != -1) {
          _previousUploadsCache[cacheIdx] = {
            ..._previousUploadsCache[cacheIdx],
            'lrNo': extractLrNoFromRecord(normalized.record),
            'isVerified': normalized.isVerified,
            'editedAt': normalized.editedAt?.toIso8601String(),
            'is_exported': normalized.isExported,
            'exportedAt': normalized.exportedAt?.toIso8601String(),
            'record': _cleanDocForStorage(normalized.record),
          };
        } else if (normalized.isVerified) {
          _recordUploadInRecentHistory(normalized);
        }
      }
      notifyListeners();
      _persistActiveBatchCache();
      triggerCloudSync();
    }
  }

  List<String> _collectItemIdentifiers(BatchItem item) {
    final ids = <String>[item.id];
    if (item.fileName.trim().isNotEmpty) ids.add(item.fileName.trim());
    final savedFn = (item.record['saved_filename'] ?? '').trim();
    if (savedFn.isNotEmpty && !ids.contains(savedFn)) {
      ids.add(savedFn);
    }
    return ids;
  }

  Future<void> _applyLocalDelete(BatchItem item, DateTime now) async {
    final newVer = item.currentVersion + 1;
    final updatedVersions = List<Map<String, dynamic>>.from(item.versions);
    final updatedHistory = List<Map<String, dynamic>>.from(item.editHistory);

    updatedVersions.add({
      'version': newVer,
      'timestamp': now.toIso8601String(),
      'action': 'delete',
      'user_name': _activeUserName ?? 'Logistics User',
      'user_mobile': _activeUserMobile ?? '',
      'details': 'Consignment item removed from batch queue',
      'diff': {'deleted': true},
      'snapshot_data': Map<String, String>.from(item.record),
    });

    updatedHistory.add({
      'timestamp': now.toIso8601String(),
      'user': _activeUserName ?? 'Logistics User',
      'mobile': _activeUserMobile ?? '',
      'action': 'delete',
      'version': newVer,
      'details': 'Item removed from batch queue',
    });

    _deletedItems.add(item.copyWith(
      deletedAt: now,
      isDeleted: true,
      currentVersion: newVer,
      versions: updatedVersions,
      editHistory: updatedHistory,
    ));

    try {
      FileLifecycleService.instance.recordFileDeletion(
        item.fileName,
        user: _activeUserName ?? 'Logistics User',
        reason: 'Consignment item removed from batch queue',
      );
    } catch (_) {}

    final ids = _collectItemIdentifiers(item);
    _items.removeWhere((i) => i.id == item.id);
    _completedItemIds.remove(item.id);
    purgeFromPreviousUploads(
      id: item.id,
      fileName: item.fileName,
      imagePath: item.imagePath,
      savedFilename: item.record['saved_filename'],
    );
    if (!_isDisposed) notifyListeners();
    await _addDismissedIdentifiers(ids);
    await _persistActiveBatchCache();
    await _persistCompletedItemsCache();
  }

  /// Waits for server delete (/api/user-cloud-storage/delete-lr & /api/previous-uploads/delete)
  /// before deleting an LR locally and updating tombstones/caches.
  Future<bool> deleteItemWithCloudSync(String itemId) async {
    final index = _items.indexWhere((i) => i.id == itemId);
    if (index == -1) return false;

    final item = _items[index];
    final identifiers = _collectItemIdentifiers(item);
    final mob = _activeUserMobile;
    if (mob != null && mob.trim().isNotEmpty) {
      final cloudDeleted = await UserCloudService.instance.deleteCloudLr(
        mob,
        identifiers,
        baseUrl: _geminiService.serverUrl,
      );
      if (!cloudDeleted) {
        return false;
      }

      final prevTarget = (item.record['saved_filename'] ?? '').trim().isNotEmpty
          ? item.record['saved_filename']!.trim()
          : (item.fileName.trim().isNotEmpty ? item.fileName.trim() : item.id);
      await _geminiService.deletePreviousUpload(
        prevTarget,
        userMobile: mob,
        userName: _activeUserName,
        sessionToken: _activeSessionToken,
      );
      UserCloudService.instance
          .deleteCloudUploadHistory(
            mob,
            identifiers,
            baseUrl: _geminiService.serverUrl,
          )
          .catchError((_) => false);
    }

    await _applyLocalDelete(item, DateTime.now());
    triggerCloudSync();
    return true;
  }

  /// Removes an individual item from the queue and records lifecycle deletion.
  void removeItem(String itemId) {
    final index = _items.indexWhere((i) => i.id == itemId);
    final removed = _items.where((i) => i.id == itemId).toList();
    if (index != -1) {
      _applyLocalDelete(_items[index], DateTime.now());
    } else {
      _items.removeWhere((i) => i.id == itemId);
      if (!_isDisposed) notifyListeners();
    }
    triggerCloudSync();
    if (_activeUserMobile != null && _activeUserMobile!.isNotEmpty) {
      final ids = [itemId, ...removed.map((r) => r.fileName)];
      UserCloudService.instance.deleteCloudLr(
        _activeUserMobile!,
        ids,
        baseUrl: _geminiService.serverUrl,
      );
      final target = removed.isNotEmpty ? removed.first : null;
      final prevTarget = (target?.record['saved_filename'] ?? '').trim().isNotEmpty
          ? target!.record['saved_filename']!.trim()
          : (target != null && target.fileName.trim().isNotEmpty ? target.fileName.trim() : itemId);
      _geminiService.deletePreviousUpload(
        prevTarget,
        userMobile: _activeUserMobile,
        userName: _activeUserName,
        sessionToken: _activeSessionToken,
      );
    }
  }

  Future<void> _applyLocalClearAll(DateTime now) async {
    final tombstoneIds = <String>{};
    for (final item in _items) {
      final newVer = item.currentVersion + 1;
      final updatedVersions = List<Map<String, dynamic>>.from(item.versions);
      final updatedHistory = List<Map<String, dynamic>>.from(item.editHistory);

      updatedVersions.add({
        'version': newVer,
        'timestamp': now.toIso8601String(),
        'action': 'delete',
        'user_name': _activeUserName ?? 'Logistics User',
        'user_mobile': _activeUserMobile ?? '',
        'details': 'Batch queue cleared by user',
        'diff': {'deleted': true},
        'snapshot_data': Map<String, String>.from(item.record),
      });

      updatedHistory.add({
        'timestamp': now.toIso8601String(),
        'user': _activeUserName ?? 'Logistics User',
        'mobile': _activeUserMobile ?? '',
        'action': 'delete',
        'version': newVer,
        'details': 'Batch queue cleared by user',
      });

      _deletedItems.add(item.copyWith(
        deletedAt: now,
        isDeleted: true,
        currentVersion: newVer,
        versions: updatedVersions,
        editHistory: updatedHistory,
      ));
      tombstoneIds.addAll(_collectItemIdentifiers(item));
      try {
        FileLifecycleService.instance.recordFileDeletion(
          item.fileName,
          user: _activeUserName ?? 'Logistics User',
          reason: 'Batch queue cleared by user',
        );
      } catch (_) {}
    }
    for (final prev in _previousUploadsCache) {
      final pId = (prev['id'] ?? prev['file_id'] ?? '').toString().trim();
      final pFn = (prev['fileName'] ?? prev['filename'] ?? '').toString().trim();
      final pSv = (prev['saved_filename'] ?? '').toString().trim();
      if (pId.isNotEmpty) tombstoneIds.add(pId);
      if (pFn.isNotEmpty) tombstoneIds.add(pFn);
      if (pSv.isNotEmpty) tombstoneIds.add(pSv);
    }
    _items.clear();
    _previousUploadsCache.clear();
    _completedItemIds.clear();
    _lastExportedPath = null;
    _statusMessage = null;
    if (!_isDisposed) notifyListeners();
    await _addDismissedIdentifiers(tombstoneIds);
    await _persistActiveBatchCache();
    await _persistRecentUploadsCache();
    await _persistCompletedItemsCache();
  }

  /// Synchronizes Clear All with /api/user-cloud-storage/clear-all and /api/previous-uploads/clear-all.
  /// Keeps local state intact if cloud clearing fails; preserves export history.
  Future<bool> clearAllWithCloudSync() async {
    final mob = _activeUserMobile;
    if (mob != null && mob.trim().isNotEmpty) {
      final cloudCleared = await UserCloudService.instance.clearAllCloudStorage(
        mob,
        clearHistory: false,
        sessionToken: _activeSessionToken,
        baseUrl: _geminiService.serverUrl,
      );
      if (!cloudCleared) {
        return false;
      }
      await _geminiService.clearAllPreviousUploads(
        userMobile: mob,
        userName: _activeUserName,
        sessionToken: _activeSessionToken,
      );
    }

    _cloudSyncTimer?.cancel();
    await _applyLocalClearAll(DateTime.now());
    return true;
  }

  /// Clears the entire queue and records lifecycle deletion.
  void clearQueue() {
    final allIds = _items.map((i) => i.id).toList();
    _cloudSyncTimer?.cancel();
    _applyLocalClearAll(DateTime.now());
    if (_activeUserMobile != null && _activeUserMobile!.isNotEmpty) {
      UserCloudService.instance.clearAllCloudStorage(
        _activeUserMobile!,
        clearHistory: false,
        sessionToken: _activeSessionToken,
        baseUrl: _geminiService.serverUrl,
      );
      _geminiService.clearAllPreviousUploads(
        userMobile: _activeUserMobile,
        userName: _activeUserName,
        sessionToken: _activeSessionToken,
      );
      if (allIds.isNotEmpty) {
        UserCloudService.instance.deleteCloudLr(
          _activeUserMobile!,
          allIds,
          baseUrl: _geminiService.serverUrl,
        );
      }
    }
  }

  /// Restores a soft-deleted item back to active batch.
  void restoreDeletedItem(String itemId) {
    final index = _deletedItems.indexWhere((i) => i.id == itemId);
    if (index == -1) return;

    final item = _deletedItems[index];
    if (isDuplicate(
      record: item.record,
      imageHash: item.imageHash,
      imagePath: item.imagePath,
      excludeItemId: item.id,
    )) {
      triggerDuplicateNotice('This LR already exists. You cannot add the same LR multiple times.');
      return;
    }

    _deletedItems.removeAt(index);
    final restored = item.copyWith(
      isDeleted: false,
      deletedAt: null,
    );
    _items.add(restored);

    try {
      FileLifecycleService.instance.restoreDeletedFile(item.fileName);
    } catch (_) {}

    notifyListeners();
  }

  /// Restores a batch item to a previous snapshot version.
  void restoreVersion(String itemId, int targetVersion) {
    final index = _items.indexWhere((i) => i.id == itemId);
    if (index == -1) return;

    final item = _items[index];
    final targetVerMap = item.versions.firstWhere(
      (v) => v['version'] == targetVersion,
      orElse: () => {},
    );
    final snapData = targetVerMap['snapshot_data'];
    if (snapData is! Map) return;

    final restoredRecord = Map<String, String>.from(
      snapData.map((k, v) => MapEntry(k.toString(), v.toString())),
    );

    final now = DateTime.now();
    final newVer = item.currentVersion + 1;
    final updatedVersions = List<Map<String, dynamic>>.from(item.versions);
    updatedVersions.add({
      'version': newVer,
      'timestamp': now.toIso8601String(),
      'action': 'restore',
      'details': 'Restored earlier snapshot',
      'diff': {'restored_from': targetVersion},
      'snapshot_data': restoredRecord,
    });

    final updatedHistory = List<Map<String, dynamic>>.from(item.editHistory);
    updatedHistory.add({
      'timestamp': now.toIso8601String(),
      'action': 'restore_version',
      'version': newVer,
      'details': 'Reverted fields to earlier snapshot',
    });

    _items[index] = item.copyWith(
      record: restoredRecord,
      editedAt: now,
      currentVersion: newVer,
      versions: updatedVersions,
      editHistory: updatedHistory,
    );

    try {
      FileLifecycleService.instance.restoreFileVersion(item.fileName, targetVersion);
    } catch (_) {}

    notifyListeners();
  }

  /// Retries processing for a failed item.
  void retryItem(String itemId) {
    final index = _items.indexWhere((i) => i.id == itemId);
    if (index == -1) return;

    _items[index] = _items[index].copyWith(
      status: BatchItemStatus.pending,
      errorMessage: null,
    );
    notifyListeners();
    _processQueue();
  }

  /// Exports items into a single styled Excel file.
  /// If [itemsToExport] is provided, only those items (e.g. verified-only) are exported.
  Future<String?> exportToExcel({DocumentSchema? schema, List<BatchItem>? itemsToExport}) async {
    final list = List<BatchItem>.from(itemsToExport ?? _items);
    if (list.isEmpty) return null;

    try {
      _statusMessage = 'Generating Excel spreadsheet...';
      notifyListeners();

      final activeSchema = schema ?? _currentSchema;

      final bytes = await Future.microtask(
        () => _excelService.generateExcelBytes(
          items: list,
          schema: activeSchema,
          userName: _activeUserName,
        ),
      );

      final file = await _excelService.saveBytesToFile(bytes);
      _lastExportedPath = file.path;
      _statusMessage = 'Exported to ${file.path}';
      notifyListeners();
      return file.path;
    } catch (e) {
      _statusMessage = 'Export failed: $e';
      notifyListeners();
      return null;
    }
  }

  /// Shares the most recently exported Excel file via the Android share sheet.
  Future<void> shareLastExport() async {
    if (_lastExportedPath != null) {
      await _excelService.shareExcelFile(_lastExportedPath!);
    }
  }

  /// Opens the most recently exported Excel file in the default spreadsheet app.
  Future<void> openLastExport() async {
    if (_lastExportedPath != null) {
      await _excelService.openExcelFile(_lastExportedPath!);
    }
  }

  @override
  void notifyListeners() {
    if (!_isDisposed && hasListeners) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    if (!_isDisposed) {
      _isDisposed = true;
      _cloudSyncTimer?.cancel();
      if (_processingCompleter != null && !_processingCompleter!.isCompleted) {
        _processingCompleter!.complete();
      }
      _processingCompleter = null;
      _ocrService.dispose();
      super.dispose();
    }
  }
}
