import 'package:flutter/material.dart';
import '../../models/batch_item.dart';
import '../../state/batch_controller.dart';
import '../widgets/billing_image_viewer.dart';
import '../widgets/step_indicator_bar.dart';
import 'batch_queue_screen.dart';
import 'edit_bilty_screen.dart';
import 'lr_preview_screen.dart';

/// Screen 7: Verification Success
/// Matches Step 7 in Logistics_LR_OCR_Workflow_App_Mockup__1_.png:
/// - Green checkmark badge with celebration confetti
/// - LR Data Verified Successfully!
/// - 7-field summary card (LR No, Customer, Department, Counter, Vehicle Category, Driver, Vehicle No)
/// - "Preview LR" and "Add More LR" actions
/// - Step Indicator (currentStep: 7)
class VerifiedScreen extends StatelessWidget {
  final BatchItem item;
  final BatchProcessingController controller;

  const VerifiedScreen({
    super.key,
    required this.item,
    required this.controller,
  });

  String _getField(String key, [String fallback = '—']) {
    final record = item.record;
    if (record.containsKey(key) && record[key]!.trim().isNotEmpty) {
      return record[key]!.trim();
    }
    final cleanKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    for (final entry in record.entries) {
      final cEntry = entry.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
      if (cleanKey == cEntry && entry.value.trim().isNotEmpty) {
        return entry.value.trim();
      }
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    const brandNavy = Color(0xFF0F172A);
    const brandBlue = Color(0xFF0284C7);
    const brandGreen = Color(0xFF16A34A);

    final lrNo = _getField('LR No *', _getField('grno (*)', _getField('grno', item.fileName)));
    final customer = _getField('Customer Name *', _getField('cngr *', _getField('customer', '—')));
    final department = _getField('Depatment Name', _getField('department', '—'));
    final counter = _getField('Counter', _getField('branchrefcode', '—'));
    final vehicleCategory = _getField('Vehicle Category', _getField('Vehicle Type *', 'MARKET'));
    final driver = _getField('Driver Name *', _getField('driver_name', _getField('driver', '—')));
    final vehicleNo = _getField('Vehicle No *', _getField('vehno', '—'));

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        title: const Text('Verification Success', style: TextStyle(color: brandNavy, fontWeight: FontWeight.bold, fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: brandNavy),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.image_outlined, color: brandBlue),
            tooltip: 'View LR Image',
            onPressed: () {
              final idx = controller.items.indexWhere((i) => i.id == item.id);
              BillingImageViewer.show(
                context,
                items: controller.items.isNotEmpty ? controller.items : [item],
                initialIndex: idx >= 0 ? idx : 0,
                controller: controller,
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.receipt_long_outlined, color: brandNavy),
            tooltip: 'Preview Voucher',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LrPreviewScreen(
                    item: item,
                    controller: controller,
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.edit_note, color: brandNavy),
            tooltip: 'Edit Again',
            onPressed: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (_) => EditBiltyScreen(item: item, controller: controller),
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                child: Column(
                  children: [
                    // Large Emerald Checkmark Badge with Confetti styling
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: const Color(0xFFDCFCE7),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF86EFAC), width: 3),
                        boxShadow: [
                          BoxShadow(
                            color: brandGreen.withAlpha(30),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Center(
                        child: Icon(Icons.check_circle_rounded, size: 52, color: brandGreen),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'LR Data Verified Successfully!',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: brandNavy),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Consignment details have been validated and saved to queue.',
                      style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),

                    // 7-Point Summary Card (Matching Mockup 7)
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: const BorderSide(color: Color(0xFFE2E8F0)),
                      ),
                      color: Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          children: [
                            _buildSummaryRow('LR No', lrNo, isBold: true, highlightColor: brandBlue),
                            const Divider(height: 18, color: Color(0xFFF1F5F9)),
                            _buildSummaryRow('Customer', customer),
                            const Divider(height: 18, color: Color(0xFFF1F5F9)),
                            _buildSummaryRow('Department', department),
                            const Divider(height: 18, color: Color(0xFFF1F5F9)),
                            _buildSummaryRow('Counter', counter),
                            const Divider(height: 18, color: Color(0xFFF1F5F9)),
                            _buildSummaryRow('Vehicle Category', vehicleCategory),
                            const Divider(height: 18, color: Color(0xFFF1F5F9)),
                            _buildSummaryRow('Driver', driver),
                            const Divider(height: 18, color: Color(0xFFF1F5F9)),
                            _buildSummaryRow('Vehicle No', vehicleNo, isBold: true, highlightColor: Colors.deepPurple),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Primary Action Buttons matching Web Screen 5: Edit Again & Next
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (_) => EditBiltyScreen(item: item, controller: controller, initialTab: 0),
                                ),
                              );
                            },
                            icon: const Icon(Icons.edit_outlined, size: 16),
                            label: const Text('Edit Again', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF334155),
                              backgroundColor: const Color(0xFFF1F5F9),
                              side: const BorderSide(color: Color(0xFFCBD5E1)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (_) => BatchQueueScreen(controller: controller),
                                ),
                              );
                            },
                            icon: const Icon(Icons.arrow_forward, size: 18),
                            label: const Text('Next', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFEA580C),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Secondary Actions: View LR Image & Add More LR
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              final idx = controller.items.indexWhere((i) => i.id == item.id);
                              BillingImageViewer.show(
                                context,
                                items: controller.items.isNotEmpty ? controller.items : [item],
                                initialIndex: idx >= 0 ? idx : 0,
                                controller: controller,
                              );
                            },
                            icon: const Icon(Icons.image_outlined, size: 16),
                            label: const Text('View LR Image', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: brandBlue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => BatchQueueScreen(controller: controller, autoOpenAddMore: true),
                                ),
                              );
                            },
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Add More LR', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: brandBlue,
                              side: const BorderSide(color: Color(0xFFBAE6FD)),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: TextButton.icon(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => LrPreviewScreen(
                                item: item,
                                controller: controller,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.receipt_long_outlined, size: 16, color: Colors.blueGrey),
                        label: const Text('Preview Printable Voucher', style: TextStyle(color: Colors.blueGrey, fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Step Indicator Flow Bar (Step 7 Active)
            StepIndicatorBar(
              currentStep: 2,
              controller: controller,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryRow(String label, String value, {bool isBold = false, Color? highlightColor}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 125,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
              color: highlightColor ?? const Color(0xFF0F172A),
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}
