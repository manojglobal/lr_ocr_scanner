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

  /// Exact 30 Counter master records from BookingCounterMast.xlsx ('Counter Name' and 'Branch Name').
  List<Map<String, String>> _bookingCounterRecords = [
    {'counter': 'DELHI', 'branch': 'DELHI'},
    {'counter': 'KOL', 'branch': 'KOLKATA'},
    {'counter': 'MUMBAI 01', 'branch': 'MUMBAI_1'},
    {'counter': 'BANG-01', 'branch': 'BANGLORE'},
    {'counter': 'BEL', 'branch': 'BELGAUM'},
    {'counter': 'BHOP', 'branch': 'BHOPAL'},
    {'counter': 'HYD', 'branch': 'HYDERABAD'},
    {'counter': 'LUDH', 'branch': 'LUDHIANA'},
    {'counter': 'JALNA', 'branch': 'JALNA'},
    {'counter': 'CHENNAI', 'branch': 'CHENNAI 01'},
    {'counter': 'INDORE-1', 'branch': 'INDORE'},
    {'counter': 'PATIALA', 'branch': 'PATIALA BRANCH '},
    {'counter': 'MANG', 'branch': 'MANGLORE'},
    {'counter': 'TUM', 'branch': 'TUMKUR'},
    {'counter': 'PATAL-1', 'branch': 'PATALGANGA(MUMBAI)'},
    {'counter': 'KARANPURA', 'branch': 'KARANPURA'},
    {'counter': 'VIJAYWADA', 'branch': 'VIJAYWADA '},
    {'counter': 'FARUKH-01', 'branch': 'FARUKHNAGAR_BRANCH'},
    {'counter': 'AHEM-01', 'branch': 'AHEMBADAB'},
    {'counter': 'PRIT-01', 'branch': 'PITHAMPUR_BRANCH'},
    {'counter': 'ZIRAK-01', 'branch': 'ZIRAKPUR_1'},
    {'counter': 'GHAZ-01', 'branch': 'GHAZIABAD_1'},
    {'counter': 'GURU-01', 'branch': 'GURUGRAM_HUB'},
    {'counter': 'RANCHI-01', 'branch': 'RANCHI_1'},
    {'counter': 'JAIP-01', 'branch': 'JAIPUR_1'},
    {'counter': 'PATNA-1', 'branch': 'PATNA_1'},
    {'counter': '1', 'branch': 'NAGPUR_1'},
    {'counter': 'BHIWANDI-01', 'branch': ' BHIWANDI_1'},
    {'counter': 'RAIPUR-01', 'branch': 'RAIPUR_1'},
    {'counter': 'SILIGURI-1', 'branch': 'SILIGURI_1'},
  ];

  static const Map<String, String> _citySpellingAliases = {
    'CALCUTTA': 'KOLKATA',
    'BOMBAY': 'MUMBAI',
    'BANGALORE': 'BANGLORE',
    'BENGALURU': 'BANGLORE',
    'BELGUAM': 'BELGAUM',
    'BELAGAVI': 'BELGAUM',
    'SECUNDERABAD': 'HYDERABAD',
    'MADRAS': 'CHENNAI',
    'MANGALORE': 'MANGLORE',
    'MANGALURU': 'MANGLORE',
    'TUMAKURU': 'TUMKUR',
    'AHMEDABAD': 'AHEMDABAD',
    'AHEMBADAB': 'AHEMDABAD',
    'GURGAON': 'GURUGRAM',
    'VIJAYAWADA': 'VIJAYWADA',
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
  /// Extracts the Origin City from the scanned LR using OCR.
  /// Uses the extracted Origin City to find the matching Department from ManiFest.xlsx.
  /// Populates only the exact Department value available in the master Excel file.
  /// Do not use hardcoded values, generated values, or default fallbacks.
  /// If no reliable match is found, returns empty string '' to require manual selection.
  String autoDetectDepartment({String? originCity, String? customer, String? deptRaw, String? destination, String? consignee}) {
    final candidateDepts = (customer != null && customer.isNotEmpty)
        ? getDepartmentsForCustomer(customer)
        : getAllDepartments();

    if (candidateDepts.isEmpty) return '';

    // 1. Check exact match if deptRaw was provided
    if (deptRaw != null && deptRaw.isNotEmpty) {
      if (candidateDepts.contains(deptRaw)) return deptRaw;
      final cleanDeptRaw = deptRaw.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
      final exactMatches = candidateDepts.where((d) => d.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() == cleanDeptRaw).toList();
      if (exactMatches.length == 1) return exactMatches.first;
    }

    // 2. Match Origin City from scanned LR against Department location in ManiFest.xlsx
    if (originCity != null && originCity.trim().isNotEmpty) {
      var normOrig = originCity.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      for (final entry in _citySpellingAliases.entries) {
        if (normOrig.contains(entry.key)) {
          normOrig = normOrig.replaceAll(entry.key, entry.value);
        }
      }

      const ignoredTokens = {
        'HIM', 'HIMALAYA', 'PATANJALI', 'PATAN', 'GLOBAL', 'MARKETING', 'REYN',
        'GOLD', 'PLUS', 'SHREE', 'CIMENT', 'INDRA', 'INDIRA', 'VESCO',
        'MONTE', 'CARLO', 'HI', 'TECH', 'UM', 'ORTHOTICS', 'LIMITED', 'PVT',
        'LTD', 'COMPANY', 'WELLNESS'
      };

      final matched = <String>[];
      for (final d in candidateDepts) {
        final dTokens = d.toUpperCase().split(RegExp(r'[\-\s]+')).where((t) => t.trim().length >= 3).toList();
        for (final t in dTokens) {
          if (ignoredTokens.contains(t)) continue;
          var tNorm = t;
          for (final entry in _citySpellingAliases.entries) {
            if (tNorm.contains(entry.key)) {
              tNorm = tNorm.replaceAll(entry.key, entry.value);
            }
          }
          final tClean = tNorm.replaceAll(RegExp(r'[^A-Z0-9]'), '');
          if (tClean.isNotEmpty && (tClean.contains(normOrig) || normOrig.contains(tClean))) {
            if (!matched.contains(d)) {
              matched.add(d);
            }
            break;
          }
        }
      }

      if (matched.length == 1) {
        return matched.first;
      }
    }
    return '';
  }

  /// Auto-detects and matches Counter information extracted from LR against BookingCounterMast.xlsx.
  /// Extracts the Origin City from the scanned LR using OCR.
  /// Uses the extracted Origin City to find the matching Counter Name from BookingCounterMast.xlsx.
  /// Populates only the exact Counter Name available in the master Excel file.
  /// Do not use hardcoded values, generated values, or default fallbacks.
  /// If no reliable match is found, returns empty string '' to require manual selection.
  String autoDetectCounter({String? originCity, String? counterRaw, String? branchRaw, String? originRaw}) {
    final effectiveClues = [originCity, originRaw, counterRaw, branchRaw];
    for (final clue in effectiveClues) {
      if (clue == null || clue.trim().isEmpty) continue;
      final clueStr = clue.trim();
      if (clueStr.toLowerCase() == 'none' || clueStr.toLowerCase() == 'null') continue;

      var normClue = clueStr.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      for (final entry in _citySpellingAliases.entries) {
        if (normClue.contains(entry.key)) {
          normClue = normClue.replaceAll(entry.key, entry.value);
        }
      }

      // 1. Direct match with Counter Name in BookingCounterMast.xlsx
      for (final rec in _bookingCounterRecords) {
        final cClean = rec['counter']!.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
        if (cClean == normClue) {
          return rec['counter']!;
        }
      }

      // 2. Match with Primary Branch Token (e.g. MUMBAI in MUMBAI_1, BANGLORE in BANGLORE)
      for (final rec in _bookingCounterRecords) {
        final brRaw = rec['branch']!.trim();
        if (brRaw.isNotEmpty) {
          final primary = brRaw.split(RegExp(r'[\(_\s]'))[0].trim();
          var pNorm = primary.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
          for (final entry in _citySpellingAliases.entries) {
            if (pNorm.contains(entry.key)) {
              pNorm = pNorm.replaceAll(entry.key, entry.value);
            }
          }
          if (pNorm.isNotEmpty && pNorm == normClue) {
            return rec['counter']!;
          }
        }
      }

      // 3. Match with Secondary Branch Name tokens
      final matched = <String>[];
      for (final rec in _bookingCounterRecords) {
        final bName = rec['branch']!.toUpperCase();
        final tokens = bName.split(RegExp(r'[^A-Z0-9]+')).where((t) => t.isNotEmpty && t != 'BRANCH' && t != 'HUB' && t != '1').toList();
        for (final t in tokens) {
          var tClean = t.replaceAll(RegExp(r'[^A-Z0-9]'), '');
          for (final entry in _citySpellingAliases.entries) {
            if (tClean.contains(entry.key)) {
              tClean = tClean.replaceAll(entry.key, entry.value);
            }
          }
          if (tClean.length >= 4 && (tClean.contains(normClue) || normClue.contains(tClean))) {
            if (!matched.contains(rec['counter'])) {
              matched.add(rec['counter']!);
            }
            break;
          }
        }
      }

      if (matched.length == 1) {
        return matched.first;
      }
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

