# OCR to Excel: Web Component Context & Architecture Guide
> **Updated: November 2026** — Reflects the 49-column `LR_Format.xlsx` schema, 3-step global flow bar, disabled `driver_master.json` auto-fill, and Web-specific Excel export rules (`Branch` lookup from `BookingCounterMast.xlsx`, blank `CustomerRefcode`/`staxpaidby`/`DeliveryType`).

---

## 1. Executive Summary & Overview

The **Web Component** of the **OCR to Excel** system is a browser-based single-page application (SPA) designed for **Box N Freight (BNF)** logistics operations. It processes scanned, photographed, and PDF consignment notes (bilty documents), extracts logistics data into the standardized **49-column Excel format (`LR_Format.xlsx`)**, maintains a per-user audit lifecycle trail with export history, and supports soft deletion with a recycle bin.

The Web Studio is served directly by the FastAPI backend (`backend/main.py`) from [`backend/static/index.html`](../backend/static/index.html) at `http://localhost:8000/` (and `/web`) or over local LAN IP addresses.

---

## 2. Web Technology Stack & Dependencies

| Layer | Technologies & Libraries | Key Responsibilities |
| :--- | :--- | :--- |
| **Markup & Styling** | **HTML5**, **Tailwind CSS (CDN)**, Custom CSS | Responsive logistics portal layout for desktop, tablet, and mobile browsers. |
| **Icons** | **Lucide Icons (`lucide.dev`)** | UI iconography across upload, verification, preview, and audit tables. |
| **Excel Processing** | **Backend `openpyxl` (`/api/export-excel-meta`) + SheetJS (`xlsx-0.20.1`)** | Primary `.xlsx` generation via FastAPI backend; SheetJS client-side fallback (`generateClientExcelWorkbook()`). |
| **Offline OCR Fallback** | **Tesseract.js (CDN)** | Browser-side ML OCR fallback (`extractViaClientMlOcr()`) when backend is unreachable. |
| **Networking** | **Fetch API**, `FormData`, `AbortController` | Multipart uploads (`/extract-handwriting`), JSON exports (`/api/export-excel-meta`), and blob/link downloads. |
| **Storage** | Browser `localStorage` + IndexedDB (`ImageDB`) | Session user metadata, cached batches, tombstones, and high-res document previews. |
| **Backend Integration** | **FastAPI** (`backend/main.py`), Python | Gemini Vision OCR (`gemini-3.5-flash-lite` default), master `.xlsx` loaders, `.xlsx` generation, and 30-day audit purge. |

---

## 3. End-to-End Web Workflow & Screens

The Web Studio organizes operations across `.screen-view` views and modals, coordinated by a sticky **3-Step Global Flow Bar** (`#globalFlowFooter`: `flow_1` *Upload LR* → `flow_2` *LR & Master Verification* → `flow_3` *LR List*):

### Screen 1: Login & OTP Gate (`#screen1_login`)
* **Mobile & User Name**: 10-digit mobile number (`+91`) and user name.
* **Auth Endpoints**: Supports direct login (`POST /api/auth/login`) and OTP flow (`POST /api/auth/send-otp`, `POST /api/auth/verify-otp`) with session state and `Authorization: Bearer <token>`.
* **Security Gate**: Navigating to protected screens without `currentUser` redirects to `#screen1_login`.

### Screen 2: Intake & Multi-File Upload Hub (`#screen2_upload`)
* **Upload Sources**: Drag & drop, multi-file picker (images & PDFs), clipboard paste (`Ctrl+V`), webcam capture, and multi-file PDF assembly (`POST /api/assemble-pdf`).
* **Previous Uploaded LRs**: Displays user-isolated upload history synced via `/api/previous-uploads` and `/api/user-cloud-storage`, with delete/clear actions and re-open for editing.
* **OCR Engine Selection**: Primary **Gemini Vision** (`POST /extract-handwriting`) with automatic non-blocking **Tesseract.js** fallback modal (`#serverFallbackModal`) if the backend is unreachable.

