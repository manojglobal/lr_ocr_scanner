# Patanjali LR Document Scraping: Specialized OCR Prompt & Pattern Guide

This document defines the production scraping architecture, layout disambiguation, 3-tier confidence classification, and the specialized Gemini OCR prompt for processing **Patanjali Parivahan Pvt. Ltd.** and **Patanjali Foods Limited** (formerly Ruchi Soya Industries Limited) transport documents into the strict 49-column BNF Excel format.

---

## 1. Document Taxonomy

Patanjali logistics packets fall into two primary structures:

1. **Standalone White Printed Consignment Note (Bilty)** (e.g. `WhatsApp Image 2026-10-07 at 5.11.54 PM.jpeg`, `WhatsApp Image 2026-10-07 at 5.11.54 PM (4).jpeg`):
   - Standard computer-generated white bilty issued by *Patanjali Parivahan Pvt. Ltd. (Transport Contractor)*.
   - Contains printed `C Note No.`, center/branch header (`INDORE CENTER`, `KOLKATA`), consignor, consignee, FTL contract markers (`xxxx` across freight rows), invoice table, and destination delivery stamps.
   - **Outer Margin Booking Sequence Number**: A 5-digit sequence number written in pen or pencil in the **top-right** or **top-left** outer margin (e.g. `21349`, `21348`).

2. **Multi-Page Dossier with Attached Compliance Credentials** (e.g. `PDF Gallery_20261010_005415.pdf`):
   - **Page 1**: Vehicle Registration Certificate (Form 23A RC) and Commercial Driving Licence (DL).
   - **Page 2**: White printed consignment note matching the vehicle registration number on Page 1 (e.g. `BR03K4305`).

---

## 2. Identifier Disambiguation: Primary LR vs. Printed C Note vs. Truck Plate

```
+---------------------------------------------------------------------------------------------------------------+
|                                      PATANJALI IDENTIFIER MATRIX                                              |
+--------------------------+-----------------------+-------------------------+----------------------------------+
| Identifier               | Physical Location     | Visual Characteristics  | Target Schema Mapping            |
+--------------------------+-----------------------+-------------------------+----------------------------------+
| 1. Primary LR Number     | Top-Left or Top-Right | Handwritten in pen or   | Col: `grno (*)` / `LR No *`      |
|    (Booking Sequence No) | outer margin          | pencil (e.g. 21349)     | If absent -> strictly `0`        |
+--------------------------+-----------------------+-------------------------+----------------------------------+
| 2. Printed C Note Number | Header Table box      | Printed 7-digit system  | Internal Patanjali SAP/ERP ref   |
|                          | 'C Note No.'          | number (e.g. 9325388)   | (NEVER confuse with margin LR)   |
+--------------------------+-----------------------+-------------------------+----------------------------------+
| 3. Vehicle Registration  | Header Table box      | Indian plate format     | Col: `Vehicle No *`              |
|    Number                | 'Vehicle Number'      | (e.g. RJ32GC5386)       | (NEVER map into LR number)       |
+--------------------------+-----------------------+-------------------------+----------------------------------+
```

### Strict Pen/Pencil Outer Margin Rule:
* **Pen/Pencil Number Present**: If an independent number is written with a pen or pencil in the top-left or top-right outer section (e.g., `21349`, `21348`), extract it as the primary `LR No *` / `grno (*)`.
* **Pen/Pencil Number Absent**: If **nothing** has been written with a pencil or pen in the top-left or top-right section, mark it strictly as **`0` (empty)**.
* Do **NOT** fall back to the printed 7-digit `C Note No.` (e.g. `9325388`, `9421832`).
* Do **NOT** confuse vehicle registration numbers (e.g. `BR03K4305`, `UP21FT4643`) with the LR number.

---

## 3. Production OCR Prompt (Gemini 3.5 Flash Lite Vision)

Below is the production prompt engineered specifically for Patanjali documents:

