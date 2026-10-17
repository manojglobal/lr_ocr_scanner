import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'gemini_backend_service.dart';

/// Master Data Service providing real logistics master records
/// derived from ManiFest.xlsx and BookingCounterMast.xlsx.
class MasterDataService {
  MasterDataService._() {
    initFromPreferences();
  }
  static final MasterDataService instance = MasterDataService._();


  /// Real Customers & their Department mapping parsed from ManiFest.xlsx
  final Map<String, List<String>> _manifestCustomerDepartments = {
    'HIMALAYA WELLNESS COMPANY': [
      'HIMA-KOLKATA',
      'HIMALAYA-SILIGURI',
      'HIMALAYA-RAIPUR',
      'HIMALAYA-BHIWANDI',
      'HIMALAYA-RANCHI',
      'HIMALAYA-NAGPUR',
      'HIMALAYA-INDORE',
      'HIMALAYA-PATNA',
      'HIMALAYA-CHENNAI',
      'HIMALAYA-ZIRAKPUR ',
      'HIMALAYA-JAIPUR',
      'HIMALAYA-AHEMDABAD',
      'HIMALAYA-DELHI',
      'HIMALAYA - VIJAYAWADA',
      'HIM - TUMKUR',
      'HIMALAYA-HYD',
      'HIMALAYA-KOL',
      'HIMALAYA-BANGLORE',
    ],
    'PATANJALI PARIVAHAN PRIVATE LIMITED': [
      'PATANJALI-HYDERABAD',
      'PATAN-KARANPURA',
      'PATAN-INDORE',
      'PATAN-JALNA',
      'PATAN-BHOPAL',
      'PATANJALI-INDORE',
      'PATANJALI-DEL',
    ],
    'GLOBAL MARKETING': [
      'GLOBAL-BANGLORE',
      'GLOBAL-PUNJAB',
      'GLOBAL-CHENNAI',
      'GLOBAL-DEL',
      'GLOBAL-MH',
    ],
    'GLOBAL MARKETING REYN': [
      'GLOBAL MARKETING REYN-DELHI',
      'GLOBAL REYN-MH',
    ],
    'INDRA HOSIERY MILLS': [
      'INDIRA-LUDHIANA',
    ],
    'VESCO CYCLE': [
      'VESCO-LUDHIANA',
    ],
    'HI TECH INTERNATIONAL': [
      'HI TECH-LUDH',
    ],
    'MONTE CARLO FASHIONS LIMITED': [
      'MONTE CARLO-LUDH',
    ],
    'UM ORTHOTICS PRIVATE LIMITED': [
      'UM ORTHOTICS-LUDH',
    ],
    'GOLD PLUS FLOAT GLASS PRIVATE LIMITED': [
      'GOLD PLUS-BELGUAM',
    ],
    'SHREE CIMENT': [
      'SHREE CIMENT- MH',
    ],
  };

  /// Real Counters & Branches parsed from BookingCounterMast.xlsx
  final List<String> _bookingCounters = [
    'KOLKATA',
    'DELHI',
    'MUMBAI 01',
    'BANGLORE',
    'BELGAUM',
    'BHOPAL',
    'HYDERABAD',
    'LUDHIANA',
    'JALNA',
    'CHENNAI',
    'INDORE-1',
    'PATIALA',
    'MANGLORE',
    'TUMKUR',
    'PATALGANGA(MUMBAI)',
    'KARANPURA',
    'VIJAYWADA',
    'FARUKHNAGAR_BRANCH',
    'AHEMBADAB',
    'PITHAMPUR_BRANCH',
    'ZIRAKPUR_1',
    'GHAZIABAD_1',
    'GURUGRAM_HUB',
    'RANCHI_1',
    'JAIPUR_1',
    'PATNA_1',
    'NAGPUR_1',
    'BHIWANDI_1',
    'RAIPUR_1',
    'SILIGURI_1',
  ];

  static const String _prefKeyDriverRegistry = 'bnf_custom_driver_master_registry';

  /// Verified Driver Master Registry by Vehicle Registration Number
  final Map<String, DriverMasterRecord> _vehicleDriverMaster = {
    'KA23B5235': const DriverMasterRecord(
      vehicleNo: 'KA23B5235',
      driverName: 'DHANAJI S PATIL',
      mobileNo: '9739443101',
      licenseNo: 'KA23 20000044025',
      validUpTo: '11/04/2030',
      vehicleCategory: 'OWNED',
    ),
    'BR29GA2038': const DriverMasterRecord(
      vehicleNo: 'BR29GA2038',
      driverName: 'AKHILESH KUMAR',
      mobileNo: '9876543210',
      licenseNo: 'BR01 20230017384',
      validUpTo: '15/08/2036',
      vehicleCategory: 'MARKET',
    ),
    'WB11K3735': const DriverMasterRecord(
      vehicleNo: 'WB11K3735',
      driverName: 'Rajesh Verma',
      mobileNo: '9820011223',
      licenseNo: 'DL-0420180098765',
      validUpTo: '15/08/2029',
      vehicleCategory: 'ATTACHED',
    ),
    'UP30T1517': const DriverMasterRecord(
      vehicleNo: 'UP30T1517',
      driverName: 'Ramesh Kumar',
      mobileNo: '7309691052',
      licenseNo: 'DL-1420110012345',
      validUpTo: '31/12/2028',
      vehicleCategory: 'MARKET',
    ),
    'UP32SN5433': const DriverMasterRecord(
      vehicleNo: 'UP32SN5433',
      driverName: 'CHANDRA KESH SINGH',
      mobileNo: '9876543210',
      licenseNo: 'UP32 20190045123',
      validUpTo: '20/05/2031',
      vehicleCategory: 'MARKET',
    ),
  };

