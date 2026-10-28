import 'dart:io';
import 'package:flutter/material.dart';
import '../../models/batch_item.dart';
import '../../state/batch_controller.dart';
import '../widgets/billing_image_viewer.dart';
import '../widgets/step_indicator_bar.dart';
import 'batch_queue_screen.dart';
import 'customization_driver_screen.dart';
import 'excel_preview_screen.dart';

/// Screen 4 & 5: Verify & Edit (Multi-Tab Form)
/// Matches Web Step 2 (Verify & Edit LR Data):
/// - 4 Segmented Tabs: Basic Details, Consignor / Consignee, Cargo Details, Other Details
/// - Only missing mandatory fields highlight in red; optional fields never highlight in red
/// - Real-time removal of red styling as user enters valid data
/// - "Mandatory Fields Incomplete" numbered modal on Next/Verify
/// - Aliases support for pmark, oamount defaults to 0.00
class EditBiltyScreen extends StatefulWidget {
  final BatchItem item;
  final BatchProcessingController controller;
  final int initialTab;
  final String? initialTargetField;
  final VoidCallback? onVerified;

  const EditBiltyScreen({
    super.key,
    required this.item,
    required this.controller,
    this.initialTab = 0,
    this.initialTargetField,
    this.onVerified,
  });

  @override
  State<EditBiltyScreen> createState() => _EditBiltyScreenState();
}

