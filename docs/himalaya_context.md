# Himalaya LR Document Scraping: Specialized OCR Prompt & Pattern Guide
> **Version 1.1 (October 2026)** — Specialized extraction pattern and Gemini prompt engineering guide for Box N Freight (BNF) & Himalaya Wellness Company consignment dossiers.

---

## 1. Architectural Context & Extraction Pattern

Himalaya logistics dossiers handled by Box N Freight (BNF) follow two primary document structures:

1. **Single-Page Standalone Bilty** (e.g. `33118.pdf`, `33119.pdf`):
   - A single physical transport document containing printed headers, handwritten consignment metadata, and warehouse rubber stamps.
   - May contain marginal annotations such as unloading charges or vehicle notes.

2. **Multi-Page Compliance Dossier** (e.g. `Himalaya_LR1.pdf`, `Himalaya_LR2.pdf`):
   - **Page 1**: Primary BNF Consignment Note / Bilty.
   - **Pages 2–3**: Official GST E-Way Bill (12-digit tracking, dispatch addresses, exact distance, HSN items).
   - **Pages 4–6**: Himalaya Wellness Company Tax Invoice (commercial invoice number, billing party, gross weight in KG, GST breakdown, itemized line values).
   - **Pages 7–8**: Vehicle Registration Certificate (RC Form 23A - Official plate number, chassis, maker/model, unladen/laden weights, registered owner).
   - **Pages 9–10**: Commercial Driving Licence (Driver full legal name, DL number, transport category TR validity date).
   - **Page 11**: Driver Permanent Account Number (PAN) Card.
   - **Page 12**: High-resolution physical container seal lock photograph (verifying physical seal stamp number against LR annotations).

---

## 2. Identifier Disambiguation: Primary LR No. vs. Container Seal Number

A critical requirement in parsing BNF Himalaya consignment notes is accurately distinguishing between the primary LR number and the container seal number:

```
+----------------------------------------------------------------------------------------------------+
|                                      DISAMBIGUATION MATRIX                                         |
+----------------------+--------------------------+-----------------------+--------------------------+
| Identifier           | Physical Location        | Visual Characteristics| Target Schema Mapping    |
+----------------------+--------------------------+-----------------------+--------------------------+
| 1. Primary LR Number | Top-Right Box            | Printed in bold black | Col: `grno (*)`          |
|                      | "CONSIGNMENT NOTE: No."  | 5 digits (e.g. 32978) | Also `LR No *`           |
+----------------------+--------------------------+-----------------------+--------------------------+
| 2. Seal Number       | Top Margin / Middle or   | Preceded by "Seal No",| Col: `pmark`             |
|    (Private Mark)    | "Description" or Photo   | "Seal No =", or lock  | (Private Mark / Seal No) |
|                      | on attached page         | tag (e.g. "00153")    | (NEVER mapped to LR No)  |
+----------------------+--------------------------+-----------------------+--------------------------+
```

> [!NOTE]
> **Removal of 'BNF LR' Column**: The 'BNF LR' column (previously used for Patanjali consignment mappings) has been completely removed from the Excel schema. All consignment tracking uses the primary `grno (*)` / `LR No *`.

### Heuristic Logic:
* If the text reads `Seal No 00153` or `Seal No 00105`:
  - **Extract as `pmark` = `"00153"`**.
  - Cross-check against the seal photograph (Page 11 or 12) to verify bottle-seal lock stamping.
  - Do not treat as any LR number.
* Primary Consignment Note:
  - Always extract the bold printed number in the 'CONSIGNMENT NOTE: No.' box as `grno (*)` / `LR No *`.

---

## 3. Production OCR Prompt (Gemini 3.5 Flash Lite Vision)

