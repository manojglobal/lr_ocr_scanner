import 'package:flutter/material.dart';
import '../../models/batch_item.dart';
import '../../services/master_data_service.dart';
import '../../state/batch_controller.dart';
import '../widgets/billing_image_viewer.dart';
import '../widgets/step_indicator_bar.dart';
import 'batch_queue_screen.dart';
import 'edit_bilty_screen.dart';

/// Screen 6: LR Customization & Driver Details
/// Matches Step 6 in Logistics_LR_OCR_Workflow_App_Mockup__1_.png:
/// - Customer & Department (populated from ManiFest.xlsx)
/// - Counter & Vehicle Category (populated from BookingCounterMast.xlsx)
/// - Driver Information (pre-populated from OCR extraction or blank, with "Fetch from Master")
/// - Back and Save & Verify navigation
class CustomizationDriverScreen extends StatefulWidget {
  final BatchItem item;
  final BatchProcessingController controller;

  const CustomizationDriverScreen({
    super.key,
    required this.item,
    required this.controller,
  });

  @override
  State<CustomizationDriverScreen> createState() => _CustomizationDriverScreenState();
}

class _CustomizationDriverScreenState extends State<CustomizationDriverScreen> {
  late final TextEditingController _customerController;
  late final TextEditingController _driverNameController;
  late final TextEditingController _driverMobileController;
  late final TextEditingController _licenseNoController;
  late final TextEditingController _licenseValidController;

  FocusNode? _customerFocusNode;
  final FocusNode _driverNameFocusNode = FocusNode();
  final FocusNode _driverMobileFocusNode = FocusNode();
  final FocusNode _licenseNoFocusNode = FocusNode();
  final FocusNode _licenseValidFocusNode = FocusNode();

  bool _hasValidated = false;

  final GlobalKey _customerKey = GlobalKey();
  final GlobalKey _counterKey = GlobalKey();
  final GlobalKey _categoryKey = GlobalKey();
  final GlobalKey _driverNameKey = GlobalKey();
  final GlobalKey _driverMobileKey = GlobalKey();
  final GlobalKey _licenseNoKey = GlobalKey();
  final GlobalKey _licenseValidKey = GlobalKey();

  String _selectedDepartment = '';
  String _selectedCounter = '';
  String _selectedVehicleCategory = 'MARKET';

  List<String> _customerOptions = [];
  List<String> _departmentOptions = [];
  List<String> _counterOptions = [];

  final List<String> _vehicleCategoryOptions = [
    'MARKET',
    'OWN',
    'ATTACHED',
  ];

