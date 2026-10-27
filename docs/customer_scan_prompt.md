# Customer LR Scan Prompts & Extraction Guidelines
> **Master Production Reference (October 2026)** — Standardized multimodal document scanning and extraction prompts for Google Gemini Vision OCR across Box N Freight (BNF) logistics operations.
> Aligned with the **49-Column Standard BNF Format (`GR_BNF_49_HEADERS`)**.

---

## 1. Executive Summary & Prompt Architecture

When processing logistics consignment notes (bilties), commercial tax invoices, E-Way bills, and driver compliance packets, extraction behavior is organized by customer according to a strict 3-tier classification:

1. **`1. Present`**: Core data elements guaranteed or standardly printed on the customer's bilty face, commercial invoice, or E-Way bill. The OCR model is instructed to capture these with 100% fidelity.
2. **`2. partially Present`**: Conditional, handwritten, stamped, or secondary credentials that depend on optional dossier pages (e.g., Driving Licence cards, Vehicle RC status, container seal lock photos, or handwritten margin notes). Strict verification rules govern their capture, ensuring empty strings (`""`) when absent.
3. **`3. absent`**: Contractually excluded, zeroed-out, or deprecated fields (e.g., FTL freight charges printed as `'xxxx'`, spot cash collections, or the deprecated `BNF LR No`). The model is strictly instructed to return `0`, `0.00`, or empty string `""` without hallucinating fake values.

---

## 2. Customer Specific Formats & Prompts

```
================================================================================
                                UNICHARM
================================================================================
```

### unicharm (company name)
* **Company Legal Entity**: `UNICHARM INDIA PVT. LTD.`
* **Aliases / OCR Recognitions**: `Unicharm`, `Vuicharm`, `Uvicharm`, `Micharm`
* **Dossier Pages**:
  - Page 1: Box N Freight Consignment Note (Bilty).
  - Page 2–4: Unicharm Commercial Tax Invoice (e.g., `10906I26-001898`).
  - Page 5: GST E-Way Bill (12-digit number with validity).
  - Page 6+: mParivahan Vehicle RC Status / Truck Photo / Commercial Driving Licence (DL).

#### 1. Present
* **`grno (*)` / `LR No *`**: Primary Consignment / LR Tracking Number. Bold printed 5-digit number in the 'CONSIGNMENT NOTE: No.' box at top right of the Box N Freight bilty (e.g., `32298`, `32299`, `32300`, `33306`), or verified against 'Transporter LR No' on the Unicharm Tax Invoice / E-Way Bill Part B.
* **`grdt *` / `stockdt`**: Consignment booking date in 'Date' box (strictly `DD/MM/YYYY`, e.g., `27/09/2026`).
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
* **`oamount`**: Other charges (unloading, hamali, detention). Extract numeric value ONLY if explicitly written; if absent, return strictly 0.00. NEVER copy valgoods into oamount.

#### 3. absent
* **`BNF LR No`**: Permanently removed / discontinued from Excel schema. Never extracted.
* **`freight  *`**: Full Truck Load (FTL) contract billed centrally $\rightarrow$ strictly `0`.
* **`cgst`**: Freight tax $\rightarrow$ strictly `0.00`.
* **`sgst`**: Freight tax $\rightarrow$ strictly `0.00`.
* **`igst`**: Always output `0.00` (or `0`) for manual entry compliance.
* **`received`**: Freight received amount at booking $\rightarrow$ strictly `0.00`.
* **`advance`**: Driver cash advance on bilty face $\rightarrow$ strictly `0.00`.
* **`Order Weight`**: Specific industrial contract weight $\rightarrow$ strictly empty string `""`.
* **`Contract wt`**: Contract weight $\rightarrow$ strictly empty string `""`.
* **`Extra Mt`**: Extra metric tons $\rightarrow$ strictly empty string `""`.
* **`viaborder`**: Transit border checkpost $\rightarrow$ strictly empty string `""`.

---

```
================================================================================
                                PATANJALI
================================================================================
```

