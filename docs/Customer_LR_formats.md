# Customer LR Formats & Document Extraction Matrix
> **System Reference Specification (October 2026)** — Production reference guide defining the Consignment Note (Bilty) and multi-page compliance dossier formats across all Box N Freight (BNF) enterprise customer accounts.
> Standardized against the **49-Column BNF Excel Schema (`GR_BNF_49_HEADERS`)**.

---

## 1. Quick Cross-Customer Comparison (49 Target Columns)

| Col # | Target Column Name | Unicharm India | Patanjali Foods / Parivahan | Himalaya Wellness | Gold Plus Float Glass |
| :---: | :--- | :---: | :---: | :---: | :---: |
| 1 | `branchrefcode` | Partially Present | Present | Partially Present | Partially Present |
| 2 | `grno (*)` / `LR No *` | **Present** (Bold 5-digit) | **Partially Present** (Pen/Pencil margin; 0 if absent) | **Present** (Bold 5-digit) | **Present** (Bold 5-digit) |
| 3 | `grdt *` | **Present** | **Present** | **Present** | **Present** |
| 4 | `grtype` | **Present** (TBB) | **Present** (TBB) | **Present** (TBB) | **Present** (TBB) |
| 5 | `Customer Name *` | **Present** | **Present** | **Present** | **Present** |
| 6 | `Depatment Name` | Partially Present | Partially Present | Partially Present | Partially Present ("BELGUAM") |
| 7 | `Counter name` | Partially Present | Present | Partially Present | Partially Present |
| 8 | `Transit Days` | **Present** (Calculated) | Partially Present (Needs E-Way) | **Present** (Calculated) | **Present** (Calculated) |
| 9 | `orgrefcode` | **Present** | **Present** | **Present** | **Present** ("Kanagal" / "Belgaum") |
| 10 | `destrefcode` | **Present** | **Present** | **Present** | **Present** ("Udupi") |
| 11 | `cngr *` | **Present** | **Present** | **Present** | **Present** |
| 12 | `cnge *` | **Present** | **Present** | **Present** | **Present** |
| 13 | `cngrgstno *` | **Present** | **Present** | **Present** | **Present** |
| 14 | `cngegstno *` | **Present** | Partially Present | **Present** | **Present** |
| 15 | `productcode` | Partially Present (HSN) | Partially Present | Partially Present | Partially Present (HSN 7005) |
| 16 | `packing` | **Present** | **Present** | **Present** | **Present** ("Boxes" / "Frames") |
| 17 | `pmark` (Seal No) | **Partially Present** (Header/Middle) | **Partially Present** (Stamp/Note) | **Partially Present** (Stamp/Photo) | Partially Present (Stencil/Seal) |
| 18 | `goods` | **Present** | **Present** | **Present** | **Present** ("Float Glass") |
| 19 | `Vehicle No *` | **Present** | **Present** | **Present** | **Present** |
| 20 | `Vehicle Type *` | **Present** ("Market") | **Present** ("Market") | **Present** ("Market" / Container) | **Present** ("Market") |
| 21 | `Driver Name *` | Partially Present (DL only) | Partially Present (DL only) | Partially Present (DL only) | Partially Present (DL only) |
| 22 | `Mobile no   *` | Partially Present (Explicit only) | Partially Present (Explicit only) | Partially Present (Explicit only) | **Present** (On Tax Invoice) |
| 23 | `Liscense No *` | Partially Present (DL only) | Partially Present (DL only) | Partially Present (DL only) | Partially Present (DL only) |
| 24 | `Valid Up to *` | Partially Present (DL only) | Partially Present (DL only) | Partially Present (DL only) | Partially Present (DL only) |
| 25 | `Loading Start date *` | **Present** (grdt) | **Present** (grdt) | **Present** (grdt) | **Present** (grdt) |
| 26 | `freight  *` | **Absent** (0 - FTL) | **Absent** (0 - FTL 'xxxx') | **Absent** (0 - FTL) | **Absent** (0 - FTL) |
| 27 | `oamount` | Partially Present (Unloading note) | Partially Present (Unloading note) | Partially Present (Unloading note) | Partially Present (Unloading note) |
| 28 | `cgst` | **Absent** (0.00 - FTL) | **Absent** (0.00 - 'xxxx') | **Absent** (0.00 - FTL) | **Absent** (0.00 - FTL) |
| 29 | `sgst` | **Absent** (0.00 - FTL) | **Absent** (0.00 - 'xxxx') | **Absent** (0.00 - FTL) | **Absent** (0.00 - FTL) |
| 30 | `igst` | **Absent** (0.00 - Manual) | **Absent** (0.00 - Manual) | **Absent** (0.00 - Manual) | **Absent** (0.00 - Manual) |
| 31 | `received` | **Absent** (0.00) | **Absent** (0.00 - 'xxxx') | **Absent** (0.00) | **Absent** (0.00) |
| 32 | `advance` | **Absent** (0.00) | **Absent** (0.00 - 'xxxx') | **Absent** (0.00) | **Absent** (0.00) |
| 33 | `collectionstncode` | **Present** (orgrefcode) | **Present** (orgrefcode) | **Present** (orgrefcode) | **Present** (orgrefcode) |
| 34 | `ftl` | **Present** ("FTL") | **Present** ("FTL") | **Present** ("FTL") | **Present** ("FTL") |
| 35 | `pckgs` | **Present** | **Present** | **Present** | **Present** |
| 36 | `Order Weight` | **Absent** ("") | **Absent** ("") | **Absent** ("") | **Absent** ("") |
| 37 | `aweight` | **Present** | **Present** | **Present** | **Present** (MT to KG: 29460) |
| 38 | `cweight` | **Present** | **Present** | **Present** | **Present** (MT to KG: 29460) |
| 39 | `Contract wt` | **Absent** ("") | **Absent** ("") | **Absent** ("") | **Absent** ("") |
| 40 | `Extra Mt` | **Absent** ("") | **Absent** ("") | **Absent** ("") | **Absent** ("") |
| 41 | `custrefcode` | Partially Present | **Present** ("BL653" / "BL652") | Partially Present | Partially Present |
| 42 | `staxpaidby` | **Present** ("C") | **Present** ("C") | **Present** ("C") | **Present** ("C") |
| 43 | `dlvtype` | **Present** ("D") | **Present** ("D" / "G") | **Present** ("D") | **Present** ("D") |
| 44 | `ewaybillno` | **Present** (12 digits) | **Present** (12 digits) | **Present** (12 digits) | **Present** (12 digits) |
| 45 | `Valid Upto` | **Present** (DD/MM/YYYY) | Partially Present (Needs E-Way) | **Present** (DD/MM/YYYY) | **Present** (DD/MM/YYYY) |
| 46 | `invoiceno` | **Present** | **Present** | **Present** | **Present** |
| 47 | `invoiedt` | **Present** | **Present** | **Present** | **Present** |
| 48 | `valgoods` | **Present** (Total Value) | **Present** (Declared Value) | **Present** (Invoice Value) | **Present** (Invoice Value) |
| 49 | `viaborder` | **Absent** ("") | **Absent** ("") | **Absent** ("") | **Absent** ("") |