  @override
  void initState() {
    super.initState();
    final rec = widget.item.record;
    final master = MasterDataService.instance;

    _customerOptions = List<String>.from(master.getCustomers());
    _counterOptions = List<String>.from(master.getCounters());

    // 1. Customer: Pre-populate from OCR or leave empty (never invent fake sample data)
    final cust = (rec['Customer Name *'] ?? rec['customer'] ?? rec['cngr *'] ?? rec['cngr'] ?? '').trim();
    _customerController = TextEditingController(text: cust);

    // 2. Department: Populate options from ManiFest.xlsx for this customer
    _departmentOptions = List<String>.from(master.getDepartmentsForCustomer(cust));
    final dept = (rec['Depatment Name'] ?? rec['department'] ?? '').trim();
    if (dept.isNotEmpty) {
      if (!_departmentOptions.contains(dept)) {
        _departmentOptions.insert(0, dept);
      }
      _selectedDepartment = dept;
    } else if (_departmentOptions.isNotEmpty) {
      _selectedDepartment = _departmentOptions.first;
    }

    // 3. Counter: Populate options from BookingCounterMast.xlsx
    final counter = (rec['Counter'] ?? rec['counter'] ?? rec['branchrefcode'] ?? '').trim();
    if (counter.isNotEmpty) {
      if (!_counterOptions.contains(counter)) {
        _counterOptions.insert(0, counter);
      }
      _selectedCounter = counter;
    } else if (_counterOptions.isNotEmpty) {
      _selectedCounter = _counterOptions.first;
    }

    // 4. Vehicle Category: Default to extracted or MARKET
    final vehCat = (rec['Vehicle Category'] ?? rec['Vehicle Type *'] ?? '').trim().toUpperCase();
    if (_vehicleCategoryOptions.contains(vehCat)) {
      _selectedVehicleCategory = vehCat;
    } else {
      _selectedVehicleCategory = 'MARKET';
    }

    // 5. Driver Details: Pre-populate from OCR or auto-fetch from Master Data
    String dName = (rec['Driver Name *'] ?? rec['driver_name'] ?? rec['owner_or_driver_name'] ?? '').trim();
    String dMob = (rec['Mobile no   *'] ?? rec['mobile_no'] ?? rec['driver_mobile'] ?? rec['mobile'] ?? '').trim();
    String dLic = (rec['Liscense No *'] ?? rec['license_no'] ?? rec['driving_licence_number'] ?? '').trim();
    String dVal = (rec['Valid Up to *'] ?? rec['Valid Up to'] ?? rec['valid_up_to'] ?? rec['dl_valid_till'] ?? '').trim();
    if (dMob == '9999999999' || dMob == '0000000000') dMob = '';

    final vehNo = (rec['Vehicle No *'] ?? rec['vehno'] ?? '').trim();
    if (vehNo.isNotEmpty) {
      DriverMasterRecord? found = master.getDriverForVehicle(vehNo);

      // Check other items in queue if not in local registry
      if (found == null) {
        final cleanVeh = vehNo.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
        for (final other in widget.controller.items) {
          final otherVeh = (other.record['Vehicle No *'] ?? '').replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
          final otherDriver = (other.record['Driver Name *'] ?? other.record['driver_name'] ?? '').trim();
          if (cleanVeh == otherVeh && otherDriver.isNotEmpty) {
            found = DriverMasterRecord(
              vehicleNo: vehNo,
              driverName: otherDriver,
              mobileNo: (other.record['Mobile no   *'] ?? other.record['mobile_no'] ?? '').trim(),
              licenseNo: (other.record['Liscense No *'] ?? other.record['license_no'] ?? '').trim(),
              validUpTo: (other.record['Valid Up to *'] ?? other.record['valid_upto'] ?? '').trim(),
              vehicleCategory: other.record['Vehicle Category'] ?? 'MARKET',
            );
            break;
          }
        }
      }

      if (found != null) {
        if (dName.isEmpty) dName = found.driverName;
        if (dMob.isEmpty || dMob == '9999999999') dMob = found.mobileNo;
        if (dLic.isEmpty) dLic = found.licenseNo;
        if (dVal.isEmpty) dVal = found.validUpTo;
        if (_vehicleCategoryOptions.contains(found.vehicleCategory)) {
          _selectedVehicleCategory = found.vehicleCategory;
        }
      } else {
        // Asynchronously check backend in background
        _autoFetchDriverFromBackend(vehNo);
      }
    }

    _driverNameController = TextEditingController(text: dName);
    _driverMobileController = TextEditingController(text: dMob);
    _licenseNoController = TextEditingController(text: dLic);
    _licenseValidController = TextEditingController(text: dVal);

    _customerController.addListener(_onCustomerChanged);
    _customerController.addListener(_onFieldChanged);
    _driverNameController.addListener(_onFieldChanged);
    _driverMobileController.addListener(_onFieldChanged);
    _licenseNoController.addListener(_onFieldChanged);
    _licenseValidController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    if (_hasValidated && mounted) {
      setState(() {});
    }
  }

  Future<void> _autoFetchDriverFromBackend(String vehNo) async {
    try {
      final backend = widget.controller.geminiService;
      final found = await MasterDataService.instance.fetchDriverForVehicleAsync(
        vehNo,
        backend: backend,
      );
      if (found != null && mounted) {
        setState(() {
          if (_driverNameController.text.trim().isEmpty) {
            _driverNameController.text = found.driverName;
          }
          if (_driverMobileController.text.trim().isEmpty || _driverMobileController.text.trim() == '9999999999') {
            _driverMobileController.text = found.mobileNo;
          }
          if (_licenseNoController.text.trim().isEmpty) {
            _licenseNoController.text = found.licenseNo;
          }
          if (_licenseValidController.text.trim().isEmpty) {
            _licenseValidController.text = found.validUpTo;
          }
          if (_vehicleCategoryOptions.contains(found.vehicleCategory)) {
            _selectedVehicleCategory = found.vehicleCategory;
          }
        });
      }
    } catch (_) {}
  }

