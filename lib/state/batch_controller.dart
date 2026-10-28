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
import '../services/ocr_service.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../services/permission_service.dart';
import '../services/file_lifecycle_service.dart';
import '../services/master_data_service.dart';
import '../services/pdf_assembler_service.dart';

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
  }

  void _purgeOldItems() {
    final now = DateTime.now();
    _items.removeWhere((i) => now.difference(i.createdAt).inDays >= 30);
    _deletedItems.removeWhere((i) => now.difference(i.createdAt).inDays >= 30);
  }

  bool _fallbackNotificationPending = false;
  String? _fallbackNoticeMessage;
  bool _duplicateNoticePending = false;
  String? _duplicateNoticeMessage;
  List<Map<String, dynamic>> _previousUploadsCache = [];

  int _currentOcrStep = 1;
  String _currentProcessingFileName = '';
  int _processingFileIndex = 1;
  int _processingTotalFiles = 1;

  // Getters
  List<BatchItem> get items => List.unmodifiable(_items);
  List<BatchItem> get deletedItems => List.unmodifiable(_deletedItems);
  List<Map<String, dynamic>> get previousUploadsCache => List.unmodifiable(_previousUploadsCache);
  bool get isProcessing => _isProcessing;
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
    _previousUploadsCache = List<Map<String, dynamic>>.from(list);
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

  /// Checks whether a given LR number, image hash, or core details already exists
  /// in the active batch items or previously uploaded LRs.
  bool isDuplicate({
    String? lrNo,
    String? imagePath,
    String? imageHash,
    String? fileName,
    Map<String, String>? record,
    String? excludeItemId,
  }) {
    // 1. Resolve candidate LR No.
    final candidateLr = normalizeLrNo(lrNo ?? extractLrNoFromRecord(record));

    // 2. Resolve candidate image hash
    final candidateHash = imageHash ?? (imagePath != null ? computeImageHash(imagePath) : '');

    // 3. Resolve candidate file name
    final candidateFileName = (fileName ?? (imagePath != null ? imagePath.split(RegExp(r'[/\\]')).last : '')).toLowerCase();

    // 4. Extract core composite fields
    final candidateCust = (record?['Customer Name *'] ?? record?['cngr *'] ?? '').trim().toLowerCase();
    final candidateCnge = (record?['cnge *'] ?? '').trim().toLowerCase();
    final candidateVeh = (record?['Vehicle No *'] ?? '').trim().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();

    // A. Check active batch items
    for (final item in _items) {
      if (item.isDeleted) continue;
      if (excludeItemId != null && item.id == excludeItemId) continue;

      // Tier 1: Check normalized LR number (most reliable)
      if (candidateLr.isNotEmpty) {
        final existingLr = normalizeLrNo(extractLrNoFromRecord(item.record));
        if (existingLr.isNotEmpty && existingLr == candidateLr) {
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
      if (candidateFileName.isNotEmpty && !candidateFileName.startsWith('image_picker') && !candidateFileName.startsWith('scaled_')) {
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

    // B. Check previous uploads cache (so duplicate documents are caught on FIRST upload attempt)
    for (final prev in _previousUploadsCache) {
      if (excludeItemId != null && prev['id'] == excludeItemId) continue;

      // Tier 1: Check LR number
      if (candidateLr.isNotEmpty) {
        final prevLr = normalizeLrNo((prev['lrNo'] ?? prev['lr_no'] ?? prev['grno'] ?? (prev['record'] is Map ? (prev['record']['LR No *'] ?? prev['record']['grno'] ?? '') : '')).toString());
        if (prevLr.isNotEmpty && prevLr == candidateLr) {
          return true;
        }
      }

      // Tier 2: Check file name / saved filename / basename
      if (candidateFileName.isNotEmpty && !candidateFileName.startsWith('image_picker') && !candidateFileName.startsWith('scaled_')) {
        final prevFn = (prev['fileName'] ?? prev['filename'] ?? '').toString().toLowerCase();
        final prevSaved = (prev['saved_filename'] ?? (prev['record'] is Map ? prev['record']['saved_filename'] : '') ?? '').toString().toLowerCase();
        final prevPath = (prev['imagePath'] ?? prev['file_path'] ?? '').toString();
        final prevBase = prevPath.isNotEmpty ? prevPath.split(RegExp(r'[/\\]')).last.toLowerCase() : '';
        if (prevFn.isNotEmpty && (prevFn == candidateFileName || (prevSaved.isNotEmpty && prevSaved == candidateFileName))) {
          return true;
        }
        if (prevBase.isNotEmpty && !prevBase.startsWith('image_picker') && !prevBase.startsWith('scaled_') && prevBase == candidateFileName) {
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

  Future<void> _loadSavedSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mob = prefs.getString('bnf_user_mobile');
      final name = prefs.getString('bnf_user_name');
      final token = prefs.getString('bnf_session_token');
      final recentRaw = prefs.getString('bnf_recent_uploaded_lrs');
      if (recentRaw != null && recentRaw.isNotEmpty) {
        try {
          final decoded = jsonDecode(recentRaw) as List<dynamic>;
          _previousUploadsCache = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        } catch (_) {}
      }
      if (mob != null && mob.trim().isNotEmpty) {
        _activeUserMobile = mob.trim();
        _activeUserName = name ?? _activeUserName;
        _activeSessionToken = token;
        await hydrateFromCloud();
      }
    } catch (_) {}
  }

  /// Hydrates active batch and previous uploads from shared cloud JSON DB (/api/user-cloud-storage)
  Future<void> hydrateFromCloud() async {
    final mob = _activeUserMobile;
    if (mob == null || mob.trim().isEmpty) return;
    try {
      final cloudData = await UserCloudService.instance.fetchUserCloudData(mob, baseUrl: _geminiService.serverUrl);
      if (cloudData != null) {
        // 1. Hydrate active batch (merge without duplicating)
        if (cloudData['active_batch'] is List) {
          final cloudList = (cloudData['active_batch'] as List);
          bool batchChanged = false;
          for (final rawDoc in cloudList) {
            if (rawDoc is Map) {
              final item = BatchItem.fromCloudDoc(Map<String, dynamic>.from(rawDoc));
              final exists = _items.any((i) =>
                  i.id == item.id ||
                  (item.record['saved_filename'] != null &&
                      item.record['saved_filename']!.isNotEmpty &&
                      i.record['saved_filename'] == item.record['saved_filename']));
              if (!exists) {
                _items.add(item);
                batchChanged = true;
              }
            }
          }
          if (batchChanged && !_isDisposed) notifyListeners();
        }

        // 2. Cache uploaded LRs from cloud into local SharedPreferences for instant HomeScreen parity
        final prefs = await SharedPreferences.getInstance();
        if (cloudData['uploaded_lrs'] is List && (cloudData['uploaded_lrs'] as List).isNotEmpty) {
          final cloudUploads = (cloudData['uploaded_lrs'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          _previousUploadsCache = cloudUploads;
          await prefs.setString('bnf_recent_uploaded_lrs', jsonEncode(cloudData['uploaded_lrs']));
        }

        // 3. Cache generated Excel exports
        if (cloudData['generated_excels'] is List && (cloudData['generated_excels'] as List).isNotEmpty) {
          await prefs.setString('bnf_exported_batches', jsonEncode(cloudData['generated_excels']));
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
        _previousUploadsCache = List<Map<String, dynamic>>.from(uploads);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('bnf_recent_uploaded_lrs', jsonEncode(uploads));
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
    final bool sessionChanged = (sessionToken != null && _activeSessionToken != sessionToken) ||
        (sessionToken == null && _activeUserMobile != mobile);

    if (sessionChanged) {
      _items.clear();
      _deletedItems.clear();
      _activeUserMobile = mobile;
      _activeUserName = name ?? _activeUserName;
      _activeSessionToken = sessionToken;
      notifyListeners();
      hydrateFromCloud();
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
      if (changed) notifyListeners();
    }
  }

  /// Clears in-memory batch and user session upon logout to prevent any data leak
  void clearForLogout() {
    _items.clear();
    _deletedItems.clear();
    _activeUserMobile = null;
    _activeUserName = null;
    _activeSessionToken = null;
    notifyListeners();
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
  Future<String> _ensurePermanentFile(String originalPath) async {
    try {
      final srcFile = File(originalPath);
      if (!await srcFile.exists()) return originalPath;

      Directory? docsDir;
      try {
        docsDir = await getApplicationDocumentsDirectory();
      } catch (_) {
        return originalPath; // Headless unit test fallback
      }

      final targetDir = Directory('${docsDir.path}/lr_documents');
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

    // Ensure permanent copies of each captured page
    final permanentPaths = <String>[];
    for (final p in paths) {
      permanentPaths.add(await _ensurePermanentFile(p));
    }

    String submissionFilePath;
    String submissionFileName;
    String? imageHash;

    if (permanentPaths.length == 1) {
      submissionFilePath = permanentPaths.first;
      submissionFileName = submissionFilePath.split(RegExp(r'[/\\]')).last;
      imageHash = computeImageHash(submissionFilePath);
    } else {
      // Assemble multiple pages into a single PDF document dossier
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
        imagePaths: permanentPaths,
        outputPath: pdfPath,
      );
      submissionFilePath = pdfFile.path;
      submissionFileName = submissionFilePath.split(RegExp(r'[/\\]')).last;
      imageHash = computeImageHash(submissionFilePath);
    }

    // Pre-OCR duplicate check
    if (isDuplicate(imagePath: submissionFilePath, imageHash: imageHash, fileName: submissionFileName)) {
      triggerDuplicateNotice('This LR already exists. You cannot add the same LR multiple times.');
      return false;
    }

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
    return true;
  }

  /// Adds multiple selected photos from the gallery to the queue and starts processing.
  Future<bool> addFromGallery() async {
    final hasPermission = await _permissionService.requestGalleryPermission();
    if (!hasPermission) {
      _statusMessage = 'Gallery permission was denied.';
      notifyListeners();
      return false;
    }

    final paths = await _imageService.pickMultipleImages();
    if (paths.isEmpty) return false;

    bool anyAdded = false;
    for (final path in paths) {
      final permanentPath = await _ensurePermanentFile(path);
      if (_addItemFromPath(permanentPath)) {
        anyAdded = true;
      }
    }
    if (anyAdded) {
      await _processQueue();
    }
    return anyAdded;
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
      if (paths.isNotEmpty) path = paths.first;
    }
    if (path == null || path.isEmpty) return false;

    final permanentPath = await _ensurePermanentFile(path);
    final added = _addItemFromPath(permanentPath);
    if (!added) return false;
    await _processQueue();
    return true;
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

  /// Ingests multiple files (images, PDFs) and processes them sequentially.
  Future<bool> addFilePaths(List<String> paths) async {
    bool anyAdded = false;
    for (final path in paths) {
      final permanentPath = await _ensurePermanentFile(path);
      if (_addItemFromPath(permanentPath)) {
        anyAdded = true;
      }
    }
    if (anyAdded) {
      await _processQueue();
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
  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;
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
                  .timeout(const Duration(seconds: 90));

              if (serverResult.status != ExtractionStatus.failed) {
                parseResult = serverResult;
                rawOcrText = serverResult.rawText;
                activeOcrEngine = 'server';
                if (isOrangeYellow) {
                  parseResult.data['BNF LR No'] = '';
                }
              } else {
                debugPrint('Server OCR failed: ${serverResult.message}. Switching to ML fallback.');
              }
            } catch (serverErr) {
              debugPrint('Server OCR unavailable ($serverErr). Switching to ML fallback.');
            }
          }

          // 2. Automatic Fallback: On-Device ML Kit OCR if server is unavailable or returned failure
          if (parseResult == null) {
            activeOcrEngine = 'ml_fallback';
            _fallbackNotificationPending = true;
            _fallbackNoticeMessage =
                'There is a technical issue with the server. You can contact the admin or continue. The results may be inaccurate.';
            _statusMessage = 'Extracting (${item.fileName})...';
            notifyListeners();

            // Extract pages for multi-page document fallback
            List<String> pagePaths = [];
            final rawPages = item.record['preview_pages'];
            if (rawPages != null && rawPages.isNotEmpty) {
              try {
                final decoded = jsonDecode(rawPages);
                if (decoded is List) {
                  pagePaths = decoded.map((e) => e.toString()).toList();
                }
              } catch (_) {}
            }

            if (pagePaths.isNotEmpty) {
              final textBuffer = StringBuffer();
              final allBlocks = <TextBlock>[];
              for (int pIdx = 0; pIdx < pagePaths.length; pIdx++) {
                final pText = await _ocrService.recognizeTextFromPath(pagePaths[pIdx]);
                if (pText.text.isNotEmpty) {
                  textBuffer.writeln('--- PAGE ${pIdx + 1} ---');
                  textBuffer.writeln(pText.text);
                  allBlocks.addAll(pText.blocks);
                }
              }
              final fullText = textBuffer.toString();
              rawOcrText = fullText;
              final fullRecognizedText = RecognizedText(text: fullText, blocks: allBlocks);
              parseResult = _parserService.parseRecognizedText(
                fullRecognizedText,
                schema: _currentSchema,
                isOrangeYellow: isOrangeYellow,
              );
            } else {
              // ML Kit On-Device Recognition
              final recognizedText =
                  await _ocrService.recognizeTextFromPath(item.imagePath);

              // Parse against active schema with image type awareness
              parseResult = _parserService.parseRecognizedText(
                recognizedText,
                schema: _currentSchema,
                isOrangeYellow: isOrangeYellow,
              );
              rawOcrText = recognizedText.text;
            }
          }

          // Retain multi-page scan metadata
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
            debugPrint('Duplicate LR detected post-OCR for item ${item.id}. Rejecting.');
            _items.removeWhere((i) => i.id == item.id);
            triggerDuplicateNotice('This LR already exists. You cannot add the same LR multiple times.');
            notifyListeners();
            continue;
          }

          // Step 5: Validating Data & Preserving Blanks
          _currentOcrStep = 5;
          notifyListeners();

          // Ensure driver details remain empty if absent in OCR (driver_master auto-fill disabled)
          for (final drvKey in ['Driver Name *', 'Mobile no   *', 'Liscense No *', 'Valid Up to *']) {
            parseResult.data.putIfAbsent(drvKey, () => '');
          }

          // Auto-enrich Department from ManiFest.xlsx if Customer is known
          final custName = (parseResult.data['Customer Name *'] ?? parseResult.data['cngr *'] ?? '').trim();
          if (custName.isNotEmpty && (parseResult.data['Depatment Name'] ?? '').trim().isEmpty) {
            final depts = MasterDataService.instance.getDepartmentsForCustomer(custName);
            if (depts.isNotEmpty) {
              final dest = (parseResult.data['destrefcode'] ?? '').trim().toUpperCase();
              String selectedDept = depts.first;
              for (final d in depts) {
                if (dest.isNotEmpty && d.toUpperCase().contains(dest)) {
                  selectedDept = d;
                  break;
                }
              }
              parseResult.data['Depatment Name'] = selectedDept;
              parseResult.data['department'] = selectedDept;
            }
          }

          // Auto-enrich Counter from BookingCounterMast.xlsx if Counter is empty
          if ((parseResult.data['Counter'] ?? '').trim().isEmpty) {
            final counters = MasterDataService.instance.getCounters();
            if (counters.isNotEmpty) {
              final org = (parseResult.data['orgrefcode'] ?? parseResult.data['branchrefcode'] ?? '').trim().toUpperCase();
              String selectedCounter = counters.first;
              for (final c in counters) {
                if (org.isNotEmpty && c.toUpperCase().contains(org)) {
                  selectedCounter = c;
                  break;
                }
              }
              parseResult.data['Counter'] = selectedCounter;
              parseResult.data['counter'] = selectedCounter;
              parseResult.data['branchrefcode'] = selectedCounter;
            }
          }

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

            _items[currentIndex] = item.copyWith(
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
          }
        } catch (e) {
          final currentIndex = _items.indexWhere((i) => i.id == item.id);
          if (currentIndex != -1) {
            _items[currentIndex] = item.copyWith(
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

    _items[index] = item.copyWith(
      record: updatedRecord,
      missingFields: updatedMissing,
      editedAt: now,
      editHistory: updatedHistory,
      currentVersion: newVer,
      versions: updatedVersions,
    );
    notifyListeners();
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
  void updateItem(BatchItem item) {
    final index = _items.indexWhere((i) => i.id == item.id);
    if (index != -1) {
      _items[index] = item;
      notifyListeners();
      triggerCloudSync();
    }
  }

  /// Removes an individual item from the queue and records lifecycle deletion.
  void removeItem(String itemId) {
    final index = _items.indexWhere((i) => i.id == itemId);
    if (index != -1) {
      final item = _items[index];
      final now = DateTime.now();
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

      final deletedItem = item.copyWith(
        deletedAt: now,
        isDeleted: true,
        currentVersion: newVer,
        versions: updatedVersions,
        editHistory: updatedHistory,
      );
      _deletedItems.add(deletedItem);

      try {
        FileLifecycleService.instance.recordFileDeletion(
          item.fileName,
          user: _activeUserName ?? 'Logistics User',
          reason: 'Consignment item removed from batch queue',
        );
      } catch (_) {}
    }
    final removed = _items.where((i) => i.id == itemId).toList();
    _items.removeWhere((i) => i.id == itemId);
    notifyListeners();
    triggerCloudSync();
    if (_activeUserMobile != null && _activeUserMobile!.isNotEmpty) {
      UserCloudService.instance.deleteCloudLr(
        _activeUserMobile!,
        [itemId, ...removed.map((r) => r.fileName)],
        baseUrl: _geminiService.serverUrl,
      );
    }
  }

  /// Clears the entire queue and records lifecycle deletion.
  void clearQueue() {
    final now = DateTime.now();
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
      try {
        FileLifecycleService.instance.recordFileDeletion(
          item.fileName,
          user: _activeUserName ?? 'Logistics User',
          reason: 'Batch queue cleared by user',
        );
      } catch (_) {}
    }
    final allIds = _items.map((i) => i.id).toList();
    _items.clear();
    _lastExportedPath = null;
    _statusMessage = null;
    notifyListeners();
    triggerCloudSync();
    if (_activeUserMobile != null && _activeUserMobile!.isNotEmpty && allIds.isNotEmpty) {
      UserCloudService.instance.deleteCloudLr(
        _activeUserMobile!,
        allIds,
        baseUrl: _geminiService.serverUrl,
      );
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
    final list = itemsToExport ?? _items;
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
  void dispose() {
    if (!_isDisposed) {
      _isDisposed = true;
      _cloudSyncTimer?.cancel();
      _ocrService.dispose();
      super.dispose();
    }
  }
}
