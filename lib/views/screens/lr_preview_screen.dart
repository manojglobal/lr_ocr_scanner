import 'package:flutter/material.dart';
import '../../models/batch_item.dart';
import '../../state/batch_controller.dart';
import '../widgets/billing_image_viewer.dart';
import '../widgets/step_indicator_bar.dart';
import 'batch_queue_screen.dart';

/// Screen 8: Preview LR (Realistic Logistics Voucher / Consignment Note)
/// Matches Step 8 in Logistics_LR_OCR_Workflow_App_Mockup__1_.png:
/// - Header: BOX N FREIGHT LOGISTICS SOLUTION PVT. LTD.
/// - Consignment Note details (LR No, Date, Station from/to)
/// - Consignor & Consignee comparison boxes
/// - Goods, Weight & Freight table
/// - Driver & Vehicle details
/// - Back & Add More LR / LR List buttons.
class LrPreviewScreen extends StatelessWidget {
  final BatchItem item;
  final BatchProcessingController controller;

  const LrPreviewScreen({
    super.key,
    required this.item,
    required this.controller,
  });

  String _get(String key, [String fallback = '—']) {
    final rec = item.record;
    if (rec.containsKey(key) && rec[key]!.trim().isNotEmpty) {
      return rec[key]!.trim();
    }
    final clean = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    for (final e in rec.entries) {
      final cEntry = e.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
      if (clean == cEntry && e.value.trim().isNotEmpty) {
        return e.value.trim();
      }
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    const brandNavy = Color(0xFF0F172A);
    const brandBlue = Color(0xFF0284C7);
    const borderSlate = Color(0xFFE2E8F0);

    final lrNo = _get('LR No *', _get('grno (*)', _get('grno', item.fileName)));
    final date = _get('grdt *', _get('grdt', _get('stockdt ', '')));
    final customer = _get('Customer Name *', _get('cngr *', ''));
    final department = _get('Depatment Name', _get('department', ''));
    final counter = _get('Counter', _get('branchrefcode', ''));
    final origin = _get('orgrefcode', '');
    final dest = _get('destrefcode', '');
    final consignor = _get('cngr *', customer);
    final consignee = _get('cnge *', '');
    final consignorGst = _get('cngrgstno *', '');
    final consigneeGst = _get('cngegstno *', '');

    final vehNo = _get('Vehicle No *', '');
    final vehType = _get('Vehicle Type *', _get('Vehicle Category', ''));
    final driverName = _get('Driver Name *', _get('driver_name', ''));
    final driverMob = _get('Mobile no   *', _get('mobile_no', ''));
    final licNo = _get('Liscense No *', _get('license_no', ''));

    final goods = _get('goods', '');
    final pkgs = _get('bookedpckgs', '');
    final packing = _get('packing', '');
    final actWeight = _get('bookedaweight', '');
    final chgWeight = _get('bookedcweight', '');

    final freight = _get('freight  *', _get('freight', ''));
    final hamali = _get('oamount', '');
    final ewb = _get('ewaybillno', '');
    final invNo = _get('invoiceno', '');

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: brandNavy),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'LR Preview',
          style: TextStyle(color: brandNavy, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        actions: const [],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Row(
              children: [
                Tooltip(
                  message: 'View LR Image',
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: brandBlue,
                      backgroundColor: const Color(0xFFF0F9FF),
                      side: const BorderSide(color: Color(0xFFBAE6FD)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: const Size(0, 30),
                    ),
                    icon: const Icon(Icons.image_outlined, size: 14),
                    label: const Text('View LR Image', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
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
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Share Voucher',
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: brandBlue,
                      backgroundColor: const Color(0xFFF0F9FF),
                      side: const BorderSide(color: Color(0xFFBAE6FD)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: const Size(0, 30),
                    ),
                    icon: const Icon(Icons.share_outlined, size: 14),
                    label: const Text('Share Voucher', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Voucher ready for export and sharing.')),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    // Realistic Document Voucher Card
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFCBD5E1), width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(12),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Header: Company Logo & Info
                          Center(
                            child: Column(
                              children: [
                                const Text(
                                  'BOX N FREIGHT LOGISTICS SOLUTION PVT. LTD.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                    color: brandNavy,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  'Fleet Hub: Kolkata - Mumbai - Delhi - Bangalore - Chennai',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 10, color: Color(0xFF64748B)),
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE0F2FE),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    'CONSIGNMENT NOTE / LORRY RECEIPT',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: brandBlue,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Divider(height: 1, color: borderSlate),
                          const SizedBox(height: 10),

                          // Top Voucher Info Row
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _buildMetaItem('LR NO.', lrNo, isHighlight: true),
                              _buildMetaItem('DATE', date),
                              _buildMetaItem('FROM', origin),
                              _buildMetaItem('TO', dest),
                            ],
                          ),
                          const SizedBox(height: 10),
                          const Divider(height: 1, color: borderSlate),
                          const SizedBox(height: 10),

                          // Consignor & Consignee Columns
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: borderSlate),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('CONSIGNOR (FROM):', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                                      const SizedBox(height: 2),
                                      Text(consignor, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: brandNavy)),
                                      const SizedBox(height: 2),
                                      Text('GST: $consignorGst', style: const TextStyle(fontSize: 9, color: Color(0xFF475569))),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: borderSlate),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('CONSIGNEE (TO):', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                                      const SizedBox(height: 2),
                                      Text(consignee, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: brandNavy)),
                                      const SizedBox(height: 2),
                                      Text('GST: $consigneeGst', style: const TextStyle(fontSize: 9, color: Color(0xFF475569))),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),

                          // Goods Details Table
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: borderSlate),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Table(
                              border: TableBorder.all(color: borderSlate),
                              columnWidths: const {
                                0: FlexColumnWidth(1),
                                1: FlexColumnWidth(2.5),
                                2: FlexColumnWidth(1.2),
                                3: FlexColumnWidth(1.5),
                              },
                              children: [
                                TableRow(
                                  decoration: const BoxDecoration(color: Color(0xFFF1F5F9)),
                                  children: [
                                    _buildTh('Pkgs'),
                                    _buildTh('Description'),
                                    _buildTh('Actual Wt'),
                                    _buildTh('Charged Wt'),
                                  ],
                                ),
                                TableRow(
                                  children: [
                                    _buildTd(pkgs),
                                    _buildTd(packing.isNotEmpty ? '$goods ($packing)' : goods),
                                    _buildTd(actWeight),
                                    _buildTd(chgWeight),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Vehicle & Driver Details Strip
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF3C7),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: const Color(0xFFFCD34D)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Vehicle No: $vehNo', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF92400E))),
                                    Text('Type: $vehType  •  Dept: $department  •  Counter: $counter', style: const TextStyle(fontSize: 9, color: Color(0xFFB45309))),
                                  ],
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text('Driver: $driverName', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF92400E))),
                                    Text('Mob: $driverMob  •  DL: $licNo', style: const TextStyle(fontSize: 9, color: Color(0xFFB45309))),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Financial & Freight Summary
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: borderSlate),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('E-Way Bill: $ewb', style: const TextStyle(fontSize: 10, color: Color(0xFF475569))),
                                    Text('Invoice No: $invNo', style: const TextStyle(fontSize: 10, color: Color(0xFF475569))),
                                  ],
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text('Hamali/Other: ₹$hamali', style: const TextStyle(fontSize: 10, color: Color(0xFF64748B))),
                                    Text('Freight Amount: ₹$freight', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: brandNavy)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Signatures Footer
                          const Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Flexible(child: Text('Consignor Signature', style: TextStyle(fontSize: 9, color: Colors.grey), overflow: TextOverflow.ellipsis)),
                              SizedBox(width: 4),
                              Flexible(child: Text('Driver Signature', style: TextStyle(fontSize: 9, color: Colors.grey), overflow: TextOverflow.ellipsis)),
                              SizedBox(width: 4),
                              Flexible(child: Text('Authorized Signatory', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: brandNavy), overflow: TextOverflow.ellipsis)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Actions: Back, View LR Image, and LR List
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: brandNavy,
                              side: const BorderSide(color: Color(0xFFCBD5E1)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('Back', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
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
                            label: const Text('View LR Image', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: brandBlue,
                              side: const BorderSide(color: brandBlue, width: 1.5),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (_) => BatchQueueScreen(controller: controller),
                                ),
                              );
                            },
                            icon: const Icon(Icons.format_list_bulleted, size: 16),
                            label: const Text('LR List', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: brandBlue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Step Indicator Flow Bar (Step 8 Active)
            StepIndicatorBar(
              currentStep: 8,
              controller: controller,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaItem(String label, String value, {bool isHighlight = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 9, color: Colors.blueGrey, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: isHighlight ? const Color(0xFF0284C7) : const Color(0xFF0F172A),
          ),
        ),
      ],
    );
  }

  Widget _buildTh(String text) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
      ),
    );
  }

  Widget _buildTd(String text) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 10, color: Color(0xFF0F172A)),
      ),
    );
  }
}
