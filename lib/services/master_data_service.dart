import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'app_config_service.dart';
import 'gemini_backend_service.dart';

/// Master Data Service providing real logistics master records
/// derived from ManiFest.xlsx and BookingCounterMast.xlsx.
class MasterDataService {
  MasterDataService._() {
    initFromPreferences();
  }
  static final MasterDataService instance = MasterDataService._();


  static const String _prefKeyManifestCache = 'bnf_manifest_customer_departments_cache';
  static const String _prefKeyCountersCache = 'bnf_booking_counters_cache';

  /// Exact Department values parsed directly from ManiFest.xlsx (single source of truth).
  /// Preserves exact capitalization, spaces, spelling, and special characters.
  Map<String, List<String>> _manifestCustomerDepartments = {
    'HIMALAYA WELLNESS COMPANY': [
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
      'PATANJALI-DEL',
    ],
    'GLOBAL MARKETING': [
      'GLOBAL-BANGLORE',
      'GLOBAL-PUNJAB',
      'GLOBAL-CHENNAI',
      'GLOBAL-MH',
      'GLOBAL-DEL',
    ],
    'GLOBAL MARKETING REYN': [
      'GLOBAL MARKETING REYN-DELHI',
      'GLOBAL REYN-MH',
    ],
    'PATANJALI PARIVAHAN PVT. LTD.-INDORE': [
      'PATANJALI-INDORE',
    ],
    'GLOBAL MARKETING ( DELHI )': [
      'GLOBAL-DEL',
    ],
    'INDRA HOSIERY MILLS': [
      'INDIRA-LUDHIANA',
    ],
    'VESCO CYCLE': [
      'VESCO-LUDHIANA',
    ],
    'PATANJALI PARIVAHAN  BHOPAL': [
      'PATANJALI-BHOPAL',
    ],
    ' PATANJALI PARIVAHAN  JALNA': [
      'PATANJALI-JALNA',
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
    'GLOBAL MARKETING (PUNJAB)': [
      'GLOBAL-PUNJAB',
    ],
    'SHREE CIMENT': [
      'SHREE CIMENT- MH',
    ],
  };

  /// Exact 30 Counter values from Column 1 ('Counter Name') of BookingCounterMast.xlsx.
  /// Preserves exact casing, spelling, and symbols without hardcoded Branch Name substitutions.
  List<String> _bookingCounters = [
    'DELHI',
    'KOL',
    'MUMBAI 01',
    'BANG-01',
    'BEL',
    'BHOP',
    'HYD',
    'LUDH',
    'JALNA',
    'CHENNAI',
    'INDORE-1',
    'PATIALA',
    'MANG',
    'TUM',
    'PATAL-1',
    'KARANPURA',
    'VIJAYWADA',
    'FARUKH-01',
    'AHEM-01',
    'PRIT-01',
    'ZIRAK-01',
    'GHAZ-01',
    'GURU-01',
    'RANCHI-01',
    'JAIP-01',
    'PATNA-1',
    '1',
    'BHIWANDI-01',
    'RAIPUR-01',
    'SILIGURI-1',
  ];

  /// Dynamically synchronizes master data from backend endpoints (/api/master/manifest & /api/master/counters)
  /// using the actual Excel files as the single source of truth.
  Future<void> fetchMasterDataFromBackend({String? baseUrl}) async {
    try {
      final effectiveBase = (baseUrl != null && baseUrl.isNotEmpty) ? baseUrl : AppConfigService.instance.baseUrl;
      final manifestUri = Uri.parse('$effectiveBase/api/master/manifest');
      final countersUri = Uri.parse('$effectiveBase/api/master/counters');

      final respManifest = await http.get(manifestUri).timeout(const Duration(seconds: 4));
      if (respManifest.statusCode == 200) {
        final data = jsonDecode(respManifest.body);
        if (data['success'] == true && data['mapping'] is Map) {
          final Map<String, List<String>> parsed = {};
          (data['mapping'] as Map).forEach((k, v) {
            if (v is List) {
              parsed[k.toString()] = v.map((e) => e.toString()).toList();
            }
          });
          if (parsed.isNotEmpty) {
            _manifestCustomerDepartments = parsed;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_prefKeyManifestCache, jsonEncode(_manifestCustomerDepartments));
          }
        }
      }

      final respCounters = await http.get(countersUri).timeout(const Duration(seconds: 4));
      if (respCounters.statusCode == 200) {
        final data = jsonDecode(respCounters.body);
        if (data['success'] == true && data['counters'] is List) {
          final parsed = (data['counters'] as List).map((e) => e.toString()).toList();
          if (parsed.isNotEmpty) {
            _bookingCounters = parsed;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_prefKeyCountersCache, jsonEncode(_bookingCounters));
          }
        }
      }
    } catch (e) {
      debugPrint('[MasterDataService] Dynamic master sync: $e');
    }
  }

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
      final cachedManifest = prefs.getString(_prefKeyManifestCache);
      if (cachedManifest != null && cachedManifest.isNotEmpty) {
        final decoded = jsonDecode(cachedManifest) as Map<String, dynamic>;
        final Map<String, List<String>> parsed = {};
        decoded.forEach((k, v) {
          if (v is List) parsed[k] = v.map((e) => e.toString()).toList();
        });
        if (parsed.isNotEmpty) _manifestCustomerDepartments = parsed;
      }

      final cachedCounters = prefs.getString(_prefKeyCountersCache);
      if (cachedCounters != null && cachedCounters.isNotEmpty) {
        final decoded = jsonDecode(cachedCounters) as List<dynamic>;
        final parsed = decoded.map((e) => e.toString()).toList();
        if (parsed.isNotEmpty) _bookingCounters = parsed;
      }

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
    if (customer.isEmpty) return getAllDepartments();
    final cleanCust = customer.trim().toUpperCase();
    for (final entry in _manifestCustomerDepartments.entries) {
      if (entry.key.toUpperCase() == cleanCust ||
          cleanCust.contains(entry.key.toUpperCase()) ||
          entry.key.toUpperCase().contains(cleanCust)) {
        return List<String>.unmodifiable(entry.value);
      }
    }
    return getAllDepartments();
  }

  /// Strictly validates Department value against ManiFest.xlsx.
  /// Preserves exact casing, spaces, and spelling.
  bool isDepartmentValid(String dept, [String? customer]) {
    if (dept.isEmpty) return true;
    if (customer != null && customer.isNotEmpty) {
      final depts = getDepartmentsForCustomer(customer);
      if (depts.contains(dept)) return true;
    }
    return getAllDepartments().contains(dept);
  }

  /// Strictly validates Counter value against BookingCounterMast.xlsx.
  /// Preserves exact casing, spaces, and spelling.
  bool isCounterValid(String counter) {
    if (counter.isEmpty) return true;
    return _bookingCounters.contains(counter);
  }

  /// Auto-detects and matches Department information extracted from LR against ManiFest.xlsx.
  /// Returns the exact matching Department string from ManiFest.xlsx if a unique reliable match is found.
  /// If 0 matches or multiple matches are possible (ambiguous), returns empty string '' to require manual selection.
  String autoDetectDepartment({String? customer, String? destination, String? deptRaw, String? consignee}) {
    final candidateDepts = (customer != null && customer.isNotEmpty)
        ? getDepartmentsForCustomer(customer)
        : getAllDepartments();

    if (candidateDepts.isEmpty) return '';

    // 1. Check exact match
    if (deptRaw != null && deptRaw.isNotEmpty) {
      if (candidateDepts.contains(deptRaw)) return deptRaw;
      final cleanDeptRaw = deptRaw.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
      final exactMatches = candidateDepts.where((d) => d.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() == cleanDeptRaw).toList();
      if (exactMatches.length == 1) return exactMatches.first;
    }

    // 2. Token match from destination / raw dept / consignee clues
    final cluesText = '${destination ?? ''} ${deptRaw ?? ''} ${consignee ?? ''}'.toUpperCase();
    final clueTokens = cluesText.split(RegExp(r'[^A-Z0-9]+')).where((t) => t.length >= 3).toList();

    const ignoredTokens = {
      'HIM', 'HIMALAYA', 'PATANJALI', 'PATAN', 'GLOBAL', 'MARKETING', 'REYN',
      'GOLD', 'PLUS', 'SHREE', 'CIMENT', 'INDRA', 'INDIRA', 'VESCO',
      'MONTE', 'CARLO', 'LIMITED', 'PVT', 'LTD', 'COMPANY', 'WELLNESS'
    };

    final matched = <String>[];
    for (final d in candidateDepts) {
      final dTokens = d.toUpperCase().split(RegExp(r'[^A-Z0-9]+')).where((t) => t.length >= 3).toList();
      bool hasMatch = false;
      for (final t in dTokens) {
        if (ignoredTokens.contains(t)) continue;
        if (clueTokens.contains(t) || clueTokens.any((ct) => ct.contains(t) || (t.length >= 4 && t.contains(ct)))) {
          hasMatch = true;
          break;
        }
      }
      if (hasMatch && !matched.contains(d)) {
        matched.add(d);
      }
    }

    // 3. Strict uniqueness: exactly 1 match -> return exact Excel string; else return ''
    if (matched.length == 1) {
      return matched.first;
    }
    return '';
  }

  /// Auto-detects and matches Counter information extracted from LR against BookingCounterMast.xlsx (Column 1).
  /// Returns the exact matching Counter string if a unique reliable match is found.
  /// If 0 matches or multiple matches (ambiguous), returns empty string '' to require manual selection.
  String autoDetectCounter({String? counterRaw, String? branchRaw, String? originRaw}) {
    final counters = getCounters();
    if (counters.isEmpty) return '';

    // 1. Exact match check
    for (final clue in [counterRaw, branchRaw, originRaw]) {
      if (clue != null && clue.isNotEmpty) {
        if (counters.contains(clue)) return clue;
        final cleanClue = clue.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
        final exactMatches = counters.where((c) => c.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() == cleanClue).toList();
        if (exactMatches.length == 1) return exactMatches.first;
      }
    }

    // 2. City to counter associations
    final cluesText = '${counterRaw ?? ''} ${branchRaw ?? ''} ${originRaw ?? ''}'.toUpperCase();
    const cityMap = {
      'DELHI': 'DELHI',
      'KOLKATA': 'KOL',
      'CALCUTTA': 'KOL',
      'MUMBAI': 'MUMBAI 01',
      'BOMBAY': 'MUMBAI 01',
      'BANGALORE': 'BANG-01',
      'BENGALURU': 'BANG-01',
      'BELGAUM': 'BEL',
      'BELAGAVI': 'BEL',
      'BHOPAL': 'BHOP',
      'HYDERABAD': 'HYD',
      'SECUNDERABAD': 'HYD',
      'LUDHIANA': 'LUDH',
      'JALNA': 'JALNA',
      'CHENNAI': 'CHENNAI',
      'MADRAS': 'CHENNAI',
      'INDORE': 'INDORE-1',
      'PATIALA': 'PATIALA',
      'MANGALORE': 'MANG',
      'MANGALURU': 'MANG',
      'TUMKUR': 'TUM',
      'TUMAKURU': 'TUM',
      'PATALGANGA': 'PATAL-1',
      'KARANPURA': 'KARANPURA',
      'VIJAYAWADA': 'VIJAYWADA',
      'VIJAYWADA': 'VIJAYWADA',
      'FARUKHNAGAR': 'FARUKH-01',
      'FARUKH': 'FARUKH-01',
      'AHMEDABAD': 'AHEM-01',
      'AHEMDABAD': 'AHEM-01',
      'PRITHLA': 'PRIT-01',
      'ZIRAKPUR': 'ZIRAK-01',
      'ZIRAK': 'ZIRAK-01',
      'GHAZIABAD': 'GHAZ-01',
      'GURGAON': 'GURU-01',
      'GURUGRAM': 'GURU-01',
      'RANCHI': 'RANCHI-01',
      'JAIPUR': 'JAIP-01',
      'PATNA': 'PATNA-1',
      'BHIWANDI': 'BHIWANDI-01',
      'RAIPUR': 'RAIPUR-01',
      'SILIGURI': 'SILIGURI-1',
    };

    final matched = <String>[];
    for (final entry in cityMap.entries) {
      if (cluesText.contains(entry.key) && counters.contains(entry.value)) {
        if (!matched.contains(entry.value)) {
          matched.add(entry.value);
        }
      }
    }

    if (matched.isEmpty) {
      for (final c in counters) {
        final cBase = c.replaceAll(RegExp(r'[^A-Z]'), '');
        if (cBase.length >= 3 && cluesText.contains(cBase)) {
          if (!matched.contains(c)) matched.add(c);
        }
      }
    }

    if (matched.length == 1) {
      return matched.first;
    }
    return '';
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

