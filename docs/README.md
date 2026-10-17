# OCR to Excel Dual-Component Studio

Enterprise-grade Logistics LR (Lorry Receipt / Bilty) OCR Extraction & Excel Workflow Suite. Combines a high-performance **Flutter** mobile/tablet application with a **FastAPI** backend powered by Google Gemini Vision OCR.

---

## 📁 Project Architecture & File Structure

```text
ocr_to_excel/
│
├── 📱 FLUTTER MOBILE APP (Root Workspace)
│   ├── lib/                           # Production Flutter application code
│   │   ├── config/                    # Document schemas, styling, and templates
│   │   ├── models/                    # Batch items, OCR data classes, lifecycle models
│   │   ├── services/                  # Excel generator, Gemini OCR, Master data, Lifecycle
│   │   ├── state/                     # Batch processing and reactive controllers
│   │   └── views/                     # Screens, review table, billing image viewer
│   ├── test/                          # Comprehensive unit & widget test suite (50 tests)
│   ├── android/                       # Native Android host project & Gradle build
│   ├── ios/, web/, windows/           # Target platform hosts
│   ├── pubspec.yaml & pubspec.lock    # Flutter dependencies & assets configuration
│   └── analysis_options.yaml          # Dart analyzer & linter rules
│
├── ⚙️ BACKEND API & OCR ENGINE (backend/)
│   ├── backend/
│   │   ├── main.py                    # FastAPI server & Gemini OCR pipeline
│   │   ├── auth_service.py            # User authentication, OTP, and session management
│   │   ├── file_lifecycle_service.py  # SHA-256 audit tracking & version vault engine
│   │   ├── audit_snapshot.py          # Excel snapshot rendering & 30-day purge engine
│   │   ├── network_server.py          # Local network pairing & upload bridge
│   │   ├── requirements.txt           # Python dependency manifest
│   │   ├── static/                    # Web component frontend (index.html, CSS, JS)
│   │   ├── data/                      # Master records (driver_master.json, users.json)
│   │   ├── exports/                   # Generated Excel exports & version snapshots
│   │   ├── phone_uploads/             # Mobile upload staging directory
│   │   └── scratch/                   # Ephemeral worker scratch space
│   │
│   ├── main.py (Root Shim)            # Backward-compatible launcher forwarding to backend
│   ├── run_server.py (Root Utility)   # Cross-platform Python server launcher
│   └── run_server.bat (Windows)       # 1-click Windows backend runner
│
├── 📚 DOCUMENTATION & SPECIFICATIONS (docs/)
│   ├── docs/
│   │   ├── spec.md                    # Cumulative system specification & features
│   │   ├── dev_audit.md               # Engineering audit log & prompt history
│   │   ├── android_context.md         # Android UI architecture & review components
│   │   ├── web_context.md             # Web component architecture & state
│   │   └── CONTEXT.md                 # System background & business domain logic
│   └── README.md                      # Project overview & quickstart guide
│
├── 📦 RELEASES & BINARIES (releases/)
│   └── releases/
│       └── ocr_to_excel.apk           # Android release APK binary
│
├── 🎨 ASSETS & MOCKUPS (assets/mockups/)
│   └── assets/
│       └── mockups/
│           └── Logistics_LR_OCR_Workflow_App_Mockup__1_.png
│
└── 🛠️ UTILITY SCRIPTS (scripts/)
    └── scripts/
        └── sync_exports.ps1           # Export synchronization utility script
```

---

## 🚀 Quickstart Guide

### 1. Starting the Python Backend

You can start the backend from the project root using any of the following methods:

**Method A: 1-Click Windows Launcher**
```cmd
run_server.bat
```

**Method B: Python Runner**
```bash
python run_server.py
```

**Method C: Traditional main.py Shim**
```bash
python main.py
```

**Method D: Direct backend directory**
```bash
cd backend
python main.py
```

- **Web Studio**: Open [http://localhost:8000](http://localhost:8000)
- **API Documentation**: Open [http://localhost:8000/docs](http://localhost:8000/docs)
- **APK Direct Download**: Open [http://localhost:8000/download-apk](http://localhost:8000/download-apk)

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

```bash
flutter test
```
All **50/50 test cases** across batch controller, duplicate protection, lifecycle vault, driver master auto-fetch, and review screens run and pass out-of-the-box.

### 4. Searching Files on Command Line (CLI)

Both uploaded LR documents and exported Excel files are automatically saved with unique names and IDs (`LR_...` and `EXP_...`):

**Option A: Built-in Python Search Tool**
```bash
# Search by LR number (e.g. 32754)
python scripts/search_files.py --lr 32754

# Search by Unique ID (e.g. EXP_20261011 or LR_20261011)
python scripts/search_files.py --id EXP_20261011

# List files created in the last 24 hours
python scripts/search_files.py --recent
```

**Option B: Native PowerShell Commands**
```powershell
# Search uploaded LRs by number:
Get-ChildItem backend\uploads\*32754*

# Search exported Excel files by LR number:
Get-ChildItem backend\exports\*32754*

# Search all unique exports created today:
Get-ChildItem backend\exports\*EXP_20261011*
```

---

## 📖 Key Documentation

- [docs/spec.md](docs/spec.md): Complete cumulative technical specifications and feature ledger.
- [docs/dev_audit.md](docs/dev_audit.md): Engineering audit trail, prompt evolution, and regression checkpoints.
- [docs/android_context.md](docs/android_context.md): Deep-dive into mobile UI screens and workflow controllers.
- [docs/web_context.md](docs/web_context.md): Single-page web studio architecture and endpoints.