### Screen 3: OCR Processing (`#screen3_ocr`)
* Displays live progress and a 5-step checklist (`Image(s) Uploaded` → `Reading LR Document` → `Extracting Consignment Details` → `Mapping with BNF 49-Column Format` → `Data Validated`).
* Rejects non-LR / invalid documents (`INVALID_LR`), multi-LR packets (`MULTIPLE_LRS`), >15-page packets (`PAGE_LIMIT_EXCEEDED`), and duplicate LR numbers.

### Screen 4: Split-Screen 4-Tab Consignment Editor (`#screen4_edit`) & Master Verification (`#screen4b_customization`)
* **Screen 4 (`#screen4_edit`)**: Left pane shows zoomable/rotatable/paginated LR document preview; right pane provides **4 categorized tabs**:
  * **Tab 1 — Basic Details (`basic`)**: LR No (`edit_grno`), LR Date (`edit_grdt`), Customer Name (`edit_customer`), Origin (`edit_org`), Destination (`edit_dest`), Vehicle No (`edit_vehno`), Vehicle Type (`edit_vehtype`).
  * **Tab 2 — Consignor / Consignee (`parties`)**: Consignor (`edit_cngr`), Consignor GSTIN (`edit_cngrgst`), Consignee (`edit_cnge`), Consignee GSTIN (`edit_cngegst`).
  * **Tab 3 — Cargo Details (`goods`)**: Goods (`edit_goods`), Packages (`edit_pkgs`), Packing (`edit_packing`), Actual Weight (`edit_aweight`), Charged Weight (`edit_cweight`), Private Mark (`edit_pmark` forced blank), Declared Value (`edit_valgoods`).
  * **Tab 4 — Other Details (`other`)**: Product Code (`edit_productcode`), E-Way Bill No (`edit_eway`), Valid Upto (`edit_validupto`), Invoice No (`edit_invno`), Invoice Date (`edit_invdt`), GR Type (`edit_grtype`), Other Charges (`edit_oamount`).
* **Screen 4b (`#screen4b_customization`)**: Master Data & Driver verification:
  * **Customer & Department**: Autocompleted/validated strictly against [`docs/ManiFest.xlsx`](ManiFest.xlsx).
  * **Counter * (`#custom_counter`)**: Populated and validated strictly against Column 1 (`Counter Name`) of [`docs/BookingCounterMast.xlsx`](BookingCounterMast.xlsx) via `/api/master/counters`.
  * **Freight Charge ***: Mandatory manual numeric input.
  * **Product Type**: `Surface-FTL` (default), `Surface-PTL`, `Global-TT`, `Global-MT`, `AIR` (kept separate from `productcode`).
  * **Driver Fields**: `autoFetchAndFillMasterDriverWeb()` is **disabled** (`driver_master.json` auto-fill is turned off) — driver fields remain empty unless extracted directly from the uploaded LR/DL packet or entered manually.

### Screen 5: Verified LR Summary (`#screen5_verified`)
* Confirmation badge and summary card (`v_grno`, `v_veh`, `v_cust`, `v_dept`, `v_counter` showing the Counter name, `v_driver`, `v_mobile`, `v_vehcat`, `v_from`, `v_to`, `v_pkgs`, `v_wt`, `v_val`, `v_created_at`).
* Actions: `Edit Again`, confirm to Batch Queue, or open Excel Preview.

### Screen 7: Batch Queue (`#screen7_lrlist`) & Lifecycle Modal (`#historyModal`)
* Search/filter active batch items, inspect/edit, soft-delete to Recycle Bin (`/api/user-cloud-storage/delete-lr`), or trigger `Generate Excel`.
* **`#historyModal`**: Displays field-level Version History & Diffs (with restore via `POST /api/files/restore-version`), Deleted Items / Recycle Bin (restore via `POST /api/files/restore-deleted`), and 30-day retention cleanup.

### Screen 8: Excel Preview & Export History (`#screen8_excel_preview`) + Spreadsheet Modal (`#excelPreviewModal`)
* **Tab 1 — Sheet 1: BNF Import Format (`#s8TabBtn_sheet1`)**: Summary table (`#bnfPreviewTable`), full 49-column interactive spreadsheet preview modal (`#excelPreviewModal`, rendered using `BNF_49_COLUMNS` and `getBnfFieldValue()`), bottom-left **Add More LR**, and bottom-right **Generate Excel**.
* **Tab 2 — Sheet 2: Audit Snapshot & Lifecycle Log (`#s8TabBtn_audit`)**:
  * **Export History (`#exportHistoryTbody`)**: User-isolated list of exports from `/api/export-audit/history` with direct download links (`/api/download-export/{filename}`).
  * **Download All My Exported LRs (.xlsx)**: Calls `downloadAllMyExportedLrs()` → `GET /api/export-audit/download-all?mobile=...&client_source=web`.