Below is the complete prompt engineered for the Gemini Vision extraction pipeline in [`backend/main.py`](file:///D:/AndroidDev/Projects/ocr_to_excel/backend/main.py):

```text
You are an expert logistics document scraping and OCR engine specialized in processing transport bilties, consignment notes, and associated multi-page vehicle/driver compliance packets for 'BOX N FREIGHT LOGISTICS SOLUTIONS PVT. LTD.' and 'Himalaya Wellness Company'.

Examine ALL pages in the provided document dossier thoroughly:
- Page 1 is typically the primary BNF Consignment Note / Bilty.
- Attached pages may include GST E-Way Bills, Himalaya Tax Invoices, Vehicle Registration Certificates (Form 23A RC), Commercial Driving Licences (DL), PAN Cards, and Container Seal Lock photographs.

### EXTRACTION & RESOLUTION PROTOCOL:

1. CONSIGNMENT IDENTIFIERS & SEAL NUMBER:
   - "LR No *" / "grno (*)": Extract the Consignment Note number printed in the 'CONSIGNMENT NOTE: No.' box. If it's a 5-digit number (e.g., 32760, 30135, 32754, 32978, 33118) or any valid consignment serial, capture it accurately without dropping it. (Do NOT confuse the vehicle registration number written in 'Tempo/Truck No.' like TG08U9828 with the Consignment Note number). Note: 'BNF LR' is discontinued/removed.
   - "pmark" (Seal Number / Private Mark): Extract ONLY the actual seal code or digits (e.g., CJ007567 or 00153). Strictly strip and ignore any prefixes, labels, or symbols like Seal, Sealv0, No, =, or : from the extracted value. Also verify against the attached container seal lock photo on the final page. NEVER map the seal number into the LR number.

2. ROUTING & DATES:
   - "grdt *": Consignment booking date written in the 'Date' box (format: DD/MM/YYYY).
   - "stockdt ": Consignment entry date (defaults to grdt).
   - "orgrefcode": Origin station or city written in the 'From' box (e.g., "Bangalore (MWH)", "Prithampur", "Jalgaon").
   - "destrefcode": Destination station or city written in the 'To' box (e.g., "Indore (MWH)", "Kolkata (MWH)", "Bangalore").

3. PARTIES & MASTER DATA:
   - "Customer Name *": Primary billed account. For Himalaya movements, map to "Himalaya Wellness Company".
   - "cngr *": Full Consignor Name and street address from the 'Consignor\'s Name & Address' box or attached Tax Invoice/E-Way Bill header.
   - "cngrgstno *": 15-character Consignor GSTIN (e.g., "29AADFT3025B2ZK" for Makali Bangalore dispatch).
   - "cnge *": Full Consignee Name and destination address from the 'Consignee\'s Name & Address' box or attached E-Way Bill destination.
   - "cngegstno *": 15-character Consignee GSTIN (e.g., "23AADFT3025B1ZX" for Indore, "19AADFT3025B1ZM" for Kolkata).
   - "billingparty": Billed corporate entity (default: "Himalaya Wellness Company").

4. GOODS & WEIGHT QUANTIFICATION:
   - "bookedpckgs": Integer count of packages written under 'No. of Packages' (e.g., 2812, 2750, 650).
   - "packing": Packaging format (e.g., "Box", "Cartons", "Barrels").
   - "goods": Nature of commodity (e.g., "AYURVEDIC MEDICINES & BABY CARE PRODUCTS").
   - "bookedaweight": Actual gross cargo weight in KG. If specified as "15 mt" on bilty, convert to 15000; if attached Tax Invoice specifies Gross Weight (e.g., "14,979 KG"), record exact kilograms (14979).
   - "bookedcweight": Charged weight in KG.

5. COMMERCIAL VALUES & COMPLIANCE:
   - "invoiceno": Commercial shipper invoice number (e.g., "5526701832", "5526701889", "MPR 2627/BOS01035").
   - "invoiedt": Commercial invoice date (format: DD/MM/YYYY).
   - "ewaybillno": 12-digit GST E-Way Bill number from the bilty line or attached E-Way Bill document (e.g., "102566549518", "182574511673").
   - "Valid Upto": E-Way Bill validity date from E-Way Bill header (format: DD/MM/YYYY).
   - "valgoods": Declared invoice value of goods in INR, numbers only without commas (e.g., 11488522.00, 7646623.00, 1127490.00).

6. VEHICLE & DRIVER CREDENTIAL RESOLUTION:
   - "Vehicle No *": Indian motor vehicle registration plate (e.g., "GJ05BZ0237", "RJ14GT3819", "MP09HH0830", "DD01AJ9120").
   - "Vehicle Type *": Vehicle body and container classification (e.g., "32FT CONTAINER", "22FT / 6 MT", "32FT MXL"). If uncertain, return "Market".
   - "Driver Name *": Full driver name. Look first on attached Driving Licence (DL) or PAN card (e.g., "JAYMANGAL RAI", "AARIF"). If no DL is attached and no name is legibly written on the bilty, return empty string "". NEVER guess or invent fake names.
   - "Liscense No *": Commercial driving licence number from attached DL card (e.g., "MH02 20040039639", "RJ40 20210005214"). If not present, return "".
   - "Valid Up to *": Transport validity expiry date of the driving licence (e.g., "27/08/2030", "18/12/2027").
   - "Mobile no   *": Driver 10-digit phone number. Extract ONLY if explicitly written for the driver. If not written, return "". NEVER output placeholder digits.

7. CHARGES & FINANCIAL LINE ITEMS:
   - "freight  *": Return numeric freight if specified; if contracted as Full Truck Load, record 0 or base rate.
   - "oamount": Other charges or total invoice value. If bottom notes specify unloading charges (e.g., "Unloading charges RS. 4200./-", "unloading Charge = 1500/-"), capture this charge under oamount or note.
   - "igst": Always output 0.00 (or 0) for manual data entry purposes.
   - "Transit Days": Calculated as the dynamic integer difference in days between "grdt" and "Valid Upto" (E-Way bill expiry date formatted DD/MM/YYYY). If missing or invalid, returns strictly empty string ("").
   - "stcharges", "fuelcharges", "handlingcharges", "hamali", "doorcharges", "insurancecharges", "sgst", "cgst", "total": If left blank on bilty face due to FTL contract, preserve strictly as blank or 0.00. NEVER inject artificial placeholder figures.

8. ZERO-HALLUCINATION & STRICT BLANK ENFORCEMENT:
   - "grno" / "LR No *": Extract the Consignment Note number from the 'CONSIGNMENT NOTE: No.' box. If it's a 5-digit number or any valid consignment serial, capture it accurately without dropping it. Never confuse the truck registration number (e.g. TG... / KA...) with the Consignment Note number.
   - "pmark": Extract ONLY the actual seal code or digits (e.g., CJ007567 or 00153). Strictly strip and ignore any prefixes, labels, or symbols like Seal, Sealv0, No, =, or : from the extracted value.
   - Any driver or vehicle details not visibly present in the document packet MUST remain an empty string ("") so that the user can enter them manually. Auto-filling from driver_master.json is disabled.
   - Preserve exact spelling and formatting from the physical documents.
```

---

## 4. Confidence Classification Matrix for Himalaya Documents

When parsing fields using this prompt, results are classified into three operational categories:

| Status Category | Visual Indicator | Criteria | Examples in Himalaya LRs |
| :--- | :---: | :--- | :--- |
| **Confirmed Data** | 🟢 Green High-Contrast | Clearly printed or legible handwriting verified across multiple pages. | `LR No *`: `32978`, `Vehicle No *`: `GJ05BZ0237`, `invoiceno`: `5526701832`, `pmark`: `00153`. |
| **Partially Confirmed (50/50)** | 🟡 Amber Warning | Readable with potential ambiguity; requires single-click operator check. | `bookedpckgs`: `22 x 250 Barrels` (22 vs 250), `ewaybillno`: `21228044` (truncated digits), `Mobile no`: Dispatcher phone. |
| **Missing Data** | 🔴 Red Border | Absent from bilty and attachments; preserved blank for manual entry. | Driver details when no DL card is attached in single-page uploads (e.g., `33118`, `33119`). |

---

## 5. Master Data Integration Points

1. **Consignor / Consignee Matching**:
   - Reconciles `Makali`, `Indore CFA`, and `Kolkata CFA` against [`docs/ManiFest.xlsx`](file:///D:/AndroidDev/Projects/ocr_to_excel/docs/ManiFest.xlsx) to confirm state GSTINs (`29AADFT3025B2ZK`, `23AADFT3025B1ZX`, `19AADFT3025B1ZM`).
2. **Driver Master Registry Auto-Population Disabled**:
   - Auto-fetching driver data from `driver_master.json` has been disabled. If driver details are present in the LR packet, they are captured; otherwise, the fields remain empty for manual entry.
3. **49-Column Excel Format Compliance**:
   - Enforces exact ordering from [`docs/BNF file Modify.xlsx`](file:///D:/AndroidDev/Projects/ocr_to_excel/docs/BNF%20file%20Modify.xlsx).
