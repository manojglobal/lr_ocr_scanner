import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/batch_item.dart';

/// Service that handles seamless synchronization with FastAPI user cloud storage
/// (/api/user-cloud-storage).
class UserCloudService {
  static final UserCloudService instance = UserCloudService._internal();
  UserCloudService._internal();

  static const String _prefUserMobile = 'bnf_user_mobile';
  static const String _prefUserName = 'bnf_user_name';
  static const String _prefUserId = 'bnf_user_id';
  static const String _prefSessionToken = 'bnf_session_token';

  Future<String> _resolveServerUrl(String? customBaseUrl) async {
    if (customBaseUrl != null && customBaseUrl.trim().isNotEmpty) {
      final url = customBaseUrl.trim();
      return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('gemini_backend_server_url') ?? 'http://192.168.1.2:8000';
    final url = saved.trim();
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  /// Fetches active batch and user cloud records for [mobile].
  Future<Map<String, dynamic>?> fetchUserCloudData(String mobile, {String? userId, String? baseUrl}) async {
    final prefs = await SharedPreferences.getInstance();
    final effectiveMobile = mobile.isNotEmpty ? mobile : (prefs.getString(_prefUserMobile) ?? '');
    final cleanMobile = effectiveMobile.replaceAll(RegExp(r'\D'), '');
    if (cleanMobile.isEmpty) return null;

    try {
      final server = await _resolveServerUrl(baseUrl);
      final queryParams = <String, String>{
        'user_mobile': cleanMobile,
      };
      if (userId != null && userId.isNotEmpty) {
        queryParams['user_id'] = userId;
      }
      final uri = Uri.parse('$server/api/user-cloud-storage').replace(queryParameters: queryParams);

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('bnf_user_token') ?? prefs.getString(_prefSessionToken) ?? '';
      final headers = <String, String>{
        'Accept': 'application/json',
      };
      if (token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      final resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final jsonBody = jsonDecode(resp.body);
        if (jsonBody is Map<String, dynamic> && jsonBody['success'] == true && jsonBody['data'] is Map) {
          return jsonBody['data'] as Map<String, dynamic>;
        }
      }
    } catch (e) {
      debugPrint('[UserCloudService] fetchUserCloudData error: $e');
    }
    return null;
  }

  /// Saves the active batch items to the cloud JSON database.
  Future<bool> saveActiveBatch(
    String mobile,
    List<BatchItem> items, {
    String? userId,
    String? userName,
    String? baseUrl,
  }) async {
    final cleanMobile = mobile.replaceAll(RegExp(r'\D'), '');
    if (cleanMobile.isEmpty) return false;

    try {
      final server = await _resolveServerUrl(baseUrl);
      final uri = Uri.parse('$server/api/user-cloud-storage/save-batch');

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('bnf_user_token') ?? prefs.getString(_prefSessionToken) ?? '';
      final resolvedName = userName ?? prefs.getString(_prefUserName) ?? 'Logistics User';
      final resolvedId = userId ?? prefs.getString(_prefUserId);

      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };
      if (token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      final docsToSend = items.map((i) => i.toCloudDoc()).toList();
      final payload = jsonEncode({
        'user_mobile': cleanMobile,
        'user_id': resolvedId,
        'user_name': resolvedName,
        'documents': docsToSend,
      });

      final resp = await http.post(uri, headers: headers, body: payload).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final jsonBody = jsonDecode(resp.body);
        return jsonBody['success'] == true;
      }
    } catch (e) {
      debugPrint('[UserCloudService] saveActiveBatch error: $e');
    }
    return false;
  }

  /// Soft-deletes LRs from cloud active batch.
  Future<bool> deleteCloudLr(
    String mobile,
    List<String> lrIdentifiers, {
    String? userId,
    String? baseUrl,
  }) async {
    final cleanMobile = mobile.replaceAll(RegExp(r'\D'), '');
    if (cleanMobile.isEmpty || lrIdentifiers.isEmpty) return false;

    try {
      final server = await _resolveServerUrl(baseUrl);
      final uri = Uri.parse('$server/api/user-cloud-storage/delete-lr');

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('bnf_user_token') ?? prefs.getString(_prefSessionToken) ?? '';
      final resolvedId = userId ?? prefs.getString(_prefUserId);

      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };
      if (token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      final payload = jsonEncode({
        'user_mobile': cleanMobile,
        'user_id': resolvedId,
        'lr_identifiers': lrIdentifiers,
      });

      final resp = await http.post(uri, headers: headers, body: payload).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final jsonBody = jsonDecode(resp.body);
        return jsonBody['success'] == true;
      }
    } catch (e) {
      debugPrint('[UserCloudService] deleteCloudLr error: $e');
    }
    return false;
  }

  /// Dismisses LRs from previously uploaded history in cloud JSON DB.
  /// Does NOT delete or alter items in active_batch (LR List).
  Future<bool> deleteCloudUploadHistory(
    String mobile,
    List<String> lrIdentifiers, {
    String? userId,
    String? baseUrl,
  }) async {
    final cleanMobile = mobile.replaceAll(RegExp(r'\D'), '');
    if (cleanMobile.isEmpty || lrIdentifiers.isEmpty) return false;

    try {
      final server = await _resolveServerUrl(baseUrl);
      final uri = Uri.parse('$server/api/user-cloud-storage/delete-upload-history');

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('bnf_user_token') ?? prefs.getString(_prefSessionToken) ?? '';
      final resolvedId = userId ?? prefs.getString(_prefUserId);

      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };
      if (token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      final payload = jsonEncode({
        'user_mobile': cleanMobile,
        'user_id': resolvedId,
        'lr_identifiers': lrIdentifiers,
      });

      final resp = await http.post(uri, headers: headers, body: payload).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final jsonBody = jsonDecode(resp.body);
        return jsonBody['success'] == true;
      }
    } catch (e) {
      debugPrint('[UserCloudService] deleteCloudUploadHistory error: $e');
    }
    return false;
  }

  /// Restores LRs to previously uploaded history in cloud JSON DB if re-uploaded.
  Future<bool> undismissCloudUpload(
    String mobile,
    List<String> lrIdentifiers, {
    String? userId,
    String? baseUrl,
  }) async {
    final cleanMobile = mobile.replaceAll(RegExp(r'\D'), '');
    if (cleanMobile.isEmpty || lrIdentifiers.isEmpty) return false;

    try {
      final server = await _resolveServerUrl(baseUrl);
      final uri = Uri.parse('$server/api/user-cloud-storage/undismiss-upload');

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('bnf_user_token') ?? prefs.getString(_prefSessionToken) ?? '';
      final resolvedId = userId ?? prefs.getString(_prefUserId);

      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };
      if (token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      final payload = jsonEncode({
        'user_mobile': cleanMobile,
        'user_id': resolvedId,
        'lr_identifiers': lrIdentifiers,
      });

      final resp = await http.post(uri, headers: headers, body: payload).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final jsonBody = jsonDecode(resp.body);
        return jsonBody['success'] == true;
      }
    } catch (e) {
      debugPrint('[UserCloudService] undismissCloudUpload error: $e');
    }
    return false;
  }
}
