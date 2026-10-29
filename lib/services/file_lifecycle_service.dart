import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Manages on-device file lifecycle tracking (Created At, Edited At, Exported At, Deleted At),
/// immutable snapshot vault versioning, and 30-day retention purge policies on Android.
class FileLifecycleService {
  FileLifecycleService._();
  static final FileLifecycleService instance = FileLifecycleService._();

  static const String _registryFileName = 'file_lifecycle_registry.json';
  File? _registryFile;
  Directory? _snapshotsDir;
  Map<String, Map<String, dynamic>> _cache = {};
  bool _initialized = false;
  Completer<void>? _initCompleter;

  Future<void> _ensureInitialized() async {
    if (_initialized && _registryFile != null) return;
    if (_initCompleter != null) {
      await _initCompleter!.future;
      return;
    }
    _initCompleter = Completer<void>();
    try {
      final dir = await getApplicationDocumentsDirectory();
      _registryFile = File('${dir.path}/$_registryFileName');
      _snapshotsDir = Directory('${dir.path}/snapshots');
      if (!await _snapshotsDir!.exists()) {
        await _snapshotsDir!.create(recursive: true);
      }

      if (await _registryFile!.exists()) {
        final content = await _registryFile!.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is Map) {
          _cache = decoded.map((k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)));
        }
      }

      // One-time cleanup of legacy file lifecycle registry for all users
      final flagFile = File('${dir.path}/.bnf_audit_history_cleared_v1');
      if (!await flagFile.exists()) {
        _cache.clear();
        if (_registryFile != null && await _registryFile!.exists()) {
          try {
            await _registryFile!.delete();
          } catch (_) {}
        }
        if (_snapshotsDir != null && await _snapshotsDir!.exists()) {
          try {
            await _snapshotsDir!.delete(recursive: true);
            await _snapshotsDir!.create(recursive: true);
          } catch (_) {}
        }
        try {
          await flagFile.writeAsString('true');
        } catch (_) {}
      }

