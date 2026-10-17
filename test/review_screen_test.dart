import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_to_excel/services/excel_service.dart';
import 'package:ocr_to_excel/services/format_parser.dart';
import 'package:ocr_to_excel/services/image_service.dart';
import 'package:ocr_to_excel/services/ocr_service.dart';
import 'package:ocr_to_excel/services/permission_service.dart';
import 'package:ocr_to_excel/state/batch_controller.dart';
import 'package:ocr_to_excel/views/review_screen.dart';
import 'package:ocr_to_excel/views/widgets/editable_data_table.dart';

class StubPermissionService extends PermissionService {}
class StubImageService extends ImageService {}
class StubOcrService extends OcrService {
  @override
  Future<void> dispose() async {}
}

void main() {
  late BatchProcessingController controller;

  setUp(() {
    controller = BatchProcessingController(
      permissionService: StubPermissionService(),
      imageService: StubImageService(),
      ocrService: StubOcrService(),
      parserService: FormatParserService(),
      excelService: ExcelService(),
    );
  });

  Widget buildTestableWidget() {
    return MaterialApp(
      home: ReviewScreen(controller: controller),
    );
  }

  testWidgets('renders empty table message and disabled export button when queue is empty', (tester) async {
    await tester.pumpWidget(buildTestableWidget());
    await tester.pump();

    expect(find.text('No records in queue'), findsOneWidget);

    final exportButtonFinder = find.widgetWithText(FilledButton, 'Export to Excel (.xlsx)');
    expect(exportButtonFinder, findsOneWidget);
    final button = tester.widget<FilledButton>(exportButtonFinder);
    expect(button.onPressed, isNull);
  });

  testWidgets('displays extracted records and allows tapping a cell to edit', (tester) async {
    // Add item manually to controller
    controller.addImagePath('/docs/test_invoice.jpg');

    // Simulate completion with fields
    final item = controller.items.first;
    controller.updateRecordField(item.id, 'invoice_no', 'INV-555');
    controller.updateRecordField(item.id, 'date', '2026-09-27');
    controller.updateRecordField(item.id, 'total_amount', r'$100.00');

    await tester.pumpWidget(buildTestableWidget());
    await tester.pump();

    // Verify cell rendered
    expect(find.text('INV-555'), findsOneWidget);
    expect(find.byType(EditableDataTable), findsOneWidget);

    // Tap the cell to open the edit dialog
    await tester.tap(find.text('INV-555'));
    await tester.pumpAndSettle();

    // Verify edit dialog opened
    expect(find.text('Edit Invoice No'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    // Enter new text and press Save
    await tester.enterText(find.byType(TextField), 'INV-MODIFIED-999');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Verify state was updated
    expect(controller.items.first.record['invoice_no'], 'INV-MODIFIED-999');
    expect(find.text('INV-MODIFIED-999'), findsOneWidget);
  });
}