  void _onCustomerChanged() {
    final newCust = _customerController.text.trim();
    final newDepts = MasterDataService.instance.getDepartmentsForCustomer(newCust);
    setState(() {
      _departmentOptions = newDepts;
      if (!_departmentOptions.contains(_selectedDepartment) && _departmentOptions.isNotEmpty) {
        _selectedDepartment = _departmentOptions.first;
      }
    });
  }

  @override
  void dispose() {
    _customerController.removeListener(_onCustomerChanged);
    _customerController.removeListener(_onFieldChanged);
    _customerController.dispose();
    _driverNameController.removeListener(_onFieldChanged);
    _driverNameController.dispose();
    _driverMobileController.removeListener(_onFieldChanged);
    _driverMobileController.dispose();
    _licenseNoController.removeListener(_onFieldChanged);
    _licenseNoController.dispose();
    _licenseValidController.removeListener(_onFieldChanged);
    _licenseValidController.dispose();
    _driverNameFocusNode.dispose();
    _driverMobileFocusNode.dispose();
    _licenseNoFocusNode.dispose();
    _licenseValidFocusNode.dispose();
    super.dispose();
  }

  void _showMandatoryIncompleteModal(List<Map<String, String>> emptyMandatory) {
    final count = emptyMandatory.length;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 24),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Mandatory Fields Incomplete',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Required Details Missing Across Pages',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
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
                'Total: $count missing mandatory field${count == 1 ? '' : 's'}:',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: count,
                  itemBuilder: (context, idx) {
                    final item = emptyMandatory[idx];
                    final tabStr = item['tabLabel'] != null ? ' (${item['tabLabel']})' : '';
                    return InkWell(
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _navigateToMissingField(item);
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
                              child: Text(
                                '${item['label']}$tabStr',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                              ),
                            ),
                            const Icon(Icons.arrow_forward_ios, size: 12, color: Color(0xFF94A3B8)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Tap any field above or choose an action below to complete mandatory details.',
                style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
              ),
            ],
          ),
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    final firstStep2 = emptyMandatory.firstWhere(
                      (m) => m['screen'] == 'step2',
                      orElse: () => {},
                    );
                    if (firstStep2.isNotEmpty) {
                      _navigateToMissingField(firstStep2);
                    } else {
                      Navigator.of(context).pop();
                    }
                  },
                  icon: const Icon(Icons.arrow_back, size: 15),
                  label: const Text(
                    'Back to LR Data',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    maxLines: 1,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0284C7),
                    side: const BorderSide(color: Color(0xFFBAE6FD)),
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  key: const Key('modal_fix_first_field_btn'),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _navigateToMissingField(emptyMandatory.first);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text(
                    'Fix Incomplete Field',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    maxLines: 1,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _navigateToMissingField(Map<String, String> item) {
    if (item['screen'] == 'step2') {
      final tabIndex = int.tryParse(item['tabIndex'] ?? '0') ?? 0;
      Navigator.of(context).pop({
        'targetKey': item['key'],
        'tabIndex': tabIndex,
        'label': item['label'],
      });
    } else {
      _scrollToAndFocusCustomField(item['key'] ?? '');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Please complete mandatory field: ${item['label']}'),
            backgroundColor: const Color(0xFFDC2626),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _scrollToAndFocusCustomField(String key) {
    GlobalKey? targetKey;
    FocusNode? targetFocus;
    if (key == 'Customer Name *') {
      targetKey = _customerKey;
      targetFocus = _customerFocusNode;
    } else if (key == 'Counter') {
      targetKey = _counterKey;
    } else if (key == 'Vehicle Category') {
      targetKey = _categoryKey;
    } else if (key == 'Driver Name *') {
      targetKey = _driverNameKey;
      targetFocus = _driverNameFocusNode;
    } else if (key == 'Mobile no   *') {
      targetKey = _driverMobileKey;
      targetFocus = _driverMobileFocusNode;
    } else if (key == 'Liscense No *') {
      targetKey = _licenseNoKey;
      targetFocus = _licenseNoFocusNode;
    } else if (key == 'Valid Up to *') {
      targetKey = _licenseValidKey;
      targetFocus = _licenseValidFocusNode;
    }

    if (targetKey?.currentContext != null) {
      Scrollable.ensureVisible(
        targetKey!.currentContext!,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        alignment: 0.2,
      );
    }
    targetFocus?.requestFocus();
  }

  void _saveAndVerify() {
    final updated = Map<String, String>.from(widget.item.record);
    updated['Customer Name *'] = _customerController.text.trim();
    updated['Depatment Name'] = _selectedDepartment;
    updated['department'] = _selectedDepartment;
    updated['Counter'] = _selectedCounter;
    updated['counter'] = _selectedCounter;
    updated['branchrefcode'] = _selectedCounter;
    updated['Vehicle Category'] = _selectedVehicleCategory;
    updated['Vehicle Type *'] = _selectedVehicleCategory;
    updated['Driver Name *'] = _driverNameController.text.trim();
    updated['driver_name'] = _driverNameController.text.trim();
    updated['Mobile no   *'] = _driverMobileController.text.trim();
    updated['mobile_no'] = _driverMobileController.text.trim();
    updated['Liscense No *'] = _licenseNoController.text.trim();
    updated['license_no'] = _licenseNoController.text.trim();
    updated['Valid Up to *'] = _licenseValidController.text.trim();
    updated['valid_up_to'] = _licenseValidController.text.trim();
    updated['dl_valid_till'] = _licenseValidController.text.trim();

    final candidate = widget.item.copyWith(record: updated);

    // Collect all missing mandatory fields matching Web
    final emptyMandatory = <Map<String, String>>[];

    void checkStep2(String key, String label, String tabLabel, int tabIndex) {
      final val = candidate.resolveField(key).trim();
      if (val.isEmpty || val == '-' || val.toLowerCase() == 'null' || val.toLowerCase() == 'none') {
        emptyMandatory.add({
          'key': key,
          'label': label,
          'tabLabel': tabLabel,
          'tabIndex': tabIndex.toString(),
          'screen': 'step2',
        });
      }
    }

    checkStep2('grno (*)', 'LR / Consignment No. *', 'Basic Details', 0);
    checkStep2('grdt *', 'LR Date *', 'Basic Details', 0);
    checkStep2('Vehicle No *', 'Vehicle No. *', 'Basic Details', 0);
    checkStep2('cngr *', 'Consignor Name *', 'Consignor / Consignee', 1);
    checkStep2('cngrgstno *', 'Consignor GSTIN *', 'Consignor / Consignee', 1);
    checkStep2('cnge *', 'Consignee Name *', 'Consignor / Consignee', 1);
    checkStep2('cngegstno *', 'Consignee GSTIN *', 'Consignor / Consignee', 1);

    void checkCustom(String val, String key, String label) {
      if (val.trim().isEmpty || val == '-' || val.toLowerCase() == 'null' || val.toLowerCase() == 'none') {
        emptyMandatory.add({
          'key': key,
          'label': label,
          'tabLabel': 'Master Data',
          'tabIndex': '4',
          'screen': 'custom',
        });
      }
    }

    checkCustom(_customerController.text, 'Customer Name *', 'Customer Name *');
    checkCustom(_selectedCounter, 'Counter', 'Counter *');
    checkCustom(_selectedVehicleCategory, 'Vehicle Category', 'Vehicle Category *');
    checkCustom(_driverNameController.text, 'Driver Name *', 'Driver Name *');
    checkCustom(_driverMobileController.text, 'Mobile no   *', 'Driver Mobile No *');
    checkCustom(_licenseNoController.text, 'Liscense No *', 'Driver License No *');
    checkCustom(_licenseValidController.text, 'Valid Up to *', 'Driver License Valid Up to *');

    if (emptyMandatory.isNotEmpty) {
      setState(() => _hasValidated = true);

      final firstMissing = emptyMandatory.first;
      if (firstMissing['screen'] == 'custom') {
        _scrollToAndFocusCustomField(firstMissing['key'] ?? '');
      }

      _showMandatoryIncompleteModal(emptyMandatory);
      return;
    }

    // Cache driver info in master if vehicle is present
    final vehNo = (updated['Vehicle No *'] ?? '').trim();
    if (vehNo.isNotEmpty && _driverNameController.text.trim().isNotEmpty) {
      MasterDataService.instance.registerDriver(DriverMasterRecord(
        vehicleNo: vehNo,
        driverName: _driverNameController.text.trim(),
        mobileNo: _driverMobileController.text.trim(),
        licenseNo: _licenseNoController.text.trim(),
        validUpTo: _licenseValidController.text.trim(),
        vehicleCategory: _selectedVehicleCategory,
      ));
    }

    final newItem = widget.item.copyWith(
      record: updated,
      status: BatchItemStatus.completed,
    );
    widget.controller.updateItem(newItem);

    // Web Parity: Navigate directly to Step 3: LR List (BatchQueueScreen)
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => BatchQueueScreen(
          controller: widget.controller,
        ),
      ),
      (route) => route.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    const brandNavy = Color(0xFF0F172A);
    const brandBlue = Color(0xFF0284C7);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: brandNavy),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'LR Customization & Driver Details',
          style: TextStyle(color: brandNavy, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        centerTitle: false,
        actions: const [],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Row(
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: brandNavy,
                    backgroundColor: const Color(0xFFF1F5F9),
                    side: const BorderSide(color: Color(0xFFCBD5E1)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 30),
                  ),
                  icon: const Icon(Icons.arrow_back, size: 14),
                  label: const Text('Back to LR Data', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
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
                    final idx = widget.controller.items.indexWhere((i) => i.id == widget.item.id);
                    BillingImageViewer.show(
                      context,
                      items: widget.controller.items.isNotEmpty ? widget.controller.items : [widget.item],
                      initialIndex: idx >= 0 ? idx : 0,
                      controller: widget.controller,
                    );
                  },
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
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Section 1: Customer & Department
                    _buildSectionCard(
                      title: 'Customer & Department',
                      icon: Icons.business_outlined,
                      children: [
                        _buildLabel('Customer *', showError: _hasValidated && _customerController.text.trim().isEmpty),
                        KeyedSubtree(
                          key: _customerKey,
                          child: Autocomplete<String>(
                            initialValue: TextEditingValue(text: _customerController.text),
                            optionsBuilder: (TextEditingValue textEditingValue) {
                              if (textEditingValue.text.isEmpty) {
                                return _customerOptions;
                              }
                              return _customerOptions.where((option) {
                                return option.toLowerCase().contains(textEditingValue.text.toLowerCase());
                              });
                            },
                            onSelected: (String selection) {
                              _customerController.text = selection;
                            },
                            fieldViewBuilder: (context, fieldTextEditingController, fieldFocusNode, onFieldSubmitted) {
                              if (fieldTextEditingController.text != _customerController.text) {
                                fieldTextEditingController.text = _customerController.text;
                              }
                              fieldTextEditingController.addListener(() {
                                if (_customerController.text != fieldTextEditingController.text) {
                                  _customerController.text = fieldTextEditingController.text;
                                }
                              });
                              final isCustErr = _hasValidated && _customerController.text.trim().isEmpty;
                              _customerFocusNode = fieldFocusNode;
                              return TextField(
                                controller: fieldTextEditingController,
                                focusNode: fieldFocusNode,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF0F172A),
                                  fontStyle: FontStyle.normal,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Select or enter customer from ManiFest',
                                  hintStyle: const TextStyle(
                                    color: Color(0xFF94A3B8),
                                    fontSize: 13,
                                    fontStyle: FontStyle.italic,
                                    fontWeight: FontWeight.normal,
                                  ),
                                  prefixIcon: Icon(Icons.search, size: 20, color: isCustErr ? const Color(0xFFEF4444) : Colors.blueGrey),
                                  filled: true,
                                  fillColor: isCustErr ? const Color(0xFFFEF2F2) : Colors.white,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isCustErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isCustErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isCustErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isCustErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isCustErr ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
                                      width: 1.5,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildLabel('Department'),
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _departmentOptions.contains(_selectedDepartment) ? _selectedDepartment : null,
                          items: _departmentOptions
                              .map((d) => DropdownMenuItem(value: d, child: Text(d, style: const TextStyle(fontSize: 13))))
                              .toList(),
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedDepartment = val);
                          },
                          decoration: InputDecoration(
                            hintText: 'Select Department from ManiFest',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Section 2: Counter & Vehicle Category
                    _buildSectionCard(
                      title: 'Counter & Vehicle Category',
                      icon: Icons.local_shipping_outlined,
                      children: [
                        _buildLabel('Counter *', showError: _hasValidated && _selectedCounter.trim().isEmpty),
                        KeyedSubtree(
                          key: _counterKey,
                          child: Builder(
                            builder: (context) {
                              final isCounterErr = _hasValidated && _selectedCounter.trim().isEmpty;
                              return DropdownButtonFormField<String>(
                                isExpanded: true,
                                initialValue: _counterOptions.contains(_selectedCounter) ? _selectedCounter : null,
                                items: _counterOptions
                                    .map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 13))))
                                    .toList(),
                                onChanged: (val) {
                                  if (val != null) setState(() => _selectedCounter = val);
                                },
                                decoration: InputDecoration(
                                  hintText: 'Select Counter from Master',
                                  filled: true,
                                  fillColor: isCounterErr ? const Color(0xFFFEF2F2) : Colors.white,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isCounterErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isCounterErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isCounterErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isCounterErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isCounterErr ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
                                      width: 1.5,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildLabel('Vehicle Category *', showError: _hasValidated && _selectedVehicleCategory.trim().isEmpty),
                        KeyedSubtree(
                          key: _categoryKey,
                          child: Builder(
                            builder: (context) {
                              final isCatErr = _hasValidated && _selectedVehicleCategory.trim().isEmpty;
                              return DropdownButtonFormField<String>(
                                isExpanded: true,
                                initialValue: _vehicleCategoryOptions.contains(_selectedVehicleCategory) ? _selectedVehicleCategory : null,
                                items: _vehicleCategoryOptions
                                    .map((v) => DropdownMenuItem(value: v, child: Text(v, style: const TextStyle(fontSize: 13))))
                                    .toList(),
                                onChanged: (val) {
                                  if (val != null) setState(() => _selectedVehicleCategory = val);
                                },
                                decoration: InputDecoration(
                                  filled: true,
                                  fillColor: isCatErr ? const Color(0xFFFEF2F2) : Colors.white,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isCatErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isCatErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isCatErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isCatErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isCatErr ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
                                      width: 1.5,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Section 3: Driver Information (Auto-fetched from Master)
                    _buildSectionCard(
                      title: 'Driver Information',
                      icon: Icons.person_pin_outlined,
                      children: [
                        _buildLabel('Driver Name *', showError: _hasValidated && _driverNameController.text.trim().isEmpty),
                        KeyedSubtree(
                          key: _driverNameKey,
                          child: Builder(
                            builder: (context) {
                              final isDrvErr = _hasValidated && _driverNameController.text.trim().isEmpty;
                              return TextField(
                                controller: _driverNameController,
                                focusNode: _driverNameFocusNode,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF0F172A),
                                  fontStyle: FontStyle.normal,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Driver Full Name',
                                  hintStyle: const TextStyle(
                                    color: Color(0xFF94A3B8),
                                    fontSize: 13,
                                    fontStyle: FontStyle.italic,
                                    fontWeight: FontWeight.normal,
                                  ),
                                  filled: true,
                                  fillColor: isDrvErr ? const Color(0xFFFEF2F2) : Colors.white,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isDrvErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isDrvErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isDrvErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isDrvErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isDrvErr ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
                                      width: 1.5,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildLabel('Mobile No. *', showError: _hasValidated && _driverMobileController.text.trim().isEmpty),
                        KeyedSubtree(
                          key: _driverMobileKey,
                          child: Builder(
                            builder: (context) {
                              final isMobErr = _hasValidated && _driverMobileController.text.trim().isEmpty;
                              return TextField(
                                controller: _driverMobileController,
                                focusNode: _driverMobileFocusNode,
                                keyboardType: TextInputType.phone,
                                maxLength: 10,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF0F172A),
                                  fontStyle: FontStyle.normal,
                                ),
                                decoration: InputDecoration(
                                  prefixText: '+91 ',
                                  counterText: '',
                                  hintText: '10-digit mobile number',
                                  hintStyle: const TextStyle(
                                    color: Color(0xFF94A3B8),
                                    fontSize: 13,
                                    fontStyle: FontStyle.italic,
                                    fontWeight: FontWeight.normal,
                                  ),
                                  filled: true,
                                  fillColor: isMobErr ? const Color(0xFFFEF2F2) : Colors.white,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isMobErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isMobErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isMobErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isMobErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isMobErr ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
                                      width: 1.5,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildLabel('License No. *', showError: _hasValidated && _licenseNoController.text.trim().isEmpty),
                        KeyedSubtree(
                          key: _licenseNoKey,
                          child: Builder(
                            builder: (context) {
                              final isLicErr = _hasValidated && _licenseNoController.text.trim().isEmpty;
                              return TextField(
                                controller: _licenseNoController,
                                focusNode: _licenseNoFocusNode,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF0F172A),
                                  fontStyle: FontStyle.normal,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'e.g. KA23 20000044025',
                                  hintStyle: const TextStyle(
                                    color: Color(0xFF94A3B8),
                                    fontSize: 13,
                                    fontStyle: FontStyle.italic,
                                    fontWeight: FontWeight.normal,
                                  ),
                                  filled: true,
                                  fillColor: isLicErr ? const Color(0xFFFEF2F2) : Colors.white,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isLicErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isLicErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isLicErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isLicErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isLicErr ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
                                      width: 1.5,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildLabel('License Valid Up To *', showError: _hasValidated && _licenseValidController.text.trim().isEmpty),
                        KeyedSubtree(
                          key: _licenseValidKey,
                          child: Builder(
                            builder: (context) {
                              final isValErr = _hasValidated && _licenseValidController.text.trim().isEmpty;
                              return TextField(
                                controller: _licenseValidController,
                                focusNode: _licenseValidFocusNode,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF0F172A),
                                  fontStyle: FontStyle.normal,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'DD/MM/YYYY',
                                  hintStyle: const TextStyle(
                                    color: Color(0xFF94A3B8),
                                    fontSize: 13,
                                    fontStyle: FontStyle.italic,
                                    fontWeight: FontWeight.normal,
                                  ),
                                  suffixIcon: const Icon(Icons.calendar_today, size: 18, color: Colors.blueGrey),
                                  filled: true,
                                  fillColor: isValErr ? const Color(0xFFFEF2F2) : Colors.white,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isValErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isValErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isValErr ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1),
                                      width: isValErr ? 1.2 : 1.0,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: isValErr ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
                                      width: 1.5,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Bottom Action Buttons: Cancel, Back to LR Data, & Save & Verify
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              flex: 1,
                              child: OutlinedButton(
                                onPressed: () async {
                                  final shouldCancel = await showCancelVerificationConfirmation(context);
                                  if (shouldCancel && context.mounted) {
                                    Navigator.of(context).pop({'cancelled': true});
                                  }
                                },
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFFDC2626),
                                  side: const BorderSide(color: Color(0xFFFCA5A5)),
                                  backgroundColor: const Color(0xFFFEF2F2),
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: const Text(
                                  'Cancel',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFDC2626)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 1,
                              child: ElevatedButton.icon(
                                onPressed: _saveAndVerify,
                                icon: const Icon(Icons.check_circle_outline, size: 18),
                                label: const Text(
                                  'Save & Verify',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                  maxLines: 1,
                                  overflow: TextOverflow.visible,
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: brandBlue,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back, size: 14, color: brandNavy),
                          label: const Text(
                            'Back to LR Data',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: brandNavy),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Step Indicator Flow Bar (Step 6)
            StepIndicatorBar(
              currentStep: 2,
              controller: widget.controller,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLabel(String text, {bool showError = false}) {
    final isMandatory = text.contains('*');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: showError
              ? const Color(0xFFDC2626)
              : (isMandatory ? const Color(0xFF0F172A) : const Color(0xFF64748B)),
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
    Widget? action,
  }) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: const Color(0xFF0284C7)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ),
                ?action,
              ],
            ),
            const Divider(height: 20, color: Color(0xFFF1F5F9)),
            ...children,
          ],
        ),
      ),
    );
  }
}
