import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Previously Uploaded LRs Android Parity with Web', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'bnf_user_name': 'Test User',
        'bnf_user_mobile': '9876543210',
        'bnf_recent_uploaded_lrs': jsonEncode([
          {
            'id': 'lr-item-1',
            'fileName': 'LR_1001.pdf',
            'saved_filename': 'LR_1001_saved.pdf',
            'imagePath': 'dummy/path/LR_1001.pdf',
            'lrNo': '1001',
            'isPdf': true,
            'createdAt': DateTime.now().toIso8601String(),
            'status': 'completed',
            'isVerified': true,
            'preview_url': '',
            'preview_path': '',
            'record': {
              'LR No *': '1001',
              'Consignor Name': 'ABC Corp',
              'Consignee Name': 'XYZ Ltd',
            },
          },
          {
            'id': 'lr-item-2',
            'fileName': 'LR_1002.jpg',
            'saved_filename': 'LR_1002_saved.jpg',
            'imagePath': 'dummy/path/LR_1002.jpg',
            'lrNo': '1002',
            'isPdf': false,
            'createdAt': DateTime.now().toIso8601String(),
            'status': 'completed',
            'isVerified': true,
            'preview_url': '',
            'preview_path': '',
            'record': {
              'LR No *': '1002',
              'Consignor Name': 'Sunrise Logistics',
              'Consignee Name': 'Moon Traders',
            },
          }
        ]),
      });
    });

    testWidgets('Previously Uploaded LRs are displayed and removal removes only from history while keeping LR List intact', (tester) async {
      final controller = BatchProcessingController(useGeminiBackend: false);
      
      // Seed controller.items (LR List) with the same items using addItemDirectly
      final batchItem1 = BatchItem(
        id: 'lr-item-1',
        imagePath: 'dummy/path/LR_1001.pdf',
        fileName: 'LR_1001.pdf',
        createdAt: DateTime.now(),
        status: BatchItemStatus.completed,
        record: {
          'LR No *': '1001',
          'Consignor Name': 'ABC Corp',
          'Consignee Name': 'XYZ Ltd',
          'saved_filename': 'LR_1001_saved.pdf',
        },
      );
      final batchItem2 = BatchItem(
        id: 'lr-item-2',
        imagePath: 'dummy/path/LR_1002.jpg',
        fileName: 'LR_1002.jpg',
        createdAt: DateTime.now(),
        status: BatchItemStatus.completed,
        record: {
          'LR No *': '1002',
          'Consignor Name': 'Sunrise Logistics',
          'Consignee Name': 'Moon Traders',
          'saved_filename': 'LR_1002_saved.jpg',
        },
      );
      controller.addItemDirectly(batchItem1);
      controller.addItemDirectly(batchItem2);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Verify Previously Uploaded LRs section is visible with 2 items
      expect(find.text('Previously Uploaded LRs'), findsOneWidget);
      expect(find.text('2 files'), findsOneWidget);
      expect(find.text('LR: 1001'), findsOneWidget);
      expect(find.text('LR: 1002'), findsOneWidget);

      // 2. Verify close icons (✕) are rendered on the items
      final closeIcons = find.byIcon(Icons.close);
      expect(closeIcons, findsNWidgets(2));

      // 3. Tap ✕ on the first item (LR: 1001)
      await tester.tap(closeIcons.first);
      await tester.pumpAndSettle();

      // 4. Verify confirmation modal matches Web design:
      // - Title: 'Remove Consignment LR'
      // - Badge: 'WARNING'
      // - Dynamic message referencing LR 1001
      // - Buttons: Cancel & Confirm
      expect(find.text('Remove Consignment LR'), findsOneWidget);
      expect(find.text('WARNING'), findsOneWidget);
      expect(find.textContaining('remove consignment LR "1001" from Previously Uploaded history'), findsOneWidget);
      expect(find.textContaining('It will remain available in your LR List.'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Confirm'), findsOneWidget);

      // 5. Test Cancel button preserves item
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('LR: 1001'), findsOneWidget);
      expect(find.text('LR: 1002'), findsOneWidget);
      expect(controller.items.length, 2);

      // 6. Tap ✕ again and this time click Confirm
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      // 7. Verify LR 1001 is removed from Previously Uploaded LRs strip
      expect(find.text('LR: 1001'), findsNothing);
      expect(find.text('LR: 1002'), findsOneWidget);
      expect(find.text('1 files'), findsOneWidget);

      // 8. CRITICAL: Verify LR List in controller STILL HAS BOTH ITEMS!
      expect(controller.items.length, 2);
      expect(controller.items.any((i) => i.id == 'lr-item-1'), isTrue);
      expect(controller.items.firstWhere((i) => i.id == 'lr-item-1').record['LR No *'], '1001');

      // 9. Verify persistence in SharedPreferences:
      final prefs = await SharedPreferences.getInstance();
      final dismissed = prefs.getStringList('bnf_dismissed_recent_lrs') ?? [];
      expect(dismissed.contains('lr-item-1') || dismissed.contains('LR_1001.pdf') || dismissed.contains('LR_1001_saved.pdf'), isTrue);

      final recentsRaw = prefs.getString('bnf_recent_uploaded_lrs') ?? '[]';
      final recentsList = jsonDecode(recentsRaw) as List;
      expect(recentsList.any((r) => r['id'] == 'lr-item-1'), isFalse);
      expect(recentsList.any((r) => r['id'] == 'lr-item-2'), isTrue);

      // 10. Simulate App Restart: Mount a fresh HomeScreen
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // After restart, LR 1001 is still dismissed from history, while LR 1002 is visible
      expect(find.text('LR: 1001'), findsNothing);
      expect(find.text('LR: 1002'), findsOneWidget);
      // And LR List in controller still retains both items!
      expect(controller.items.length, 2);
    });
  });
}