---

## 2. Customer Specific Formats

```
================================================================================
                                UNICHARM
================================================================================
```

### unicharm (company name)
* **Company Legal Entity**: `UNICHARM INDIA PVT. LTD.`
* **Aliases / OCR Spelling Variations**: `Unicharm`, `Vuicharm`, `Uvicharm`, `Micharm`
* **Sample Files Directory**: [`docs/Vuicharm/`](file:///C:/Users/DELL/OCR_project/ocr_to_excel/ocr_to_excel/docs/Vuicharm) (e.g., `29356.pdf`, `32298.pdf`, `33306.pdf`, `32550.pdf`)
* **Typical Document Packet**: Multi-page packet comprising:
  1. Box N Freight Consignment Note (Bilty).
  2. Unicharm Commercial Tax Invoice (e.g., `10906I26-001898`).
  3. GST E-Way Bill (12-digit number with validity).
  4. mParivahan Vehicle RC Status / Truck Photo.
  5. Commercial Driving Licence (DL) / Driver photo (when attached).

#### 1. Present
* **`grno (*)` / `LR No *`**: Primary Consignment / LR Tracking Number. Printed 5-digit number in the 'CONSIGNMENT NOTE: No.' box at top right of the Box N Freight bilty (e.g., `32298`, `32299`, `32300`, `33306`), or verified against the 'Transporter LR No' on the Unicharm Tax Invoice / E-Way Bill Part B.
* **`grdt *` / `stockdt`**: Consignment booking date in 'Date' box (strictly formatted as `DD/MM/YYYY`, e.g., `27/09/2026`).
* **`Customer Name *`**: Corporate billed entity: `"UNICHARM INDIA PVT. LTD."`.
* **`cngr *`**: Consignor Name & Address from bilty or Tax Invoice (e.g., `"UNICHARM INDIA PVT. LTD., Village Mau, Tehsil Pataudi, District Gurugram, Haryana - 122414"` or `"UNICHARM INDIA PVT. LTD., Sanand, Gujarat"`).
* **`cngrgstno *`**: Consignor 15-character GSTIN from Tax Invoice or E-Way Bill (e.g., `"06AABCU0113A2ZA"`).
* **`cnge *`**: Consignee Name & Address from bilty or Tax Invoice (e.g., `"GLOBAL MARKETING-MT, Khasra No. 240, Hamidpur Narela Village, New Delhi - 110036"` or `"GLOBAL MARKETING, Ambala"`).
* **`cngegstno *`**: Consignee 15-character GSTIN from Tax Invoice or E-Way Bill (e.g., `"07AJYPK4522G1ZX"`).
* **`orgrefcode` / `collectionstncode`**: Origin station / city from 'From' box on bilty or E-Way Bill dispatch place (e.g., `"MAU"`, `"GURGAON"`, `"SANAND"`).
* **`destrefcode`**: Destination station / city from 'To' box on bilty or E-Way Bill delivery place (e.g., `"DELHI"`, `"SOUTH DELHI"`, `"AMBALA"`).
* **`pckgs` (bookedpckgs / stockpckgs)**: Package count from Tax Invoice 'Total Cases' or bilty 'No. of Packages' (e.g., `1375`, `2064`, `1251`, `797`).
* **`packing`**: Packaging type (`"Cases"`, `"Carton box"`, `"Box"`).
* **`goods`**: Commodity description from Tax Invoice (e.g., `"Baby Diapers"`, `"MPP All Night Absorb COCO L40"`, `"Sofy Bodyfit Pro XL 6P"`). *Rule: Seal numbers or invoice numbers must never be included inside the goods description.*
* **`aweight` (bookedaweight / stockaweight)**: Actual gross weight in KG from Tax Invoice or bilty.
* **`cweight` (bookedcweight / stockcweight)**: Charged weight in KG from bilty or Tax Invoice.
* **`invoiceno`**: Commercial invoice number from Tax Invoice (e.g., `10906I26-001898`, `10906F26-001407`, `10906I26-001909`, `3324726-000484`).
* **`invoiedt`**: Commercial invoice date from Tax Invoice (`DD/MM/YYYY`).
* **`valgoods`**: Total declared invoice value of goods from Tax Invoice (numbers only, e.g., `2112307.00`, `2817236.00`).
* **`ewaybillno`**: 12-digit GST E-Way Bill number from E-Way Bill page (e.g., `362343603918`, `372343679800`, `392344317558`).
* **`Valid Upto`**: E-Way Bill validity expiry date (`DD/MM/YYYY`, e.g., `28/09/2026`).
* **`Transit Days`**: Calculated integer difference between `grdt *` and `Valid Upto`.
* **`Vehicle No *`**: Indian motor vehicle registration plate from bilty 'Tempo/Truck No.', mParivahan RC status, or truck photo (e.g., `HR55AX5490`, `HR55AT7593`, `RJ18GB7132`, `NL01AFS826`).
* **`Vehicle Type *`**: Vehicle body type (`"Market"` or `"32 FT CONTAINER"`).
* **`Loading Start date *`**: Dispatch or loading date (matches `grdt *`).
* **`ftl`**: Vehicle container/service type: `"FTL"` (Dedicated 32 FT container).
* **`staxpaidby`**: GST on freight paying party: `"C"` (Consignor).
* **`dlvtype`**: Delivery type: `"D"` (Door Delivery).
* **`grtype`**: Payment terms from bilty: `"TBB"` (To Be Billed).

#### 2. partially Present
* **`pmark` (Container / Transit Seal Number)**:
  * **Top Header / Margin (e.g., `32298.pdf`, `32299.pdf`)**: Handwritten at top right near header/logo (e.g., `Seal. No- 03386`, `Seal No - 03330`). Pure digits extracted (`03386`).
  * **Middle of LR / Description Table (e.g., `33306.pdf`)**: Handwritten or stamped in the middle of 'Description (Said to Contain)' goods area (e.g., `Seal no: 002765`). Pure digits extracted (`002765`). Must NEVER be confused with LR No or kept inside `goods`.
  * **Absent / Unsealed**: If no physical container seal was applied, returns strictly empty string `""`.
* **`Driver Name *`**: Driver full legal name. Extracted ONLY if an official Commercial Driving Licence (DL) is attached in the multi-page dossier (e.g., `"OM PRAKASH"`, `"JITENDRA JHA"`). If no DL is attached, preserved strictly as empty string `""` for manual entry.
* **`Mobile no   *`**: Driver 10-digit mobile number. Extracted ONLY if explicitly written for the driver. If absent, left strictly as `""`. Consignor/shipper contact numbers are never auto-filled.
* **`Liscense No *`**: Commercial driving licence number from attached DL card (e.g., `"UP33 20170006650"`). If not attached, left strictly as `""`.
* **`Valid Up to *`**: Transport validity expiry date on attached DL card (`"TR"` validity date, strictly `DD/MM/YYYY`, e.g., `"27/03/2027"`). If not attached, left strictly as `""`.
* **`productcode`**: Product / HSN code from Tax Invoice (e.g., `"96190030"`). Left empty `""` if not itemized.
* **`custrefcode`**: Customer account reference code (e.g., `"UNICHARM"` or party code). Left empty `""` if omitted.
* **`Depatment Name`**: Designated warehouse department name (e.g., `"GLOBAL-BANGLORE"`, `"GLOBAL MARKETING-MT"`). Left empty `""` if not specifically designated.
* **`branchrefcode` / `Counter name`**: Hub center code (e.g., `"GURGAON"`, `"DELHI"`, `"SANAND"`) if specified in bilty header.
* **`oamount`**: Other charges (unloading, hamali, detention). Extract numeric value ONLY if explicitly written in the bilty or notes (e.g. 1000.00). If absent or FTL without extra charges, return strictly 0.00. NEVER copy valgoods into oamount.

#### 3. absent
* **`BNF LR No`**: Permanently removed / discontinued from Excel schema. Never extracted.
* **`freight  *`**: Full Truck Load (FTL) contract billed centrally -> strictly `0`.
* **`cgst`**: Freight tax -> strictly `0.00`.
* **`sgst`**: Freight tax -> strictly `0.00`.
* **`igst`**: Always output `0.00` (or `0`) for manual entry compliance.
* **`received`**: Freight received amount at booking -> strictly `0.00`.
* **`advance`**: Driver cash advance on bilty face -> strictly `0.00`.
* **`Order Weight`**: Specific industrial contract weight -> strictly empty string `""`.
* **`Contract wt`**: Contract weight -> strictly empty string `""`.
* **`Extra Mt`**: Extra metric tons -> strictly empty string `""`.
* **`viaborder`**: Transit border checkpost -> strictly empty string `""`.

---

```
================================================================================
                                PATANJALI
================================================================================
```

### patanjali (company name)
* **Company Legal Entity**: `PATANJALI FOODS LIMITED` (formerly Ruchi Soya Industries Limited) & `PATANJALI PARIVAHAN PVT. LTD.`
* **Aliases / OCR Spelling Variations**: `Patanjali`, `Patajali`, `PFL`, `RSIL`, `Patanjali Parivahan`
* **Sample Files Directory**: [`docs/Patajali/`](file:///C:/Users/DELL/OCR_project/ocr_to_excel/ocr_to_excel/docs/Patajali) (e.g., `PDF Gallery_20261001_210749.pdf`, `PDF Gallery_20261010_005415.pdf`, `WhatsApp Image 2026-10-07...`)
* **Typical Document Packet**:
  1. Standalone White Computer-Generated Bilty issued by Patanjali Parivahan Pvt. Ltd. (Transport Contractor).
  2. Multi-page dossier with Form 23A Vehicle RC, Commercial Driving Licence (DL), and White Printed Consignment Note.

#### 1. Present
* **`grdt *` / `stockdt`**: Consignment booking date printed in 'Bkg. Date' box (strictly `DD/MM/YYYY`, e.g., `05/02/2026`, `09/10/2026`).
* **`Customer Name *`**: Corporate billed entity printed under 'Billing Party' (e.g., `"PATANJALI FOODS LTD (OIL & SOYA) (Formerly RSIL)"`, `"PATANJALI FOODS LTD BISCUIT (Formerly RSIL)"`).
* **`custrefcode`**: Billing customer/party code printed before party name (e.g., `"BL653"`, `"BL652"`, or default `"CM001"`).
* **`branchrefcode`**: Center or branch code printed above 'CONSIGNMENT NOTE' title (e.g., `"INDORE"`, `"KOLKATA"`).
* **`Counter name`**: Booking counter or center (matches `branchrefcode`).
* **`orgrefcode` / `collectionstncode`**: Origin station / city printed in 'From City' box (e.g., `"INDORE"`, `"KARNPURA SSRM"`).
* **`destrefcode`**: Destination station / city printed in 'To City' box (e.g., `"BANGALORE"`, `"VARANASI"`, `"SUGAULI"`).
* **`cngr *`**: Consignor name and full street address printed in 'CONSIGNOR' box (e.g., `"PFL20 : PATANJALI FOODS LTD - INDORE, TALAWALI CHANDA OPP MANGALIYAGAON RLY STATION INDUSTRIAL AREA A.B. ROAD INDORE, 453771"`).
* **`cngrgstno *`**: Consignor 15-character GSTIN printed in header block (e.g., `"05AAFCF1505P1ZD"`).
* **`cnge *`**: Consignee name and destination address printed in 'CONSIGNEE' box (e.g., `"8888 : PATANJALI FOODS LIMITED, Maruthi Main Road nearby Sridhara Srigud Kengeri Satellite Town, BANGALORE, 560060"`).
* **`pckgs` (bookedpckgs / stockpckgs)**: Package count printed under 'No. of Package' or 'Total Charged No of Packages' (e.g., `410`, `419`, `845`).
* **`packing`**: Packaging type printed under 'Packaging Type' (e.g., `"BAG"`, `"Carton box"`).
* **`goods`**: Commodity description printed under 'Said to Contain' (e.g., `"SOYABADI"`, `"BISCUITS"`).
* **`aweight` (bookedaweight / stockaweight)**: Actual gross weight in KG printed under 'Actual Wt(Kgs)' (e.g., `7500`, `6567`).
* **`cweight` (bookedcweight / stockcweight)**: Charged weight in KG printed under 'Total Charged Weight' (e.g., `7500`, `7000`).
* **`invoiceno`**: Commercial invoice number printed under 'Invoice No.' in INVOICE DETAILS table (e.g., `8501817437`, `8501817324`, `8604510455`).
* **`invoiedt`**: Commercial invoice date printed under 'Inv. Date' (`DD/MM/YYYY`).
* **`valgoods`**: Declared invoice value of goods printed under 'Declared Value' without commas (e.g., `476204`, `519158`, `725770`).
* **`ewaybillno`**: 12-digit GST E-Way Bill number printed under 'Eway Bill No' (e.g., `612053161654`, `652051661257`, `811752253963`).
* **`Vehicle No *`**: Indian truck registration plate printed in 'Vehicle Number' header box or attached RC Form 23A (e.g., `RJ32GC5386`, `UP21FT4643`, `BR03K4305`).
* **`Vehicle Type *`**: Vehicle body type (`"Market"`).
* **`Loading Start date *`**: Dispatch / loading date (matches `grdt *`).
* **`grtype`**: Payment terms printed under 'Payment Type' (`"TBB"`).
* **`ftl`**: Vehicle load type: `"FTL"` (Full Truck Load).
* **`staxpaidby`**: Service tax / GST paying party: `"C"` (Consignor).
* **`dlvtype`**: Delivery type: `"D"` (Door Delivery) or `"G"` (Godown).

#### 2. partially Present
* **`grno (*)` / `LR No *` (Strict Pen/Pencil Outer Margin Rule)**:
  * **Present**: If an independent 5-digit number is written by hand with a pen or pencil in the **top-left** or **top-right** outer margins outside the printed borders (e.g., `21349`, `21348`), extract it as the primary `LR No *`.
  * **Strictly 0 / Blank**: If NOTHING is written with a pencil or pen in the outer margins, mark it strictly as **`0` (or `""`)**.
  * *Critical Rule: DO NOT fall back to the printed 7-digit 'C Note No.' (e.g., `9325388`, `9421832`) — this is an internal Patanjali SAP/ERP number, NOT the LR number.*
  * *Critical Rule: NEVER copy the vehicle plate into the LR number.*
* **`pmark` (Seal Number / Private Mark)**: Extracted ONLY if an explicit container seal code is written/stamped (e.g., `CJ007567`). If only generic notes appear (e.g., 'all seal ok') or no seal code is stamped, left strictly as empty string `""`.
* **`Driver Name *`**: Driver full name. Extracted ONLY if an official Commercial Driving Licence (DL) is attached in the multi-page dossier (e.g., `"MANOJ SINGH"`). If no DL is attached, left strictly as empty string `""` for manual entry.
* **`Mobile no   *`**: Driver 10-digit mobile number. Extracted ONLY if explicitly written for the driver. Consignor telephone (`8209435149`) or dummy numbers (`9999999999`) are strictly ignored.
* **`Liscense No *`**: Commercial driving licence number from attached DL card (e.g., `"BR44 20110036047"`). If absent, left strictly as `""`.
* **`Valid Up to *`**: Transport validity expiry date on attached DL card (`DD/MM/YYYY`, e.g., `"10/02/2027"`). If absent, left strictly as `""`.
* **`cngegstno *`**: Consignee 15-character GSTIN (often present; left empty `""` if local un-registered depot).
* **`Depatment Name`**: Destination depot name if printed in Consignee block (e.g., `"Depot Popular -Varanasi"`). Left empty `""` if absent.
* **`Valid Upto`**: E-Way Bill validity expiry date from attached E-Way Bill page (`DD/MM/YYYY`). Left empty `""` if E-Way page absent.
* **`Transit Days`**: Integer difference between `grdt *` and `Valid Upto`. Left empty `""` if E-Way bill date absent.
* **`oamount`**: Other charges (unloading, hamali, detention). If handwritten receiver notes at bottom specify an unloading charge (e.g., 'Unloading charge 1000/-'), capture numeric 1000. If absent or FTL without extra charges, return strictly 0.00. NEVER copy valgoods into oamount.
* **`productcode`**: Product code if itemized; otherwise empty string `""`.

#### 3. absent
* **`BNF LR No`**: Permanently removed / discontinued from schema.
* **`freight  *`**: Printed as `'xxxx'` across all rows on bilty face (FTL TBB contract) -> strictly `0`.
* **`cgst`**: Printed as `'xxxx'` -> strictly `0.00`.
* **`sgst`**: Printed as `'xxxx'` -> strictly `0.00`.
* **`igst`**: Always output `0.00` (or `0`) for manual entry compliance.
* **`received`**: Printed as `'xxxx'` -> strictly `0.00`.
* **`advance`**: Printed as `'xxxx'` -> strictly `0.00`.
* **`Order Weight`**: Not recorded on Patanjali bilties -> strictly empty string `""`.
* **`Contract wt`**: Not recorded -> strictly empty string `""`.
* **`Extra Mt`**: Not recorded -> strictly empty string `""`.
* **`viaborder`**: Border transit checkpoint -> strictly empty string `""`.

---

```
================================================================================
                                HIMALAYA
================================================================================
```

### himalaya (company name)
* **Company Legal Entity**: `Himalaya Wellness Company`
* **Aliases / OCR Spelling Variations**: `Himalaya`, `Himalaya Baby Care`, `HIM`
* **Sample Files Directory**: [`docs/himalaya/`](file:///C:/Users/DELL/OCR_project/ocr_to_excel/ocr_to_excel/docs/himalaya) (e.g., `DocScanner Sep 26, 2026 1-55 PM.pdf`, `HR74C1091 LR no 32752 ambala.pdf`, `RJ14GK0196 LR no 32754 ambala.pdf`)
* **Typical Document Packet**:
  1. Single-Page Standalone BNF Bilty (e.g., `33118.pdf`, `33119.pdf`).
  2. Multi-Page Compliance Dossier (up to 12 pages: BNF Consignment Note, GST E-Way Bill, Himalaya Tax Invoice, RC Form 23A, Commercial DL, Driver PAN, Physical Bottle Seal Lock Photograph).

#### 1. Present
* **`grno (*)` / `LR No *`**: Primary Consignment / LR Tracking Number. Bold printed 5-digit number in the 'CONSIGNMENT NOTE: No.' box at top right (e.g., `32752`, `32754`, `32760`, `32978`, `33118`). *Rule: Never confuse the vehicle registration number (e.g., `TG08U9828`) with the Consignment Note number.*
* **`grdt *` / `stockdt`**: Consignment booking date written in 'Date' box (strictly `DD/MM/YYYY`, e.g., `12/10/2026`).
* **`Customer Name *`**: Primary billed corporate account: `"Himalaya Wellness Company"`.
* **`cngr *`**: Full Consignor Name & street address from 'Consignor's Name & Address' box or attached Tax Invoice/E-Way Bill (e.g., Makali Bangalore central warehouse).
* **`cngrgstno *`**: Consignor 15-character GSTIN (e.g., `"29AADFT3025B2ZK"` for Makali Bangalore).
* **`cnge *`**: Full Consignee Name & destination address from 'Consignee's Name & Address' box or E-Way Bill (e.g., Indore CFA, Kolkata CFA).
* **`cngegstno *`**: Consignee 15-character GSTIN (e.g., `"23AADFT3025B1ZX"` for Indore, `"19AADFT3025B1ZM"` for Kolkata).
* **`orgrefcode` / `collectionstncode`**: Origin station / city written in 'From' box (e.g., `"Bangalore (MWH)"`, `"Prithampur"`, `"Jalgaon"`).
* **`destrefcode`**: Destination station / city written in 'To' box (e.g., `"Indore (MWH)"`, `"Kolkata (MWH)"`, `"Bangalore"`).
* **`pckgs` (bookedpckgs / stockpckgs)**: Package count under 'No. of Packages' (e.g., `2812`, `2750`, `650`).
* **`packing`**: Packaging format (`"Box"`, `"Cartons"`, `"Barrels"`).
* **`goods`**: Nature of commodity (`"AYURVEDIC MEDICINES & BABY CARE PRODUCTS"`).
* **`aweight` (bookedaweight / stockaweight)**: Actual gross cargo weight in KG. (If specified as "15 mt" on bilty face -> convert to `15000`; if attached Tax Invoice specifies Gross Weight, record exact kilograms, e.g., `14979`).
* **`cweight` (bookedcweight / stockcweight)**: Charged weight in KG.
* **`invoiceno`**: Commercial shipper invoice number (e.g., `5526701832`, `5526701889`, `MPR 2627/BOS01035`).
* **`invoiedt`**: Commercial invoice date (`DD/MM/YYYY`).
* **`valgoods`**: Declared invoice value of goods in INR (numeric without commas, e.g., `11488522.00`, `7646623.00`, `1127490.00`).
* **`ewaybillno`**: 12-digit GST E-Way Bill number from bilty or attached E-Way Bill (e.g., `102566549518`, `182574511673`).
* **`Valid Upto`**: E-Way Bill validity date from E-Way Bill header (`DD/MM/YYYY`).
* **`Transit Days`**: Calculated integer difference between `grdt *` and `Valid Upto`.
* **`Vehicle No *`**: Indian motor vehicle registration plate (e.g., `GJ05BZ0237`, `RJ14GT3819`, `MP09HH0830`, `DD01AJ9120`).
* **`Vehicle Type *`**: Vehicle body and container classification (e.g., `"32FT CONTAINER"`, `"22FT / 6 MT"`, `"32FT MXL"`, or default `"Market"`).
* **`Loading Start date *`**: Dispatch / loading date (matches `grdt *`).
* **`ftl`**: Vehicle load type: `"FTL"` (Full Truck Load).
* **`staxpaidby`**: Party paying GST on freight: `"C"` (Consignor).
* **`dlvtype`**: Delivery type: `"D"` (Door Delivery).
* **`grtype`**: Payment terms: `"TBB"` (To Be Billed).

#### 2. partially Present
* **`pmark` (Seal Number / Private Mark)**:
  * **Top Margin / Description Notes / Seal Photo**: Preceded by `Seal No`, `Seal No =`, or verified against the high-resolution container seal lock photograph on Page 11/12 (e.g., `00153`, `00105`, `CJ007567`).
  * Pure digits/code extracted (`00153`). Prefixes and labels (`Seal`, `No`, `=`) strictly stripped.
  * *Critical Rule: The seal number must NEVER be mapped into the LR number.*
  * If no physical seal is present, left strictly as empty string `""`.
* **`Driver Name *`**: Driver full legal name. Extracted ONLY if an official Commercial Driving Licence (DL) or PAN card is attached in the multi-page compliance dossier (e.g., `"JAYMANGAL RAI"`, `"AARIF"`). If no DL card is attached (e.g., single-page bilty uploads `33118`, `33119`), left strictly as empty string `""` for manual entry.
* **`Mobile no   *`**: Driver 10-digit phone number. Extracted ONLY if explicitly written for the driver. Left strictly as empty string `""` otherwise.
* **`Liscense No *`**: Commercial driving licence number from attached DL card (e.g., `"MH02 20040039639"`, `"RJ40 20210005214"`). Left strictly as `""` if not attached.
* **`Valid Up to *`**: Transport validity expiry date on attached DL card (`"TR"` validity date, `DD/MM/YYYY`, e.g., `"27/08/2030"`). Left strictly as `""` if not attached.
* **`oamount`**: Other charges (unloading, hamali, detention). If handwritten margin notes specify unloading charges (e.g., "Unloading charges RS. 4200./-", "unloading Charge = 1500/-"), capture numeric (4200 or 1500). If absent or FTL without extra charges, return strictly 0.00. NEVER copy valgoods into oamount.
* **`Depatment Name`**: Destination department name matched against [`docs/ManiFest.xlsx`](file:///C:/Users/DELL/OCR_project/ocr_to_excel/ocr_to_excel/docs/ManiFest.xlsx) (e.g., `"HIMALAYA-INDORE"`, `"HIMALAYA-KOLKATA"`, `"HIMALAYA-RAIPUR"`).
* **`custrefcode`**: Customer account reference code if specified.
* **`productcode`**: Product / HSN code if itemized in Tax Invoice.
* **`branchrefcode` / `Counter name`**: Booking hub or branch name if specified on bilty.

#### 3. absent
* **`BNF LR No`**: Permanently removed / discontinued from Excel schema. Never extracted.
* **`freight  *`**: Contracted under Full Truck Load (FTL) -> strictly `0` (unless spot rate noted).
* **`cgst`**: Freight tax under FTL / RCM -> strictly `0.00`.
* **`sgst`**: Freight tax under FTL / RCM -> strictly `0.00`.
* **`igst`**: Always output `0.00` (or `0`) for manual entry compliance.
* **`received`**: Spot cash received -> strictly `0.00`.
* **`advance`**: Cash advance on bilty face -> strictly `0.00`.
* **`stcharges`, `fuelcharges`, `handlingcharges`, `hamali`, `doorcharges`, `insurancecharges`**: Blank or `0.00` under FTL contract.
* **`Order Weight`**: Industrial contract field -> strictly empty string `""`.
* **`Contract wt`**: Not recorded -> strictly empty string `""`.
* **`Extra Mt`**: Not recorded -> strictly empty string `""`.
* **`viaborder`**: Border transit checkpoint -> strictly empty string `""`.

---

```
================================================================================
                               GOLD PLUS
================================================================================
```

### gold plus (company name)
* **Company Legal Entity**: `GOLD PLUS FLOAT GLASS PRIVATE LIMITED`
* **Department in ManiFest**: `GOLD PLUS-BELGUAM` (Belagavi / Hukkeri, Karnataka, GST: `29AAICG7897C1Z1`, Dept ID: 5)
* **Aliases / OCR Spelling Variations**: `Gold Plus`, `Gold Plus Glass`, `Gold Plus Float Glass Pvt. Ltd.`
* **Sample Files Directory**: [`docs/Gold_plus/`](file:///C:/Users/DELL/OCR_project/ocr_to_excel/ocr_to_excel/docs/Gold_plus) (e.g., `..._LR_31745_KA25AB-2955.pdf`, `..._LR_31746_KA22D-0257.pdf`, `..._LR_31744_...pdf`, `..._31878.pdf`)
* **Typical Document Packet**: 6-page comprehensive compliance dossier:
  1. Box N Freight Consignment Note (Bilty) — Bold printed 5-digit LR number (`31745`, `31746`).
  2. Returnable Gate Pass (Out) — Gate Pass No (`24347`), vehicle plate, frame description.
  3. Official Tax Invoice (Duplicate for Transporter) — Itemized clear glass products, driver phone (`7338673806`).
  4. Official Tax Invoice (Original for Buyer) — Full tax and GST breakdown.
  5. GST E-Way Bill — 12-digit number (`132567309121`), distance, validity date.
  6. Weighment Slip (Weighbridge Receipt) — Gross, Tare, and Net Weight (`29.460 MT` = `29,460 KG`).

#### 1. Present
* **`grno (*)` / `LR No *`**: Primary Consignment / LR Tracking Number. Bold printed 5-digit number in 'CONSIGNMENT NOTE: No.' box at top right of the Box N Freight bilty (e.g., `31745`, `31746`, `31744`, `31878`), cross-verified against 'LR No' on Tax Invoice.
* **`grdt *` / `stockdt`**: Consignment booking date printed in 'Date' box (strictly formatted as `DD/MM/YYYY`, e.g., `01/10/2026`).
* **`Customer Name *`**: Corporate billed entity: `"GOLD PLUS FLOAT GLASS PRIVATE LIMITED"`.
* **`cngr *`**: Full Consignor Name & Address: `"M/S. GOLD PLUS FLOAT GLASS PVT. LTD., Road No. 10-14, Kanagala Industrial Area Kiadb, Tal. Hukkeri, Dist. Belagavi, Karnataka - 591225"`.
* **`cngrgstno *`**: Consignor 15-character GSTIN: `"29AAICG7897C1Z1"`.
* **`cnge *`**: Full Consignee Name & destination address from bilty or Tax Invoice (e.g., `"M/S. FORTUNE SAFETY GLASS, Udupi, Karnataka"`).
* **`cngegstno *`**: Consignee 15-character GSTIN (e.g., `"29AAFFF7172H1Z5"`).
* **`orgrefcode` / `collectionstncode`**: Origin station / city from 'From' box on bilty: `"Kanagal"` (or `"Belgaum"` / `"Belagavi"`).
* **`destrefcode`**: Destination station / city from 'To' box on bilty: `"Udupi"` (or `"Mangalore"`, `"Bangalore"`).
* **`pckgs` (bookedpckgs / stockpckgs)**: Package count under 'No. of Packages' (e.g., `12`).
* **`packing`**: Packaging format: `"Boxes"`, `"Frames"`.
* **`goods`**: Commodity description: `"Float Glass"`, `"Clear Float Glass"`.
* **`aweight` (bookedaweight / stockaweight)**: Actual cargo gross weight in KG. Bilty specifies Metric Tons (e.g., `29.460 MT`), converted to exact kilograms: `29460`. Cross-verified against Weighment Slip Net Weight.
* **`cweight` (bookedcweight / stockcweight)**: Charged weight in KG (matches actual weight `29460`).
* **`invoiceno`**: Commercial invoice number from bilty or Tax Invoice (e.g., `26271010344` or `262710344`).
* **`invoiedt`**: Commercial invoice date from Tax Invoice (`DD/MM/YYYY`, e.g., `01/10/2026`).
* **`valgoods`**: Declared invoice value / Total invoice amount without commas (e.g., `1285094.81`).
* **`ewaybillno`**: 12-digit GST E-Way Bill number from bilty or E-Way Bill page (e.g., `132567309121`).
* **`Valid Upto`**: E-Way Bill validity expiry date from E-Way Bill header (`DD/MM/YYYY`, e.g., `04/10/2026`).
* **`Transit Days`**: Calculated integer difference between booking date (`01/10/2026`) and E-Way validity (`04/10/2026`) = `3`.
* **`Vehicle No *`**: Indian motor vehicle registration plate from bilty, Gate Pass, or Weighment Slip (e.g., `KA25AB2955`, `KA22D0257`, `KA23A5937`).
* **`Vehicle Type *`**: Vehicle body type: `"Market"`.
* **`Loading Start date *`**: Booking date (matches `grdt *`).
* **`ftl`**: Vehicle load type: `"FTL"` (Full Truck Load).
* **`staxpaidby`**: Party paying GST on freight: `"C"` (Consignor).
* **`dlvtype`**: Delivery type: `"D"` (Door Delivery).
* **`grtype`**: Payment terms: `"TBB"` (To Be Billed).

#### 2. partially Present
* **`Mobile no   *` (Driver Phone Number)**:
  * Uniquely in Gold Plus dossiers, the driver's phone number is explicitly printed on the Tax Invoice header under 'Driver No:' (e.g., `7338673806`).
  * If printed on Tax Invoice or bilty, captured as `Mobile no   *`. If absent, left strictly as `""`.
* **`pmark` (Private Mark / Seal Number)**:
  * If a container seal number or stencil mark is written/stamped on bilty, captured into `pmark`. If no seal is used, left strictly as `""`.
* **`Driver Name *`**: Driver full name. Captured ONLY if an official Driving Licence (DL) is attached or driver signature/name is written; otherwise strictly `""`.
* **`Liscense No *` & `Valid Up to *`**: Commercial driving licence details. Captured ONLY from attached DL card; otherwise strictly empty strings `""`.
* **`Depatment Name`**: Matched against `docs/ManiFest.xlsx` (`"GOLD PLUS-BELGUAM"`).
* **`branchrefcode` / `Counter name`**: Hub center name (e.g. `"BEL"` / `"BELGAUM"`) if printed on bilty header.
* **`custrefcode`**: Customer account code (e.g. `"GOLDPLUS"` or party code) if printed.
* **`productcode`**: Product / HSN code if itemized (e.g., HSN 7005 for float glass).
* **`oamount`**: Other charges (unloading, hamali, detention). Extract numeric value ONLY if explicitly written; if absent or FTL without extra charges, return strictly 0.00. NEVER copy valgoods into oamount.

#### 3. absent
* **`BNF LR No`**: Permanently removed from schema. Never extracted.
* **`freight  *`**: Full Truck Load (FTL) contract billed centrally -> strictly `0`.
* **`cgst`, `sgst`, `igst`**: Freight tax under FTL / RCM -> strictly `0.00`.
* **`received`, `advance`**: Cash received/advanced at booking -> strictly `0.00`.
* **`stcharges`, `fuelcharges`, `handlingcharges`, `hamali`, `doorcharges`, `insurancecharges`**: Blank or `0.00` under FTL.
* **`Order Weight`, `Contract wt`, `Extra Mt`**: Inapplicable -> strictly empty string `""`.
* **`viaborder`**: Border transit checkpoint -> strictly empty string `""`.

---

```
================================================================================
                    GENERIC / OTHER CLIENTS (MANI-FEST)
================================================================================
```

### generic / other clients (company name)
* **Company Legal Entities**: `Global Marketing`, `Monte Carlo Fashions Ltd.`, `Vesco Cycle`, `UM Orthotics`, `Shree Ciment`, `Indra Hosiery Mills` (derived from [`docs/ManiFest.xlsx`](file:///C:/Users/DELL/OCR_project/ocr_to_excel/ocr_to_excel/docs/ManiFest.xlsx)).
* **Standard Consignment Document**: Standard Box N Freight (BNF) printed consignment note (White or Yellow/Orange).

#### 1. Present
* **`grno (*)` / `LR No *`**: Primary Consignment Note number printed in the 'CONSIGNMENT NOTE: No.' box at top right.
* **`grdt *` / `stockdt`**: Booking date in 'Date' box (`DD/MM/YYYY`).
* **`Customer Name *`**: Corporate customer name as matched against `ManiFest.xlsx`.
* **`cngr *`**: Consignor Name & Address from 'Consignor's Name & Address' box.
* **`cnge *`**: Consignee Name & Address from 'Consignee's Name & Address' box.
* **`orgrefcode` / `collectionstncode`**: Origin station / city in 'From' box.
* **`destrefcode`**: Destination station / city in 'To' box.
* **`pckgs` (bookedpckgs / stockpckgs)**: Number of packages under 'No. of Packages'.
* **`packing`**: Packaging unit (`"Boxes"`, `"Cartons"`, `"Bales"`).
* **`goods`**: Description of goods under 'Description (Said to Contain)'.
* **`aweight` / `cweight`**: Actual and charged weights in KG from Weight box.
* **`Vehicle No *`**: Registration plate written under 'Tempo/Truck No.'.
* **`Vehicle Type *`**: Vehicle body type (defaults to `"Market"`).
* **`Loading Start date *`**: Booking date (matches `grdt *`).
* **`ftl`**: Load type (`"FTL"` or `"LTL"` / `"Part Load"`).
* **`staxpaidby`**: Party paying GST (`"C"`, `"E"`, or `"T"`).
* **`dlvtype`**: Delivery type (`"D"` for Door Delivery, `"G"` for Godown).
* **`grtype`**: Payment term (`"TBB"`, `"PAID"`, or `"TO PAY"`).

#### 2. partially Present
* **`cngrgstno *` / `cngegstno *`**: 15-character GST numbers if printed or matched via `ManiFest.xlsx`.
* **`invoiceno` / `invoiedt`**: Invoice number and date if written on bilty face (`INVO =`, `Inv No`).
* **`valgoods`**: Declared value of goods if written in value box.
* **`ewaybillno` / `Valid Upto`**: E-Way Bill number and expiry if written on bilty or attached.
* **`Transit Days`**: Calculated difference if E-Way validity date is present.
* **`pmark`**: Container seal or stencil mark if written/stamped.
* **`Driver Name *` / `Mobile no   *` / `Liscense No *` / `Valid Up to *`**: Captured ONLY if explicitly written on bilty or attached credentials; otherwise strictly empty strings `""`.
* **`freight  *`**: Captured if numeric freight is specified; `0` if FTL contract.
* **`oamount`**: Other charges if specified.
* **`custrefcode`**: Party code if printed.
* **`Depatment Name`**: Department name from `ManiFest.xlsx` if matched.
* **`branchrefcode` / `Counter name`**: Hub counter name if printed.

#### 3. absent
* **`BNF LR No`**: Permanently removed / discontinued from Excel schema.
* **`cgst` / `sgst` / `igst`**: Set to `0.00` (or `0`).
* **`received` / `advance`**: Set to `0.00` unless cash paid/advanced is explicitly written on bilty face.
* **`Order Weight` / `Contract wt` / `Extra Mt`**: Strictly empty string `""`.
* **`viaborder`**: Strictly empty string `""`.

---

## 3. Operational Rules & System Guardrails

1. **Strict Zero-Hallucination Policy**:
   * If any field is classified as **Absent** or is not visibly present on the document, it MUST remain strictly empty (`""`) or `0.00` / `0` as specified.
   * Auto-filling driver credentials from `driver_master.json` is disabled in the Gemini vision prompts so operators retain full manual verification control.

2. **Color-Based Orange/Yellow vs. White Bilty Rule**:
   * **Orange/Yellow Bilties**: Transport consignment notes with yellow/orange paper backgrounds represent standard BNF consignments. `BNF LR No` is completely deprecated and forced to blank.
   * **White Printed Consignment Notes (Patanjali / Unicharm / Gold Plus)**: Standard white computer-generated bilties. Follow specific customer margin rules.

3. **Multimodal 300 DPI Rendering**:
   * Multi-page PDFs are rendered at 300 DPI high-definition JPEG images prior to Gemini submission to ensure small rubber stamps, handwritten pencil notes, and container seal codes are clearly legible.
