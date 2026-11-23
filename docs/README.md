# OCR to Excel Dual-Component Studio

Enterprise-grade Logistics LR (Lorry Receipt / Bilty) OCR Extraction & Excel Workflow Suite for **Box N Freight (BNF)**. Combines a **Flutter** mobile/tablet application with a **FastAPI** backend and single-page **Web Studio** powered by Google Gemini Vision OCR and client-side ML fallback.

---

## 📁 Project Architecture & File Structure

```text
ocr_to_excel/
│
├── 📱 FLUTTER MOBILE APP (Root Workspace)
│   ├── lib/                           # Flutter application code
│   │   ├── config/                    # Document schemas & configuration
│   │   ├── models/                    # Batch items, OCR data & word models
│   │   ├── services/                  # Excel generator, Gemini API client, Master data, ML Kit OCR, Lifecycle
│   │   ├── state/                     # Batch processing ChangeNotifier controller
│   │   └── views/                     # Login, Home, Scan, Edit, Verification, Preview & Lifecycle screens/widgets
│   ├── test/                          # 37 Dart unit & widget test files (*_test.dart)
│   ├── android/                       # Native Android host project & Kotlin Gradle build
│   ├── ios/, linux/, macos/, web/, windows/ # Target platform hosts
│   ├── pubspec.yaml & pubspec.lock    # Flutter dependencies & assets configuration
│   └── analysis_options.yaml          # Dart analyzer & linter rules
│
├── ⚙️ BACKEND API, WEB STUDIO & OCR ENGINE (backend/)
│   ├── backend/
│   │   ├── main.py                    # FastAPI server, Gemini OCR pipeline, master loaders & Excel exports
│   │   ├── auth_service.py            # User authentication, OTP, and session management
│   │   ├── user_cloud_service.py      # Per-user cloud batch & export DB (mobile-isolated)
│   │   ├── file_lifecycle_service.py  # SHA-256 audit tracking & version vault engine
│   │   ├── audit_snapshot.py          # Audit log tracking, dual export naming & 30-day purge engine
│   │   ├── network_server.py          # Local network pairing & IP bridge
│   │   ├── manage_users.py            # User management CLI helper
│   │   ├── requirements.txt           # Python dependency manifest
│   │   ├── server_config.json         # Backend fallback server configuration
│   │   ├── static/
│   │   │   └── index.html             # Single-page Web Studio (HTML5 + Tailwind + SheetJS + Tesseract.js)
│   │   ├── data/                      # users.json, sessions.json, driver_master.json, cloud_db/
│   │   ├── uploads/                   # Legacy upload staging directory
│   │   ├── export/                    # upload_LR/, snapshots_excel/, metadata/ (file & audit registries)
│   │   └── test_*.py                  # 9 Python backend unit/regression test scripts
│   │
│   ├── main.py (Root Shim)            # Launcher forwarding to backend/main.py
│   ├── run_server.bat (Windows)       # 1-click Windows backend runner (.venv + backend/main.py)
│   └── server_config.json             # Centralized remote server configuration
│
├── 📚 DOCUMENTATION, TEMPLATES & MASTER DATA (docs/)
│   ├── docs/
│   │   ├── CONTEXT.md                 # Master system blueprint, 49-col schema & operational context
│   │   ├── web_context.md             # Single-page Web Studio workflow, rules & API contract
│   │   ├── android_context.md         # Android UI screens, widgets & ML Kit fallback guide
│   │   ├── IMPLEMENTATION_PLAN.md     # Original Flutter v1 roadmap
│   │   ├── Customer_LR_formats.md     # Cross-customer extraction matrix (Unicharm, Patanjali, Himalaya, Gold Plus)
│   │   ├── customer_scan_prompt.md    # Master Gemini Vision prompt guidelines
│   │   ├── himalaya_context.md        # Himalaya dossier extraction reference
│   │   ├── patanjali_context.md       # Patanjali dossier extraction reference
│   │   ├── README.md                  # This project overview & quickstart guide
│   │   ├── run_server.py              # Convenience server runner script
│   │   ├── LR_Format.xlsx             # Canonical 49-column BNF export template (served by /download-template)
│   │   ├── ManiFest.xlsx              # 45 customer/department rows & GSTIN master (runtime source)
│   │   ├── BookingCounterMast.xlsx    # 30 booking counters & branch name mappings (runtime source)
│   │   ├── GoodsMaster.xlsx           # 2,789 commodity records (2,776 active, runtime source)
│   │   ├── VehicleTypeMaster.xlsx     # 154 vehicle type definitions (runtime source)
│   │   └── Gold_plus/, himalaya/, Patajali/, Vuicharm/ # Sample customer PDF/JPEG dossiers
│
├── 📦 RELEASES & BINARIES (releases/)
│   └── releases/
│       ├── ocr_to_excel.apk           # Android release APK served by /download-apk
│       ├── app-release.apk
│       └── app-arm64-v8a-release.apk
│
├── 🎨 ASSETS & MOCKUPS (assets/mockups/)
│   └── assets/mockups/Logistics_LR_OCR_Workflow_App_Mockup__1_.png
│
└── 🛠️ UTILITY SCRIPTS (scripts/)
    ├── scripts/search_files.py        # CLI tool to search files by LR # or Export ID
    ├── scripts/manage_users.py        # User management script
    └── scripts/sync_exports.ps1       # Export synchronization PowerShell utility
```