      _initialized = true;
    } catch (e) {
      debugPrint('[FileLifecycleService] Init error: $e');
      _cache = {};
      _initialized = true;
    } finally {
      if (_initCompleter != null && !_initCompleter!.isCompleted) {
        _initCompleter!.complete();
      }
      _initCompleter = null;
    }
  }

  Future<void> _persist() async {
    try {
      if (_registryFile != null) {
        final tmpFile = File('${_registryFile!.path}.tmp_${DateTime.now().microsecondsSinceEpoch}');
        await tmpFile.writeAsString(jsonEncode(_cache), flush: true);
        await tmpFile.rename(_registryFile!.path);
      }
    } catch (e) {
      debugPrint('[FileLifecycleService] Persist error: $e');
    }
  }

  String _formatIso(DateTime dt) => dt.toIso8601String();

  /// Returns the snapshot directory for a given file ID.
  Future<Directory> _getItemSnapshotDir(String fileId) async {
    await _ensureInitialized();
    final itemDir = Directory('${_snapshotsDir!.path}/$fileId');
    if (!await itemDir.exists()) {
      await itemDir.create(recursive: true);
    }
    return itemDir;
  }

  /// Records the creation of an Excel file, snapshot screenshot, or bilty image.
  /// Initializes Version 1 snapshot.
  Future<Map<String, dynamic>> recordFileCreation(
    String filePath,
    String fileType, {
    String createdBy = 'Logistics User',
    Map<String, dynamic>? customMeta,
    Map<String, String>? initialData,
  }) async {
    await _ensureInitialized();
    final now = DateTime.now();
    final fileName = filePath.split(RegExp(r'[/\\]')).last;
    final fileId = 'fl_${now.millisecondsSinceEpoch}_${fileName.hashCode.abs().toRadixString(16)}';

    int sizeBytes = 0;
    try {
      final f = File(filePath);
      if (await f.exists()) {
        sizeBytes = await f.length();
      }
    } catch (_) {}

    // Save initial v1 snapshot JSON
    String? snapshotPath;
    if (initialData != null && initialData.isNotEmpty) {
      try {
        final vaultDir = await _getItemSnapshotDir(fileId);
        final snapFile = File('${vaultDir.path}/v1_created_${now.millisecondsSinceEpoch}.json');
        await snapFile.writeAsString(jsonEncode(initialData), flush: true);
        snapshotPath = snapFile.path;
      } catch (e) {
        debugPrint('[FileLifecycleService] Snapshot write error: $e');
      }
    }

    final v1Record = <String, dynamic>{
      'version': 1,
      'timestamp': _formatIso(now),
      'action': 'create',
      'user': createdBy,
      'details': 'File registered in system',
      'diff': null,
      'snapshot_file': snapshotPath,
      'snapshot_data': initialData,
    };

    final entry = <String, dynamic>{
      'file_id': fileId,
      'file_name': fileName,
      'file_type': fileType, // 'excel', 'snapshot_screenshot', 'bilty_image', 'export'
      'file_path': filePath,
      'file_size_bytes': sizeBytes,
      'file_size_kb': (sizeBytes / 1024).toStringAsFixed(1),
      'created_at': _formatIso(now),
      'edited_at': null,
      'exported_at': null,
      'deleted_at': null,
      'is_deleted': false,
      'created_by': createdBy,
      'last_edited_by': null,
      'current_version': 1,
      'versions': [v1Record],
      'edit_history': <Map<String, dynamic>>[
        {
          'timestamp': _formatIso(now),
          'user': createdBy,
          'action': 'create',
          'details': 'File registered in system',
        }
      ],
      'custom_meta': customMeta ?? {},
      'current_data': initialData,
    };

    _cache[fileId] = entry;
    await _persist();
    return entry;
  }

  /// Records an edit event, increments version number (v2, v3...), saves snapshot, and logs diffs.
  Future<void> recordFileEdit(
    String filePathOrId, {
    String user = 'Logistics User',
    String action = 'edit',
    dynamic details,
    Map<String, dynamic>? diff,
    Map<String, String>? newData,
  }) async {
    await _ensureInitialized();
    final entry = _findEntry(filePathOrId);
    if (entry == null) return;

    final now = DateTime.now();
    final fileId = entry['file_id'] as String;
    final currVer = (entry['current_version'] as int?) ?? 1;
    final newVer = currVer + 1;

    entry['edited_at'] = _formatIso(now);
    entry['last_edited_by'] = user;
    entry['current_version'] = newVer;

    // Save snapshot of this version
    String? snapshotPath;
    if (newData != null && newData.isNotEmpty) {
      try {
        final vaultDir = await _getItemSnapshotDir(fileId);
        final snapFile = File('${vaultDir.path}/v${newVer}_edit_${now.millisecondsSinceEpoch}.json');
        await snapFile.writeAsString(jsonEncode(newData), flush: true);
        snapshotPath = snapFile.path;
        entry['current_data'] = newData;
      } catch (e) {
        debugPrint('[FileLifecycleService] Version snapshot write error: $e');
      }
    }

    final versionRecord = <String, dynamic>{
      'version': newVer,
      'timestamp': _formatIso(now),
      'action': action,
      'user': user,
      'details': details ?? 'Updated snapshot #$newVer',
      'diff': diff,
      'snapshot_file': snapshotPath,
      'snapshot_data': newData,
    };

    final versions = (entry['versions'] as List?)?.map((v) => Map<String, dynamic>.from(v as Map)).toList() ?? [];
    versions.add(versionRecord);
    entry['versions'] = versions;

    final history = (entry['edit_history'] as List?) ?? [];
    history.add({
      'timestamp': _formatIso(now),
      'user': user,
      'action': action,
      'version': newVer,
      'details': details ?? 'File updated snapshot #$newVer',
    });
    entry['edit_history'] = history;

    await _persist();
  }

  /// Restores an earlier snapshot as a new active version.
  Future<Map<String, dynamic>?> restoreFileVersion(
    String filePathOrId,
    int targetVersion, {
    String user = 'Logistics User',
  }) async {
    await _ensureInitialized();
    final entry = _findEntry(filePathOrId);
    if (entry == null) return null;

    final versions = (entry['versions'] as List?)?.map((v) => Map<String, dynamic>.from(v as Map)).toList() ?? [];
    final matched = versions.firstWhere((v) => v['version'] == targetVersion, orElse: () => {});
    if (matched.isEmpty) return null;

    final now = DateTime.now();
    final currVer = (entry['current_version'] as int?) ?? 1;
    final newVer = currVer + 1;

    entry['edited_at'] = _formatIso(now);
    entry['last_edited_by'] = user;
    entry['current_version'] = newVer;

    final restoredData = matched['snapshot_data'];
    if (restoredData is Map) {
      entry['current_data'] = Map<String, String>.from(restoredData.map((k, v) => MapEntry(k.toString(), v.toString())));
    }

    versions.add({
      'version': newVer,
      'timestamp': _formatIso(now),
      'action': 'restore',
      'user': user,
      'details': 'Restored earlier snapshot',
      'diff': {'restored_from': targetVersion},
      'snapshot_data': restoredData,
    });
    entry['versions'] = versions;

    final history = (entry['edit_history'] as List?) ?? [];
    history.add({
      'timestamp': _formatIso(now),
      'user': user,
      'action': 'restore_version',
      'details': 'Reverted record to earlier snapshot',
    });
    entry['edit_history'] = history;

    await _persist();
    return entry;
  }

  /// Records an export or download event with timestamp.
  Future<void> recordFileExport(
    String filePathOrId, {
    String user = 'Logistics User',
    String destination = 'device_download',
  }) async {
    await _ensureInitialized();
    final entry = _findEntry(filePathOrId);
    if (entry == null) return;

    final now = DateTime.now();
    entry['exported_at'] = _formatIso(now);

    final history = (entry['edit_history'] as List?) ?? [];
    history.add({
      'timestamp': _formatIso(now),
      'user': user,
      'action': 'export',
      'destination': destination,
    });
    entry['edit_history'] = history;

    await _persist();
  }

  /// Records file deletion with timestamp and reasons, marking is_deleted = true while preserving versions.
  Future<void> recordFileDeletion(
    String filePathOrId, {
    String user = 'Logistics User',
    String reason = 'User deleted item',
  }) async {
    await _ensureInitialized();
    final entry = _findEntry(filePathOrId);
    if (entry == null) return;

    final now = DateTime.now();
    entry['deleted_at'] = _formatIso(now);
    entry['is_deleted'] = true;

    final history = (entry['edit_history'] as List?) ?? [];
    history.add({
      'timestamp': _formatIso(now),
      'user': user,
      'action': 'delete',
      'reason': reason,
    });
    entry['edit_history'] = history;

    await _persist();
  }

  /// Restores a soft-deleted file back into the active list.
  Future<Map<String, dynamic>?> restoreDeletedFile(
    String filePathOrId, {
    String user = 'Logistics User',
  }) async {
    await _ensureInitialized();
    final entry = _findEntry(filePathOrId);
    if (entry == null) return null;

    final now = DateTime.now();
    entry['deleted_at'] = null;
    entry['is_deleted'] = false;

    final history = (entry['edit_history'] as List?) ?? [];
    history.add({
      'timestamp': _formatIso(now),
      'user': user,
      'action': 'restore_from_trash',
      'details': 'Item restored from deleted items',
    });
    entry['edit_history'] = history;

    await _persist();
    return entry;
  }

  /// Automatically deletes snapshot and screenshot files older than 30 days from local storage.
  /// Updates each purged file entry with deleted_at and logs 'auto_retention_purge' in history.
  Future<List<String>> purgeLocalSnapshotsOlderThan({int days = 30}) async {
    await _ensureInitialized();
    final List<String> purged = [];
    final now = DateTime.now();

    for (final entry in _cache.values) {
      final fType = entry['file_type']?.toString();
      final isDeleted = entry['is_deleted'] == true;
      final createdStr = entry['created_at']?.toString();
      if (createdStr == null) continue;

      try {
        final dt = DateTime.parse(createdStr);
        final diffDays = now.difference(dt).inDays;
        if (diffDays >= days) {
          // Check snapshot vault directory
          final fileId = entry['file_id']?.toString();
          if (fileId != null && _snapshotsDir != null) {
            final vDir = Directory('${_snapshotsDir!.path}/$fileId');
            if (await vDir.exists()) {
              try {
                await vDir.delete(recursive: true);
                purged.add('$fileId (vault)');
              } catch (_) {}
            }
          }

          if ((fType == 'snapshot_screenshot' || fType == 'screenshot') && !isDeleted) {
            final fPath = entry['file_path']?.toString();
            if (fPath != null) {
              final f = File(fPath);
              if (await f.exists()) {
                await f.delete();
              }
            }

            final nowIso = _formatIso(now);
            entry['deleted_at'] = nowIso;
            entry['is_deleted'] = true;

            final history = (entry['edit_history'] as List?) ?? [];
            history.add({
              'timestamp': nowIso,
              'user': 'System (Retention Policy)',
              'action': 'auto_retention_purge',
              'reason': 'Automatically purged after $days-day retention period ($diffDays days old)',
            });
            entry['edit_history'] = history;
            purged.add(entry['file_name']?.toString() ?? entry['file_id']?.toString() ?? '');
          }
        }
      } catch (e) {
        debugPrint('[FileLifecycleService] Error checking file age: $e');
      }
    }

    if (purged.isNotEmpty) {
      await _persist();
      debugPrint('[FileLifecycleService] Auto-purged ${purged.length} snapshot(s) older than $days days.');
    }

    return purged;
  }

  /// Returns all tracked file entries sorted by creation time descending.
  Future<List<Map<String, dynamic>>> getAllMetadata({bool includeDeleted = false}) async {
    await _ensureInitialized();
    final items = _cache.values.where((e) => includeDeleted || e['is_deleted'] != true).toList();
    items.sort((a, b) => (b['created_at']?.toString() ?? '').compareTo(a['created_at']?.toString() ?? ''));
    return items;
  }

  /// Returns all deleted items.
  Future<List<Map<String, dynamic>>> getDeletedFiles() async {
    await _ensureInitialized();
    final items = _cache.values.where((e) => e['is_deleted'] == true).toList();
    items.sort((a, b) => (b['deleted_at']?.toString() ?? '').compareTo(a['deleted_at']?.toString() ?? ''));
    return items;
  }

  Map<String, dynamic>? _findEntry(String key) {
    if (_cache.containsKey(key)) return _cache[key];
    final norm = key.replaceAll('\\', '/');
    final fn = norm.split('/').last;
    for (final entry in _cache.values) {
      if (entry['file_id'] == key || entry['file_name'] == key || entry['file_name'] == fn) {
        return entry;
      }
      final path = entry['file_path']?.toString().replaceAll('\\', '/');
      if (path == norm || (path != null && path.endsWith('/$fn'))) {
        return entry;
      }
    }
    return null;
  }
}
