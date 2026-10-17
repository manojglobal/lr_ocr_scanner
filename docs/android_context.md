# OCR to Excel: Android Mobile App Context & Architecture Guide

---

## 1. Executive Summary & Mobile Architecture

The **Android Mobile App** of the **OCR to Excel** system is a cross-platform Flutter application tailored for Android devices. It provides high-accuracy document digitisation for **Box N Freight (BNF)** logistics field workers, branch managers, and warehouse supervisors.

### Key Architectural Strengths
* **100% Feature Parity with Web Portal**: Mirrors all 9 screens, color-based bilty classification, 50-column standardized BNF format, audit lifecycle tracking, and export history.
* **Dual-Engine Architecture (Cloud + Offline)**:
  * **Primary (Cloud)**: Google Gemini 3.5 Flash Lite API via FastAPI backend server (`GeminiBackendService`).
  * **Secondary (On-Device)**: Google ML Kit Text Recognition (`google_mlkit_text_recognition`) enabling offline extraction whenever network connectivity is lost.
* **Local Storage & Public Downloads Access**: Saves exported Excel workbooks both to internal app sandbox storage and directly to the public device `Downloads` directory via `ExcelService`.
* **State Management**: Reactive state architecture driven by `BatchProcessingController` (`ChangeNotifier`).

---

## 2. Technical Stack & Dependencies

### Environment & SDKs
* **Flutter SDK**: 3.47.5 (Channel stable)
* **Dart SDK**: 3.13.4
* **Android Target SDK**: 37 (Android 15+)
* **Android Min SDK**: 29 (Android 10+)
* **JDK Version**: OpenJDK 17 / 25 (`C:\Program Files\Android\Android Studio\jbr`)
* **Gradle Wrapper**: 9.3.1 (Kotlin DSL `build.gradle.kts`)

### Dependencies (`pubspec.yaml`)
```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  google_mlkit_text_recognition: ^0.17.1  # Local on-device ML OCR engine
  image_picker: ^1.2.3                   # Camera and gallery intake
  permission_handler: ^13.0.2            # Runtime permissions (Camera, Storage)
  excel: ^4.0.6                          # Native client-side .xlsx workbook generator
  path_provider: ^2.1.6                  # App directories and device storage access
  share_plus: ^13.3.0                    # Android system share sheet integration
  open_filex: ^4.7.0                     # System Excel viewer integration
  uuid: ^4.6.0                           # Unique IDs for consignment snapshots
  image: ^4.3.0                          # Image decoding, rotation, and downsampling
  http: ^1.2.2                           # REST client for backend API communication
  http_parser: ^4.0.2                    # MediaType parsing for multipart uploads
  shared_preferences: ^2.3.2             # Persistent user credentials and server URL
```

---

## 3. Native 9-Screen Workflow Implementation