> [!IMPORTANT]
> **Runtime Dependency on `docs/*.xlsx`**: The live FastAPI server ([backend/main.py](../backend/main.py)) loads `LR_Format.xlsx`, `ManiFest.xlsx`, `BookingCounterMast.xlsx`, `GoodsMaster.xlsx`, and `VehicleTypeMaster.xlsx` directly from `docs/` at runtime. Do not move, rename, or delete those `.xlsx` files without updating the backend loaders.

---

## 🚀 Quickstart Guide

### 1. Starting the Python Backend

From the project root:

**Method A: 1-Click Windows Launcher**
```cmd
run_server.bat
```

**Method B: Traditional `main.py` Root Shim**
```bash
.venv\Scripts\python.exe main.py
```

**Method C: Direct `backend/` directory**
```bash
cd backend
..\.venv\Scripts\python.exe main.py
```

- **Web Studio**: Open [http://localhost:8000](http://localhost:8000) (or `/web`)
- **API Documentation**: Open [http://localhost:8000/docs](http://localhost:8000/docs)
- **APK Direct Download**: Open [http://localhost:8000/download-apk](http://localhost:8000/download-apk)
- **Excel Template Download**: Open [http://localhost:8000/download-template](http://localhost:8000/download-template)

### 2. Running the Flutter Mobile App

From the project root:

```bash
# Install Flutter dependencies
flutter pub get

# Run on connected device or emulator
flutter run

# Build release APK
flutter build apk --release
```

### 3. Running Automated Tests

**Backend Python Tests** (from project root):
```bash
.venv\Scripts\python.exe -m unittest backend\test_web_fixes.py backend\test_four_requirements_backend.py backend\test_three_fixes_backend.py backend\test_date_format_fix.py backend\test_unverified_removal_backend.py backend\test_multi_file_upload_backend.py backend\test_15_page_validation.py
```

**Flutter Tests** (from project root):
```bash
flutter test test\excel_service_test.dart
```
*(37 Dart test files live in `test/` and 9 Python test scripts live in `backend/`.)*

### 4. Searching Files on Command Line (CLI)

Uploaded LR documents and backend audit Excel snapshots are stored under `backend\export\upload_LR\` and `backend\export\snapshots_excel\`:

**Option A: Built-in Python Search Tool**
```bash
# Search by LR number (e.g. 32754)
python scripts/search_files.py --lr 32754

# Search by Unique ID (e.g. EXP_20261011 or LR_20261011)
python scripts/search_files.py --id EXP_20261011

# List recent files
python scripts/search_files.py --recent
```

**Option B: Native PowerShell Commands**
```powershell
# Search uploaded LRs by number:
Get-ChildItem backend\export\upload_LR\*32754*

# Search audit Excel snapshots:
Get-ChildItem backend\export\snapshots_excel\*EXP_*
```

---

## 📖 Key Documentation

- [docs/CONTEXT.md](CONTEXT.md): Complete system architecture, 49-column `LR_Format.xlsx` schema, master datasets, endpoints, and web vs. mobile rules.
- [docs/web_context.md](web_context.md): Single-page Web Studio (`backend/static/index.html`) workflow, web-only Excel field rules, and backend API contract.
- [docs/android_context.md](android_context.md): Mobile UI screens, widgets, and offline ML Kit fallback guide.
- [docs/Customer_LR_formats.md](Customer_LR_formats.md): Customer-specific LR extraction rules across Unicharm, Patanjali, Himalaya, and Gold Plus.
- [docs/customer_scan_prompt.md](customer_scan_prompt.md): Master Gemini Vision OCR prompt specifications.
