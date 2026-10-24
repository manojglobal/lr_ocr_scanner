import 'dart:io';
import 'package:flutter/material.dart';
import '../../models/batch_item.dart';
import '../../state/batch_controller.dart';
import '../widgets/billing_image_viewer.dart';
import '../widgets/step_indicator_bar.dart';
import 'batch_queue_screen.dart';
import 'file_history_screen.dart';

/// Screen 4 & 5: Verify & Edit (Multi-Tab Form)
/// Matches Steps 4 & 5 in Logistics_LR_OCR_Workflow_App_Mockup__1_.png:
/// - 4 Segmented Tabs: Basic Details, Goods Details, Financial Details, Other Details
/// - Searchable suggestions & field inputs
/// - Cancel & Next navigation
/// - Links to Screen 6: LR Customization & Driver Details
class EditBiltyScreen extends StatefulWidget {
  final BatchItem item;
  final BatchProcessingController controller;
  final int initialTab;
  final VoidCallback? onVerified;

  const EditBiltyScreen({
    super.key,
    required this.item,
    required this.controller,
    this.initialTab = 0,
    this.onVerified,
  });

  @override
  State<EditBiltyScreen> createState() => _EditBiltyScreenState();
}

class _EditBiltyScreenState extends State<EditBiltyScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final Map<String, TextEditingController> _fieldControllers = {};
  late BatchItem _currentItem;

  // 4 Tabs matching Mockup Steps 4 & 5
  final List<String> _basicKeys = [
    'LR No *',
    'grdt *',
    'Customer Name *',
    'Depatment Name',
    'cngr *',
    'cnge *',
    'orgrefcode',
    'destrefcode',
    'Vehicle No *',
    'Vehicle Type *',
    'cngrgstno *',
    'cngegstno *',
  ];

  final List<String> _goodsKeys = [
    'goods',
    'productcode',
    'packing',
    'pmark',
    'bookedpckgs',
    'bookedaweight',
    'bookedcweight',
  ];

  final List<String> _finKeys = [
    'freight  *',
    'oamount',
    'loading start date *',
    'cgst',
    'sgst',
    'igst',
    'received',
    'advance',
    'collectionstncode',
    'staxpaidby',
    'dlvtype',
    'valgoods',
  ];

  final List<String> _otherKeys = [
    'productcode',
    'packing',
    'pmark',
    'goods',
    'bookedpckgs',
    'bookedaweight',
    'bookedcweight',
    'ewaybillno',
    'Valid Upto',
    'invoiceno',
    'invoiedt',
  ];

  @override
  void initState() {
    super.initState();
    _currentItem = widget.item;
    final startTab = widget.initialTab.clamp(0, 3);
    _tabController = TabController(length: 4, vsync: this, initialIndex: startTab);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });

    final record = widget.item.record;
    final allKeys = {..._basicKeys, ..._goodsKeys, ..._finKeys, ..._otherKeys};
    for (final key in allKeys) {
      String val = record[key] ?? '';
      if (val.isEmpty) {
        final cleanKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
        for (final entry in record.entries) {
          final cleanEntry = entry.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
          if (cleanKey == cleanEntry) {
            val = entry.value;
            break;
          }
        }
      }
      _fieldControllers[key] = TextEditingController(text: val);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final c in _fieldControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _openImageViewer() {
    final list = widget.controller.items.isNotEmpty ? widget.controller.items : [_currentItem];
    final idx = list.indexWhere((i) => i.id == _currentItem.id);
    BillingImageViewer.show(
      context,
      items: list,
      initialIndex: idx >= 0 ? idx : 0,
      controller: widget.controller,
    );
  }

  BatchItem _collectUpdatedItem() {
    final updated = Map<String, String>.from(_currentItem.record);
    for (final entry in _fieldControllers.entries) {
      updated[entry.key] = entry.value.text;
    }
    final newItem = _currentItem.copyWith(
      record: updated,
      status: BatchItemStatus.completed,
    );
    widget.controller.updateItem(newItem);
    _currentItem = newItem;
    return newItem;
  }

  void _handleNextAction() {
    _collectUpdatedItem();
    if (_tabController.index < 3) {
      _tabController.animateTo(_tabController.index + 1);
    } else {
      // Transition directly to Step 3: LR List
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BatchQueueScreen(
            controller: widget.controller,
          ),
        ),
      );
    }
  }

  void _proceedToDriverDetails() {
    _collectUpdatedItem();
    _tabController.animateTo(3);
  }

  @override
  Widget build(BuildContext context) {
    const brandNavy = Color(0xFF0F172A);
    const brandBlue = Color(0xFF0284C7);
    final file = File(widget.item.imagePath);

    final lrNoVal = _fieldControllers['LR No *']?.text.trim() ?? '';
    final titleText = lrNoVal.isNotEmpty ? 'LR: $lrNoVal' : widget.item.fileName;

    const currentStep = 2; // Step 2: LR & Master Verification

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: brandNavy),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _tabController.index == 3 ? 'Other Details' : 'Verify & Edit LR',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: brandNavy),
            ),
            Text(
              titleText,
              style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.image_outlined, color: brandBlue),
            tooltip: 'View LR Image',
            onPressed: _openImageViewer,
          ),
          IconButton(
            icon: const Icon(Icons.local_shipping_outlined, color: brandBlue),
            tooltip: 'Driver Details',
            onPressed: _proceedToDriverDetails,
          ),
          IconButton(
            icon: const Icon(Icons.history_outlined, color: brandNavy),
            tooltip: 'Audit History',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => FileHistoryScreen(controller: widget.controller),
                ),
              );
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            color: Colors.white,
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              labelColor: brandBlue,
              unselectedLabelColor: const Color(0xFF64748B),
              indicatorColor: brandBlue,
              indicatorWeight: 3,
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
              tabs: const [
                Tab(text: 'Basic Details'),
                Tab(text: 'Goods Details'),
                Tab(text: 'Financial Details'),
                Tab(text: 'Other Details'),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          // Fallback notice banner if any
          if (_currentItem.isFallbackOcr)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFFFEF3C7),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFB45309)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'There is a technical issue with the server. Results may be inaccurate. Please review all fields.',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF92400E)),
                    ),
                  ),
                ],
              ),
            ),

          // Quick Image / Document Strip Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.white,
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Builder(
                      builder: (context) {
                        final isPdf = widget.item.fileName.toLowerCase().endsWith('.pdf') || widget.item.imagePath.toLowerCase().endsWith('.pdf');
                        if (isPdf) {
                          return Container(
                            color: const Color(0xFFFEE2E2),
                            child: const Center(
                              child: Icon(Icons.picture_as_pdf, color: Color(0xFFDC2626), size: 22),
                            ),
                          );
                        }
                        if (file.existsSync()) {
                          return Image.file(
                            file,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              color: Colors.grey.shade200,
                              child: const Icon(Icons.image, size: 20, color: Colors.blueGrey),
                            ),
                          );
                        }
                        return Container(
                          color: const Color(0xFFE0F2FE),
                          child: const Center(
                            child: Icon(Icons.description, size: 20, color: Color(0xFF0284C7)),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item.fileName,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: brandNavy),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Text(
                        'Review and edit extracted fields below:',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _openImageViewer,
                  icon: const Icon(Icons.image_outlined, size: 15),
                  label: const Text('View LR Image', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: brandBlue,
                    side: const BorderSide(color: Color(0xFFBAE6FD)),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
              ],
            ),
          ),

          // 4 Tab Views
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildFormList(_basicKeys, Icons.description_outlined, 'Basic Logistics Details (LR & Parties)'),
                _buildFormList(_goodsKeys, Icons.inventory_2_outlined, 'Cargo, Commodity & Packaging Details'),
                _buildFormList(_finKeys, Icons.receipt_long_outlined, 'Invoicing, Freight & Taxes'),
                _buildFormList(_otherKeys, Icons.more_horiz_outlined, 'Additional Details'),
              ],
            ),
          ),

          // Bottom Action Bar (Cancel / Back on left, Next on right)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(12),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    flex: 1,
                    child: OutlinedButton(
                      onPressed: () {
                        if (_tabController.index > 0) {
                          _tabController.animateTo(_tabController.index - 1);
                        } else {
                          Navigator.of(context).pop();
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: brandNavy,
                        side: const BorderSide(color: Color(0xFFCBD5E1)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        _tabController.index > 0 ? 'Back' : 'Cancel',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: _handleNextAction,
                      icon: const Icon(Icons.arrow_forward, size: 18),
                      label: const Text(
                        'Next',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
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
            ),
          ),

          // Step Indicator Flow Bar
          StepIndicatorBar(
            currentStep: currentStep,
            controller: widget.controller,
          ),
        ],
      ),
    );
  }

  Widget _buildFormList(List<String> keys, IconData sectionIcon, String sectionTitle) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Icon(sectionIcon, size: 16, color: const Color(0xFF0284C7)),
            const SizedBox(width: 8),
            Text(
              sectionTitle,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.blueGrey),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: keys.map((key) {
                final ctrl = _fieldControllers[key]!;
                final isMandatory = key.contains('*');
                final isKeyDoc = key == 'LR No *' || key == 'grno (*)';
                final isDate = key == 'Valid Upto' || key == 'invoiedt' || key == 'grdt *' || key == 'loading start date *';
                final isSearch = key == 'Customer Name *' || key == 'orgrefcode' || key == 'destrefcode';

                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: ctrl,
                    builder: (context, value, _) {
                      final isEmpty = value.text.trim().isEmpty || value.text.trim() == '-';
                      return TextField(
                        controller: ctrl,
                        decoration: InputDecoration(
                          labelText: _getFieldLabel(key),
                          labelStyle: TextStyle(
                            fontSize: 13,
                            color: isEmpty
                                ? const Color(0xFFDC2626)
                                : (isMandatory ? const Color(0xFF0284C7) : Colors.blueGrey),
                            fontWeight: (isEmpty || isMandatory) ? FontWeight.bold : FontWeight.normal,
                          ),
                          prefixIcon: isKeyDoc
                              ? Icon(Icons.vpn_key_outlined, size: 18, color: isEmpty ? const Color(0xFFDC2626) : const Color(0xFF0284C7))
                              : null,
                          suffixIcon: isDate
                              ? const Icon(Icons.calendar_today, size: 16, color: Colors.blueGrey)
                              : isSearch
                                  ? const Icon(Icons.search, size: 18, color: Colors.blueGrey)
                                  : null,
                          filled: true,
                          fillColor: isEmpty ? const Color(0xFFFEF2F2) : const Color(0xFFF8FAFC),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(
                              color: isEmpty ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                              width: isEmpty ? 1.2 : 1.0,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(
                              color: isEmpty ? const Color(0xFFEF4444) : const Color(0xFFE2E8F0),
                              width: isEmpty ? 1.2 : 1.0,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(
                              color: isEmpty ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
                              width: 1.5,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  String _getFieldLabel(String key) {
    switch (key) {
      case 'productcode': return 'Product Code';
      case 'packing': return 'Packing';
      case 'pmark': return 'Packing Mark';
      case 'goods': return 'Goods Description *';
      case 'bookedpckgs': return 'No. of Packages *';
      case 'bookedaweight': return 'Actual Weight (KG) *';
      case 'bookedcweight': return 'Charged Weight (KG) *';
      case 'ewaybillno': return 'E-Way Bill No.';
      case 'Valid Upto': return 'E-Way Bill Valid Upto';
      case 'invoiceno': return 'Invoice No.';
      case 'invoiedt': return 'Invoice Date';
      case 'LR No *': return 'LR / Consignment No. *';
      case 'grdt *': return 'LR Date *';
      case 'Customer Name *': return 'Customer Name *';
      case 'Depatment Name': return 'Department Name';
      case 'cngr *': return 'Consignor Name *';
      case 'cnge *': return 'Consignee Name *';
      case 'orgrefcode': return 'Origin *';
      case 'destrefcode': return 'Destination *';
      case 'Vehicle No *': return 'Vehicle No. *';
      case 'Vehicle Type *': return 'Vehicle Type *';
      case 'cngrgstno *': return 'Consignor GSTIN *';
      case 'cngegstno *': return 'Consignee GSTIN *';
      case 'freight  *': return 'Freight (₹) *';
      case 'oamount': return 'Other Charges (₹)';
      case 'valgoods': return 'Invoice Value (₹)';
      case 'loading start date *': return 'Loading Start Date *';
      default: return key;
    }
  }
}