### Screen 9: Excel Generated (`#screen9_excel_generated`)
* Displays export confirmation, file size, LR count, file name, audit metadata, direct download trigger, and **Start New Batch**.

---

## 4. Standard 49-Column Schema (`LR_Format.xlsx`) & Web-Only Export Rules

The Web Studio previews and exports **49 columns** matching [`docs/LR_Format.xlsx`](LR_Format.xlsx) (`BNF_49_COLUMNS` in `index.html`, `LR_FORMAT_49_HEADERS` in `backend/main.py`) with zero asterisks:

```text
 1. Branch             11. Consignor          21. DriverName         31. Received         41. CustomerRefcode
 2. GrNo               12. ConsignorGST       22. DriverMobileNo     32. Advance          42. staxpaidby
 3. GrDate             13. Consignee          23. DrivingLicenseNo   33. CollectionBranch 43. DeliveryType
 4. GrType             14. ConsigneeGST       24. DrivingValidUpto   34. FTL              44. EwayBillNo
 5. Customer           15. ProductName        25. LoadingStartDate   35. PCS              45. ValidUpto
 6. CustomerDepartment 16. Packing            26. Freight            36. OrderWeight      46. InvoiceNo
 7. Countername        17. PMark              27. OtherAmount        37. ActualWeight     47. InvoieDate
 8. TransitDays        18. Goods              28. CGST               38. ChargableWeight  48. ValueOfGoods
 9. Origen             19. VehicleNo          29. SGST               39. ContractWeight   49. viaborder
10. Destination        20. VehicleTypeName    30. IGST               40. ExtraMt
```

### Web-Specific Field Rules (`client_source="web"` / `web_mode=True`)
1. **`Branch` vs `Countername` (Counter preserved intact)**:
   - `Countername` (Col 7) always keeps the exact Counter Name from `BookingCounterMast.xlsx` (e.g., `KOL`, `BANG-01`, `1`, `BHIWANDI-01`).
   - `Branch` (Col 1) is resolved from [`docs/BookingCounterMast.xlsx`](BookingCounterMast.xlsx) (`Branch Name` column) via `getBranchNameForCounterWeb(counterName)` on the frontend and `get_branch_name_for_counter(counter_name)` on the backend (e.g., `KOL` → `KOLKATA`, `BANG-01` → `BANGLORE`, `1` → `NAGPUR_1`, `BHIWANDI-01` → `BHIWANDI_1`), or left empty `""` if no Counter is matched.
2. **Always Empty Web Fields (`CustomerRefcode`, `staxpaidby`, `DeliveryType`)**:
   - Columns 41–43 (`CustomerRefcode`, `staxpaidby`, `DeliveryType`) are always forced empty (`""` in Web UI/SheetJS and `None` / blank cell in backend `.xlsx` exports when `client_source == "web"`), overriding legacy `'CM001'`, `'C'`/`'E'`, and `'G'`/`'D'` defaults.
   - Non-web / Android requests (`web_mode=False`) continue using their existing defaults unchanged.

---

## 5. Web Backend API Endpoints & Contract

