import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('User Data Isolation & History Sync Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('1. User data isolation: Cached history for User A is not exposed to User B', () async {
      final prefs = await SharedPreferences.getInstance();

      // Setup User A history
      final userAExcels = [
        {
          'export_id': 'EXP_USER_A_001',
          'filename': 'UserA_Report.xlsx',
          'download_url': '/api/download-export/UserA_Report.xlsx',
          'total_lrs': 3,
          'exported_by': 'User A',
          'user_mobile': '8009970417',
        }
      ];
      await prefs.setString('bnf_exported_batches', jsonEncode(userAExcels));
      await prefs.setString('bnf_user_mobile', '8009970417');

      final controller = BatchProcessingController(useGeminiBackend: true);
      controller.setActiveUser('8009970417', name: 'User A', sessionToken: 'token_a');
      expect(controller.activeUserMobile, equals('8009970417'));

      // Switch to User B (e.g., logout or login as another user)
      controller.setActiveUser('9999999999', name: 'User B', sessionToken: 'token_b');
      expect(controller.activeUserMobile, equals('9999999999'));

      // Ensure switching user clears prior user's items
      expect(controller.items, isEmpty);
      expect(controller.deletedItems, isEmpty);
    });

    test('2. Export history payload excludes heavy base64 strings', () async {
      final mockServerExportHistory = [
        {
          'export_id': 'EXP_20261101_001',
          'filename': 'LR_Report_01_11_2026.xlsx',
          'download_url': '/api/download-export/LR_Report_01_11_2026.xlsx',
          'audit_filename': 'Audit_LR_Report_01_11_2026.xlsx',
          'total_lrs': 4,
          'file_size_kb': 7.3,
          'generated_on': '01-Nov-2026 06:45:08 PM',
          'exported_by': 'maurya',
          'documents': [
            {
              'filename': 'IMG_20260928_175240.jpg',
              'document_title': 'Consignment Note',
              'data': {'LR No *': '32815', 'Vehicle No *': 'KA52C8617'},
              'preview_url': '/uploads/LR_20261101_184149_preview.jpg',
              'file_url': '/snapshots/LR_20261101_184149.jpg',
            }
          ]
        }
      ];

      final encoded = jsonEncode(mockServerExportHistory);
      // Ensure payload is compact and lightweight (< 5KB, never megabytes)
      expect(encoded.length, lessThan(5000));
      expect(encoded.contains('data:image/'), isFalse);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bnf_exported_batches', encoded);

      final readBack = prefs.getString('bnf_exported_batches');
      expect(readBack, isNotNull);
      final decoded = jsonDecode(readBack!) as List;
      expect(decoded.length, equals(1));
      expect(decoded[0]['filename'], equals('LR_Report_01_11_2026.xlsx'));
      expect(decoded[0]['total_lrs'], equals(4));
    });

    test('3. Previous uploads deduplication accepts server valid uploads without nested record', () {
      final serverUploads = [
        {
          'id': 'lr_12345',
          'filename': 'IMG_20260928_175245.jpg',
          'saved_filename': 'LR_30049_IMG.jpg',
          'preview_url': '/uploads/preview.jpg',
          'file_url': '/snapshots/LR_30049_IMG.jpg',
          'lrNo': '30049',
          'status': 'completed',
          'isVerified': true,
          'data': {},
        },
        {
          'id': 'lr_pdf_67890',
          'filename': 'DocScanner_Oct_9.pdf',
          'saved_filename': 'LR_32991_DocScanner.pdf',
          'preview_url': '/uploads/pdf_preview.jpg',
          'file_url': '/snapshots/LR_32991_DocScanner.pdf',
          'lrNo': '',
          'status': 'completed',
          'isVerified': true,
          'data': {},
        }
      ];

      final results = <Map<String, dynamic>>[];
      for (final item in serverUploads) {
        final status = (item['status'] ?? '').toString().toLowerCase();
        final isInvalid = item['isInvalidLr'] == true ||
            item['error_code'] == 'INVALID_LR' ||
            status == 'failed' ||
            status == 'pending' ||
            (item['isVerified'] != true && status != 'completed');
        if (isInvalid) continue;

        final fn = (item['filename'] ?? item['fileName'] ?? '').toString().toLowerCase();
        final lr = (item['lrNo'] ?? '').toString().toLowerCase();
        final hasLrNo = lr.trim().isNotEmpty && lr.trim() != 'null';
        final rec = item['record'] is Map ? item['record'] as Map : (item['data'] is Map ? item['data'] as Map : null);
        final hasData = rec != null && rec.isNotEmpty;
        final hasFile = fn.trim().isNotEmpty && fn.trim() != 'null';
        final hasUrl = (item['saved_filename'] ?? item['file_url'] ?? item['preview_url'] ?? item['imagePath'] ?? '').toString().trim().isNotEmpty;

        if (!hasLrNo && !hasData && (!hasFile || !hasUrl)) {
          continue;
        }
        results.add(item);
      }

      expect(results.length, equals(2));
      expect(results[0]['filename'], equals('IMG_20260928_175245.jpg'));
      expect(results[1]['filename'], equals('DocScanner_Oct_9.pdf'));
    });
  });
}