### patanjali (company name)
* **Company Legal Entity**: `PATANJALI FOODS LIMITED` (formerly Ruchi Soya Industries Limited) & `PATANJALI PARIVAHAN PVT. LTD.`
* **Aliases / OCR Recognitions**: `Patanjali`, `Patajali`, `PFL`, `RSIL`, `Patanjali Parivahan`
* **Dossier Pages**:
  - Standalone White Computer-Generated Bilty issued by Patanjali Parivahan Pvt. Ltd. (Transport Contractor).
  - Multi-page dossier with Form 23A Vehicle RC, Commercial Driving Licence (DL), and White Printed Consignment Note.

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
* **`oamount`**: Other charges (unloading, hamali, detention). Extract numeric value ONLY if explicitly written in bilty or notes; if absent, return strictly 0.00. NEVER copy valgoods into oamount.
* **`productcode`**: Product code if itemized; otherwise empty string `""`.

#### 3. absent
* **`BNF LR No`**: Permanently removed / discontinued from schema.
* **`freight  *`**: Printed as `'xxxx'` across all rows on bilty face (FTL TBB contract) $\rightarrow$ strictly `0`.
* **`cgst`**: Printed as `'xxxx'` $\rightarrow$ strictly `0.00`.
* **`sgst`**: Printed as `'xxxx'` $\rightarrow$ strictly `0.00`.
* **`igst`**: Always output `0.00` (or `0`) for manual entry compliance.
* **`received`**: Printed as `'xxxx'` $\rightarrow$ strictly `0.00`.
* **`advance`**: Printed as `'xxxx'` $\rightarrow$ strictly `0.00`.
* **`Order Weight`**: Not recorded on Patanjali bilties $\rightarrow$ strictly empty string `""`.
* **`Contract wt`**: Not recorded $\rightarrow$ strictly empty string `""`.
* **`Extra Mt`**: Not recorded $\rightarrow$ strictly empty string `""`.
* **`viaborder`**: Border transit checkpoint $\rightarrow$ strictly empty string `""`.

---

```
================================================================================
                                HIMALAYA
================================================================================
```

### himalaya (company name)
* **Company Legal Entity**: `Himalaya Wellness Company`
* **Aliases / OCR Recognitions**: `Himalaya`, `Himalaya Baby Care`, `HIM`
* **Dossier Pages**:
  - Single-Page Standalone BNF Bilty (e.g., `33118.pdf`, `33119.pdf`).
  - Multi-Page Compliance Dossier (up to 12 pages: BNF Consignment Note, GST E-Way Bill, Himalaya Tax Invoice, RC Form 23A, Commercial DL, Driver PAN, Physical Bottle Seal Lock Photograph).