| Endpoint | Method | Payload / Params | Description |
| :--- | :--- | :--- | :--- |
| `/` & `/web` | `GET` | None | Serves `backend/static/index.html`. |
| `/api/auth/login` | `POST` | `{"mobile", "name"}` | Direct mobile/name session login. |
| `/api/auth/send-otp` | `POST` | `{"mobile", "name"}` | Generates 6-digit OTP with resend cooldown. |
| `/api/auth/verify-otp` | `POST` | `{"mobile", "otp", "name"}` | Validates OTP and issues session token. |
| `/api/auth/me` / `/api/auth/logout` | `GET`/`POST` | `Authorization: Bearer <token>` | Fetches active user / invalidates session. |
| `/extract-handwriting` | `POST` | `multipart/form-data`: `file`/`files`, `use_gemini`, user fields | Gemini Vision OCR, LR authenticity validation, and 49-col mapping. |
| `/api/assemble-pdf` | `POST` | `multipart/form-data` images/PDFs | Combines multi-page uploads into a single PDF dossier. |
| `/api/master/manifest` & `/parties` | `GET` | None | Customer/department mappings and GSTIN map from `ManiFest.xlsx`. |
| `/api/master/counters` | `GET` | None | 30 `counters` and `records` (`counter_name`, `branch_name`) from `BookingCounterMast.xlsx`. |
| `/api/master/vehicle-types` | `GET` | None | Vehicle types from `VehicleTypeMaster.xlsx`. |
| `/api/master/goods-master` & `/goods` | `GET` | None | Active commodity names/records from `GoodsMaster.xlsx`. |
| `/api/export-excel-meta` | `POST` | `{"documents", "format_type": "gr_bnf_49", "client_source": "web", ...}` | Builds Sheet1 + Audit copy (`web_mode=True`), logs audit, returns `download_url`. |
| `/generate-excel` | `POST` | `ExcelExportRequest` (`client_source="web"`) | Streams generated `.xlsx` workbook directly. |
| `/api/download-export/{filename}` | `GET` | Path: `filename` | Downloads user `.xlsx` export. |
| `/api/export-audit/history` | `GET` | Query: `mobile`, `session_token` | Retrieves user-isolated export history (30-day retention). |
| `/api/export-audit/download-all` | `GET` | Query: `mobile`, `client_source=web` | Consolidates user's exported LRs into one `.xlsx` (`web_mode=True`). |
| `/api/export-audit/cleanup-expired` | `POST` | None | Purges export files/audit entries older than 30 days. |
| `/api/previous-uploads` & `/api/user-cloud-storage/*` | `GET`/`POST` | User mobile / token | User-isolated recent uploads and cloud batch state sync. |
| `/api/files/*` | `GET`/`POST` | `file_id`, `version` | Version history, soft-deleted items, and restore endpoints. |

---

## 6. Key JavaScript Functions ([`backend/static/index.html`](../backend/static/index.html))

* **`getBranchNameForCounterWeb(counterName)`**: Resolves `Branch Name` from `masterBookingCounterRecords` (`docs/BookingCounterMast.xlsx`) for a given Counter.
* **`getBnfFieldValue(data, fieldKey)`**: Maps item data into `BNF_49_COLUMNS`, resolving `Branch` from the Counter, preserving `Countername`, and returning `''` for `CustomerRefcode`, `staxpaidby`, and `DeliveryType`.
* **`enrichExtractedResultWeb(result)`**: Post-processes `/extract-handwriting` responses (populates `Counter`, sets `Branch`/`branchrefcode` via `getBranchNameForCounterWeb`, forces `custrefcode`/`staxpaidby`/`dlvtype` to `''`).
* **`handleCustomizationBackToScanData()` & `saveAndVerifyFromCustomization()`**: Persist `Counter` (`counterVal`), update `Branch`/`branchrefcode` via `getBranchNameForCounterWeb(counterVal)`, validate against master Excel files, and keep `custrefcode`/`staxpaidby`/`dlvtype` empty.
* **`autoFetchAndFillMasterDriverWeb()`**: Intentionally no-op (`driver_master.json` auto-fill disabled).
* **`executeGenerateExcel()`**: Sends `client_source: 'web'` and sanitized doc copies to `POST /api/export-excel-meta`, then triggers browser `.xlsx` download.
* **`downloadAllMyExportedLrs()`**: Triggers consolidated download via `/api/export-audit/download-all?mobile=...&client_source=web`.
* **`generateClientExcelWorkbook()`**: Offline SheetJS fallback exporter using `BNF_49_COLUMNS` and `getBnfFieldValue()`.

---

## 7. Running the Web Component Locally

From the project root (`ocr_to_excel`):
```cmd
run_server.bat
```
or
```bash
.venv\Scripts\python.exe main.py
```
Then open `http://127.0.0.1:8000` (or `http://<LAN_IP>:8000` from another device on the LAN).