```text
You are an expert OCR and document information scraping engine specialized in reading transport bilties, consignment notes, and driver/vehicle compliance credentials for 'PATANJALI PARIVAHAN PVT. LTD.' and 'PATANJALI FOODS LIMITED' (formerly Ruchi Soya Industries Limited).

DOCUMENT & MULTI-PAGE DOSSIER INSTRUCTIONS:
This document may contain a single page (white printed consignment note) or multiple pages (including Form 23A Vehicle Registration Certificate RC and Commercial Driving Licence DL). Inspect ALL pages thoroughly and map the data strictly into the 49 target columns:

1. CONSIGNMENT IDENTIFIERS & BOOKING SEQUENCE NUMBER:
- "grno (*)" / "LR No *": Primary Consignment / LR Tracking Number.
  * RULE: Check the top-left and top-right outer sections (margins outside the printed borders) for an independent number written with a pen or pencil (e.g., 21349, 21348).
  * If a handwritten or penciled number is written in the top-left or top-right section, extract that exact number.
  * If NOTHING has been written with a pencil or pen in the top-left or top-right section, mark it strictly as 0 (empty / "0").
  * DO NOT fall back to the printed 'C Note No.' (e.g. 9325388, 9325382, 9421832).
  * NEVER copy or confuse vehicle registration numbers (e.g. RJ32GC5386, BR03K4305).
- "pmark": Seal Number / Private Mark. Extract ONLY if an explicit seal code or container seal stamp is written (e.g., CJ007567). Strictly strip and ignore prefixes like 'Seal', 'Seal No', 'No', '='. If only generic text like 'all seal good and ok' appears or no physical seal code is written, return empty string "".

2. ROUTING & STATIONS:
- "branchrefcode": Center or branch code printed above the CONSIGNMENT NOTE title (e.g., "INDORE", "KOLKATA").
- "Counter name": Booking counter or center (matches branchrefcode, e.g., "INDORE", "KOLKATA").
- "orgrefcode": Origin station or city printed in 'From City' box (e.g., "INDORE", "KARNPURA SSRM").
- "destrefcode": Destination station or city printed in 'To City' box (e.g., "BANGALORE", "VARANASI", "SUGAULI").
- "collectionstncode": Dispatch station code (same as orgrefcode).
- "viaborder": Via border route if printed, else empty string "".

3. DATES & TRANSIT TIME:
- "grdt *": Consignment booking date printed in 'Bkg. Date' box (formatted as DD/MM/YYYY, e.g. 05/02/2026, 09/10/2026).
- "stockdt ": Consignment entry date printed in 'C Note Entry Date' (defaults to grdt).
- "Loading Start date *": Dispatch or loading date (same as grdt).
- "Valid Upto": E-Way Bill validity expiry date if present on an attached E-Way Bill page (formatted as DD/MM/YYYY), else empty string "".
- "Transit Days": Calculate the integer difference in days between 'grdt *' and 'Valid Upto'. If either date is missing, unparseable, or invalid, return strictly empty string "" (DO NOT default to 2).

4. PARTIES & MASTER DATA:
- "Customer Name *": Corporate billed entity printed under 'Billing Party' (e.g., "PATANJALI FOODS LTD (OIL & SOYA) (Formerly RSIL)", "PATANJALI FOODS LTD BISCUIT (Formerly RSIL)").
- "custrefcode": Billing customer/party code printed before the party name (e.g., "BL653", "BL652", or default "CM001").
- "cngr *": Consignor name and street address printed in the 'CONSIGNOR' box (e.g., "PFL20 : PATANJALI FOODS LTD - INDORE, TALAWALI CHANDA OPP MANGALIYAGAON RLY STATION INDUSTRIAL AREA A.B. ROAD INDORE, 453771").
- "cngrgstno *": Consignor 15-character GSTIN printed in the transporter/works header block or tax invoice (e.g., "05AAFCF1505P1ZD").
- "cnge *": Consignee name and destination address printed in the 'CONSIGNEE' box (e.g., "8888 : PATANJALI FOODS LIMITED, Maruthi Main Road nearby Sridhara Srigud Kengeri Satellite Town, BANGALORE, 560060").
- "cngegstno *": Consignee 15-character GSTIN if printed/present, else empty string "".
- "Depatment Name": Destination depot name if printed in Consignee block (e.g., "Depot Popular -Varanasi"), else empty string "".

5. GOODS, PACKAGING & WEIGHT QUANTIFICATION:
- "pckgs" / "bookedpckgs": Integer package count printed under 'No. of Package' or 'Total Charged No of Packages' (e.g., 410, 419, 845).
- "stockpckgs": Total stock packages (matches pckgs).
- "packing": Packaging type printed under 'Packaging Type' in CONSIGNMENT DETAILS (e.g., "BAG", "Carton box").
- "goods": Commodity name printed under 'Said to Contain' in CONSIGNMENT DETAILS (e.g., "SOYABADI", "BISCUITS").
- "productcode": Product code if specified, else empty string "".
- "aweight" / "bookedaweight": Actual gross weight in KG printed under 'Actual Wt(Kgs)' (e.g., 7500, 6567).
- "stockaweight": Actual cargo weight (matches aweight).
- "cweight" / "bookedcweight": Charged weight in KG printed under 'Total Charged Weight' (e.g., 7500, 7000).
- "stockcweight": Charged stock weight (matches cweight).
- "Order Weight": Weight if specified separately, else empty string "".
- "Contract wt": Contract weight if specified, else empty string "".
- "Extra Mt": Extra metric tons if specified, else empty string "".

6. COMMERCIAL INVOICE & E-WAY BILL:
- "invoiceno": Commercial shipper invoice number printed under 'Invoice No.' in the INVOICE DETAILS table (e.g., 8501817437, 8501817324, 8604510455).
- "invoiedt": Commercial invoice date printed under 'Inv. Date' (formatted as DD/MM/YYYY).
- "valgoods": Declared invoice value of goods printed under 'Declared Value' without commas (e.g., 476204, 519158, 725770).
- "oamount": Total invoice amount or declared value. If receiver notes at the bottom specify an unloading charge (e.g., 'Unloading charge 1000/-'), capture that charge numeric (1000), otherwise map to valgoods.
- "ewaybillno": 12-digit GST E-Way Bill number printed under 'Eway Bill No' (e.g., 612053161654, 652051661257, 811752253963).

7. CHARGES & TAX BREAKDOWN (FTL CONTRACT RULES):
- "grtype": Payment terms printed under 'Payment Type' (e.g., "TBB").
- "freight  *": Return 0. On Patanjali bilties, all freight charges are printed as 'xxxx' (Full Truck Load TBB contract).
- "cgst": Central GST. Printed as 'xxxx' -> return 0.00.
- "sgst": State GST. Printed as 'xxxx' -> return 0.00.
- "igst": Integrated GST. Always output 0.00 (or 0) for manual data entry purposes.
- "received": Freight received amount -> return 0.00.
- "advance": Advance paid to transporter -> return 0.00.
- "ftl": Vehicle load type. If Service Type is 'FTL', return "FTL", else "N".
- "staxpaidby": Party paying service tax / GST on freight: 'C' (Consignor), 'E' (Consignee), or 'T' (Transporter). For TBB/FTL movements, default to "C".
- "dlvtype": Delivery type. If PickUp/Delivery is 'Door/Door', return "D" (Door Delivery), else "G" (Godown).

8. VEHICLE & DRIVER CREDENTIAL RESOLUTION:
- "Vehicle No *": Indian motor vehicle registration plate printed under 'Vehicle Number' in the header table or attached RC Form 23A (e.g., RJ32GC5386, UP21FT4643, BR03K4305).
- "Vehicle Type *": Vehicle body type. If FTL or unspecified, return "Market".
- "Driver Name *": Driver full name. Extract ONLY if explicitly visible on an attached Driving Licence (DL) card (e.g., "MANOJ SINGH"). If NO DL card is attached, leave STRICTLY as an empty string "". NEVER guess or invent names.
- "Mobile no   *": Driver 10-digit mobile number. Extract ONLY if explicitly written for the driver. NEVER copy the consignor phone (8209435149) or dummy phone (9999999999) into the driver phone field. If absent, leave STRICTLY as an empty string "".
- "Liscense No *": Commercial driving licence number from attached DL card (e.g., "BR44 20110036047"). If not attached, leave STRICTLY as an empty string "".
- "Valid Up to *": Transport validity expiry date of the driving licence ('TR' validity date on DL card, e.g., "10/02/2027"). If not attached, leave STRICTLY as an empty string "".

9. ZERO-HALLUCINATION & STRICT EMPTY FIELD RULES:
* The 'BNF LR' column has been permanently removed from the Excel schema. Never extract or output any value as BNF LR.
* Auto-fetching from driver_master.json is completely disabled. If driver details are absent from the document, keep them strictly as empty strings ("") for manual entry.
* If any field is missing, illegible, or not present on the document, leave it as an empty string "" (never invent placeholder data).

Produce the output as a valid JSON object matching all 49 keys exactly.
```

---

## 4. Confidence Classification Matrix for Patanjali Documents

| Status Category | Visual Indicator | Criteria | Examples in Patanjali Documents |
| :--- | :---: | :--- | :--- |
| **Confirmed Data** | 🟢 Green | Clearly printed or legible handwriting verified across documents. | `LR No *`: `21349` (or `0` when margin is clean), `Vehicle No *`: `RJ32GC5386`, `invoiceno`: `8501817437`, `valgoods`: `476204`. |
| **Partially Confirmed (50/50)** | 🟡 Amber | Legible with potential ambiguity; requires verification. | `oamount`: `1000` (from handwritten note "Unloading charge 1000/-"). |
| **Missing Data** | 🔴 Red Border | Absent from bilty and attachments; preserved blank for manual entry. | Driver details on single-page uploads (e.g. `WhatsApp Image ...`), `pmark` when no seal code is stamped. |
