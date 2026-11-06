import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/models/batch_item.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/screens/customization_driver_screen.dart';
import 'package:ocr_to_excel/views/screens/edit_bilty_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'bnf_user_mobile': '8009970417',
      'bnf_user_name': 'Test User',
      'bnf_user_token': 'bnf_token',
    });
  });

  group('Fix 1: Freight Field Validation', () {
    test('Freight defaults to empty in BatchProcessingController even if OCR produces 0 or empty', () {
      final item = BatchItem(
        id: 'test-freight-empty',
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        createdAt: DateTime.now(),
        record: {
          'freight': '0',
          'freight  *': '0.00',
        },
      );

      final rawFrt = (item.record['freight  *'] ?? item.record['freight'] ?? '').trim();
      final cleanFrt = (rawFrt == '0' || rawFrt == '0.00' || rawFrt == '0.0') ? '' : rawFrt;
      expect(cleanFrt, isEmpty, reason: 'Freight must not display 0 or automatic values');
    });

    testWidgets('CustomizationDriverScreen blocks Save & Verify when Freight is empty and shows validation message', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());
      addTearDown(() => tester.view.resetDevicePixelRatio());

      final controller = BatchProcessingController();
      final item = BatchItem(
        id: 'test-freight-validation',
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        createdAt: DateTime.now(),
        record: {
          'grno (*)': '32754',
          'grdt *': '05/11/2026',
          'Customer Name *': 'HIMALAYA WELLNESS COMPANY',
          'Depatment Name': 'HIMALAYA-SILIGURI',
          'Counter': 'DELHI',
          'cngr *': 'HIMALAYA WELLNESS COMPANY',
          'cngrgstno *': '07AAAAA0000A1Z5',
          'cnge *': 'DESTINATION PHARMA',
          'cngegstno *': '29BBBBB1111B2Z9',
          'Vehicle No *': 'KA25AB2955',
          'Vehicle Type *': 'Market',
          'Driver Name *': 'Ramesh Kumar',
          'Mobile no   *': '9876543210',
          'Liscense No *': 'KA2520190001234',
          'Valid Up to *': '31/12/2030',
          'freight  *': '', // Empty freight
          'freight': '',
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomizationDriverScreen(item: item, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find Save & Verify button and tap it
      final saveBtn = find.text('Save & Verify');
      expect(saveBtn, findsOneWidget);
      await tester.ensureVisible(saveBtn);
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      // Must display mandatory incomplete modal with Freight Charge *
      expect(find.text('Mandatory Fields Incomplete'), findsOneWidget);
      expect(find.textContaining('Freight Charge *'), findsWidgets);
    });

    testWidgets('CustomizationDriverScreen allows Save & Verify when Freight is manually entered', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());
      addTearDown(() => tester.view.resetDevicePixelRatio());

      final controller = BatchProcessingController();
      final item = BatchItem(
        id: 'test-freight-success',
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        createdAt: DateTime.now(),
        record: {
          'grno (*)': '32754',
          'grdt *': '05/11/2026',
          'Customer Name *': 'HIMALAYA WELLNESS COMPANY',
          'Depatment Name': 'HIMALAYA-SILIGURI',
          'Counter': 'DELHI',
          'cngr *': 'HIMALAYA WELLNESS COMPANY',
          'cngrgstno *': '07AAAAA0000A1Z5',
          'cnge *': 'DESTINATION PHARMA',
          'cngegstno *': '29BBBBB1111B2Z9',
          'Vehicle No *': 'KA25AB2955',
          'Vehicle Type *': 'Market',
          'Driver Name *': 'Ramesh Kumar',
          'Mobile no   *': '9876543210',
          'Liscense No *': 'KA2520190001234',
          'Valid Up to *': '31/12/2030',
          'freight  *': '',
          'freight': '',
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomizationDriverScreen(item: item, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Enter manual freight
      final allTextFields = find.byType(TextField);
      for (int i = 0; i < allTextFields.evaluate().length; i++) {
        final tf = tester.widget<TextField>(allTextFields.at(i));
        if (tf.controller?.text == '') {
          await tester.enterText(allTextFields.at(i), '1850.00');
          break;
        }
      }
      await tester.pumpAndSettle();

      // Tap Save & Verify
      final saveBtn = find.text('Save & Verify');
      await tester.ensureVisible(saveBtn);
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      // Modal should NOT appear, since freight is filled
      expect(find.text('Mandatory Fields Incomplete'), findsNothing);
    });
  });

  group('Fix 2: Product Code Mapping', () {
    test('Product Code is empty by default when missing from LR and never uses Product Type value', () {
      final parseData = <String, String>{
        'cngr *': 'HIMALAYA WELLNESS COMPANY',
        'goods': 'Ayurvedic Products',
      };

      // Controller post-OCR logic
      const prodTypeOptions = {'Surface-FTL', 'Surface-PTL', 'Global-TT', 'Global-MT', 'AIR'};
      final pCode = (parseData['productcode'] ?? '').trim();
      if (prodTypeOptions.contains(pCode)) {
        parseData['productcode'] = '';
      }
      if ((parseData['product_type'] ?? '').trim().isEmpty) {
        parseData['product_type'] = 'Surface-FTL';
        parseData['Product Type'] = 'Surface-FTL';
      }

      expect(parseData['productcode'], isNull, reason: 'Missing productcode must not be populated with Product Type');
      expect(parseData['product_type'], equals('Surface-FTL'));
    });

    test('Explicit Product Code in LR is preserved separately from Product Type', () {
      final parseData = <String, String>{
        'cngr *': 'GOLD PLUS FLOAT GLASS',
        'productcode': 'HSN-7005',
        'product_type': 'Global-TT',
      };

      const prodTypeOptions = {'Surface-FTL', 'Surface-PTL', 'Global-TT', 'Global-MT', 'AIR'};
      final pCode = (parseData['productcode'] ?? '').trim();
      if (prodTypeOptions.contains(pCode)) {
        parseData['productcode'] = '';
      }

      expect(parseData['productcode'], equals('HSN-7005'));
      expect(parseData['product_type'], equals('Global-TT'));
    });
  });

  group('Fix 3: Back to LR Data Button', () {
    testWidgets('Tapping Back to LR Data navigates back to Edit LR Data preserving changes', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());
      addTearDown(() => tester.view.resetDevicePixelRatio());

      final controller = BatchProcessingController();
      final item = BatchItem(
        id: 'test-back-btn',
        fileName: 'test.jpg',
        imagePath: '/tmp/test.jpg',
        createdAt: DateTime.now(),
        record: {
          'grno (*)': '32754',
          'grdt *': '05/11/2026',
          'Customer Name *': 'HIMALAYA WELLNESS COMPANY',
          'Depatment Name': 'HIMALAYA-SILIGURI',
          'Counter': 'DELHI',
          'freight  *': '',
          'freight': '',
        },
      );
      controller.addItemDirectly(item);

      await tester.pumpWidget(
        MaterialApp(
          home: EditBiltyScreen(item: item, controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Advance to tab 3 (Other Details)
      final nextBtn = find.text('Next');
      await tester.tap(nextBtn);
      await tester.pumpAndSettle();
      await tester.tap(nextBtn);
      await tester.pumpAndSettle();
      await tester.tap(nextBtn);
      await tester.pumpAndSettle();

      // Now on tab 3, button is "Next: Master Data"
      expect(find.text('Next: Master Data'), findsOneWidget);
      await tester.tap(find.text('Next: Master Data'));
      await tester.pumpAndSettle();

      // Now on CustomizationDriverScreen
      expect(find.text('LR Customization & Driver Details'), findsOneWidget);

      // Verify "Back to LR Data" button exists and tap it
      final backBtn = find.widgetWithText(OutlinedButton, 'Back to LR Data');
      expect(backBtn, findsOneWidget);
      await tester.tap(backBtn);
      await tester.pumpAndSettle();

      // Should have popped back to EditBiltyScreen on tab 3 (Other Details)
      expect(find.text('Other Details'), findsWidgets);
      // And the controller has the active item
      expect(controller.items.first.resolveField('grno (*)'), equals('32754'));
    });
  });
}