The Android app follows the exact 9-screen journey coordinated by [`StepIndicatorBar`](file:///D:/AndroidDev/Projects/ocr_to_excel/lib/views/widgets/step_indicator_bar.dart):

```text
[Screen 1: Login] ──▶ [Screen 2: Upload] ──▶ [Screen 3: OCR Dialog]
                              │
                              ▼
[Screen 5: Verified] ◀── [Screen 4: Edit LR]
      │
      ├───────────────────────┬────────────────────────┐
      ▼                       ▼                        ▼
[Screen 6: Viewer]     [Screen 7: Queue]     [Screen 8: Preview]
                                                       │
                                                       ▼
                                             [Screen 9: Generated]
```

### Screen 1: Login & Security Gate ([`login_screen.dart`](file:///D:/AndroidDev/Projects/ocr_to_excel/lib/views/login_screen.dart))
* **OTP Input**: 6 individual text input boxes with automatic focus progression and backspace routing.
* **Server IP Configuration Modal**: Accessible from the top bar icon; allows the operator to configure and test ping to the backend host (e.g., `http://10.154.209.156:8000` on Wi-Fi or `http://10.0.2.2:8000` on the Android emulator).
* **30-Second Countdown Timer**: Auto-disables resend requests until cooldown elapses.
* **Session Persistence**: Stores `bnf_user_mobile`, `bnf_user_name`, and `bnf_user_token` in `SharedPreferences`.

### Screen 2: Intake & Upload Hub ([`home_screen.dart`](file:///D:/AndroidDev/Projects/ocr_to_excel/lib/views/home_screen.dart))
* **Intake Sources**:
  * **Camera**: High-resolution photo capture with autofocus.
  * **Gallery**: Multi-image selection from Android photo album.
* **Queue Cards**: Displays pending images with remove and intake status badges.
* **Automatic Fallback Alert**: Non-blocking dialog alerting the user if the server connection drops, allowing immediate transition to local ML OCR.

### Screen 3: OCR Processing Dialog ([`ocr_processing_dialog.dart`](file:///D:/AndroidDev/Projects/ocr_to_excel/lib/views/widgets/ocr_processing_dialog.dart))
* 5-step extraction checklist:
  1. *Image(s) Uploaded*
  2. *Reading LR Document*
  3. *Extracting Consignment Details*
  4. *Mapping with BNF 50-Column Format*
  5. *Validating Data & Preserving Blanks*
* Real-time file index indicator: `Reading Consignment X of Y (<Filename>)`.

### Screen 4: Edit Consignment Note ([`edit_bilty_screen.dart`](file:///D:/AndroidDev/Projects/ocr_to_excel/lib/views/screens/edit_bilty_screen.dart))
* **Mobile 3-Tab Categorization**:
  * **Basic & Logistics**: LR Number, BNF LR No, Customer, From, To, Vehicle Number.
  * **Goods & Packaging**: Packages, Packing type, Weight, Chargeable weight.
  * **Financial & Tax**: Goods Value, Freight, E-Way Bill, Invoice Number, Driver details.
* **Snapshot Versioning**: Every save increments `currentVersion` (`v1` $\rightarrow$ `v2`...) and appends an entry to `editHistory` with user ID, ISO timestamp, and field diffs.

### Screen 5: Verified Summary Card ([`verified_screen.dart`](file:///D:/AndroidDev/Projects/ocr_to_excel/lib/views/screens/verified_screen.dart))
* Prominent green checkmark banner.
* Clean summary list of primary logistics attributes.
* Quick actions to inspect document image or proceed directly to Excel Preview or Batch Queue.

### Screen 6: Billing Document Viewer ([`billing_image_viewer.dart`](file:///D:/AndroidDev/Projects/ocr_to_excel/lib/views/widgets/billing_image_viewer.dart))
* **Interactive Viewer**: Smooth pinch-to-zoom (up to 4x) and double-tap zoom via `TransformationController`.
* **90° Rotation**: Instant 90° clockwise rotation button.
* **Thumbnail Strip**: Horizontal gallery allowing one-tap switching between batch bilty documents.
* **BNF 50-Column Overlay Toggle**: Renders an interactive spreadsheet overlay on top of the document for field-by-field verification.

### Screen 7: Batch Queue & File Lifecycle Manager ([`batch_queue_screen.dart`](file:///D:/AndroidDev/Projects/ocr_to_excel/lib/views/screens/batch_queue_screen.dart))
* Real-time search by LR Number, Customer, Vehicle, or File name.
* Batch item cards displaying thumbnails, metadata, version badges, and OCR engine badges.
* **Lifecycle & Recycle Bin Screen ([`file_history_screen.dart`](file:///D:/AndroidDev/Projects/ocr_to_excel/lib/views/screens/file_history_screen.dart))**:
  * **Tab 1: Versions & Diffs**: Detailed side-by-side audit diffs showing field modifications across versions.
  * **Tab 2: Recycle Bin**: Soft-deleted consignments with one-tap **Restore** action.
  * **Tab 3: Retention (30d)**: Explains the 30-day automated cleanup policy with manual trigger options.

### Screen 8: Excel Preview Screen ([`excel_preview_screen.dart`](file:///D:/AndroidDev/Projects/ocr_to_excel/lib/views/screens/excel_preview_screen.dart))
* **Sheet 1: BNF Data (50 Cols)**:
  * **Header Toolbar**: Clean card displaying `Icons.table_chart`, title *"Sheet 1: BNF Import Format (50 Columns)"*, `50 Columns` badge, and subtitle.
  * **Scrollable DataTable**: Vertical and horizontal scrolling displaying all 50 BNF fields without clutter or artificial fills.
* **Sheet 2: Audit & Lifecycle Log**:
  * **Generated Excel Exports History**: Table listing past user exports (File Name, Date/Time, User, LR Count, Retention Countdown, Download action).
  * **Download All My Exported LRs**: Downloads a combined `.xlsx` file containing all past consignments for the logged-in user.
  * **Per-User Isolation**: Queries only the records associated with the user's mobile number.
* **Bottom Action Bar**:
  * **Bottom-Left**: **“Add More LR”** button (`OutlinedButton.icon` with slate styling `Color(0xFFF1F5F9)`, icon `Icons.add`), navigating to `BatchQueueScreen`.
  * **Bottom-Right**: **“Generate Excel (<N> LRs)”** button (`FilledButton.icon` with sky-600 styling `Color(0xFF0284C7)`, icon `Icons.table_chart_outlined`), executing `_handleGenerateExcel()`.
  * Identical layout and styling across both Sheet 1 and Sheet 2.

### Screen 9: Excel Generated Screen ([`excel_generated_screen.dart`](file:///D:/AndroidDev/Projects/ocr_to_excel/lib/views/screens/excel_generated_screen.dart))
* Confirmation badge and metadata card (Filename, Consignment count, Exported By, Timestamp).
* **Lightweight Snapshot Card**: Displays the base64-encoded visual audit snapshot generated by the backend with file size badge.
* **Downloads Integration**: Automatically saves the `.xlsx` file to the device's public `Downloads` directory.
* Actions: `Save to Downloads`, `Open in Excel Viewer` (`open_filex`), `Share File` (`share_plus`), and `Start New Batch`.

---

## 4. Dual-Engine Extraction Strategy

```text
                  [ User Captures Bilty Image ]
                               │
                               ▼
               Check Network & Backend Availability
                               │
              ┌────────────────┴────────────────┐
              ▼                                 ▼
       [ Server Reachable ]             [ Server Unreachable ]
              │                                 │
              ▼                                 ▼
    GeminiBackendService              OcrService (Offline)
    Google Gemini 3.5 Flash           Google ML Kit Text Recognition
    High-accuracy JSON mapping        Spatial bounding-box analysis
    Rule-based BNF LR No split        DynamicStructureDetector
              │                                 │
              └────────────────┬────────────────┘
                               │
                               ▼
            Standardized BatchItem (50 Fields)
```

1. **Online Engine (`gemini_backend_service.dart`)**:
   Sends multipart image bytes to FastAPI `/api/extract-handwriting`. Applies rule-based color checks (`is_orange_yellow_image`):
   * Orange/Yellow bilties $\rightarrow$ Only `LR No *` is populated.
   * White printed bilties $\rightarrow$ `BNF LR No` populated from top corner handwriting if present.
2. **Offline Engine (`ocr_service.dart`)**:
   Invokes Google ML Kit on-device (`google_mlkit_text_recognition`) combined with `DynamicStructureDetector` to group words into rows and columns, mapping directly to `DocumentSchema.grBnf`.

---

## 5. Android Manifest & Permissions

In [`android/app/src/main/AndroidManifest.xml`](file:///D:/AndroidDev/Projects/ocr_to_excel/android/app/src/main/AndroidManifest.xml):

* **Permissions**:
  ```xml
  <uses-permission android:name="android.permission.CAMERA" />
  <uses-permission android:name="android.permission.INTERNET" />
  <uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
  <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
  ```
* **Cleartext Traffic & Security Config**:
  ```xml
  <application
      android:label="BNF OCR to Excel"
      android:usesCleartextTraffic="true"
      android:networkSecurityConfig="@xml/network_security_config">
  ```
  Permits local IP testing (e.g. `http://192.168.x.x:8000` or `http://10.x.x.x:8000`) across corporate networks and local routers.

---

## 6. Building and Installing the Android APK

### Building Release APK
From the project root directory:
```powershell
Push-Location "D:\AndroidDev\Projects\ocr_to_excel"
flutter build apk --release
Pop-Location
```

### Output File
* **Path**: `D:\AndroidDev\Projects\ocr_to_excel\build\app\outputs\flutter-apk\app-release.apk`
* **Size**: ~99.1 MB
* **Signing**: Configured with debug signing key for immediate sideloading.

### Installing to Device / Emulator
```powershell
adb install -r "D:\AndroidDev\Projects\ocr_to_excel\build\app\outputs\flutter-apk\app-release.apk"
```
