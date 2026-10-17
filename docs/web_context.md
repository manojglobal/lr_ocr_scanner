# OCR to Excel: Web Component Context & Architecture Guide

---

## 1. Executive Summary & Overview

The **Web Component** of the **OCR to Excel** system is a responsive, browser-based single-page application (SPA) designed for **Box N Freight (BNF)** logistics operations. It processes scanned, photographed, and handwritten consignment notes (bilty documents), extracts all logistics data into a standardized **50-column Microsoft Excel format (`.xlsx`)**, maintains an immutable audit trail with visual snapshots, and supports soft deletion with a dedicated recycle bin.

The Web component is served directly by the FastAPI backend server (`main.py`) from [`static/index.html`](file:///D:/AndroidDev/Projects/ocr_to_excel/static/index.html) and connects seamlessly to the backend APIs on `http://localhost:8000/` or local LAN IP addresses.

---

## 2. Web Technology Stack & Dependencies

| Layer | Technologies & Libraries | Key Responsibilities |
| :--- | :--- | :--- |
| **Markup & Styling** | **HTML5**, **Tailwind CSS (CDN)**, Custom CSS | Modern, responsive logistics portal layout; optimized for desktop, tablet, and mobile browsers. |
| **Icons** | **Lucide Icons (`lucide.dev`)** | Clean iconography for actions, document statuses, file types, and navigation elements. |
| **Excel Processing** | **SheetJS / xlsx (`xlsx.full.min.js`)** | Client-side spreadsheet generation fallback, workbook creation, and `.xlsx` blob generation. |
| **Networking** | Standard browser **Fetch API**, `FormData` | Multipart document uploads, JSON payload communication, and binary blob downloads. |
| **Storage** | Browser `localStorage` / `sessionStorage` | Session tokens, active user details (`bnf_user_mobile`, `bnf_user_name`), and cached queue state. |
| **Backend Integration** | **FastAPI** (`main.py`), Python 3.10+ | Gemini 3.5 Flash Lite OCR, server-side `.xlsx` generation, audit logging, and 30-day lifecycle management. |

---

## 3. End-to-End 9-Screen Web Workflow

The web portal organizes logistics workflows into an intuitive 9-screen journey, navigable via top/bottom controls and tracked by a persistent **Step Indicator Flow Bar** (`flow_1` through `flow_9`):

### Screen 1: Login & Security Gate (`#screen1_login`)
* **Phone Number & Name**: 10-digit mobile input with fixed `+91` country code prefix.
* **OTP Verification**:
  * Calls `POST /api/auth/send-otp` to initiate 6-digit OTP dispatch.
  * 6 individual digit input boxes with auto-focus, backspace backward shift, and paste handling.
  * 30-second resend countdown timer with automatic cooldown.
  * Dev Mode: Auto-fills test OTP for rapid QA verification.
  * Calls `POST /api/auth/verify-otp` to obtain `session_token`, storing user credentials in `localStorage`.
* **Security Redirection Gate**: Any attempt to access Screens 2–9 without a verified session automatically redirects back to Screen 1.

### Screen 2: Intake & Multi-Image Upload Hub (`#screen2_upload`)
* **Header & User Profile**: Displays active user name, mobile badge, and Logout action.
* **Upload Sources**:
  * **Drag & Drop Zone**: Drag single or multiple images directly into the browser window.
  * **File Picker**: File input supporting JPEG, PNG, WEBP, and HEIC files.
  * **Clipboard Paste (`Ctrl+V`)**: Instant paste of captured screenshots from clipboard.
  * **Webcam Capture**: Browser camera access via `navigator.mediaDevices.getUserMedia`.
* **OCR Engine Selection**: Switch between **Google Gemini 3.5 Flash Lite** (primary high-accuracy cloud engine) and **Local/Fallback ML OCR**.
* **Intelligent Rule-Based Bilty Classification**:
  * **Orange/Yellow Handwritten Bilties**: Automatically classified via color detection; extracts only `LR No` (does NOT populate `BNF LR No`).
  * **White Printed Pages**: Extracts handwritten/pencil numbers near top-left or top-right as `BNF LR No` (e.g., "33196"); if absent, strictly preserved as blank.

### Screen 3: OCR Processing Animation (`#screen3_ocr`)
* **Live Progress Graphic**: Animated scanner graphic with progress percentages.
* **5-Step Extraction Checklist**:
  1. `Image(s) Uploaded`
  2. `Reading LR Document`
  3. `Extracting Consignment Details`
  4. `Mapping with BNF 50-Column Format`
  5. `Validating Data & Preserving Blanks`
* **Non-Blocking Fallback Dialog**: If backend server is unreachable, displays a non-blocking modal notifying the user of automatic ML OCR fallback while allowing batch continuity.

### Screen 4: Split-Screen & Tabbed Consignment Editor (`#screen4_edit`)
* **Side-by-Side Review**: Left pane shows high-resolution zoomable bilty image; right pane displays all 50 extracted fields.
* **Categorized Tab Structure**:
  * **Tab 1: Basic & Logistics**: `LR No *`, `BNF LR No`, `grno (*)`, `grdt *`, `Customer Name *`, `Vehicle No *`, `From`, `To`.
  * **Tab 2: Goods & Packaging**: `bookedpckgs`, `packing`, `goods`, `bookedaweight`, `bookedcweight`, `pmark`.
  * **Tab 3: Financial & Tax**: `freight  *`, `valgoods`, `ewaybillno`, `invoiceno`, `Driver Name *`, `Mobile no   *`.
* **Undo & Redo Engine**: Full history stack for field modifications.
* **Version Snapshot Creation**: Saving edits increments version number (`v1` $\rightarrow$ `v2`...) and records exact field-level diffs (`old` $\rightarrow$ `new`) with timestamp and user ID.

### Screen 5: Verified LR Confirmation (`#screen5_verified`)
* **Visual Status**: Large green badge with checkmark and "Consignment Note Verified!" headline.
* **Summary Card**: Displays 8 critical fields: LR Number, Vehicle Number, Customer Name, Route (`From` $\rightarrow$ `To`), Packages, Weight, Invoice Value, and Timestamps.
* **Action Buttons**:
  * `View Billing Image` $\rightarrow$ Opens Screen 6.
  * `Edit Again` $\rightarrow$ Returns to Screen 4.
  * `Preview Excel` $\rightarrow$ Opens Screen 8.
  * `Batch Queue` $\rightarrow$ Opens Screen 7.

### Screen 6: Multi-Image Billing Document Viewer (`#screen6_preview`)
* **Interactive Viewport**: Zoom in/out, reset zoom, 90° clockwise rotation, pan/drag.
* **Thumbnail Carousel Strip**: Bottom thumbnail bar of all uploaded consignments in the current batch with active selection indicators.
* **50-Column Spreadsheet Overlay Toggle**: Allows toggling between the raw document image and an overlay table showing all 50 BNF fields with Captured / Blank status badges.
* **Bottom Toolbar**: `Edit Bilty`, `Toggle Spreadsheet View`, `Preview Excel`, `Batch Queue`.

### Screen 7: Batch Queue & File Lifecycle Manager (`#screen7_lrlist`)
* **Real-Time Search & Filtering**: Filters consignments by LR Number, Vehicle Number, Customer Name, or filename.
* **Consignment Queue Table**: Lists all active batch items with thumbnail, LR number, customer, vehicle, version badge (`v1`), OCR engine badge (`Gemini` / `ML Fallback`), and actions (`View Image`, `History`, `Edit`, `Delete`).
* **Lifecycle & Recycle Bin Modal (`#auditLifecycleModal`)**:
  * **Tab 1: Version History & Diffs**: Select any consignment to inspect its full revision history, timestamp audit, active version, and field-level diff cards.
  * **Tab 2: Deleted Items / Recycle Bin**: Displays all soft-deleted items with reason and timestamp. Contains a one-click **"Restore Consignment"** button returning items to active queue.

### Screen 8: Excel Preview & Audit Log (`#screen8_excel_preview`)
* **Dual-Tab Switcher**:
  * **Tab 1: Sheet 1: BNF Import Format (50 Columns)** (`#s8TabBtn_sheet1`):
    * **Header Toolbar**: Clean header card displaying spreadsheet icon, title *"Sheet 1: BNF Import Format (50 Columns)"*, `50 Columns` badge, and subtitle *"Consignment data preview ready to export to Excel (.xlsx)"*.
    * **50-Column Table Preview** (`#bnfPreviewTable`): Sticky header row, responsive scroll container, showing all 50 BNF columns with clean zero-color-fill styling.
    * **Bottom Action Bar**:
      * **Bottom-Left**: **“Add More LR”** button (`bg-slate-100 hover:bg-slate-200 text-slate-700`, icon `plus`), calling `navigateTo('screen2_upload')`.
      * **Bottom-Right**: **“Generate Excel (<N> LRs)”** button (`bg-sky-600 hover:bg-sky-700 text-white font-bold`, icon `table`), calling `executeGenerateExcel()`.
  * **Tab 2: Sheet 2: Audit Snapshot & Lifecycle Log** (`#s8TabBtn_audit`):
    * **History Table** (`#exportHistoryTbody`): Displays all historical Excel exports generated from LR images by the current user within the 30-day window (`#`, File Name, Date/Time, User, LR Count, Retention Countdown, Download Excel Action).
    * **Download All My Exported LRs**: Dedicated button calling `downloadAllMyExportedLrs()`, generating and downloading a single consolidated `.xlsx` file containing all past exports for the user.
    * **30-Day Auto-Purge Notice**: Explains automated cleanup policy for expired files.
    * **Bottom Action Bar**: Identical **“Add More LR”** (bottom-left) and **“Generate Excel (<N> LRs)”** (bottom-right) buttons matching Sheet 1.

### Screen 9: Excel Generated & Export Hub (`#screen9_excel_generated`)
* **Success Certificate Banner**: Green checkmark header, confirmation message, and export metadata (Filename, Date/Time, Exported By, Records Count).
* **Lightweight Snapshot Preview**: Interactive visual snapshot card showing the generated Excel layout with thumbnail and file size badge.
* **Auto-Purge Retention Badge**: Displays *"Auto 30-Day Purge Enabled"*.
* **Action Buttons**:
  * `Download Excel (.xlsx)`: Direct browser download trigger.
  * `Start New Batch`: Resets queue and returns to Screen 2.

---

## 4. Standard 50-Column BNF Logistics Schema

The web component strictly validates and maps data to the **50 standardized columns** of the Box N Freight import format:

```text
 1. stockdt            11. cngrgstno *       21. goods             31. handlingcharges   41. invoiceno
 2. branchrefcode      12. cngraddress       22. pmark             32. doorcharges       42. invoiedt
 3. grno (*)           13. cnge *            23. bookedaweight     33. cod               43. ewaybillno
 4. grdt *             14. cngegstno *       24. bookedcweight     34. demurragecharges  44. Valid Upto
 5. deliveryat         15. cngeaddress       25. transmode         35. insurancecharges  45. grtype(Don’t know)
 6. LR No *            16. billingparty      26. freight  *        36. subtotal          46. Vehicle No *
 7. BNF LR No          17. billingpartyadd.. 27. stcharges         37. sgst              47. Vehicle Type *
 8. orgrefcode         18. billingpartygst.. 28. fuelcharges       38. cgst              48. Driver Name *
 9. destrefcode        19. bookedpckgs       29. oamount           39. igst              49. Mobile no   *
10. cngr *             20. packing           30. hamali            40. total             50. Liscense No *
                                                                                         51. valgoods
                                                                                         52. viaborder
```
*(Note: Column indices follow the `DocumentSchema.grBnf` specification where total fields = 50).*

---

## 5. Web Backend API Endpoints & Contract

| Endpoint | Method | Payload / Params | Response Structure | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| `/api/auth/send-otp` | `POST` | `{"mobile": "9876543210", "name": "User"}` | `{"success": true, "dev_otp": "123456"}` | Initiates OTP dispatch with 30s rate limit. |
| `/api/auth/verify-otp` | `POST` | `{"mobile": "9876543210", "otp": "123456", "name": "User"}` | `{"success": true, "session_token": "...", "name": "User", "mobile": "..."}` | Validates OTP and issues user session. |
| `/api/extract-handwriting` | `POST` | `multipart/form-data`: `file`, `use_gemini` | `{"success": true, "fields": {...}, "ocr_engine": "gemini_flash"}` | Runs Gemini OCR and color-based bilty classification. |
| `/api/export-excel-meta` | `POST` | `{"documents": [...], "format_type": "gr_bnf_49", "user_name": "...", "user_mobile": "..."}` | `{"success": true, "filename": "...", "download_url": "...", "snapshot_base64": "..."}` | Generates 50-column Excel file, logs export history, and builds visual snapshot. |
| `/download-excel/{filename}` | `GET` | Path variable `filename` | Binary `.xlsx` stream (`application/vnd.openxmlformats...`) | Streams generated Excel file to browser download folder. |
| `/api/audit/export-history` | `GET` | Query params: `mobile`, `session_token` | `{"success": true, "exports": [{"filename": "...", "exported_at": "...", "total_lrs": 5, ...}]}` | Retrieves user's personal export history (30-day retention). |
| `/api/audit/download-all-lrs` | `GET` | Query params: `mobile`, `session_token` | Binary `.xlsx` stream | Combines all historical LR records of the user into one consolidated `.xlsx` file. |
| `/api/audit/purge-30d` | `POST` | Empty | `{"success": true, "purged_count": N}` | Scheduled auto-purge for files and audit logs older than 30 days. |

---

## 6. Key JavaScript Modules & Functions

In [`static/index.html`](file:///D:/AndroidDev/Projects/ocr_to_excel/static/index.html):

* **`switchPreviewSheet(sheet)`**: Switches between Sheet 1 (`bnfPreviewTable`) and Sheet 2 (`exportHistoryTbody`).
* **`populateExcelPreview()`**: Renders all 50 columns in Sheet 1 preview and synchronizes dynamic button labels (`Generate Excel (N LRs)`).
* **`executeGenerateExcel()`**: Disables buttons, shows spinning loader, calls `/api/export-excel-meta`, triggers automatic browser download, updates history, and transitions to Screen 9.
* **`loadAndRenderExportHistory()`**: Fetches user-isolated export records from `/api/audit/export-history` and populates Sheet 2.
* **`downloadAllMyExportedLrs()`**: Requests combined workbook of all past user exports via `/api/audit/download-all-lrs`.
* **`navigateTo(screenId)`**: Controls the Screen Router, updates flow bar indicators (`updateFlowBar`), and triggers Lucide icon rendering.

---

## 7. Running the Web Component Locally

1. Start Python backend server:
   ```bash
   cd D:\AndroidDev\Projects\ocr_to_excel
   python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
   ```
2. Open any browser and navigate to:
   ```text
   http://127.0.0.1:8000
   ```
   *(Or accessible from local network devices at `http://<LAN_IP>:8000`)*.