#### 1. Present
* **`grno (*)` / `LR No *`**: Primary Consignment / LR Tracking Number. Bold printed 5-digit number in the 'CONSIGNMENT NOTE: No.' box at top right (e.g., `32752`, `32754`, `32760`, `32978`, `33118`). *Rule: Never confuse the vehicle registration number (e.g., `TG08U9828`) with the Consignment Note number.*
* **`grdt *` / `stockdt`**: Consignment booking date written in 'Date' box (strictly `DD/MM/YYYY`, e.g., `12/10/2026`).
* **`Customer Name *`**: Primary billed corporate account: `"Himalaya Wellness Company"`.
* **`cngr *`**: Full Consignor Name & street address from 'Consignor\'s Name & Address' box or attached Tax Invoice/E-Way Bill (e.g., Makali Bangalore central warehouse).
* **`cngrgstno *`**: Consignor 15-character GSTIN (e.g., `"29AADFT3025B2ZK"` for Makali Bangalore).
* **`cnge *`**: Full Consignee Name & destination address from 'Consignee\'s Name & Address' box or E-Way Bill (e.g., Indore CFA, Kolkata CFA).
* **`cngegstno *`**: Consignee 15-character GSTIN (e.g., `"23AADFT3025B1ZX"` for Indore, `"19AADFT3025B1ZM"` for Kolkata).
* **`orgrefcode` / `collectionstncode`**: Origin station / city written in 'From' box (e.g., `"Bangalore (MWH)"`, `"Prithampur"`, `"Jalgaon"`).
* **`destrefcode`**: Destination station / city written in 'To' box (e.g., `"Indore (MWH)"`, `"Kolkata (MWH)"`, `"Bangalore"`).
* **`pckgs` (bookedpckgs / stockpckgs)**: Package count under 'No. of Packages' (e.g., `2812`, `2750`, `650`).
* **`packing`**: Packaging format (`"Box"`, `"Cartons"`, `"Barrels"`).
* **`goods`**: Nature of commodity (`"AYURVEDIC MEDICINES & BABY CARE PRODUCTS"`).
* **`aweight` (bookedaweight / stockaweight)**: Actual gross cargo weight in KG. (If specified as "15 mt" on bilty face $\rightarrow$ convert to `15000`; if attached Tax Invoice specifies Gross Weight, record exact kilograms, e.g., `14979`).
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
* **`oamount`**: Other charges (unloading, hamali, detention). If handwritten margin notes specify unloading charges, capture numeric; otherwise return strictly 0.00. NEVER copy valgoods into oamount.
* **`Depatment Name`**: Destination department name matched against [`docs/ManiFest.xlsx`](file:///C:/Users/DELL/OCR_project/ocr_to_excel/ocr_to_excel/docs/ManiFest.xlsx) (e.g., `"HIMALAYA-INDORE"`, `"HIMALAYA-KOLKATA"`, `"HIMALAYA-RAIPUR"`).
* **`custrefcode`**: Customer account reference code if specified.
* **`productcode`**: Product / HSN code if itemized in Tax Invoice.
* **`branchrefcode` / `Counter name`**: Booking hub or branch name if specified on bilty.

#### 3. absent
* **`BNF LR No`**: Permanently removed / discontinued from Excel schema. Never extracted.
* **`freight  *`**: Contracted under Full Truck Load (FTL) $\rightarrow$ strictly `0` (unless spot rate noted).
* **`cgst`**: Freight tax under FTL / RCM $\rightarrow$ strictly `0.00`.
* **`sgst`**: Freight tax under FTL / RCM $\rightarrow$ strictly `0.00`.
* **`igst`**: Always output `0.00` (or `0`) for manual entry compliance.
* **`received`**: Spot cash received $\rightarrow$ strictly `0.00`.
* **`advance`**: Cash advance on bilty face $\rightarrow$ strictly `0.00`.
* **`stcharges`, `fuelcharges`, `handlingcharges`, `hamali`, `doorcharges`, `insurancecharges`**: Blank or `0.00` under FTL contract.
* **`Order Weight`**: Industrial contract field $\rightarrow$ strictly empty string `""`.
* **`Contract wt`**: Not recorded $\rightarrow$ strictly empty string `""`.
* **`Extra Mt`**: Not recorded $\rightarrow$ strictly empty string `""`.
* **`viaborder`**: Border transit checkpoint $\rightarrow$ strictly empty string `""`.

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
* **`oamount`**: Other charges (unloading, hamali, detention). Extract numeric value ONLY if explicitly written; if absent, return strictly 0.00. NEVER copy valgoods into oamount.

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
* **Company Legal Entities**: `Global Marketing`, `Monte Carlo Fashions Ltd.`, `Vesco Cycle`, `UM Orthotics`, `Shree Ciment`, `Indra Hosiery Mills`, `Gold Plus Glass` (from [`docs/ManiFest.xlsx`](file:///C:/Users/DELL/OCR_project/ocr_to_excel/ocr_to_excel/docs/ManiFest.xlsx)).
* **Standard Consignment Document**: Standard Box N Freight (BNF) printed consignment note.

#### 1. Present
* **`grno (*)` / `LR No *`**: Primary Consignment Note number printed in 'CONSIGNMENT NOTE: No.' box at top right.
* **`grdt *` / `stockdt`**: Booking date in 'Date' box (`DD/MM/YYYY`).
* **`Customer Name *`**: Corporate customer name matched against `ManiFest.xlsx`.
* **`cngr *`**: Consignor Name & Address from 'Consignor\'s Name & Address' box.
* **`cnge *`**: Consignee Name & Address from 'Consignee\'s Name & Address' box.
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

## 3. Production Master OCR Prompt (Gemini Vision)

This master prompt is embedded in [`backend/main.py`](file:///C:/Users/DELL/OCR_project/ocr_to_excel/ocr_to_excel/backend/main.py) as `DEFAULT_HANDWRITTEN_OCR_PROMPT`. It performs automatic customer identification followed by specialized `1. Present`, `2. partially Present`, and `3. absent` extraction:

```text
You are an expert OCR and document information scraping engine specialized in reading transport bilties, consignment notes, tax invoices, E-Way bills, and vehicle/driver compliance packets for 'BOX N FREIGHT LOGISTICS SOLUTIONS PVT. LTD.' and its enterprise customers.

DOCUMENT & MULTI-PAGE DOSSIER INSTRUCTIONS:
This document may contain a single page (consignment note bilty) or a multi-page compliance dossier (including Consignment Note, Tax Invoice, E-Way Bill, Vehicle RC Form 23A, and Commercial Driving Licence DL).
Inspect ALL pages thoroughly and map the data strictly into the 49 target columns:

STEP 1: IDENTIFY THE CUSTOMER & DOCUMENT PROFILE
Visually inspect the document headers, logos, billing parties, and stamps to identify the company profile:
- UNICHARM PROFILE: If headers, invoices, or consignor/consignee mention 'UNICHARM INDIA PVT. LTD.', 'Vuicharm', 'Uvicharm', or 'GLOBAL MARKETING-MT'.
- PATANJALI PROFILE: If headers mention 'PATANJALI PARIVAHAN PVT. LTD.', 'PATANJALI FOODS LIMITED', 'Ruchi Soya', or show Patanjali C Note layouts.
- HIMALAYA PROFILE: If headers mention 'Himalaya Wellness Company' or 'Makali Bangalore'.
- GOLD PLUS PROFILE: If headers or tax invoices mention 'GOLD PLUS FLOAT GLASS PVT. LTD.' or 'Kanagala Belagavi'.
- GENERIC BNF PROFILE: Standard Box N Freight printed bilty or other client from the manifest.

STEP 2: APPLY CUSTOMER EXTRACTION RULES (1. Present, 2. partially Present, 3. absent)

A. UNICHARM RULES:
1. Present:
   - "grno" / "LR No *": Extract bold 5-digit number printed in 'CONSIGNMENT NOTE: No.' box at top right of Box N Freight bilty (e.g. 32298, 33306), or from Tax Invoice 'Transporter LR No'.
   - "Customer Name *": Corporate billed entity: "UNICHARM INDIA PVT. LTD.".
   - "cngr": "UNICHARM INDIA PVT. LTD., Village Mau, Tehsil Pataudi, District Gurugram, Haryana - 122414" (or Sanand, Gujarat).
   - "cngrgstno": "06AABCU0113A2ZA".
   - "cnge": "GLOBAL MARKETING-MT, Khasra No. 240, Hamidpur Narela Village, New Delhi - 110036" (or Ambala).
   - "cngegstno": "07AJYPK4522G1ZX".
   - "orgrefcode": "MAU", "GURGAON", or "SANAND". "destrefcode": "DELHI", "SOUTH DELHI", or "AMBALA".
   - "bookedpckgs" / "stockpckgs": Integer package count from Tax Invoice 'Total Cases' (e.g. 1375, 2064, 1251, 797).
   - "packing": "Cases" or "Carton box".
   - "goods": Commodity description from Tax Invoice (e.g., "Baby Diapers", "MPP All Night Absorb COCO L40"). (Do NOT include seal numbers or invoice numbers in the goods description).
   - "bookedaweight" / "bookedcweight": Actual gross weight and charged weight in KG.
   - "invoiceno": Commercial invoice number from Tax Invoice (e.g., 10906I26-001898).
   - "invoiedt": Commercial invoice date (DD/MM/YYYY).
   - "valgoods": Total declared invoice value from Tax Invoice (numeric without commas, e.g. 2112307.00).
   - "ewaybillno": 12-digit GST E-Way Bill number. "Valid Upto": E-Way Bill validity date (DD/MM/YYYY).
   - "Transit Days": Integer difference between grdt and Valid Upto.
   - "Vehicle No *": Indian truck registration plate from bilty, mParivahan RC status, or truck photo (e.g., HR55AX5490, RJ18GB7132).
   - "Vehicle Type *": "Market". "ftl": "FTL". "staxpaidby": "C". "dlvtype": "D". "grtype": "TBB".
2. partially Present:
   - "pmark": Extract ONLY the pure digits of the container seal code (e.g., 03386, 002765).
     * If written in top header/margin (e.g. 'Seal. No- 03386') -> extract '03386'.
     * If stamped/written in middle of 'Description (Said to Contain)' goods area (e.g. 'Seal no: 002765') -> extract '002765' into pmark. NEVER treat middle seal as LR No, and NEVER leave it inside goods.
     * If no container seal code exists -> return strictly "".
   - "Driver Name *", "Mobile no *", "Liscense No *", "Valid Up to *": Extract ONLY if an official Driving Licence (DL) is attached in the multi-page dossier. If absent, leave strictly as empty string "".
   - "productcode" (HSN 96190030), "custrefcode", "Depatment Name": Extract if present; else "".
   - "oamount": Other charges (unloading, hamali, detention). Return numeric only if explicitly written; otherwise return strictly 0.00. NEVER copy valgoods into oamount.
3. absent:
   - "BNF LR No": Permanently removed from schema. Never extract.
   - "freight *", "cgst", "sgst", "igst": Contracted under FTL -> return 0 or 0.00.
   - "received", "advance": Return 0.00.
   - "Order Weight", "Contract wt", "Extra Mt", "viaborder": Return "".

B. PATANJALI RULES:
1. Present:
   - "grdt": Consignment booking date printed in 'Bkg. Date' box (DD/MM/YYYY).
   - "Customer Name *": "PATANJALI FOODS LTD (OIL & SOYA) (Formerly RSIL)" or "PATANJALI FOODS LTD BISCUIT (Formerly RSIL)".
   - "custrefcode": "BL653", "BL652", or "CM001".
   - "branchrefcode" / "Counter name": Center printed above title (e.g., "INDORE", "KOLKATA").
   - "orgrefcode": "INDORE", "KARNPURA SSRM". "destrefcode": "BANGALORE", "VARANASI", "SUGAULI".
   - "cngr": "PATANJALI FOODS LTD - INDORE...". "cngrgstno": "05AAFCF1505P1ZD".
   - "cnge": Consignee name & address.
   - "bookedpckgs": Integer package count under 'No. of Package'. "packing": "BAG" or "Carton box".
   - "goods": "SOYABADI", "BISCUITS". "bookedaweight" / "bookedcweight": Actual / charged weights in KG.
   - "invoiceno": Shipper invoice number from INVOICE DETAILS table (e.g., 8501817437).
   - "invoiedt": Invoice date (DD/MM/YYYY). "valgoods": Declared value without commas (e.g., 476204).
   - "ewaybillno": 12-digit GST E-Way Bill number. "Vehicle No *": Plate from header or RC Form 23A.
   - "Vehicle Type *": "Market". "ftl": "FTL". "staxpaidby": "C". "dlvtype": "D" or "G". "grtype": "TBB".
2. partially Present:
   - "grno" / "LR No *" (Strict Pen/Pencil Outer Margin Rule):
     * Check top-left and top-right outer sections (margins outside printed borders) for an independent handwritten/penciled number (e.g., 21349, 21348).
     * If present, extract that exact number.
     * If NOTHING is written in pen/pencil in the outer margins, leave strictly empty ("").
     * CRITICAL: DO NOT fall back to printed 7-digit 'C Note No.' (e.g. 9325388, 9421832).
     * NEVER confuse vehicle registration numbers with LR number.
   - "pmark": Extract ONLY if an explicit seal code is stamped (e.g. CJ007567); else "".
   - "Driver Name *", "Mobile no *", "Liscense No *", "Valid Up to *": Extract ONLY if an official DL card is attached. If absent, leave strictly as "".
   - "cngegstno", "Depatment Name", "Valid Upto", "Transit Days", "productcode": Extract if present; else "".
   - "oamount": Other charges (unloading, hamali, detention). Extract numeric only if explicitly written; otherwise return strictly 0.00. NEVER copy valgoods into oamount.
3. absent:
   - "BNF LR No": Permanently removed.
   - "freight *", "cgst", "sgst", "igst", "received", "advance": Printed as 'xxxx' on bilty face -> return 0 or 0.00.
   - "Order Weight", "Contract wt", "Extra Mt", "viaborder": Return "".

C. HIMALAYA RULES:
1. Present:
   - "grno" / "LR No *": Bold 5-digit number printed in 'CONSIGNMENT NOTE: No.' box at top right (e.g., 32752, 32754, 32978, 33118). Never confuse truck plate with LR number.
   - "grdt": Booking date in 'Date' box (DD/MM/YYYY).
   - "Customer Name *": "Himalaya Wellness Company".
   - "cngr": Consignor name & address (Makali Bangalore). "cngrgstno": "29AADFT3025B2ZK".
   - "cnge": Consignee name & address (Indore CFA, Kolkata CFA).
   - "cngegstno": Consignee GSTIN ("23AADFT3025B1ZX" for Indore, "19AADFT3025B1ZM" for Kolkata).
   - "orgrefcode": "Bangalore (MWH)". "destrefcode": "Indore (MWH)", "Kolkata (MWH)".
   - "bookedpckgs": Integer count under 'No. of Packages'. "packing": "Box", "Cartons".
   - "goods": "AYURVEDIC MEDICINES & BABY CARE PRODUCTS".
   - "bookedaweight": Actual gross weight in KG. (Convert '15 mt' to 15000; or record exact KG from Tax Invoice like 14979). "bookedcweight": Charged weight.
   - "invoiceno": Commercial invoice number (e.g., 5526701832). "invoiedt": Invoice date (DD/MM/YYYY).
   - "valgoods": Declared invoice value without commas (e.g., 11488522.00).
   - "ewaybillno": 12-digit GST E-Way Bill number. "Valid Upto": E-Way Bill expiry date.
   - "Transit Days": Integer difference between grdt and Valid Upto.
   - "Vehicle No *": Plate (e.g., GJ05BZ0237, RJ14GT3819). "Vehicle Type *": "32FT CONTAINER" or "Market".
   - "ftl": "FTL". "staxpaidby": "C". "dlvtype": "D". "grtype": "TBB".
2. partially Present:
   - "pmark": Extract ONLY pure digits/code (e.g., 00153, CJ007567) from top margin, description, or attached bottle seal photo. Strictly strip 'Seal', 'Seal No', '=', ':'. NEVER map seal number into LR number.
   - "Driver Name *", "Mobile no *", "Liscense No *", "Valid Up to *": Extract ONLY if an official DL/PAN card is attached. If absent (e.g. single-page uploads), leave strictly as "".
   - "oamount": If bottom notes specify unloading charges (e.g., "Unloading charges RS. 4200./-"), capture numeric (4200); else matches valgoods or 0.00.
   - "Depatment Name": Match against manifest (e.g., "HIMALAYA-INDORE", "HIMALAYA-KOLKATA").
   - "custrefcode", "productcode", "branchrefcode" / "Counter name": Extract if present; else "".
3. absent:
   - "BNF LR No": Permanently removed.
   - "freight *", "cgst", "sgst", "igst", "received", "advance", surcharges: Contracted under FTL -> return 0 or 0.00.
   - "Order Weight", "Contract wt", "Extra Mt", "viaborder": Return "".


D. GOLD PLUS RULES:
1. Present:
   - "grno" / "LR No *": Primary Consignment / LR Tracking Number. Bold printed 5-digit number in 'CONSIGNMENT NOTE: No.' box at top right (e.g., 31745, 31746).
   - "grdt": Consignment booking date in 'Date' box (DD/MM/YYYY, e.g., 01/10/2026).
   - "Customer Name *": "GOLD PLUS FLOAT GLASS PRIVATE LIMITED".
   - "cngr": "M/S. GOLD PLUS FLOAT GLASS PVT. LTD., Kanagala Industrial Area Kiadb, Tal. Hukkeri, Dist. Belagavi, Karnataka - 591225".
   - "cngrgstno": "29AAICG7897C1Z1".
   - "cnge": Consignee Name & address from bilty or Tax Invoice (e.g., "M/S. FORTUNE SAFETY GLASS, Udupi").
   - "cngegstno": Consignee GSTIN ("29AAFFF7172H1Z5").
   - "orgrefcode": "Kanagal" or "Belgaum". "destrefcode": "Udupi", "Mangalore", "Bangalore".
   - "bookedpckgs": Integer package count under 'No. of Packages' (e.g., 12).
   - "packing": "Boxes" or "Frames". "goods": "Float Glass" or "Clear Float Glass".
   - "bookedaweight": Actual gross weight in KG. (Convert '29.460 MT' -> 29460). "bookedcweight": 29460.
   - "invoiceno": Commercial invoice number from Tax Invoice or bilty (e.g., 26271010344).
   - "invoiedt": Commercial invoice date (DD/MM/YYYY). "valgoods": Declared value without commas (e.g., 1285094.81).
   - "ewaybillno": 12-digit GST E-Way Bill number. "Valid Upto": E-Way Bill expiry date.
   - "Transit Days": Integer difference between grdt and Valid Upto.
   - "Vehicle No *": Plate from bilty, Gate Pass, or Weighment Slip (e.g., KA25AB2955, KA22D0257).
   - "Vehicle Type *": "Market". "ftl": "FTL". "staxpaidby": "C". "dlvtype": "D". "grtype": "TBB".
2. partially Present:
   - "Mobile no   *": Driver 10-digit phone number. In Gold Plus dossiers, inspect the Tax Invoice header under 'Driver No:' (e.g., 7338673806). Extract if printed; else "".
   - "pmark": Extract seal or stencil mark if printed/stamped; else "".
   - "Driver Name *", "Liscense No *", "Valid Up to *": Extract ONLY if an official DL card is attached; else "".
   - "Depatment Name": "GOLD PLUS-BELGUAM".
   - "custrefcode", "productcode", "branchrefcode" / "Counter name": Extract if present; else "".
   - "oamount": Other charges (unloading, hamali, detention). Return numeric only if explicitly written; otherwise return strictly 0.00. NEVER copy valgoods into oamount.
3. absent:
   - "BNF LR No": Permanently removed.
   - "freight *", "cgst", "sgst", "igst", "received", "advance", surcharges: Contracted under FTL -> return 0 or 0.00.
   - "Order Weight", "Contract wt", "Extra Mt", "viaborder": Return "".

E. GENERIC BNF RULES:
   - Apply standard BNF mapping. Extract bold printed Consignment Note number as LR No.
   - For orange/yellow bilties: BNF LR No is permanently removed / blank.
   - Extract driver details ONLY if explicitly written or attached; never invent.
   - If freight is contracted under FTL, return 0.

STEP 3: MANDATORY ZERO-HALLUCINATION ENFORCEMENT
1. Do NOT guess or invent driver names, phone numbers, or license numbers. If not visibly present on an attached DL card or bilty, leave strictly as empty string "".
2. Preserve exact formatting for dates (DD/MM/YYYY).
3. Produce valid JSON object matching all 49 keys exactly.
```