  /// Loads custom driver records previously saved on this device
  Future<void> initFromPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKeyDriverRegistry);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((k, v) {
          if (v is Map) {
            final rec = DriverMasterRecord.fromMap(Map<String, dynamic>.from(v));
            _vehicleDriverMaster[rec.vehicleNo] = rec;
            final clean = rec.vehicleNo.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
            _vehicleDriverMaster[clean] = rec;
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _persistToPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = <String, dynamic>{};
      for (final entry in _vehicleDriverMaster.entries) {
        map[entry.key] = entry.value.toMap();
      }
      await prefs.setString(_prefKeyDriverRegistry, jsonEncode(map));
    } catch (_) {}
  }

  /// Returns list of all master customers
  List<String> getCustomers() {
    return _manifestCustomerDepartments.keys.toList();
  }

  /// Returns valid departments for a given customer from ManiFest.xlsx
  List<String> getDepartmentsForCustomer(String customer) {
    final cleanCust = customer.trim().toUpperCase();
    for (final entry in _manifestCustomerDepartments.entries) {
      if (entry.key.toUpperCase() == cleanCust ||
          cleanCust.contains(entry.key.toUpperCase()) ||
          entry.key.toUpperCase().contains(cleanCust)) {
        return entry.value;
      }
    }
    // Return all unique departments if specific customer not matched
    return getAllDepartments();
  }

  /// Returns all unique departments from ManiFest.xlsx
  List<String> getAllDepartments() {
    final Set<String> depts = {};
    for (final list in _manifestCustomerDepartments.values) {
      depts.addAll(list);
    }
    return depts.toList()..sort();
  }

  /// Returns list of booking counters from BookingCounterMast.xlsx
  List<String> getCounters() {
    return List<String>.unmodifiable(_bookingCounters);
  }

  /// Looks up driver details synchronously by vehicle registration number
  DriverMasterRecord? getDriverForVehicle(String vehicleNo) {
    final cleanVeh = vehicleNo.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    if (cleanVeh.isEmpty) return null;

    for (final entry in _vehicleDriverMaster.entries) {
      final cleanKey = entry.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
      if (cleanKey == cleanVeh) {
        return entry.value;
      }
    }
    return null;
  }

  /// Asynchronously fetches driver from local cache, other queue items, or server API
  Future<DriverMasterRecord?> fetchDriverForVehicleAsync(
    String vehicleNo, {
    GeminiBackendService? backend,
    List<DriverMasterRecord>? queueFallbacks,
  }) async {
    final cleanVeh = vehicleNo.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    if (cleanVeh.isEmpty) return null;

    // 1. Synchronous local check
    final local = getDriverForVehicle(cleanVeh);
    if (local != null) return local;

    // 2. Queue items check
    if (queueFallbacks != null) {
      for (final q in queueFallbacks) {
        final qVeh = q.vehicleNo.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
        if (qVeh == cleanVeh && q.driverName.isNotEmpty) {
          registerDriver(q);
          return q;
        }
      }
    }

    // 3. Backend API check
    if (backend != null) {
      try {
        final uri = Uri.parse('${backend.serverUrl}/api/master/driver?vehicle_no=$cleanVeh');
        final resp = await http.get(uri).timeout(const Duration(seconds: 4));
        if (resp.statusCode == 200) {
          final json = jsonDecode(resp.body);
          if (json['success'] == true && json['driver'] != null) {
            final d = json['driver'] as Map<String, dynamic>;
            final rec = DriverMasterRecord(
              vehicleNo: d['vehicle_no']?.toString() ?? vehicleNo,
              driverName: d['driver_name']?.toString() ?? '',
              mobileNo: d['mobile_no']?.toString() ?? '',
              licenseNo: d['license_no']?.toString() ?? '',
              validUpTo: d['valid_upto']?.toString() ?? '',
              vehicleCategory: d['vehicle_category']?.toString() ?? 'MARKET',
            );
            registerDriver(rec);
            return rec;
          }
        }
      } catch (err) {
        debugPrint('[MasterDataService] Backend lookup error: $err');
      }
    }

    return null;
  }

  /// Returns all registered driver records
  List<DriverMasterRecord> getAllDriverRecords() {
    return _vehicleDriverMaster.values.toSet().toList();
  }

  /// Registers or caches a driver record for a vehicle
  void registerDriver(DriverMasterRecord record) {
    _vehicleDriverMaster[record.vehicleNo] = record;
    final clean = record.vehicleNo.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    _vehicleDriverMaster[clean] = record;
    _persistToPreferences();
  }
}

class DriverMasterRecord {
  final String vehicleNo;
  final String driverName;
  final String mobileNo;
  final String licenseNo;
  final String validUpTo;
  final String vehicleCategory;

  const DriverMasterRecord({
    required this.vehicleNo,
    required this.driverName,
    required this.mobileNo,
    required this.licenseNo,
    required this.validUpTo,
    this.vehicleCategory = 'MARKET',
  });

  Map<String, dynamic> toMap() => {
        'vehicle_no': vehicleNo,
        'driver_name': driverName,
        'mobile_no': mobileNo,
        'license_no': licenseNo,
        'valid_upto': validUpTo,
        'vehicle_category': vehicleCategory,
      };

  factory DriverMasterRecord.fromMap(Map<String, dynamic> map) => DriverMasterRecord(
        vehicleNo: map['vehicle_no']?.toString() ?? '',
        driverName: map['driver_name']?.toString() ?? '',
        mobileNo: map['mobile_no']?.toString() ?? '',
        licenseNo: map['license_no']?.toString() ?? '',
        validUpTo: map['valid_upto']?.toString() ?? '',
        vehicleCategory: map['vehicle_category']?.toString() ?? 'MARKET',
      );
}

