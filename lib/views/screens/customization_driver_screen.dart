import 'package:flutter/material.dart';
import '../../models/batch_item.dart';
import '../../services/master_data_service.dart';
import '../../state/batch_controller.dart';
import '../widgets/billing_image_viewer.dart';
import '../widgets/step_indicator_bar.dart';
import 'verified_screen.dart';

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

    _customerOptions = master.getCustomers();
    _counterOptions = master.getCounters();

    // 1. Customer: Pre-populate from OCR or leave empty (never invent fake sample data)
    final cust = (rec['Customer Name *'] ?? rec['customer'] ?? rec['cngr *'] ?? rec['cngr'] ?? '').trim();
    _customerController = TextEditingController(text: cust);

    // 2. Department: Populate options from ManiFest.xlsx for this customer
    _departmentOptions = master.getDepartmentsForCustomer(cust);
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
    String dVal = (rec['Valid Up to *'] ?? rec['valid_upto'] ?? rec['dl_valid_till'] ?? '').trim();
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
    _customerController.dispose();
    _driverNameController.dispose();
    _driverMobileController.dispose();
    _licenseNoController.dispose();
    _licenseValidController.dispose();
    super.dispose();
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
    updated['valid_upto'] = _licenseValidController.text.trim();

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

    // Navigate to Screen 7 (Verification Success)
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => VerifiedScreen(
          item: newItem,
          controller: widget.controller,
        ),
      ),
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
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: brandBlue,
                backgroundColor: const Color(0xFFF1F5F9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.image_outlined, size: 16),
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
          ),
        ],
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
                        _buildLabel('Customer *'),
                        Autocomplete<String>(
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
                            return TextField(
                              controller: fieldTextEditingController,
                              focusNode: fieldFocusNode,
                              decoration: InputDecoration(
                                hintText: 'Select or enter customer from ManiFest',
                                prefixIcon: const Icon(Icons.search, size: 20, color: Colors.blueGrey),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 14),
                        _buildLabel('Department *'),
                        DropdownButtonFormField<String>(
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
                        _buildLabel('Counter *'),
                        DropdownButtonFormField<String>(
                          initialValue: _counterOptions.contains(_selectedCounter) ? _selectedCounter : null,
                          items: _counterOptions
                              .map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 13))))
                              .toList(),
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedCounter = val);
                          },
                          decoration: InputDecoration(
                            hintText: 'Select Counter from Master',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildLabel('Vehicle Category *'),
                        DropdownButtonFormField<String>(
                          initialValue: _vehicleCategoryOptions.contains(_selectedVehicleCategory) ? _selectedVehicleCategory : null,
                          items: _vehicleCategoryOptions
                              .map((v) => DropdownMenuItem(value: v, child: Text(v, style: const TextStyle(fontSize: 13))))
                              .toList(),
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedVehicleCategory = val);
                          },
                          decoration: InputDecoration(
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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

                        _buildLabel('Driver Name *'),
                        TextField(
                          controller: _driverNameController,
                          decoration: InputDecoration(
                            hintText: 'Driver Full Name',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildLabel('Mobile No. *'),
                        TextField(
                          controller: _driverMobileController,
                          keyboardType: TextInputType.phone,
                          maxLength: 10,
                          decoration: InputDecoration(
                            prefixText: '+91 ',
                            counterText: '',
                            hintText: '10-digit mobile number',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildLabel('License No. *'),
                        TextField(
                          controller: _licenseNoController,
                          decoration: InputDecoration(
                            hintText: 'e.g. KA23 20000044025',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildLabel('License Valid Up To *'),
                        TextField(
                          controller: _licenseValidController,
                          decoration: InputDecoration(
                            hintText: 'DD/MM/YYYY',
                            suffixIcon: const Icon(Icons.calendar_today, size: 18, color: Colors.blueGrey),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Bottom Action Buttons: Back & Save & Verify
                    Row(
                      children: [
                        Expanded(
                          flex: 1,
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
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: _saveAndVerify,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: brandBlue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.check_circle_outline, size: 18),
                                SizedBox(width: 8),
                                Text(
                                  'Save & Verify',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                              ],
                            ),
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
              currentStep: 6,
              controller: widget.controller,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    final isMandatory = text.contains('*');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: isMandatory ? const Color(0xFF0F172A) : const Color(0xFF64748B),
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