class _EditBiltyScreenState extends State<EditBiltyScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final Map<String, TextEditingController> _fieldControllers = {};
  final Map<String, FocusNode> _fieldFocusNodes = {};
  final Map<String, GlobalKey> _fieldGlobalKeys = {};
  late BatchItem _currentItem;

  // 4 Tabs matching Web Version
  final List<String> _basicKeys = [
    'grno (*)',
    'grdt *',
    'Customer Name *',
    'orgrefcode',
    'destrefcode',
    'Vehicle No *',
    'Vehicle Type *',
  ];

  final List<String> _partyKeys = [
    'cngr *',
    'cngrgstno *',
    'cnge *',
    'cngegstno *',
  ];

  final List<String> _cargoKeys = [
    'goods',
    'bookedpckgs',
    'packing',
    'bookedaweight',
    'bookedcweight',
    'pmark',
    'valgoods',
  ];

  final List<String> _otherKeys = [
    'productcode',
    'ewaybillno',
    'Valid Upto',
    'invoiceno',
    'invoiedt',
    'grtype',
    'oamount',
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

    final allKeys = {..._basicKeys, ..._partyKeys, ..._cargoKeys, ..._otherKeys};
    for (final key in allKeys) {
      String val = _currentItem.resolveField(key);
      if (key == 'oamount') {
        if (val.isEmpty || val == '0') val = '0.00';
      }
      _fieldControllers[key] = TextEditingController(text: val);
      _fieldFocusNodes[key] = FocusNode();
      _fieldGlobalKeys[key] = GlobalKey();
      _fieldControllers[key]!.addListener(() {
        if (mounted) setState(() {});
      });
    }

    if (widget.initialTargetField != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToAndFocusField(widget.initialTargetField!);
      });
    }

    // Pre-warm base64 decoding and pre-cache PDF preview pages immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      BillingImageViewer.prewarm(
        widget.item,
        context,
        widget.controller.geminiService.serverUrl,
      );
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final c in _fieldControllers.values) {
      c.dispose();
    }
    for (final f in _fieldFocusNodes.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _scrollToAndFocusField(String key) {
    final tabIndex = _getTabIndexForKey(key);
    if (_tabController.index != tabIndex) {
      _tabController.animateTo(tabIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final gKey = _fieldGlobalKeys[key];
      if (gKey?.currentContext != null) {
        Scrollable.ensureVisible(
          gKey!.currentContext!,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.2,
        );
      }
      _fieldFocusNodes[key]?.requestFocus();
    });
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
      final textVal = entry.value.text.trim();
      updated[entry.key] = textVal;
      // Sync known aliases for consistency
      if (entry.key == 'grno (*)') {
        updated['LR No *'] = textVal;
        updated['grno'] = textVal;
        updated['lrno'] = textVal;
      } else if (entry.key == 'grdt *') {
        updated['grdt'] = textVal;
        updated['stockdt'] = textVal;
      } else if (entry.key == 'Customer Name *') {
        updated['customer_name'] = textVal;
      } else if (entry.key == 'pmark') {
        updated['Private Mark'] = textVal;
        updated['seal_no'] = textVal;
      } else if (entry.key == 'Vehicle No *') {
        updated['vehno'] = textVal;
      } else if (entry.key == 'Vehicle Type *') {
        updated['Vehicle Category'] = textVal;
      } else if (entry.key == 'Driver Name *') {
        updated['driver_name'] = textVal;
      } else if (entry.key == 'Mobile no   *') {
        updated['mobile_no'] = textVal;
      } else if (entry.key == 'Liscense No *') {
        updated['license_no'] = textVal;
      } else if (entry.key == 'Valid Up to *') {
        updated['valid_up_to'] = textVal;
        updated['dl_valid_till'] = textVal;
      } else if (entry.key == 'Valid Upto') {
        updated['valid_upto'] = textVal;
        updated['ewb valid upto'] = textVal;
      } else if (entry.key == 'bookedpckgs' || entry.key == 'pckgs') {
        updated['pckgs'] = textVal;
        updated['bookedpckgs'] = textVal;
        updated['stockpckgs'] = textVal;
        updated['stockpkgs'] = textVal;
      } else if (entry.key == 'bookedaweight' || entry.key == 'aweight') {
        updated['aweight'] = textVal;
        updated['bookedaweight'] = textVal;
        updated['stockaweight'] = textVal;
      } else if (entry.key == 'bookedcweight' || entry.key == 'cweight') {
        updated['cweight'] = textVal;
        updated['bookedcweight'] = textVal;
        updated['stockcweight'] = textVal;
      } else if (entry.key == 'oamount') {
        updated['oamount'] = textVal.isNotEmpty ? textVal : '0.00';
      }
    }
    final newItem = _currentItem.copyWith(
      record: updated,
      status: BatchItemStatus.completed,
    );
    widget.controller.updateItem(newItem);
    _currentItem = newItem;
    return newItem;
  }

  String _getTabNameForKey(String key) {
    if (_basicKeys.contains(key)) return 'Basic Details';
    if (_partyKeys.contains(key)) return 'Consignor / Consignee';
    if (_cargoKeys.contains(key)) return 'Cargo Details';
    if (_otherKeys.contains(key)) return 'Other Details';
    return 'Master Data & Driver';
  }

  int _getTabIndexForKey(String key) {
    if (_basicKeys.contains(key)) return 0;
    if (_partyKeys.contains(key)) return 1;
    if (_cargoKeys.contains(key)) return 2;
    if (_otherKeys.contains(key)) return 3;
    return 4;
  }

  // ignore: unused_element
  List<Map<String, String>> _getMissingMandatoryDetails() {
    final missing = <Map<String, String>>[];
    for (final key in BatchItem.mandatoryKeys) {
      final ctrl = _fieldControllers[key];
      final val = ctrl != null ? ctrl.text.trim() : _currentItem.resolveField(key);
      if (val.isEmpty || val == '-' || val.toLowerCase() == 'null' || val.toLowerCase() == 'none') {
        missing.add({
          'key': key,
          'label': _getFieldLabel(key),
          'tab': _getTabNameForKey(key),
          'tabIndex': _getTabIndexForKey(key).toString(),
        });
      }
    }
    return missing;
  }

  // ignore: unused_element
  void _showMandatoryIncompleteModal(List<Map<String, String>> missing) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 26),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Mandatory Fields Incomplete',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${missing.length} mandatory field${missing.length == 1 ? '' : 's'} across the 4 tabs ${missing.length == 1 ? 'is' : 'are'} incomplete:',
                style: const TextStyle(fontSize: 13, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: missing.length,
                  itemBuilder: (context, idx) {
                    final item = missing[idx];
                    return InkWell(
                      onTap: () {
                        Navigator.of(ctx).pop();
                        final tabIndex = int.tryParse(item['tabIndex'] ?? '0') ?? 0;
                        final k = item['key'];
                        _tabController.animateTo(tabIndex);
                        if (k != null) {
                          _scrollToAndFocusField(k);
                        }
                      },
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${idx + 1}. ',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFDC2626)),
                            ),
                            Expanded(
                              child: RichText(
                                text: TextSpan(
                                  children: [
                                    TextSpan(
                                      text: item['label'],
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                                    ),
                                    TextSpan(
                                      text: ' (${item['tab']})',
                                      style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const Icon(Icons.chevron_right, size: 16, color: Color(0xFF64748B)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              final firstTab = int.tryParse(missing.first['tabIndex'] ?? '0') ?? 0;
              final firstKey = missing.first['key'];
              _tabController.animateTo(firstTab);
              if (firstKey != null) {
                _scrollToAndFocusField(firstKey);
              }
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF0284C7),
              side: const BorderSide(color: Color(0xFFBAE6FD)),
            ),
            child: const Text('Fix Fields'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BatchQueueScreen(
                    controller: widget.controller,
                  ),
                ),
              );
            },
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            child: const Text('Continue to LR List'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleNextAction() async {
    final updatedItem = _collectUpdatedItem();
    widget.controller.updateItem(updatedItem);
    if (_tabController.index < 3) {
      _tabController.animateTo(_tabController.index + 1);
    } else {
      // Advance to Screen 4b: Customization & Driver Details (Master Data) matching Web workflow
      final result = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(
          builder: (_) => CustomizationDriverScreen(
            item: updatedItem,
            controller: widget.controller,
          ),
        ),
      );
      if (result != null && mounted) {
        final tabIndex = result['tabIndex'] as int? ?? 0;
        final targetKey = result['targetKey'] as String?;
        final label = result['label'] as String? ?? '';
        _tabController.animateTo(tabIndex);
        if (targetKey != null) {
          _scrollToAndFocusField(targetKey);
        }
        if (label.isNotEmpty && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Please enter mandatory field: $label'),
              backgroundColor: const Color(0xFFDC2626),
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  // ignore: unused_element
  void _proceedToDriverDetails() {
    _collectUpdatedItem();
    _tabController.animateTo(3);
  }

  @override
  Widget build(BuildContext context) {
    const brandNavy = Color(0xFF0F172A);
    const brandBlue = Color(0xFF0284C7);
    final file = File(widget.item.imagePath);

    final lrNoVal = _fieldControllers['grno (*)']?.text.trim() ?? '';
    final titleText = lrNoVal.isNotEmpty ? 'LR: $lrNoVal' : widget.item.fileName;

    const currentStep = 2; // Step 2: LR & Master Verification

    return Scaffold(
      resizeToAvoidBottomInset: true,
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
        actions: const [],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(88),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Operation / Action buttons placed directly below page title
              Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                child: Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ExcelPreviewScreen(controller: widget.controller, initialTab: 1),
                          ),
                        );
                      },
                      icon: const Icon(Icons.history_outlined, size: 14, color: brandNavy),
                      label: const Text('History', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: brandNavy)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        side: const BorderSide(color: Color(0xFFCBD5E1)),
                        backgroundColor: const Color(0xFFF1F5F9),
                        minimumSize: const Size(0, 30),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
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
                    Tab(text: 'Consignor / Consignee'),
                    Tab(text: 'Cargo Details'),
                    Tab(text: 'Other Details'),
                  ],
                ),
              ),
            ],
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
                        final bytes = BillingImageViewer.resolveBase64Bytes(widget.item);
                        if (bytes != null) {
                          return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
                        }
                        final pUrl = widget.item.record['preview_url'] ?? '';
                        if (pUrl.isNotEmpty) {
                          final server = widget.controller.geminiService.serverUrl.trim();
                          final fullUrl = pUrl.startsWith('http') ? pUrl : '$server${pUrl.startsWith('/') ? pUrl : '/$pUrl'}';
                          return Image.network(
                            fullUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              color: const Color(0xFFFEE2E2),
                              child: const Center(
                                child: Icon(Icons.picture_as_pdf, color: Color(0xFFDC2626), size: 22),
                              ),
                            ),
                          );
                        }
                        if (file.existsSync() && !isPdf) {
                          return Image.file(
                            file,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              color: Colors.grey.shade200,
                              child: const Icon(Icons.image, size: 20, color: Colors.blueGrey),
                            ),
                          );
                        }
                        if (isPdf) {
                          return Container(
                            color: const Color(0xFFFEE2E2),
                            child: const Center(
                              child: Icon(Icons.picture_as_pdf, color: Color(0xFFDC2626), size: 22),
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
                _buildFormList(_basicKeys, Icons.description_outlined, 'Basic Logistics Details (LR & Vehicle)'),
                _buildFormList(_partyKeys, Icons.people_outline, 'Consignor & Consignee Details'),
                _buildFormList(_cargoKeys, Icons.inventory_2_outlined, 'Cargo, Packaging & Seal Details'),
                _buildFormList(_otherKeys, Icons.more_horiz_outlined, 'Invoice, E-Way Bill & Other Charges'),
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
                      label: Text(
                        _tabController.index == 3 ? 'Next: Master Data' : 'Next',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
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
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Icon(sectionIcon, size: 16, color: const Color(0xFF0284C7)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                sectionTitle,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.blueGrey),
                overflow: TextOverflow.ellipsis,
              ),
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
                final isMandatory = BatchItem.mandatoryKeys.contains(key) || key.contains('*');
                final isKeyDoc = key == 'grno (*)' || key == 'LR No *';
                final isDate = key == 'Valid Upto' || key == 'invoiedt' || key == 'grdt *' || key == 'Loading Start date *' || key == 'Valid Up to *';
                final isSearch = key == 'Customer Name *' || key == 'orgrefcode' || key == 'destrefcode';

                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: ctrl,
                    builder: (context, value, _) {
                      final isValEmpty = value.text.trim().isEmpty || value.text.trim() == '-';
                      // Highlight ONLY missing or invalid mandatory fields in red!
                      // Optional fields must NEVER appear red or trigger validation errors.
                      final isRed = isMandatory && isValEmpty;

                      return Container(
                        key: _fieldGlobalKeys[key],
                        child: TextField(
                          controller: ctrl,
                          focusNode: _fieldFocusNodes[key],
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF0F172A),
                            fontStyle: FontStyle.normal,
                          ),
                          decoration: InputDecoration(
                            labelText: _getFieldLabel(key),
                            hintText: _getFieldPlaceholder(key),
                            hintStyle: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 13,
                              fontStyle: FontStyle.italic,
                              fontWeight: FontWeight.normal,
                            ),
                            labelStyle: TextStyle(
                              fontSize: 13,
                              color: isRed
                                  ? const Color(0xFFDC2626)
                                  : (isMandatory ? const Color(0xFF0284C7) : Colors.blueGrey),
                              fontWeight: (isRed || isMandatory) ? FontWeight.bold : FontWeight.normal,
                            ),
                            prefixIcon: isKeyDoc
                                ? Icon(Icons.vpn_key_outlined, size: 18, color: isRed ? const Color(0xFFDC2626) : const Color(0xFF0284C7))
                                : null,
                            suffixIcon: isDate
                                ? const Icon(Icons.calendar_today, size: 16, color: Colors.blueGrey)
                                : isSearch
                                    ? const Icon(Icons.search, size: 18, color: Colors.blueGrey)
                                    : null,
                            filled: true,
                            fillColor: isRed ? const Color(0xFFFEF2F2) : const Color(0xFFF8FAFC),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(
                                color: isRed ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                width: isRed ? 1.4 : 1.0,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(
                                color: isRed ? const Color(0xFFEF4444) : const Color(0xFFE2E8F0),
                                width: isRed ? 1.4 : 1.0,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(
                                color: isRed ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
                                width: 1.6,
                              ),
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

  String _getFieldPlaceholder(String key) {
    switch (key) {
      case 'grno (*)':
      case 'LR No *':
        return 'Enter LR / Consignment No. (e.g. BNF-2024-001)';
      case 'grdt *':
        return 'DD/MM/YYYY';
      case 'Customer Name *':
        return 'Enter Customer Name (e.g. Patanjali)';
      case 'orgrefcode':
        return 'Origin Station / Branch code';
      case 'destrefcode':
        return 'Destination Station / Branch code';
      case 'Vehicle No *':
        return 'Enter Vehicle No. (e.g. MH12AB1234)';
      case 'Vehicle Type *':
        return 'Vehicle Category / Type (e.g. MARKET)';
      case 'cngr *':
        return 'Enter Consignor (Sender) Name';
      case 'cnge *':
        return 'Enter Consignee (Receiver) Name';
      case 'cngrgstno *':
        return '15-digit Consignor GSTIN';
      case 'cngegstno *':
        return '15-digit Consignee GSTIN';
      case 'Depatment Name':
        return 'Enter Department';
      case 'goods':
        return 'Description of goods';
      case 'bookedpckgs':
        return 'Number of packages (e.g. 10)';
      case 'packing':
        return 'Packing type (e.g. Cartons, Bags)';
      case 'bookedaweight':
        return 'Actual weight in KG (e.g. 150.00)';
      case 'bookedcweight':
        return 'Charged weight in KG (e.g. 150.00)';
      case 'pmark':
        return 'Seal No or Private Mark';
      case 'valgoods':
        return 'Declared goods value (₹)';
      case 'productcode':
        return 'Product code';
      case 'ewaybillno':
        return '12-digit E-Way Bill No.';
      case 'Valid Upto':
        return 'DD/MM/YYYY';
      case 'invoiceno':
        return 'Invoice number';
      case 'invoiedt':
        return 'DD/MM/YYYY';
      case 'grtype':
        return 'Paid, To Pay, or TBB';
      case 'oamount':
        return '0.00';
      case 'Driver Name *':
        return 'Driver Full Name';
      case 'Mobile no   *':
        return '10-digit mobile number';
      case 'Liscense No *':
        return 'e.g. KA23 20000044025';
      case 'Valid Up to *':
        return 'DD/MM/YYYY';
      case 'Loading Start date *':
        return 'DD/MM/YYYY';
      case 'freight  *':
        return '0.00';
      default:
        return 'Enter $key';
    }
  }

  String _getFieldLabel(String key) {
    switch (key) {
      case 'grno (*)':
      case 'LR No *': return 'LR / Consignment No. *';
      case 'grdt *': return 'LR Date *';
      case 'Customer Name *': return 'Customer Name *';
      case 'orgrefcode': return 'Origin Station';
      case 'destrefcode': return 'Destination Station';
      case 'Vehicle No *': return 'Vehicle No. *';
      case 'Vehicle Type *': return 'Vehicle Type *';
      case 'cngr *': return 'Consignor Name *';
      case 'cnge *': return 'Consignee Name *';
      case 'cngrgstno *': return 'Consignor GSTIN *';
      case 'cngegstno *': return 'Consignee GSTIN *';
      case 'Depatment Name': return 'Department Name';
      case 'goods': return 'Goods Description';
      case 'bookedpckgs': return 'Packages';
      case 'packing': return 'Packing';
      case 'bookedaweight': return 'Actual Weight (KG)';
      case 'bookedcweight': return 'Charged Weight (KG)';
      case 'pmark': return 'Seal No / Private Mark';
      case 'valgoods': return 'Declared Value (₹)';
      case 'productcode': return 'Product Code';
      case 'ewaybillno': return 'E-Way Bill No.';
      case 'Valid Upto': return 'E-Way Bill Valid Upto';
      case 'invoiceno': return 'Invoice No.';
      case 'invoiedt': return 'Invoice Date';
      case 'grtype': return 'GR Type';
      case 'oamount': return 'Other Charges (₹)';
      case 'Driver Name *': return 'Driver Name *';
      case 'Mobile no   *': return 'Mobile No *';
      case 'Liscense No *': return 'License No *';
      case 'Valid Up to *': return 'Valid Up to *';
      case 'Loading Start date *': return 'Loading Start Date *';
      case 'freight  *': return 'Freight Charge *';
      default: return key;
    }
  }
}
