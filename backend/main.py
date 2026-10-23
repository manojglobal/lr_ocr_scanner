import base64
import io
import json
import os
import re
import socket
import uuid
from datetime import datetime
from fastapi import FastAPI, File, Form, HTTPException, UploadFile, Header, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from typing import Any
from pydantic import BaseModel, ConfigDict, Field, field_validator
from PIL import Image, ImageOps, ImageEnhance
import openpyxl
from openpyxl.styles import PatternFill, Font, Alignment, Border, Side
from openpyxl.utils import get_column_letter
import google.generativeai as genai
from google.generativeai.types import HarmCategory, HarmBlockThreshold

import auth_service
import audit_snapshot
import file_lifecycle_service

# Configuration
def _load_env_file():
    # 1. Try python-dotenv if installed
    try:
        from dotenv import load_dotenv
        for p in [
            os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"),
            os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env"),
        ]:
            if os.path.isfile(p):
                load_dotenv(p, override=False)
    except Exception:
        pass

    # 2. Built-in zero-dependency fallback parser
    for p in [
        os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"),
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env"),
    ]:
        if os.path.isfile(p):
            try:
                with open(p, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith("#") or "=" not in line:
                            continue
                        k, v = line.split("=", 1)
                        k = k.strip()
                        v = v.strip().strip('"').strip("'")
                        if k and k not in os.environ:
                            os.environ[k] = v
            except Exception as e:
                print(f"[Warning] Failed reading {p}: {e}")

_load_env_file()

API_KEY = os.getenv("GEMINI_API_KEY", "")
if not API_KEY or API_KEY.strip() in ("", "YOUR_GEMINI_API_KEY_HERE", "your_gemini_api_key_here"):
    print("=" * 70)
    print("  [CONFIGURATION NEEDED] GEMINI_API_KEY is not configured!")
    print("  Please open backend/.env and add your Google Gemini API key:")
    print("  GEMINI_API_KEY=AIzaSy...")
    print("=" * 70)
    raise RuntimeError("GEMINI_API_KEY is not set. Please add your API key to backend/.env")

MODEL_NAME = os.getenv("GEMINI_MODEL", "gemini-3.5-flash-lite")

# Disable content blocking on compliance documents (driving licence, permits, bilties)
SAFETY_SETTINGS = {
    HarmCategory.HARM_CATEGORY_HARASSMENT: HarmBlockThreshold.BLOCK_NONE,
    HarmCategory.HARM_CATEGORY_HATE_SPEECH: HarmBlockThreshold.BLOCK_NONE,
    HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT: HarmBlockThreshold.BLOCK_NONE,
    HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT: HarmBlockThreshold.BLOCK_NONE,
}

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

def _resolve_project_file(*subpaths: str) -> str:
    """Searches for file in BASE_DIR, parent project root, or common subdirectories."""
    candidates = [
        os.path.join(BASE_DIR, *subpaths),
        os.path.join(os.path.dirname(BASE_DIR), *subpaths),
        os.path.join(BASE_DIR, "data", *subpaths),
        os.path.join(os.path.dirname(BASE_DIR), "data", *subpaths),
    ]
    for p in candidates:
        norm = os.path.normpath(p)
        if os.path.exists(norm):
            return norm
    return os.path.normpath(os.path.join(BASE_DIR, *subpaths))

def _resolve_apk_path() -> str | None:
    """Finds available Android APK build from flutter build output or releases folder."""
    candidates = [
        os.path.join(BASE_DIR, "releases", "ocr_to_excel.apk"),
        os.path.join(os.path.dirname(BASE_DIR), "releases", "ocr_to_excel.apk"),
        os.path.join(os.path.dirname(BASE_DIR), "build", "app", "outputs", "flutter-apk", "app-release.apk"),
        os.path.join(os.path.dirname(BASE_DIR), "build", "app", "outputs", "apk", "release", "app-release.apk"),
        os.path.join(os.path.dirname(BASE_DIR), "build", "app", "outputs", "flutter-apk", "app-debug.apk"),
        os.path.join(os.path.dirname(BASE_DIR), "build", "app", "outputs", "apk", "debug", "app-debug.apk"),
    ]
    for c in candidates:
        norm = os.path.normpath(c)
        if os.path.isfile(norm) and os.path.getsize(norm) > 0:
            return norm
    return None

STATIC_DIR = os.path.join(BASE_DIR, "static")
SAMPLE_IMAGES_DIR = os.path.join(STATIC_DIR, "sample_images")
APK_PATH = _resolve_apk_path() or _resolve_project_file("releases", "ocr_to_excel.apk")
EXPORT_DIR = os.path.join(BASE_DIR, "export")
UPLOAD_LR_DIR = getattr(audit_snapshot, "UPLOAD_LR_DIR", os.path.join(EXPORT_DIR, "upload_LR"))
SNAPSHOTS_EXCEL_DIR = getattr(audit_snapshot, "SNAPSHOTS_EXCEL_DIR", os.path.join(EXPORT_DIR, "snapshots_excel"))
os.makedirs(UPLOAD_LR_DIR, exist_ok=True)
os.makedirs(SNAPSHOTS_EXCEL_DIR, exist_ok=True)

# Backward compatibility aliases
UPLOADS_DIR = UPLOAD_LR_DIR
LEGACY_UPLOADS_DIR = os.path.join(BASE_DIR, "uploads")
os.makedirs(LEGACY_UPLOADS_DIR, exist_ok=True)

print(f"[Init] Configuring Gemini API with model: {MODEL_NAME}...")
genai.configure(api_key=API_KEY)

print("[Init] Initializing FastAPI application...")
app = FastAPI(title="OCR to Excel Dual-Component Studio")

# CORS middleware for Web and Mobile cross-origin requests
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount static directory for web component assets
if os.path.isdir(STATIC_DIR):
    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

if os.path.isdir(SAMPLE_IMAGES_DIR):
    app.mount("/sample_images", StaticFiles(directory=SAMPLE_IMAGES_DIR), name="sample_images")

if os.path.isdir(UPLOAD_LR_DIR):
    app.mount("/export/upload_LR", StaticFiles(directory=UPLOAD_LR_DIR), name="export_upload_lr")
    # Route /uploads and /snapshots to UPLOAD_LR_DIR for full backward compatibility
    app.mount("/uploads", StaticFiles(directory=UPLOAD_LR_DIR), name="uploads")
    app.mount("/snapshots", StaticFiles(directory=UPLOAD_LR_DIR), name="snapshots")
elif os.path.isdir(UPLOADS_DIR):
    app.mount("/uploads", StaticFiles(directory=UPLOADS_DIR), name="uploads")
    if os.path.isdir(audit_snapshot.SNAPSHOTS_DIR):
        app.mount("/snapshots", StaticFiles(directory=audit_snapshot.SNAPSHOTS_DIR), name="snapshots")

# =========================================================================
# Standard Logistics Goods Receipt (GR / LR / Bilty) Export Column Schemas
# Derived directly from:
# 1. ImportGRStockExcelFormat.xlsx (38 Columns)
# 2. GR IMport format_BNF (1) (1) (1).xlsx (49 Columns)
# =========================================================================
GR_STOCK_38_HEADERS = [
    "stockdt", "branchrefcode", "grno", "grdt", "grtype", "orgrefcode", "destrefcode",
    "cngr", "cnge", "cngrgstno", "cngegstno", "productcode", "packing", "pmark", "goods",
    "freight", "oamount", "cgst", "sgst", "igst", "received", "advance", "collectionstncode",
    "ftl", "bookedpckgs", "bookedaweight", "bookedcweight", "custrefcode", "staxpaidby",
    "dlvtype", "stockpckgs", "stockaweight", "stockcweight", "ewaybillno", "invoiceno",
    "invoiedt", "valgoods", "viaborder"
]

GR_BNF_49_HEADERS = [
    "branchrefcode", "grno (*)", "grdt *", "grtype", "Customer Name *",
    "Depatment Name", "Counter name", "Transit Days", "orgrefcode", "destrefcode",
    "cngr *", "cnge *", "cngrgstno *", "cngegstno *", "productcode", "packing",
    "pmark", "goods", "Vehicle No *", "Vehicle Type *", "Driver Name *",
    "Mobile no   *", "Liscense No *", "Valid Up to *", "Loading Start date *",
    "freight  *", "oamount", "cgst", "sgst", "igst", "received", "advance",
    "collectionstncode", "ftl", "pckgs", "Order Weight", "aweight", "cweight",
    "Contract wt", "Extra Mt", "custrefcode", "staxpaidby", "dlvtype",
    "ewaybillno", "Valid Upto", "invoiceno", "invoiedt", "valgoods", "viaborder"
]
GR_BNF_50_HEADERS = GR_BNF_49_HEADERS

RED_COLUMNS_BNF_49 = [
    "grtype",
    "Customer Name *",
    "grno (*)",
    "Depatment Name",
    "Vehicle No *",
    "Vehicle Type *",
    "Driver Name *",
    "Mobile no   *",
    "Liscense No *",
    "Valid Up to *",
    "Loading Start date *",
    "Valid Upto",
]

TEMPLATE_BNF_49 = _resolve_project_file("GR IMport format_BNF (1) (1) (1).xlsx")
TEMPLATE_STOCK_38 = _resolve_project_file("ImportGRStockExcelFormat.xlsx")

DEFAULT_HANDWRITTEN_OCR_PROMPT = """
You are an expert OCR and document information scraping engine specialized in reading transport bilties, consignment notes, lorry receipts, and associated vehicle/driver compliance documents (including 'BOX N FREIGHT LOGISTICS SOLUTIONS PVT. LTD.' bilties, Vehicle Registration Certificate Form 23A / RC, National/State Goods Permits, Pollution Test Certificates, and Driving Licences).

DOCUMENT & MULTI-PAGE EXTRACTION RULES:
This document may contain a single page or multiple pages (e.g. Consignment Note, Vehicle RC, Permit, Insurance, Pollution Test, and Driving Licence). Examine ALL pages thoroughly:

1. Consignment & Billing Details (from Consignment Note / Bilty if present):
- "grno": Consignment Note No (written in 'CONSIGNMENT NOTE: No.', 'C Note No.', or 'LR No.' box, e.g. 9421736, 30035, 9415364).
- "LR No *": Same printed Consignment Note / LR Number.
- "grdt": Consignment Note Date (written in 'Date' box, e.g. 05 Oct 26, 05/08/2026).
- "stockdt": Date of entry or Consignment Note Date (same as grdt).
- "Customer Name *": Billed customer / party name (e.g. 'PATANJALI FOODS LTD BISCUIT (Formerly RSIL)', 'Himalaya Wellness Company').
- "cngr *": Consignor Name & Address (written in 'Consignor\'s Name & Address' box).
- "cnge *": Consignee Name & Address (written in 'Consignee\'s Name & Address' box).
- "cngrgstno *": Consignor 15-digit GSTIN (if printed/written, else empty).
- "cngegstno *": Consignee 15-digit GSTIN (if printed/written, else empty).
- "orgrefcode": Origin station / city (written in 'From' box, e.g. 'KOLKATA', 'KARNPURA SSRM', 'HYDERABAD').
- "destrefcode": Destination station / city (written in 'To' box, e.g. 'SUPAUL', 'Haryana (Ambada)', 'Bangalore').
- "bookedpckgs": Number of packages (written under 'No. of Packages', numeric, e.g. 808, 2632, 980).
- "packing": Packaging unit (e.g. 'Carton box', 'Box', 'Ctn').
- "goods": Description of Goods (written under 'Description (Said to Contain)', e.g. 'BISCUITS', 'Himalaya Products').
- "valgoods": Invoice Value (numeric without commas, e.g. 699909, 5446344).
- "invoiceno": Invoice Number (look for 'INVO =', 'Invoice No', e.g. 8604510266, 5616700769).
- "invoiedt": Invoice Date (look for 'Dt' or consignment date, e.g. 05 Oct 26, 01/08/2026).
- "ewaybillno": E-way Bill Number (digits only, e.g. 811749749318, 102509410411).
- "Valid Upto": E-way bill validity date (look for 'Valid =', e.g. 08 Oct 26, 14/08/2026).
- "bookedaweight": Actual Weight in KG (written in Weight box, e.g. 6300, 6500, 15057).
- "bookedcweight": Charged Weight in KG (same as bookedaweight or charged weight).
- "pmark": Seal Number / Private Mark (look for 'Seal No =', e.g. '001678').
- "grtype(Don’t know)": Payment term (written in Freight box, e.g. 'TBB', 'TO B', 'TO PAY').
- "freight  *": Numerical freight charge from the transporter/bilty charges table. If not specified or left blank, return null or 0.
- "oamount": Total invoice amount (rounded off / gross invoice value). Prefer the Grand Total from the Tax Invoice or "Value of Goods" from the E-Way Bill (e.g., 5802888, 6102872, 4017285).
- "cgst": Central GST amount from invoice tax summary. If the supply is interstate (IGST charged), return 0.00.
- "sgst": State GST amount from invoice tax summary. If the supply is interstate (IGST charged), return 0.00.
- "igst": Total Integrated GST amount from the invoice tax summary (e.g., 706796.16, 433434.20). If intrastate, return 0.00.
- "received": Amount already received against the freight/consignment note. If blank, return 0.00.
- "advance": Advance amount paid to transporter/driver on the bilty. If blank, return 0.00.
- "collectionstncode": Station code or city of origin/dispatch (e.g., from "From" station on LR or dispatch PIN/city, like HYDERABAD, Bangalore).
- "ftl": Vehicle load type (e.g., "FTL" if dedicated truck/dimensions like "32 FT", "7 MT", or "LTL"/"Part Load" if parcel/carton consignment).
- "custrefcode": Customer reference/account code (e.g., Party code like "C7056", "C7006", "C7008", "C7030" from the invoice header).
- "staxpaidby": Party responsible for paying service tax / GST on freight: 'C' (Consignor), 'E' (Consignee), or 'T' (Transporter under RCM). Inspect 'GST payable under form 38 Charges merchandise by: CONSIGNOR [ ] CONSIGNEE [ ] TRANSPORTER [ ]' or payment term.
- "dlvtype": Delivery type: 'D' (Door Delivery) or 'G' (Godown Delivery) based on whether consignee premises address is specified.
- "stockpckgs": Total number of packages/cartons (matches bookedpckgs / box count).
- "stockaweight": Actual gross weight of the cargo in KG (from invoice Gross Weight or LR Declared Weight).
- "stockcweight": Charged weight of the cargo in KG (matches stockaweight or charged weight from LR).
- "productcode": Product code (if printed/written, else empty).

2. Vehicle & Compliance Details (from Vehicle RC / Permit / Pollution / Bilty):
- "Vehicle No *": Vehicle registration number (written in 'Tempo/Truck No.', RC 'REG NO', or Permit, e.g. KA23B5235, BR29GA2038).
- "Vehicle Type *": Vehicle category or body type (e.g. 'GOODS CARRIER', 'FTL', 'CAB CHASSIS', '32 FT MXL'). If not explicitly specified or uncertain, return 'Market'.
- "Depatment Name": Department name if mentioned (e.g. 'TRANSPORT DEPARTMENT', 'SURGICAL').

3. Driver Details (from Driving Licence / Pollution Certificate / Driver Signature):
- "Driver Name *": Driver full name. Extract ONLY if explicitly visible and written on a Driving Licence card, driver box, or signature in this document. If NOT written, leave as empty string "". NEVER guess or invent names.
- "Mobile no   *": Driver 10-digit mobile number. Extract ONLY if a genuine mobile number is written for the driver or transporter. If NOT written, leave as empty string "". NEVER output dummy numbers like "9999999999".
- "Liscense No *": Driving Licence number. Extract ONLY if explicitly written on Driving Licence card or document. If NOT written, leave as empty string "".
- "Valid Up to *": Driving Licence or permit validity date (DD/MM/YYYY or DD-Mon-YY). Extract ONLY if written. If NOT written, leave as empty string "".

4. DOCUMENT TYPE & BNF LR NO. EXTRACTION RULES:
* Orange/Yellow handwritten-image: Extract only the LR No.; do not treat any number as BNF LR No. "BNF LR No" MUST BE an empty string "".
* White printed page: If a number is handwritten/penciled at top-left or top-right, treat it as BNF LR No.
* If there is no handwritten/pencil number on the white page, leave BNF LR No blank ("").
* Never copy the printed consignment note number into BNF LR No.
* IF ANY FIELD IS MISSING OR NOT WRITTEN IN THE DOCUMENT, LEAVE IT AS AN EMPTY STRING "" (DO NOT GUESS OR INVENT FAKE DATA).
"""


def is_orange_yellow_image(pil_img: Image.Image) -> bool:
    """
    Classifies whether an image is predominantly orange/yellow (handwritten transport bilty)
    versus a white printed consignment page.
    """
    try:
        thumb = pil_img.convert("RGB").resize((100, 100))
        pixels = list(thumb.getdata())
        orange_yellow_count = 0
        for r, g, b in pixels:
            if r > 115 and g > 90 and (r - b > 35 or g - b > 30):
                orange_yellow_count += 1
        return (orange_yellow_count / len(pixels)) > 0.15
    except Exception:
        return False


def map_to_gr_row(data: dict[str, str], headers: list[str]) -> list:
    """
    Intelligently maps extracted OCR key-values into the target GR template columns.
    Converts numbers and dates to clean values.
    Leaves any missing or unclear fields completely BLANK (None).
    Never injects fake dummy ERP placeholder data.
    """
    import re

    def clean(s: str) -> str:
        return "".join(c for c in str(s).lower() if c.isalnum())

    data_norm = {clean(k): str(v).strip() for k, v in data.items() if v is not None and str(v).strip() != ""}

    def get_val(*aliases, default=None):
        for a in aliases:
            norm_a = clean(a)
            if norm_a in data_norm:
                val = data_norm[norm_a]
                if val and val.lower() not in ("none", "null", "nan", ""):
                    return val
        return default

    # Clean numeric helper
    def clean_num(val):
        if val is None:
            return None
        s = str(val).strip()
        if not s or s.lower() in ("none", "null", "nan"):
            return None
        # Handle addition expressions like "908 + 34" or "6230 + 228"
        if "+" in s:
            parts = [re.sub(r"[^\d\.]", "", p).strip() for p in s.split("+")]
            try:
                total = sum(float(p) for p in parts if p)
                return int(total) if total.is_integer() else total
            except Exception:
                pass
        # Remove commas, currency symbols, and unit suffixes
        cleaned = s.replace(",", "").strip()
        # Match weight suffixes like "15057 kg" or "07 MT"
        kg_m = re.match(r"^([\d\.]+)\s*(?:kg|kgs|mt|metric\s*ton)$", cleaned, re.IGNORECASE)
        if kg_m:
            try:
                num = float(kg_m.group(1))
                if "mt" in cleaned.lower():
                    num = num * 1000
                return int(num) if num.is_integer() else num
            except Exception:
                pass
        cleaned_no_unit = re.sub(r"[^\d\.]", "", cleaned)
        if cleaned_no_unit:
            try:
                f = float(cleaned_no_unit)
                return int(f) if f.is_integer() else f
            except ValueError:
                pass
        return s

    # Base GR fields
    grno = get_val("grno", "grno (*)", "gr number", "bilty no", "bilty number", "lr no", "lr number", "consignment no", "cn no")
    grdt = get_val("grdt", "grdt *", "gr date", "bilty date", "lr date", "booking date", "date")
    stockdt = get_val("stockdt", "stockdt ", "stock date", "entry date", default=grdt)
    branch = get_val("branchrefcode", "branch", "branch code")
    org = get_val("orgrefcode", "from", "origin", "from station", "booking station")
    dest = get_val("destrefcode", "to", "destination", "to station", "delivery station")
    cngr = get_val("cngr", "cngr *", "consignor", "sender", "shipper", "consignor name", "from party")
    cnge = get_val("cnge", "cnge *", "consignee", "receiver", "consignee name", "to party")
    cngrgst = get_val("cngrgstno", "cngrgstno *", "consignor gst", "consignor gstin", "sender gst")
    cngegst = get_val("cngegstno", "cngegstno *", "consignee gst", "consignee gstin", "receiver gst")
    packing = get_val("packing", "packaging", "package type")
    pmark = get_val("pmark", "private mark", "p mark", "brand mark", "seal no", "seal")
    goods = get_val("goods", "goods description", "commodity", "item description", "material")
    freight = clean_num(get_val("freight", "freight  *", "freight amount", "basic freight", "total freight", "freight charge", "total_freight", "basic_freight", "total freight charge"))
    if freight is None or freight == "":
        freight = 0

    valgoods = clean_num(get_val("valgoods", "value of goods", "declared value", "goods value", "invoice value"))
    oamount_raw = clean_num(get_val("oamount", "total invoice amount", "gross invoice value", "grand total", "total invoice value", "total amount"))
    if oamount_raw is not None and oamount_raw != "" and oamount_raw != 0:
        oamount = oamount_raw
    elif valgoods is not None and valgoods != "" and valgoods != 0:
        oamount = valgoods
    elif oamount_raw is not None and oamount_raw != "":
        oamount = oamount_raw
    else:
        oamount = clean_num(get_val("other amount", "other charges", "hamali", "loading charges", "unloading charges", "aoc", "labour", "st charge", "st. charge", "statistical charge", "misc charges", "misc", "ch post")) or 0

    cgst = clean_num(get_val("cgst", "cgst amount", "central gst"))
    sgst = clean_num(get_val("sgst", "sgst amount", "state gst"))
    igst = clean_num(get_val("igst", "igst amount", "integrated gst"))
    pkgs = clean_num(get_val("pckgs", "bookedpckgs", "stockpckgs", "stockpkgs", "packages", "pkgs", "quantity", "qty", "no of packages", "no of articles"))
    order_wt = clean_num(get_val("Order Weight", "order weight", "order_weight", "order wt"))
    aweight = clean_num(get_val("aweight", "bookedaweight", "stockaweight", "actual weight", "actual wt", "act wt", "weight", "gross weight", "Actual Wt"))
    cweight = clean_num(get_val("cweight", "bookedcweight", "stockcweight", "charged weight", "charged wt", "chg wt", "Chargable wt", default=aweight))
    contract_wt = clean_num(get_val("Contract wt", "contract wt", "contract_wt", "contract weight"))
    extra_mt = clean_num(get_val("Extra Mt", "extra mt", "extra_mt"))
    eway = get_val("ewaybillno", "eway bill no", "e-way bill", "ewb no")
    invno = get_val("invoiceno", "invoice no", "bill no", "invoice number")
    invdt = get_val("invoiedt", "invoice date", "bill date", default=grdt)

    vehno = get_val("Vehicle No *", "Vehicle No", "vehicle no", "truck no", "lorry no", "veh no", "reg no", "registration no", "rc no")
    raw_vehtype = get_val("Vehicle Type *", "Vehicle Type", "vehicle type", "truck type", "lorry type", "body type", "vehicle category", "category", default="Market")
    vehtype = "Market" if not raw_vehtype or str(raw_vehtype).strip() in ("", "None", "none", "null") else str(raw_vehtype).strip()
    if vehtype.upper() == "MARKET":
        vehtype = "Market"
    driver = get_val("Driver Name *", "Driver Name", "driver name", "driver", "pilot", "owner/driver name", "owner or driver name", "driver/owner name", "owner name", "driver_name")
    mobile = get_val("Mobile no   *", "Mobile no *", "mobile no", "driver mobile", "phone no", "mobile", "contact no", "driver_mobile", "driver phone")
    license = get_val("Liscense No *", "Liscense No", "license no", "dl no", "driving license", "licence no", "driving licence no", "driving licence number", "dl number", "license_no")
    valid_up_to = get_val("Valid Up to *", "Valid Up to", "valid up to", "valid upto", "fitness valid", "permit valid", "license valid", "dl valid till", "valid till", "valid_upto")
    loading_date = get_val("Loading Start date *", "Loading Start date", "loading start date", "loading date", "dispatch date", default=grdt)
    customer = get_val("Customer Name *", "Customer Name", "customer name", "customer", "party name", "billed to", "account name", default=cngr)
    lrno = get_val("grno (*)", "grno", "LR No *", "LR No", "lr no", "lr number", "lorry receipt no", "lr #", default=grno)
    bnflr = get_val("BNF LR No", "bnf lr no", "bnf lr", "bnf no")
    dept = get_val("Depatment Name", "department name", "department", "dept", "depatment name")
    counter_name = get_val("Counter name", "counter name", "counter", "booking counter", "branchrefcode", "branch", default="delhi")
    transit_days = clean_num(get_val("Transit Days", "transit days", "transit_days", default=2))
    grtype = get_val("grtype", "grtype(Don’t know)", "grtype(don't know)", "payment type", "pay type", "paid type")
    valid_upto = get_val("Valid Upto", "valid upto", "valid up to", "ewb valid upto", default=valid_up_to)
    branch = get_val("branchrefcode", "branch", "branch code", "counter", "booking counter")

    # Derivations & fallbacks for the 15 affected fields
    rec_val = clean_num(get_val("received", "amount received", "received amount", "advance received", "rcvd"))
    received = 0 if (rec_val is None or rec_val == "") else rec_val

    adv_val = clean_num(get_val("advance", "advance amount", "driver advance", "adv"))
    advance = 0 if (adv_val is None or adv_val == "") else adv_val

    # collectionstncode: Station code or city of origin/dispatch (from "From" station on LR or dispatch PIN/city)
    coll_stn = get_val("collectionstncode", "collection station", "collection station code", "collection stn code", "coll stn")
    if not coll_stn:
        coll_stn = org or branch
        if not coll_stn:
            pay_term = str(grtype or "").strip().upper()
            is_to_pay = pay_term in ("T", "TO PAY", "TOPAY", "TO-PAY") or "TO PAY" in pay_term or pay_term.startswith("TO PAY")
            if is_to_pay:
                coll_stn = dest or org or branch
            else:
                coll_stn = org or branch or dest

    # ftl: Vehicle load type ('FTL' if dedicated truck/32 FT/7 MT/full truck load, 'LTL' if part load, or 'Y'/'N')
    raw_ftl = get_val("ftl", "full truck load", "ftl flag", "load type")
    if raw_ftl:
        ftl_str = str(raw_ftl).strip().upper()
        if ftl_str in ("FTL", "LTL", "Y", "N"):
            ftl = ftl_str
        elif "FTL" in ftl_str or "FULL" in ftl_str or "32" in ftl_str or ftl_str.startswith("Y") or "7 MT" in ftl_str:
            ftl = "FTL"
        elif "LTL" in ftl_str or "PART" in ftl_str or ftl_str.startswith("N"):
            ftl = "LTL"
        else:
            ftl = raw_ftl
    else:
        ftl = "N"

    # custrefcode: Customer reference / account / party code (defaults to CM001 if not found)
    custref = get_val("custrefcode", "customer ref code", "customer code", "cust code", "party code", "account code", "party no")
    if not custref:
        custref = "CM001"

    # staxpaidby: 'C' (Consignor), 'E' (Consignee), 'T' (Transporter)
    raw_stax = get_val("staxpaidby", "service tax paid by", "stax paid by", "gst paid by", "tax paid by")
    if raw_stax:
        stax_str = str(raw_stax).strip().upper()
        staxpaidby = "E" if (stax_str.startswith("E") or "CONSIGNEE" in stax_str) else ("T" if (stax_str.startswith("T") or "TRANSPORTER" in stax_str) else "C")
    else:
        pay_term = str(grtype or "").strip().upper()
        is_to_pay = pay_term in ("T", "TO PAY", "TOPAY", "TO-PAY") or "TO PAY" in pay_term or pay_term.startswith("TO PAY")
        staxpaidby = "E" if is_to_pay else "C"

    # dlvtype: 'G' (Godown) or 'D' (Door)
    raw_dlv = get_val("dlvtype", "delivery type", "dlv type", "delivery mode")
    if raw_dlv:
        dlv_str = str(raw_dlv).strip().upper()
        dlvtype = "D" if (dlv_str.startswith("D") or "DOOR" in dlv_str) else "G"
    else:
        dlvtype = "G"

    # stock packages & weights matching booked values
    stock_pkgs = clean_num(get_val("stockpckgs", "stockpkgs", "stock packages", "stock qty", "stock quantity"))
    if stock_pkgs is None or stock_pkgs == "":
        stock_pkgs = pkgs or 0

    stock_awt = clean_num(get_val("stockaweight", "stock actual weight", "stock act wt", "stock weight"))
    if stock_awt is None or stock_awt == "":
        stock_awt = aweight or 0

    stock_cwt = clean_num(get_val("stockcweight", "stock charged weight", "stock chg wt"))
    if stock_cwt is None or stock_cwt == "":
        stock_cwt = cweight or aweight or 0

    # Interstate vs Intra-state Tax Handling
    is_interstate = False
    if igst is not None and isinstance(igst, (int, float)) and igst > 0:
        is_interstate = True
    else:
        cngr_gst_clean = re.sub(r'[^0-9]', '', str(cngrgst or "")[:2])
        cnge_gst_clean = re.sub(r'[^0-9]', '', str(cngegst or "")[:2])
        if cngr_gst_clean and cnge_gst_clean and len(cngr_gst_clean) == 2 and len(cnge_gst_clean) == 2:
            if cngr_gst_clean != cnge_gst_clean:
                is_interstate = True
        elif org and dest and str(org).strip().upper() != str(dest).strip().upper():
            is_interstate = True

    if is_interstate:
        cgst = 0
        sgst = 0
        if igst is None or igst == "":
            total_tax = clean_num(get_val("tax", "gst", "total tax", "tax amount", "gst amount"))
            if total_tax and isinstance(total_tax, (int, float)) and total_tax > 0:
                igst = total_tax
            else:
                igst = 0
    else:
        if igst is None or igst == "":
            igst = 0
        if cgst is None and sgst is None:
            total_tax = clean_num(get_val("tax", "gst", "total tax", "tax amount", "gst amount"))
            if total_tax and isinstance(total_tax, (int, float)) and total_tax > 0:
                half = round(total_tax / 2, 2)
                cgst = int(half) if half.is_integer() else half
                sgst = int(half) if half.is_integer() else half
            else:
                cgst = 0
                sgst = 0
        else:
            if cgst is None or cgst == "":
                cgst = 0
            if sgst is None or sgst == "":
                sgst = 0

    val_map = {
        "stockdt": stockdt,
        "stockdt ": stockdt,
        "branchrefcode": branch,
        "grno": grno,
        "grno (*)": grno,
        "grdt": grdt,
        "grdt *": grdt,
        "grtype": grtype,
        "grtype(Don’t know)": grtype,
        "Customer Name *": customer,
        "LR No *": lrno,
        "BNF LR No": bnflr,
        "Depatment Name": dept,
        "Counter name": counter_name,
        "Transit Days": transit_days,
        "orgrefcode": org,
        "destrefcode": dest,
        "cngr": cngr,
        "cngr *": cngr,
        "cnge": cnge,
        "cnge *": cnge,
        "cngrgstno": cngrgst,
        "cngrgstno *": cngrgst,
        "cngegstno": cngegst,
        "cngegstno *": cngegst,
        "productcode": get_val("productcode"),
        "packing": packing,
        "pmark": pmark,
        "goods": goods,
        "Vehicle No *": vehno,
        "Vehicle Type *": vehtype,
        "Driver Name *": driver,
        "Mobile no   *": mobile,
        "Liscense No *": license,
        "Valid Up to *": valid_up_to,
        "Loading Start date *": loading_date,
        "freight": freight,
        "freight  *": freight,
        "oamount": oamount,
        "cgst": cgst,
        "sgst": sgst,
        "igst": igst,
        "received": received,
        "advance": advance,
        "collectionstncode": coll_stn,
        "ftl": ftl,
        "pckgs": pkgs,
        "bookedpckgs": pkgs,
        "Order Weight": order_wt,
        "aweight": aweight,
        "bookedaweight": aweight,
        "cweight": cweight,
        "bookedcweight": cweight,
        "Contract wt": contract_wt,
        "Extra Mt": extra_mt,
        "custrefcode": custref,
        "staxpaidby": staxpaidby,
        "dlvtype": dlvtype,
        "stockpckgs": stock_pkgs,
        "stockpkgs": stock_pkgs,
        "stockaweight": stock_awt,
        "stockcweight": stock_cwt,
        "ewaybillno": eway,
        "Valid Upto": valid_upto,
        "invoiceno": invno,
        "invoiedt": invdt,
        "valgoods": valgoods,
        "viaborder": get_val("viaborder")
    }

    norm_val_map = {clean(k): v for k, v in val_map.items()}
    row = []
    for h in headers:
        v = val_map.get(h)
        if v is None and h is not None:
            v = norm_val_map.get(clean(str(h)))
        if v is not None and isinstance(v, str):
            v_str = v.strip()
            if not v_str or v_str.lower() in ("none", "null", "nan"):
                v = None
            elif v_str.isdigit():
                v = int(v_str)
            else:
                try:
                    v_float = float(v_str)
                    if v_float.is_integer():
                        v = int(v_float)
                except ValueError:
                    pass
        row.append(v)
    return row


class KeyValuePair(BaseModel):
    key: str
    value: str


class GeminiOCRResponse(BaseModel):
    document_title: str
    key_value_pairs: list[KeyValuePair]
    confidence_notes: str


class ParsedDocument(BaseModel):
    document_title: str
    data: dict[str, str]
    key_value_pairs: list[KeyValuePair]
    confidence_notes: str
    created_at: str | None = None
    edited_at: str | None = None
    exported_at: str | None = None
    deleted_at: str | None = None
    current_version: int = 1
    versions: list[dict[str, Any]] = Field(default_factory=list)
    preview_image: str | None = None
    file_id: str | None = None
    upload_id: str | None = None
    saved_filename: str | None = None
    file_path: str | None = None
    file_url: str | None = None
    preview_url: str | None = None
    page_count: int = 1
    preview_pages: list[str] = Field(default_factory=list)


class ComparisonInfo(BaseModel):
    headers: list[str] = []
    fields: list[str] = []
    groups: dict[str, dict[str, str]] = {}


class SingleDocumentExport(BaseModel):
    model_config = ConfigDict(extra="allow")
    filename: str | None = "document.jpg"
    document_title: str | None = "Handwritten Document"
    data: dict[str, Any] = Field(default_factory=dict)
    comparison_info: ComparisonInfo | None = None
    created_at: str | None = None
    edited_at: str | None = None
    exported_at: str | None = None
    deleted_at: str | None = None
    current_version: int | None = 1
    versions: list[Any] = Field(default_factory=list)
    edit_history: list[Any] = Field(default_factory=list)

    @field_validator("filename", mode="before")
    @classmethod
    def _validate_filename(cls, v):
        return v if (v and isinstance(v, str) and v.strip()) else "document.jpg"

    @field_validator("document_title", mode="before")
    @classmethod
    def _validate_title(cls, v):
        return v if (v and isinstance(v, str) and v.strip()) else "Handwritten Document"

    @field_validator("data", mode="before")
    @classmethod
    def _validate_data(cls, v):
        return v if isinstance(v, dict) else {}


def _get_doc_data(doc: SingleDocumentExport | dict) -> dict[str, Any]:
    if isinstance(doc, dict):
        d = doc.get("data")
        if isinstance(d, dict) and d:
            return d
        return {k: str(v) for k, v in doc.items() if k not in ("filename", "document_title", "comparison_info")}
    if hasattr(doc, "data") and isinstance(doc.data, dict) and doc.data:
        return doc.data
    if hasattr(doc, "model_extra") and doc.model_extra:
        return doc.model_extra
    if hasattr(doc, "model_dump"):
        dumped = doc.model_dump()
        d = dumped.get("data")
        if isinstance(d, dict) and d:
            return d
        return {k: str(v) for k, v in dumped.items() if k not in ("filename", "document_title", "comparison_info")}
    return {}


class ExcelExportRequest(BaseModel):
    documents: list[SingleDocumentExport] = []
    format_type: str = "gr_bnf_49"  # Default is "gr_bnf_49" (49 cols including RED columns)
    document_title: str | None = None
    data: dict[str, Any] | None = None
    comparison_info: ComparisonInfo | None = None
    user_name: str | None = None


def get_local_ip() -> str:
    """Detects active LAN IPv4 address."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


# --- ROUTE 1: Web Component Dashboard ---
@app.get("/")
@app.get("/web")
def serve_web_component():
    index_file = os.path.join(STATIC_DIR, "index.html")
    if os.path.exists(index_file):
        return FileResponse(
            index_file,
            media_type="text/html",
            headers={
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "Pragma": "no-cache",
                "Expires": "0"
            }
        )
    return {
        "status": "online",
        "service": "OCR to Excel Dual-Component Studio",
        "model": MODEL_NAME,
        "web_component": "Place index.html in static/"
    }


# --- ROUTE 2: API Health Check ---
@app.get("/api/health")
def health_check():
    return {
        "status": "online",
        "service": "OCR to Excel Dual Engine",
        "model": MODEL_NAME,
        "local_ip": get_local_ip(),
        "port": 8000
    }


# --- ROUTE 3: Android APK Download ---
@app.get("/download-apk")
def download_apk():
    apk_file = _resolve_apk_path() or APK_PATH
    if apk_file and os.path.exists(apk_file):
        return FileResponse(
            apk_file,
            filename="ocr_to_excel.apk",
            media_type="application/vnd.android.package-archive",
            headers={"Content-Disposition": 'attachment; filename="ocr_to_excel.apk"'}
        )
    raise HTTPException(status_code=404, detail="APK build not found on server.")


def _resolve_user_from_request(
    authorization: str | None = None,
    user_id: str | None = None,
    user_mobile: str | None = None,
    user_name: str | None = None
) -> dict[str, str]:
    """
    Resolves the authenticated user context from session token, user_id, or mobile number.
    Returns dict with keys: user_id, user_mobile, user_name.
    """
    resolved_id = (user_id or "").strip()
    resolved_mobile = (user_mobile or "").strip()
    resolved_name = (user_name or "").strip()

    # 1. First attempt to resolve via active session token
    if authorization:
        session_user = auth_service.get_session_user(authorization)
        if session_user:
            resolved_id = session_user.get("user_id") or resolved_id
            resolved_mobile = session_user.get("mobile") or resolved_mobile
            resolved_name = session_user.get("name") or resolved_name

    # 2. If mobile is present, standardize and look up in registered users.json
    if resolved_mobile:
        clean_mob = re.sub(r"\D", "", resolved_mobile)
        if clean_mob.startswith("91") and len(clean_mob) == 12:
            clean_mob = clean_mob[2:]
        elif clean_mob.startswith("0") and len(clean_mob) == 11:
            clean_mob = clean_mob[1:]
        resolved_mobile = clean_mob

        users = auth_service._load_users()
        if clean_mob in users:
            u_entry = users[clean_mob]
            resolved_id = u_entry.get("id") or resolved_id
            resolved_name = resolved_name or u_entry.get("name") or "Logistics User"

    # 3. If only user_id is present, look up by ID in registered users.json
    elif resolved_id:
        users = auth_service._load_users()
        for mob_key, u_entry in users.items():
            if u_entry.get("id") == resolved_id:
                resolved_mobile = mob_key
                resolved_name = resolved_name or u_entry.get("name") or "Logistics User"
                break

    return {
        "user_id": resolved_id,
        "user_mobile": resolved_mobile,
        "user_name": resolved_name or "Logistics User"
    }


# --- ROUTE 4: Image Extraction API (Web & Android) ---
@app.post("/extract-handwriting", response_model=ParsedDocument)
async def extract_handwriting(
    file: UploadFile = File(...),
    custom_prompt: str | None = Form(default=None),
    user_id: str | None = Form(default=None),
    user_mobile: str | None = Form(default=None),
    user_name: str | None = Form(default=None),
    authorization: str | None = Header(default=None),
):
    actor = _resolve_user_from_request(
        authorization=authorization,
        user_id=user_id,
        user_mobile=user_mobile,
        user_name=user_name
    )
    print(f"\n[Step 1/5] Received file: '{file.filename}' (Content-Type: '{file.content_type}')")

    image_bytes = await file.read()
    raw_upload_bytes = image_bytes
    print(f"[Step 2/5] Read image file ({len(image_bytes)} bytes)")

    # Enforce maximum allowed file size limit of 10 MB per file
    MAX_FILE_SIZE_BYTES = 10 * 1024 * 1024
    if len(image_bytes) > MAX_FILE_SIZE_BYTES:
        size_mb = len(image_bytes) / (1024 * 1024)
        print(f"[Size Limit Error] Uploaded file '{file.filename}' ({size_mb:.2f} MB) exceeds 10 MB limit.")
        raise HTTPException(
            status_code=413,
            detail=f"File '{file.filename}' ({size_mb:.2f} MB) exceeds the allowed limit of 10 MB per file. Please upload a file under 10 MB."
        )

    # 1. Strictly validate active_prompt as a string (prevent FastAPI Form parameter leaks)
    if isinstance(custom_prompt, str) and custom_prompt.strip():
        active_prompt = custom_prompt.strip()
        prompt_type = "Custom"
    else:
        active_prompt = DEFAULT_HANDWRITTEN_OCR_PROMPT
        prompt_type = "Default Handwritten OCR"

    # 2. Determine safe MIME type
    mime_type = file.content_type
    lower_name = (file.filename or "").lower()
    if not mime_type or mime_type == "application/octet-stream":
        if lower_name.endswith(".jpg") or lower_name.endswith(".jpeg"):
            mime_type = "image/jpeg"
        elif lower_name.endswith(".webp"):
            mime_type = "image/webp"
        elif lower_name.endswith(".pdf"):
            mime_type = "application/pdf"
        else:
            mime_type = "image/png"
    elif lower_name.endswith(".pdf") or "pdf" in (mime_type or "").lower():
        mime_type = "application/pdf"

    # 3. Optimize high-resolution phone images, render PDF previews, and preserve orientation
    is_yellow_image = False
    preview_image_data_url = None
    pdf_preview_bytes = None
    pdf_all_preview_bytes = []
    pdf_page_count = 1
    target_page_idx = 0

    if mime_type == "application/pdf":
        print(f"[DocType] Classified as PDF document ({len(image_bytes)} bytes). Passing directly to Gemini.")
        try:
            import fitz
            pdf_doc = fitz.open(stream=image_bytes, filetype="pdf")
            pdf_page_count = len(pdf_doc)
            print(f"[PDF Detection] Document contains {pdf_page_count} page(s).")
            if pdf_page_count > 0:
                target_page_idx = 0
                for p_idx, p in enumerate(pdf_doc):
                    txt_low = p.get_text().lower()
                    if any(w in txt_low for w in ["consignment", "lorry receipt", "c note", "bilty", "cngr"]):
                        target_page_idx = p_idx
                        break

                # Render all pages at high-definition 300 DPI for razor-sharp inspection
                for p_idx, p in enumerate(pdf_doc):
                    try:
                        pix = p.get_pixmap(dpi=300)
                        p_bytes = pix.tobytes("jpeg")
                        pdf_all_preview_bytes.append(p_bytes)
                    except Exception as p_ex:
                        print(f"[PDF Preview Error] Failed rendering page {p_idx+1}: {p_ex}")

                if pdf_all_preview_bytes:
                    t_idx = target_page_idx if target_page_idx < len(pdf_all_preview_bytes) else 0
                    pdf_preview_bytes = pdf_all_preview_bytes[t_idx]
                    b64_str = base64.b64encode(pdf_preview_bytes).decode("utf-8")
                    preview_image_data_url = f"data:image/jpeg;base64,{b64_str}"
                    print(f"[PDF Preview] Rendered {len(pdf_all_preview_bytes)} page(s) at 300 DPI (primary page: {t_idx+1})")
        except Exception as ex:
            print(f"[PDF Preview Error]: {ex}")
    else:
        try:
            pil_img = Image.open(io.BytesIO(image_bytes))
            # Auto-orient based on camera EXIF tags so rotated mobile photos aren't sideways
            try:
                pil_img = ImageOps.exif_transpose(pil_img)
            except Exception:
                pass

            is_yellow_image = is_orange_yellow_image(pil_img)
            if is_yellow_image:
                print("[DocType] Classified as Orange/Yellow handwritten bilty (BNF LR No will be forced to blank)")
            else:
                print("[DocType] Classified as White printed consignment page")

            orig_w, orig_h = pil_img.size

            # Preserve high resolution for legible handwriting while keeping within API boundaries
            if max(orig_w, orig_h) > 2600:
                scale = 2400.0 / max(orig_w, orig_h)
                new_size = (int(orig_w * scale), int(orig_h * scale))
                pil_img = pil_img.resize(new_size, Image.Resampling.LANCZOS)

            buf = io.BytesIO()
            if pil_img.mode in ("RGBA", "P"):
                pil_img = pil_img.convert("RGB")
            pil_img.save(buf, format="JPEG", quality=95)
            image_bytes = buf.getvalue()
            mime_type = "image/jpeg"
            b64_str = base64.b64encode(image_bytes).decode("utf-8")
            preview_image_data_url = f"data:image/jpeg;base64,{b64_str}"
            print(f"[Optimize] Ready image: {orig_w}x{orig_h} ({len(image_bytes)} bytes)")
        except Exception as img_err:
            print(f"[Notice] Image resize pass-through: {img_err}")

    print(f"[Step 3/5] Initializing Gemini model ('{MODEL_NAME}') with [{prompt_type}] prompt...")
    model = genai.GenerativeModel(MODEL_NAME)
    print(f"[Step 4/5] Sending request to Gemini API (MIME type: {mime_type})...")

    try:
        response = model.generate_content(
            [
                {"mime_type": mime_type, "data": image_bytes},
                active_prompt,
            ],
            generation_config=genai.GenerationConfig(
                response_mime_type="application/json",
                response_schema=GeminiOCRResponse,
                temperature=0.0,
            ),
            safety_settings=SAFETY_SETTINGS,
        )
        print("[Step 5/5] Response received from Gemini. Parsing JSON into key-value pairs...")
        raw_text = response.text.strip()
        if raw_text.startswith("```json"):
            raw_text = raw_text[7:]
        if raw_text.startswith("```"):
            raw_text = raw_text[3:]
        if raw_text.endswith("```"):
            raw_text = raw_text[:-3]
        raw_result = json.loads(raw_text.strip())

        kv_pairs = raw_result.get("key_value_pairs", [])
        data_dict = {item["key"]: item["value"] for item in kv_pairs}

        # Document Type Logic for BNF LR No:
        # * Orange/Yellow handwritten-image: Extract only the LR No.; do not treat any number as BNF LR No.
        # * White printed page: If a number is handwritten/penciled at top-left or top-right, treat it as BNF LR No.
        #   If there is no handwritten/pencil number on the white page, leave BNF LR No blank ("").
        if is_yellow_image:
            data_dict["BNF LR No"] = ""
            for item in kv_pairs:
                if item.get("key") == "BNF LR No":
                    item["value"] = ""

        # Sanitize any dummy/placeholder values
        if str(data_dict.get("Mobile no   *") or "").strip() in ("9999999999", "0000000000", "99999 99999"):
            data_dict["Mobile no   *"] = ""

        # Auto-lookup driver details from Master Registry if Vehicle No is present
        v_num = (data_dict.get("Vehicle No *") or data_dict.get("Vehicle No") or "").strip()
        if v_num:
            v_clean = "".join(c for c in v_num.upper() if c.isalnum())
            for reg_k, reg_v in MASTER_DRIVER_REGISTRY.items():
                if "".join(c for c in reg_k.upper() if c.isalnum()) == v_clean:
                    if not data_dict.get("Driver Name *"):
                        data_dict["Driver Name *"] = reg_v.get("driver_name", "")
                    if not data_dict.get("Mobile no   *"):
                        data_dict["Mobile no   *"] = reg_v.get("mobile_no", "")
                    if not data_dict.get("Liscense No *"):
                        data_dict["Liscense No *"] = reg_v.get("license_no", "")
                    if not data_dict.get("Valid Up to *"):
                        data_dict["Valid Up to *"] = reg_v.get("valid_upto", "")
                    if not data_dict.get("Vehicle Category"):
                        data_dict["Vehicle Category"] = reg_v.get("vehicle_category", "Market")
                    if not data_dict.get("Vehicle Type *"):
                        data_dict["Vehicle Type *"] = reg_v.get("vehicle_category", "Market")
                    break

        # Ensure Vehicle Type defaults consistently to "Market"
        current_veh_type = str(data_dict.get("Vehicle Type *") or data_dict.get("Vehicle Category") or "").strip()
        if not current_veh_type or current_veh_type.lower() in ("none", "null", "nan", "") or current_veh_type.upper() == "MARKET":
            data_dict["Vehicle Type *"] = "Market"
            data_dict["Vehicle Category"] = "Market"
        else:
            data_dict["Vehicle Type *"] = current_veh_type
            data_dict["Vehicle Category"] = current_veh_type

        # Auto-lookup Department from ManiFest.xlsx if Customer Name is present
        cust_name = (data_dict.get("Customer Name *") or data_dict.get("cngr *") or "").strip()
        if cust_name and not data_dict.get("Depatment Name"):
            try:
                manifest_map = _load_manifest_data()
                norm_cust = cust_name.upper()
                matched_depts = []
                for m_cust, m_depts in manifest_map.items():
                    if m_cust.upper() in norm_cust or norm_cust in m_cust.upper():
                        matched_depts = m_depts
                        break
                if matched_depts:
                    dest = str(data_dict.get("destrefcode") or "").upper()
                    selected_dept = matched_depts[0]
                    for dept in matched_depts:
                        if dest and dest in dept.upper():
                            selected_dept = dept
                            break
                    data_dict["Depatment Name"] = selected_dept
                    data_dict["department"] = selected_dept
            except Exception as e_dept:
                print(f"[Master] Department auto-lookup notice: {e_dept}")

        # Auto-lookup Counter from BookingCounterMast.xlsx if Counter is empty
        if not data_dict.get("Counter"):
            try:
                counters = _load_counters_data()
                org = str(data_dict.get("orgrefcode") or data_dict.get("branchrefcode") or "").upper()
                selected_counter = counters[0] if counters else "KOLKATA"
                for c in counters:
                    if org and org in c.upper():
                        selected_counter = c
                        break
                data_dict["Counter"] = selected_counter
                data_dict["counter"] = selected_counter
                data_dict["branchrefcode"] = selected_counter
            except Exception as e_cntr:
                print(f"[Master] Counter auto-lookup notice: {e_cntr}")

        # Auto-lookup Consignor & Consignee GSTIN from ManiFest master data
        try:
            _, party_gst_map = _load_manifest_parties()
            cngr_val = str(data_dict.get("cngr *") or data_dict.get("cngr") or data_dict.get("Customer Name *") or "").strip()
            if cngr_val and (not data_dict.get("cngrgstno *") or not str(data_dict.get("cngrgstno *")).strip()):
                matched_gst = _match_party_gst(cngr_val, party_gst_map)
                if matched_gst:
                    data_dict["cngrgstno *"] = matched_gst
                    data_dict["cngrgstno"] = matched_gst

            cnge_val = str(data_dict.get("cnge *") or data_dict.get("cnge") or "").strip()
            if cnge_val and (not data_dict.get("cngegstno *") or not str(data_dict.get("cngegstno *")).strip()):
                matched_cnge_gst = _match_party_gst(cnge_val, party_gst_map)
                if matched_cnge_gst:
                    data_dict["cngegstno *"] = matched_cnge_gst
                    data_dict["cngegstno"] = matched_cnge_gst
        except Exception as e_gst:
            print(f"[Master] Party GST auto-lookup notice: {e_gst}")

        # Enrich the 15 affected fields systematically if empty/missing
        stock_pkgs_val = data_dict.get("stockpckgs") or data_dict.get("stockpkgs") or data_dict.get("bookedpckgs") or data_dict.get("packages") or data_dict.get("pkgs") or data_dict.get("quantity") or ""
        data_dict["stockpckgs"] = stock_pkgs_val
        data_dict["stockpkgs"] = stock_pkgs_val

        stock_awt_val = data_dict.get("stockaweight") or data_dict.get("bookedaweight") or data_dict.get("actual weight") or data_dict.get("actual wt") or data_dict.get("weight") or ""
        data_dict["stockaweight"] = stock_awt_val

        stock_cwt_val = data_dict.get("stockcweight") or data_dict.get("bookedcweight") or data_dict.get("charged weight") or stock_awt_val
        data_dict["stockcweight"] = stock_cwt_val

        if not data_dict.get("received"):
            data_dict["received"] = "0"
        if not data_dict.get("advance"):
            data_dict["advance"] = "0"

        if not data_dict.get("collectionstncode"):
            coll_orig = data_dict.get("orgrefcode") or data_dict.get("branchrefcode") or data_dict.get("Counter") or data_dict.get("from") or ""
            if coll_orig:
                data_dict["collectionstncode"] = coll_orig
            else:
                pay_term = str(data_dict.get("grtype") or data_dict.get("grtype(Don’t know)") or data_dict.get("Payment Term") or "").strip().upper()
                is_to_pay = pay_term in ("T", "TO PAY", "TOPAY", "TO-PAY") or "TO PAY" in pay_term or pay_term.startswith("TO PAY")
                data_dict["collectionstncode"] = (data_dict.get("destrefcode") or data_dict.get("destination") or data_dict.get("to") or "") if is_to_pay else ""

        raw_ftl = data_dict.get("ftl")
        if raw_ftl:
            u_ftl = str(raw_ftl).strip().upper()
            if u_ftl in ("FTL", "LTL", "Y", "N"):
                data_dict["ftl"] = u_ftl
            elif "FTL" in u_ftl or "32 FT" in u_ftl or "7 MT" in u_ftl or "FULL" in u_ftl or u_ftl.startswith("Y"):
                data_dict["ftl"] = "FTL"
            elif "LTL" in u_ftl or "PART" in u_ftl or u_ftl.startswith("N"):
                data_dict["ftl"] = "LTL"
        else:
            data_dict["ftl"] = "N"

        if not data_dict.get("custrefcode"):
            data_dict["custrefcode"] = data_dict.get("partycode") or data_dict.get("accountcode") or "CM001"

        raw_stax = data_dict.get("staxpaidby")
        if raw_stax:
            u_stax = str(raw_stax).strip().upper()
            data_dict["staxpaidby"] = "E" if (u_stax.startswith("E") or "CONSIGNEE" in u_stax) else ("T" if (u_stax.startswith("T") or "TRANSPORTER" in u_stax) else "C")
        else:
            pay_term = str(data_dict.get("grtype") or data_dict.get("grtype(Don’t know)") or "").strip().upper()
            is_to_pay = pay_term in ("T", "TO PAY", "TOPAY", "TO-PAY") or "TO PAY" in pay_term or pay_term.startswith("TO PAY")
            data_dict["staxpaidby"] = "E" if is_to_pay else "C"

        raw_dlv = data_dict.get("dlvtype")
        if raw_dlv:
            u_dlv = str(raw_dlv).strip().upper()
            data_dict["dlvtype"] = "D" if (u_dlv.startswith("D") or "DOOR" in u_dlv) else "G"
        else:
            data_dict["dlvtype"] = "G"

        fr_val = data_dict.get("freight  *") or data_dict.get("freight") or data_dict.get("Freight Charge") or data_dict.get("basic freight") or ""
        if fr_val:
            data_dict["freight  *"] = fr_val
            data_dict["freight"] = fr_val
        else:
            data_dict["freight  *"] = "0"
            data_dict["freight"] = "0"

        oamt_raw = data_dict.get("oamount")
        if not oamt_raw or str(oamt_raw).strip() in ("", "0"):
            fallback_oamt = data_dict.get("valgoods") or data_dict.get("declared value") or data_dict.get("other amount") or data_dict.get("other charges") or data_dict.get("hamali") or "0"
            data_dict["oamount"] = fallback_oamt

        ig_val = str(data_dict.get("igst") or "").strip()
        has_igst = ig_val and ig_val not in ("0", "0.0", "0.00", "none", "null")
        if has_igst:
            data_dict["cgst"] = "0.00"
            data_dict["sgst"] = "0.00"
        else:
            if not data_dict.get("cgst"):
                data_dict["cgst"] = "0"
            if not data_dict.get("sgst"):
                data_dict["sgst"] = "0"
            if not data_dict.get("igst"):
                data_dict["igst"] = "0.00"

        # Sync kv_pairs with fully enriched data_dict
        kv_pairs = [{"key": k, "value": v} for k, v in data_dict.items()]


        now_ts = file_lifecycle_service.get_current_timestamp()
        now_dt = datetime.now()
        upload_id = f"LR_{now_dt.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"

        # Extract and sanitize LR number from extracted fields
        extracted_lr = str(
            data_dict.get("lrno")
            or data_dict.get("LR No *")
            or data_dict.get("BNF LR No")
            or data_dict.get("grno")
            or data_dict.get("grno (*)")
            or data_dict.get("bilty_no")
            or ""
        ).strip()
        lr_clean = re.sub(r'[^a-zA-Z0-9]', '', extracted_lr)[:25]
        lr_tag = f"_LR_{lr_clean}" if lr_clean else ""

        # Clean original filename
        orig_base = os.path.basename(file.filename or "uploaded_doc")
        orig_name_part, orig_ext = os.path.splitext(orig_base)
        if not orig_ext:
            orig_ext = ".pdf" if mime_type == "application/pdf" else ".jpg"
        clean_name = re.sub(r'[^a-zA-Z0-9_\-\.]', '_', orig_name_part)[:35]

        unique_filename = f"{upload_id}{lr_tag}_{clean_name}{orig_ext}"

        # Bytes to save: use original bytes
        bytes_to_save = raw_upload_bytes if raw_upload_bytes else image_bytes

        # 1. Save directly into backend/export/upload_LR/ with unique descriptive timestamped filename (never overwritten)
        snapshot_lr_filename, snapshot_lr_path = audit_snapshot.save_uploaded_lr_document(
            file_bytes=bytes_to_save,
            original_filename=file.filename,
            lr_no=lr_clean
        )
        print(f"[Upload Vault] Successfully saved LR document to {snapshot_lr_path}")

        # If document is a PDF, persist all rendered 300 DPI preview pages directly into backend/export/upload_LR/
        preview_saved_url = None
        preview_pages_urls = []
        if mime_type == "application/pdf" and pdf_all_preview_bytes:
            for p_idx, p_bytes in enumerate(pdf_all_preview_bytes):
                # Page 1 preview uses original naming for backward compatibility
                page_suffix = "_preview.jpg" if p_idx == 0 else f"_page_{p_idx + 1}.jpg"
                p_filename = f"{upload_id}{lr_tag}_{clean_name}{page_suffix}"
                p_file_path = os.path.join(UPLOAD_LR_DIR, p_filename)
                try:
                    with open(p_file_path, "wb") as f_prev:
                        f_prev.write(p_bytes)
                    p_url = f"/uploads/{p_filename}"
                    preview_pages_urls.append(p_url)
                except Exception as e_prev:
                    print(f"[Upload Vault Error] Failed to save page {p_idx+1} preview: {e_prev}")
            if preview_pages_urls:
                t_idx = target_page_idx if target_page_idx < len(preview_pages_urls) else 0
                preview_saved_url = preview_pages_urls[t_idx]
                print(f"[Upload Vault] Successfully saved {len(preview_pages_urls)} PDF 300 DPI preview image(s) (primary: {preview_saved_url})")
        elif preview_saved_url:
            preview_pages_urls = [preview_saved_url]

        reg_entry = None
        try:
            reg_entry = file_lifecycle_service.record_file_creation(
                file_path=snapshot_lr_path,
                file_type="bilty_image" if mime_type != "application/pdf" else "bilty_pdf",
                file_bytes=bytes_to_save,
                file_id=upload_id,
                user_name=actor.get("user_name") or "Logistics User",
                user_mobile=actor.get("user_mobile") or "",
                user_id=actor.get("user_id") or None,
                custom_meta={
                    "extracted_fields": len(data_dict),
                    "upload_id": upload_id,
                    "lr_no": lr_clean,
                    "saved_filename": snapshot_lr_filename,
                    "original_filename": file.filename,
                    "snapshot_path": snapshot_lr_path,
                    "user_id": actor.get("user_id") or "",
                    "user_mobile": actor.get("user_mobile") or "",
                    "created_by": actor.get("user_name") or "Logistics User",
                },
                initial_data=data_dict
            )
        except Exception as ex:
            print(f"[Lifecycle] Non-critical image registration error: {ex}")

        v1_list = reg_entry.get("versions", []) if reg_entry else [
            {
                "version": 1,
                "timestamp": now_ts,
                "action": "create",
                "details": "Document created from OCR",
                "snapshot_data": data_dict
            }
        ]

        rel_saved_path = os.path.relpath(snapshot_lr_path, BASE_DIR).replace("\\", "/")

        parsed_output = ParsedDocument(
            document_title=raw_result.get("document_title", "Handwritten Document"),
            data=data_dict,
            key_value_pairs=kv_pairs,
            confidence_notes=raw_result.get("confidence_notes", ""),
            created_at=now_ts,
            edited_at=None,
            exported_at=None,
            deleted_at=None,
            current_version=1,
            versions=v1_list,
            preview_image=preview_image_data_url,
            file_id=upload_id,
            upload_id=upload_id,
            saved_filename=snapshot_lr_filename,
            file_path=rel_saved_path,
            file_url=f"/snapshots/{snapshot_lr_filename}",
            preview_url=preview_saved_url or f"/snapshots/{snapshot_lr_filename}",
            page_count=pdf_page_count if (mime_type == "application/pdf" and pdf_page_count > 0) else 1,
            preview_pages=preview_pages_urls,
        )

        print(f"[Success] Extracted {len(data_dict)} key-value pair(s)")
        print(f"[Output Title] {parsed_output.document_title}")
        return parsed_output

    except Exception as e:
        print(f"[Error] Inference pipeline failed: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Inference pipeline failed: {str(e)}")


def _build_workbook_for_docs(
    docs: list[SingleDocumentExport],
    format_type: str = "gr_bnf_49",
    user_name: str = "Logistics User",
    export_id: str | None = None,
    include_audit_meta: bool = True
) -> tuple[openpyxl.Workbook, bytes, str, str]:
    wb = openpyxl.Workbook()

    now = datetime.now()
    export_date = now.strftime("%d-%b-%Y")
    export_time = now.strftime("%I:%M:%S %p")
    exported_at = now.strftime("%d-%b-%Y %I:%M:%S %p")

    # Styling Palettes
    header_fill = PatternFill(start_color="1565C0", end_color="1565C0", fill_type="solid")
    header_font = Font(name="Calibri", size=11, bold=True, color="FFFFFF")
    title_font = Font(name="Calibri", size=13, bold=True, color="0D47A1")
    title_fill = PatternFill(start_color="E3F2FD", end_color="E3F2FD", fill_type="solid")
    zebra_fill = PatternFill(start_color="F8FAFC", end_color="F8FAFC", fill_type="solid")
    data_font = Font(name="Calibri", size=10)
    key_font = Font(name="Calibri", size=10, bold=True, color="1E293B")
    thin_border = Border(
        left=Side(style="thin", color="CBD5E1"),
        right=Side(style="thin", color="CBD5E1"),
        top=Side(style="thin", color="CBD5E1"),
        bottom=Side(style="thin", color="CBD5E1"),
    )
    center_align = Alignment(horizontal="center", vertical="center", wrap_text=True)
    left_align = Alignment(horizontal="left", vertical="center", wrap_text=True)

    # Check export format requested
    fmt = (format_type or "").lower().strip()

    # Auto-detect format if not explicitly set (Default to full 49-col BNF format with RED columns)
    if not fmt or fmt == "auto":
        is_gr = False
        for d in docs:
            k_lower = "".join(d.data.keys()).lower()
            if any(term in k_lower for term in ("grno", "gr_no", "bilty", "lr", "cngr", "cnge", "consignor", "consignee", "eway", "freight", "vehicle", "driver")):
                is_gr = True
                break
        fmt = "gr_bnf_49" if is_gr else "dynamic"

    # Clean uncolored styling (no yellow, no red fills)
    no_fill = PatternFill(fill_type=None)
    header_font_clean = Font(name="Calibri", size=10, bold=True, color="000000")

    # =========================================================================
    # OPTION 1: Exact 38-Column Import Format (ImportGRStockExcelFormat.xlsx)
    # =========================================================================
    if fmt in ("gr_stock_38", "gr_stock", "importgrstock"):
        if os.path.exists(TEMPLATE_STOCK_38):
            wb = openpyxl.load_workbook(TEMPLATE_STOCK_38)
            for sname in list(wb.sheetnames):
                if sname != "Sheet1":
                    wb.remove(wb[sname])
            ws1 = wb["Sheet1"]
            if ws1.max_row > 1:
                ws1.delete_rows(2, ws1.max_row - 1)
            headers = [ws1.cell(1, col_idx).value for col_idx in range(1, ws1.max_column + 1)]
            # Remove all color fills from template headers
            for col_idx in range(1, ws1.max_column + 1):
                cell = ws1.cell(row=1, column=col_idx)
                cell.fill = no_fill
                cell.font = header_font_clean
                cell.alignment = left_align
                cell.border = thin_border
        else:
            ws1 = wb.active
            ws1.title = "Sheet1"
            headers = GR_STOCK_38_HEADERS
            ws1.append(headers)
            ws1.row_dimensions[1].height = 24
            for col_idx in range(1, len(headers) + 1):
                cell = ws1.cell(row=1, column=col_idx)
                cell.fill = no_fill
                cell.font = header_font_clean
                cell.alignment = left_align
                cell.border = thin_border

        for r_idx, doc in enumerate(docs, start=2):
            row_vals = map_to_gr_row(_get_doc_data(doc), headers)
            ws1.append(row_vals)
            ws1.row_dimensions[r_idx].height = 20
            for col_idx in range(1, len(row_vals) + 1):
                c = ws1.cell(row=r_idx, column=col_idx)
                c.font = data_font
                c.border = thin_border
                c.alignment = left_align
                c.fill = no_fill

        for col in ws1.columns:
            max_len = max(len(str(cell.value or '')) for cell in col)
            col_letter = get_column_letter(col[0].column)
            ws1.column_dimensions[col_letter].width = max(13, min(max_len + 3, 38))

    # =========================================================================
    # OPTION 2: Exact 49-Column BNF Import Format (BNF file Modify.xlsx)
    # Includes all 49 Columns with pure clean uncolored styling (no yellow/red)
    # =========================================================================
    elif fmt in ("gr_bnf_50", "gr_bnf_49", "gr_bnf", "bnf"):
        ws1 = wb.active
        ws1.title = "Sheet1"
        ws1.views.sheetView[0].showGridLines = True

        headers = GR_BNF_49_HEADERS

        if include_audit_meta:
            # Rows 1-4: Metadata headers above the table (User Name, Export Date, Export Time, Exported At)
            meta_font = Font(name="Calibri", size=11, bold=True, color="000000")
            ws1.cell(row=1, column=1, value=f"User Name: {user_name}").font = meta_font
            ws1.cell(row=2, column=1, value=f"Export Date: {export_date}").font = meta_font
            ws1.cell(row=3, column=1, value=f"Export Time: {export_time}").font = meta_font
            ws1.cell(row=4, column=1, value=f"Exported At: {exported_at}").font = meta_font
            ws1.row_dimensions[1].height = 20
            ws1.row_dimensions[2].height = 20
            ws1.row_dimensions[3].height = 20
            ws1.row_dimensions[4].height = 20

            header_row_idx = 5
            data_start_row = 6
        else:
            # User Download File: Clean business data only - Row 1 is Column Headers
            header_row_idx = 1
            data_start_row = 2

        # Column Headers
        for col_idx, h in enumerate(headers, start=1):
            cell = ws1.cell(row=header_row_idx, column=col_idx, value=h)
            cell.fill = no_fill
            cell.font = header_font_clean
            cell.alignment = left_align
            cell.border = thin_border
        ws1.row_dimensions[header_row_idx].height = 24

        # Extracted Consignment Data Rows
        for r_offset, doc in enumerate(docs):
            curr_row = data_start_row + r_offset
            row_vals = map_to_gr_row(_get_doc_data(doc), headers)
            for col_idx, val in enumerate(row_vals, start=1):
                c = ws1.cell(row=curr_row, column=col_idx, value=val)
                c.font = data_font
                c.border = thin_border
                c.alignment = left_align
                c.fill = no_fill
            ws1.row_dimensions[curr_row].height = 20

        for col in ws1.columns:
            max_len = 0
            for cell in col:
                if cell.row < header_row_idx:
                    continue
                if cell.value:
                    max_len = max(max_len, len(str(cell.value)))
            col_letter = get_column_letter(col[0].column)
            ws1.column_dimensions[col_letter].width = max(13, min(max_len + 3, 38))

    # =========================================================================
    # OPTION 3: Generic Dynamic Column Format (Non-Transport Documents)
    # =========================================================================
    else:
        distinct_keys = []
        seen_keys = set()
        for d in docs:
            d_data = _get_doc_data(d)
            for k in d_data.keys():
                k_clean = k.strip()
                if k_clean and k_clean not in seen_keys:
                    seen_keys.add(k_clean)
                    distinct_keys.append(k_clean)

        ws1 = wb.active
        ws1.title = "Consolidated Dataset"

        total_cols = max(3 + len(distinct_keys), 4)
        end_col_letter = get_column_letter(total_cols)
        ws1.merge_cells(f"A1:{end_col_letter}1")
        t_cell = ws1["A1"]
        t_cell.value = f"Consolidated Document Records ({len(docs)} Image{'s' if len(docs) > 1 else ''})"
        t_cell.font = title_font
        t_cell.fill = title_fill
        t_cell.alignment = left_align
        ws1.row_dimensions[1].height = 28

        ws1.merge_cells(f"A2:{end_col_letter}2")
        sub_cell = ws1["A2"]
        sub_cell.value = f"Generated on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} • Columns: {len(distinct_keys)} Fields • Single Unified Dataset"
        sub_cell.font = Font(name="Calibri", size=9, italic=True, color="64748B")
        ws1.row_dimensions[2].height = 18

        ws1.append([])

        headers = ["#", "Image File Name", "Document Title", *distinct_keys]
        ws1.append(headers)
        ws1.row_dimensions[4].height = 26

        for col_idx in range(1, len(headers) + 1):
            cell = ws1.cell(row=4, column=col_idx)
            cell.fill = header_fill
            cell.font = header_font
            cell.alignment = center_align if col_idx == 1 else left_align
            cell.border = thin_border

        for r_idx, doc in enumerate(docs, start=1):
            row_num = 4 + r_idx
            d_data = _get_doc_data(doc)
            row_vals = [r_idx, getattr(doc, "filename", "document.jpg"), getattr(doc, "document_title", "Document")]
            for k in distinct_keys:
                row_vals.append(d_data.get(k, ""))

            ws1.append(row_vals)
            ws1.row_dimensions[row_num].height = 22

            for col_idx in range(1, len(row_vals) + 1):
                cell = ws1.cell(row=row_num, column=col_idx)
                cell.font = data_font
                cell.border = thin_border
                cell.alignment = center_align if col_idx == 1 else left_align
                if r_idx % 2 == 0:
                    cell.fill = zebra_fill

        for col in ws1.columns:
            max_len = 0
            col_letter = get_column_letter(col[0].column)
            for cell in col:
                if cell.row in (1, 2):
                    continue
                if cell.value:
                    max_len = max(max_len, len(str(cell.value)))
            ws1.column_dimensions[col_letter].width = max(14, min(max_len + 4, 55))

        # SHEET 2: Comparison View (Side-by-Side Images) - For dynamic non-logistics exports
        if len(docs) > 1 and len(distinct_keys) > 0:
            ws2 = wb.create_sheet(title="Comparison View")
            ws2.merge_cells(f"A1:{get_column_letter(len(docs) + 1)}1")
            ws2["A1"].value = "Side-by-Side Attribute Comparison"
            ws2["A1"].font = title_font
            ws2["A1"].fill = title_fill
            ws2["A1"].alignment = left_align
            ws2.row_dimensions[1].height = 26
            ws2.append([])

            comp_headers = ["Field / Attribute", *[d.filename for d in docs]]
            ws2.append(comp_headers)
            ws2.row_dimensions[3].height = 24

            for col_idx in range(1, len(comp_headers) + 1):
                c = ws2.cell(row=3, column=col_idx)
                c.fill = header_fill
                c.font = header_font
                c.alignment = left_align
                c.border = thin_border

            for r_idx, field in enumerate(distinct_keys, start=1):
                curr_row = 3 + r_idx
                row_data = [field, *[d.data.get(field, "") for d in docs]]
                ws2.append(row_data)
                ws2.row_dimensions[curr_row].height = 20

                for col_idx in range(1, len(row_data) + 1):
                    c = ws2.cell(row=curr_row, column=col_idx)
                    c.font = key_font if col_idx == 1 else data_font
                    c.border = thin_border
                    c.alignment = left_align
                    if r_idx % 2 == 0:
                        c.fill = zebra_fill

            for col in ws2.columns:
                max_len = 0
                col_letter = get_column_letter(col[0].column)
                for cell in col:
                    if cell.row in (1, 2):
                        continue
                    if cell.value:
                        max_len = max(max_len, len(str(cell.value)))
                ws2.column_dimensions[col_letter].width = max(14, min(max_len + 4, 55))

    # Set Workbook Core Properties
    wb.properties.creator = user_name
    wb.properties.title = f"Consignment Export - {len(docs)} Document(s)"
    wb.properties.subject = "Logistics Bilty Import & History"
    wb.properties.created = now
    wb.properties.modified = now

    if include_audit_meta:
        # Append dedicated "History" worksheet with exact 49 BNF columns and metadata
        ws_history = wb.create_sheet(title="History")
        ws_history.views.sheetView[0].showGridLines = True

        # Rows 1-4: Metadata headers above the table (User Name, Export Date, Export Time, Exported At)
        meta_font = Font(name="Calibri", size=11, bold=True, color="000000")
        ws_history.cell(row=1, column=1, value=f"User Name: {user_name}").font = meta_font
        ws_history.cell(row=2, column=1, value=f"Export Date: {export_date}").font = meta_font
        ws_history.cell(row=3, column=1, value=f"Export Time: {export_time}").font = meta_font
        ws_history.cell(row=4, column=1, value=f"Exported At: {exported_at}").font = meta_font
        ws_history.row_dimensions[1].height = 20
        ws_history.row_dimensions[2].height = 20
        ws_history.row_dimensions[3].height = 20
        ws_history.row_dimensions[4].height = 20

        # Row 5: Column Headers (User Name, Export Date, Export Time, Exported At + 49 BNF headers)
        history_meta_cols = ["User Name", "Export Date", "Export Time", "Exported At"]
        history_full_headers = [*history_meta_cols, *GR_BNF_49_HEADERS]

        for c_idx, h in enumerate(history_full_headers, start=1):
            cell = ws_history.cell(row=5, column=c_idx, value=h)
            cell.fill = no_fill
            cell.font = header_font_clean
            cell.alignment = left_align
            cell.border = thin_border
        ws_history.row_dimensions[5].height = 24

        # Rows 6+: Data Rows
        for r_idx, doc in enumerate(docs, start=6):
            doc_data = _get_doc_data(doc)
            gr_49_vals = map_to_gr_row(doc_data, GR_BNF_49_HEADERS)
            row_vals = [user_name, export_date, export_time, exported_at, *gr_49_vals]
            for col_idx, val in enumerate(row_vals, start=1):
                c = ws_history.cell(row=r_idx, column=col_idx, value=val)
                c.font = data_font
                c.border = thin_border
                c.alignment = left_align
                c.fill = no_fill
            ws_history.row_dimensions[r_idx].height = 20

        for col in ws_history.columns:
            max_l = 0
            for cell in col:
                if cell.row < 5:
                    continue
                if cell.value:
                    max_l = max(max_l, len(str(cell.value)))
            col_letter = get_column_letter(col[0].column)
            ws_history.column_dimensions[col_letter].width = max(13, min(max_l + 3, 38))

    # Save to buffer
    buf = io.BytesIO()
    wb.save(buf)
    file_bytes = buf.getvalue()

    if fmt in ("gr_stock_38", "gr_stock", "importgrstock"):
        prefix = "ImportGRStock"
    elif fmt in ("gr_bnf_50", "gr_bnf_49", "gr_bnf", "bnf"):
        prefix = "GR_Import_BNF"
    else:
        prefix = "Consolidated_OCR"

    if not export_id:
        now_dt = datetime.now()
        export_id = f"EXP_{now_dt.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"

    # Extract distinct LR numbers if available in documents
    lr_nums = []
    for d in docs:
        d_map = _get_doc_data(d)
        val = str(d_map.get("lrno") or d_map.get("LR No *") or d_map.get("BNF LR No") or d_map.get("grno") or d_map.get("bilty_no") or "").strip()
        val_clean = re.sub(r'[^a-zA-Z0-9]', '', val)
        if val_clean and val_clean not in lr_nums:
            lr_nums.append(val_clean)

    lr_tag = ""
    if lr_nums:
        if len(lr_nums) <= 2:
            lr_tag = f"_LR_{'_'.join(lr_nums)}"
        else:
            lr_tag = f"_LR_{lr_nums[0]}_plus_{len(lr_nums)-1}"

    filename = f"{prefix}_{export_id}{lr_tag}_{len(docs)}LRs.xlsx"
    return wb, file_bytes, filename, export_id


# --- ROUTE 5: Stylized Excel Generator (openpyxl) ---
@app.post("/generate-excel")
async def generate_excel(req: ExcelExportRequest):
    """
    Generates a single, consolidated .xlsx workbook.
    """
    docs = req.documents
    if not docs:
        if req.data:
            docs = [
                SingleDocumentExport(
                    filename="document_1.jpg",
                    document_title=req.document_title or "Handwritten Document",
                    data=req.data,
                    comparison_info=req.comparison_info,
                )
            ]
        else:
            raise HTTPException(status_code=400, detail="No document data provided for Excel export")

    user_name = req.user_name or "Logistics User"
    wb, file_bytes, filename, export_id = _build_workbook_for_docs(docs, req.format_type or "gr_bnf_49", user_name=user_name, include_audit_meta=False)
    return StreamingResponse(
        io.BytesIO(file_bytes),
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f"attachment; filename={filename}"}
    )


# =========================================================================
# ROUTE 6: AUTHENTICATION & OTP VALIDATION ENDPOINTS
# =========================================================================
class SendOtpRequest(BaseModel):
    mobile: str
    name: str | None = None


class VerifyOtpRequest(BaseModel):
    mobile: str
    otp: str
    name: str | None = None


class DirectLoginRequest(BaseModel):
    mobile: str
    name: str | None = None


@app.post("/api/auth/login")
async def api_direct_login(req: DirectLoginRequest):
    res = auth_service.direct_login(req.mobile, req.name)
    if not res.get("success"):
        raise HTTPException(status_code=400, detail=res.get("error"))
    return res


@app.post("/api/auth/send-otp")
async def api_send_otp(req: SendOtpRequest):
    res = auth_service.send_otp(req.mobile, req.name)
    if not res.get("success"):
        raise HTTPException(status_code=400, detail=res.get("error"))
    return res


@app.post("/api/auth/verify-otp")
async def api_verify_otp(req: VerifyOtpRequest):
    res = auth_service.verify_otp(req.mobile, req.otp, req.name)
    if not res.get("success"):
        raise HTTPException(status_code=400, detail=res.get("error"))
    return res


@app.get("/api/auth/me")
async def api_get_me(authorization: str | None = Header(default=None)):
    user = auth_service.get_session_user(authorization)
    if not user:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return {"authenticated": True, "user": user}


@app.post("/api/auth/logout")
async def api_logout(authorization: str | None = Header(default=None)):
    auth_service.logout_session(authorization)
    return {"success": True, "message": "Logged out successfully"}


# =========================================================================
# ROUTE: MASTER DATA (ManiFest.xlsx, BookingCounterMast.xlsx, Driver Registry)
# =========================================================================
MANIFEST_FILE_PATH = _resolve_project_file("ManiFest.xlsx")
COUNTERS_FILE_PATH = _resolve_project_file("BookingCounterMast.xlsx")

def _clean_party_key(s: str) -> str:
    return "".join(c for c in str(s).lower() if c.isalnum())

KNOWN_BRAND_GSTS: dict[str, str] = {
    "patanjali": "07AAFCP1505P2Z8",
    "himalaya": "29AADFT3025B2ZK",
    "globalmarketing": "29AJYPK4522G1ZR",
    "indrahosiery": "0303AAAFI3511ZG",
    "vescocycle": "03AAOFV6259L1ZJ",
    "hitech": "0303AADFH966966",
    "montecarlo": "0303AAFCM788788",
    "umorthotics": "0303AADCU323323",
    "goldplus": "2929AAICG789789",
    "shreeciment": "27AADFG7889B1Z2"
}

def _load_manifest_parties() -> tuple[list[dict[str, str]], dict[str, str]]:
    parties: list[dict[str, str]] = []
    gst_map: dict[str, str] = dict(KNOWN_BRAND_GSTS)
    if os.path.isfile(MANIFEST_FILE_PATH):
        try:
            wb = openpyxl.load_workbook(MANIFEST_FILE_PATH, data_only=True)
            ws = wb.active
            header_row = [str(c).strip().lower() if c is not None else "" for c in next(ws.iter_rows(min_row=1, max_row=1, values_only=True), [])]
            cust_idx = 3
            dept_idx = 2
            state_idx = 4
            gst_idx = 6
            for idx, h in enumerate(header_row):
                if "customer" in h: cust_idx = idx
                elif "department" in h: dept_idx = idx
                elif "state" in h: state_idx = idx
                elif "gst" in h: gst_idx = idx

            def _is_standard_gst(g: str) -> bool:
                return len(g) == 15 and bool(re.match(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{3}$', g.upper()))

            def _set_gst(k: str, g: str):
                if not k or not g:
                    return
                if k not in gst_map:
                    gst_map[k] = g
                elif _is_standard_gst(g) and not _is_standard_gst(gst_map[k]):
                    gst_map[k] = g

            for row in ws.iter_rows(min_row=2, values_only=True):
                if not row: continue
                cust = str(row[cust_idx]).strip() if len(row) > cust_idx and row[cust_idx] is not None else ""
                dept = str(row[dept_idx]).strip() if len(row) > dept_idx and row[dept_idx] is not None else ""
                state = str(row[state_idx]).strip() if len(row) > state_idx and row[state_idx] is not None else ""
                gst = str(row[gst_idx]).strip() if len(row) > gst_idx and row[gst_idx] is not None else ""
                if gst in ("None", "none", "null", ""): gst = ""
                if cust and cust not in ("None", "none", ""):
                    parties.append({"customer": cust, "department": dept, "state": state, "gst": gst})
                    if gst:
                        _set_gst(_clean_party_key(cust), gst)
                        if dept:
                            _set_gst(_clean_party_key(dept), gst)
                            _set_gst(_clean_party_key(f"{cust} {dept}"), gst)
                            _set_gst(_clean_party_key(f"{cust} {state}"), gst)
        except Exception as ex:
            print(f"[MasterData] Error loading parties from ManiFest.xlsx: {ex}")

    return parties, gst_map

def _match_party_gst(name_or_text: str, gst_map: dict[str, str]) -> str | None:
    if not name_or_text:
        return None
    c = _clean_party_key(name_or_text)
    if c in gst_map:
        return gst_map[c]
    for brand, gst in KNOWN_BRAND_GSTS.items():
        if brand in c:
            return gst
    for k, v in gst_map.items():
        if len(k) >= 5 and (k in c or c in k):
            return v
    return None

def _load_manifest_data() -> dict[str, list[str]]:
    mapping: dict[str, list[str]] = {}
    parties, _ = _load_manifest_parties()
    for p in parties:
        cust = p.get("customer", "")
        dept = p.get("department", "")
        if cust and cust not in ("None", "none", ""):
            if cust not in mapping:
                mapping[cust] = []
            if dept and dept not in ("None", "none", "") and dept not in mapping[cust]:
                mapping[cust].append(dept)

    # Standard curated master customers matching Android MasterDataService
    base_defaults = {
        "HIMALAYA WELLNESS COMPANY": [
            "HIMA-KOLKATA", "HIMALAYA-SILIGURI", "HIMALAYA-RAIPUR", "HIMALAYA-BHIWANDI",
            "HIMALAYA-RANCHI", "HIMALAYA-NAGPUR", "HIMALAYA-INDORE", "HIMALAYA-PATNA",
            "HIMALAYA-CHENNAI", "HIMALAYA-ZIRAKPUR ", "HIMALAYA-JAIPUR", "HIMALAYA-AHEMDABAD",
            "HIMALAYA-DELHI", "HIMALAYA - VIJAYAWADA", "HIM - TUMKUR", "HIMALAYA-HYD",
            "HIMALAYA-KOL", "HIMALAYA-BANGLORE"
        ],
        "PATANJALI PARIVAHAN PRIVATE LIMITED": [
            "PATANJALI-HYDERABAD", "PATAN-KARANPURA", "PATAN-INDORE", "PATAN-JALNA",
            "PATAN-BHOPAL", "PATANJALI-INDORE", "PATANJALI-DEL"
        ],
        "GLOBAL MARKETING": [
            "GLOBAL-BANGLORE", "GLOBAL-PUNJAB", "GLOBAL-CHENNAI", "GLOBAL-DEL", "GLOBAL-MH"
        ],
        "GLOBAL MARKETING REYN": [
            "GLOBAL MARKETING REYN-DELHI", "GLOBAL REYN-MH"
        ],
        "INDRA HOSIERY MILLS": ["INDIRA-LUDHIANA"],
        "VESCO CYCLE": ["VESCO-LUDHIANA"],
        "HI TECH INTERNATIONAL": ["HI TECH-LUDH"],
        "MONTE CARLO FASHIONS LIMITED": ["MONTE CARLO-LUDH"],
        "UM ORTHOTICS PRIVATE LIMITED": ["UM ORTHOTICS-LUDH"],
        "GOLD PLUS FLOAT GLASS PRIVATE LIMITED": ["GOLD PLUS-BELGUAM"],
        "SHREE CIMENT": ["SHREE CIMENT- MH"],
        "TORRENT PHARMACEUTICALS LTD": ["TORRENT-AHMEDABAD", "TORRENT-INDORE"],
        "CADILA PHARMACEUTICALS LIMITED": ["CADILA-AHMEDABAD", "CADILA-ANKLESHWAR"],
        "SUN PHARMA LABORATORIES LTD": ["SUN-MUMBAI", "SUN-HALOL", "SUN-SIKKIM"],
        "ZYDUS HEALTHCARE LIMITED": ["ZYDUS-AHMEDABAD", "ZYDUS-MORAIYA"],
        "CIPLA LIMITED": ["CIPLA-MUMBAI", "CIPLA-GOA", "CIPLA-INDORE", "CIPLA-KURKUMBH"],
        "LUPIN LIMITED": ["LUPIN-MUMBAI", "LUPIN-TARAPUR", "LUPIN-MANDIDEEP"],
        "ALKEM LABORATORIES LTD": ["ALKEM-MUMBAI", "ALKEM-DAMAN", "ALKEM-BADDI"],
        "MANKIND PHARMA LIMITED": ["MANKIND-DELHI", "MANKIND-PAONTA SAHIB"]
    }

    # Merge base defaults with loaded mapping
    for k, v in base_defaults.items():
        if k not in mapping:
            mapping[k] = list(v)
        else:
            for item in v:
                if item not in mapping[k]:
                    mapping[k].append(item)

    return mapping

def _load_counters_data() -> list[str]:
    counters: list[str] = []
    if os.path.isfile(COUNTERS_FILE_PATH):
        try:
            wb = openpyxl.load_workbook(COUNTERS_FILE_PATH, data_only=True)
            ws = wb.active
            # Header is ('ID', 'Counter Name', 'From Date', 'Close Date', 'Branch Name')
            for row in ws.iter_rows(min_row=2, values_only=True):
                if not row:
                    continue
                cnt_name = str(row[1]).strip() if len(row) > 1 and row[1] is not None else ""
                branch_name = str(row[4]).strip() if len(row) > 4 and row[4] is not None else ""
                # Replace single-digit index typos (e.g. '1' at row 27) with Branch Name
                target = branch_name if (cnt_name.isdigit() or not cnt_name) else cnt_name
                if target and target not in ("None", "none", "") and target not in counters:
                    counters.append(target)
                if branch_name and branch_name not in ("None", "none", "") and branch_name not in counters:
                    counters.append(branch_name)
        except Exception as ex:
            print(f"[MasterData] Error loading BookingCounterMast.xlsx: {ex}")

    # Standard booking counters matching Android MasterDataService
    std_counters = [
        "KOLKATA", "DELHI", "MUMBAI 01", "BANGLORE", "BELGAUM", "BHOPAL", "HYDERABAD",
        "LUDHIANA", "JALNA", "CHENNAI", "INDORE-1", "PATIALA", "MANGLORE", "TUMKUR",
        "PATALGANGA(MUMBAI)", "KARANPURA", "VIJAYWADA", "FARUKHNAGAR_BRANCH", "AHEMBADAB",
        "PITHAMPUR_BRANCH", "ZIRAKPUR_1", "GHAZIABAD_1", "GURUGRAM_HUB", "RANCHI_1",
        "JAIPUR_1", "PATNA_1", "NAGPUR_1", "BHIWANDI_1", "RAIPUR_1", "SILIGURI_1"
    ]
    for c in std_counters:
        if c not in counters:
            counters.append(c)

    return counters

DRIVER_MASTER_FILE = os.path.join(os.path.dirname(__file__), "data", "driver_master.json")

MASTER_DRIVER_REGISTRY: dict[str, dict[str, str]] = {
    "KA23B5235": {
        "vehicle_no": "KA23B5235",
        "driver_name": "DHANAJI S PATIL",
        "mobile_no": "9739443101",
        "license_no": "KA23 20000044025",
        "valid_upto": "11/04/2030",
        "vehicle_category": "OWNED"
    },
    "BR29GA2038": {
        "vehicle_no": "BR29GA2038",
        "driver_name": "AKHILESH KUMAR",
        "mobile_no": "9876543210",
        "license_no": "BR01 20230017384",
        "valid_upto": "15/08/2036",
        "vehicle_category": "MARKET"
    },
    "WB11K3735": {
        "vehicle_no": "WB11K3735",
        "driver_name": "Rajesh Verma",
        "mobile_no": "9820011223",
        "license_no": "DL-0420180098765",
        "valid_upto": "15/08/2029",
        "vehicle_category": "ATTACHED"
    },
    "UP30T1517": {
        "vehicle_no": "UP30T1517",
        "driver_name": "Ramesh Kumar",
        "mobile_no": "7309691052",
        "license_no": "DL-1420110012345",
        "valid_upto": "31/12/2028",
        "vehicle_category": "MARKET"
    },
    "UP32SN5433": {
        "vehicle_no": "UP32SN5433",
        "driver_name": "CHANDRA KESH SINGH",
        "mobile_no": "9876543210",
        "license_no": "UP32 20190045123",
        "valid_upto": "20/05/2031",
        "vehicle_category": "MARKET"
    }
}

def _load_driver_master() -> dict[str, dict[str, str]]:
    global MASTER_DRIVER_REGISTRY
    if os.path.exists(DRIVER_MASTER_FILE):
        try:
            with open(DRIVER_MASTER_FILE, "r", encoding="utf-8") as f:
                saved = json.load(f)
                if isinstance(saved, dict):
                    for k, v in saved.items():
                        clean_k = "".join(c for c in k.upper() if c.isalnum())
                        MASTER_DRIVER_REGISTRY[clean_k] = v
        except Exception as ex:
            print(f"[DriverMaster] Load error: {ex}")
    return MASTER_DRIVER_REGISTRY

def _save_driver_master(record: dict[str, str]):
    global MASTER_DRIVER_REGISTRY
    v_clean = "".join(c for c in record.get("vehicle_no", "").upper() if c.isalnum())
    if not v_clean:
        return
    MASTER_DRIVER_REGISTRY[v_clean] = record
    try:
        os.makedirs(os.path.dirname(DRIVER_MASTER_FILE), exist_ok=True)
        with open(DRIVER_MASTER_FILE, "w", encoding="utf-8") as f:
            json.dump(MASTER_DRIVER_REGISTRY, f, indent=2)
    except Exception as ex:
        print(f"[DriverMaster] Save error: {ex}")

# Load persistent driver master on startup
_load_driver_master()

@app.get("/api/master/manifest")
async def api_get_master_manifest():
    data = _load_manifest_data()
    return {"success": True, "customers": list(data.keys()), "mapping": data}

@app.get("/api/master/parties")
async def api_get_master_parties():
    parties, gst_map = _load_manifest_parties()
    return {"success": True, "parties": parties, "gst_map": gst_map}

@app.get("/api/master/counters")
async def api_get_master_counters():
    counters = _load_counters_data()
    return {"success": True, "counters": counters}

@app.get("/api/master/driver")
async def api_get_master_driver(vehicle_no: str = Query(default="")):
    registry = _load_driver_master()
    v_clean = "".join(c for c in vehicle_no.upper() if c.isalnum())
    match = None
    for k, v in registry.items():
        if "".join(c for c in k.upper() if c.isalnum()) == v_clean:
            match = v
            break
    if match:
        return {"success": True, "driver": match}
    return {"success": False, "driver": None}

@app.post("/api/master/register-driver")
async def api_register_master_driver(record: dict[str, Any]):
    v_no = str(record.get("vehicle_no") or record.get("Vehicle No *") or "").strip()
    if v_no:
        reg_item = {
            "vehicle_no": v_no,
            "driver_name": str(record.get("driver_name") or record.get("Driver Name *") or "").strip(),
            "mobile_no": str(record.get("mobile_no") or record.get("Mobile no   *") or "").strip(),
            "license_no": str(record.get("license_no") or record.get("Liscense No *") or "").strip(),
            "valid_upto": str(record.get("valid_upto") or record.get("Valid Up to *") or "").strip(),
            "vehicle_category": str(record.get("vehicle_category") or record.get("Vehicle Category") or "MARKET").strip(),
        }
        _save_driver_master(reg_item)
        return {"success": True, "registered": reg_item}
    return {"success": False, "error": "No vehicle number provided"}



# =========================================================================
# ROUTE 7: EXPORT WITH LIGHTWEIGHT VISUAL SNAPSHOT ENDPOINTS
# =========================================================================
class ExportMetaRequest(BaseModel):
    model_config = ConfigDict(extra="allow")
    documents: list[SingleDocumentExport] = []
    format_type: str = "gr_bnf_49"
    user_name: str | None = None
    user_mobile: str | None = None
    session_token: str | None = None
    token: str | None = None


# In-memory ephemeral cache for clean user-facing Excel bytes (avoids saving user files to disk)
_USER_EXCEL_BYTES_CACHE: dict[str, bytes] = {}

@app.post("/api/export-excel-meta")
async def api_export_excel_meta(req: ExportMetaRequest):
    docs = req.documents
    if not docs:
        raise HTTPException(status_code=400, detail="No document data provided for export")

    user_name = req.user_name or "Logistics User"
    user_mobile = req.user_mobile or ""
    active_token = req.session_token or req.token
    if active_token:
        session_user = auth_service.get_session_user(active_token)
        if session_user:
            user_name = session_user.get("name", user_name)
            user_mobile = session_user.get("mobile", user_mobile)

    # Auto-learn and persist driver details from exported documents
    for doc in docs:
        d_map = _get_doc_data(doc)
        v_no = str(d_map.get("Vehicle No *") or d_map.get("vehno") or "").strip()
        d_name = str(d_map.get("Driver Name *") or d_map.get("driver_name") or "").strip()
        if v_no and d_name:
            _save_driver_master({
                "vehicle_no": v_no,
                "driver_name": d_name,
                "mobile_no": str(d_map.get("Mobile no   *") or d_map.get("mobile_no") or "").strip(),
                "license_no": str(d_map.get("Liscense No *") or d_map.get("license_no") or "").strip(),
                "valid_upto": str(d_map.get("Valid Up to *") or d_map.get("valid_upto") or "").strip(),
                "vehicle_category": str(d_map.get("Vehicle Category") or d_map.get("Vehicle Type *") or "MARKET").strip(),
            })

    now = datetime.now()
    export_date = now.strftime("%d-%b-%Y")
    export_time = now.strftime("%I:%M:%S %p")
    exported_at = now.strftime("%d-%b-%Y %I:%M:%S %p")


    # 1. Build backend audit copy (retaining snapshot info: User Name, Export Date, Export Time, Exported At, History sheet)
    audit_wb, audit_bytes, raw_filename, export_id = _build_workbook_for_docs(
        docs, req.format_type or "gr_bnf_49", user_name=user_name, include_audit_meta=True
    )

    # 2. Build user download copy (containing ONLY actual business data - Row 1 Headers, Rows 2+ Data, 0 metadata rows)
    user_wb, user_bytes, _, _ = _build_workbook_for_docs(
        docs, req.format_type or "gr_bnf_49", user_name=user_name, export_id=export_id, include_audit_meta=False
    )
    _USER_EXCEL_BYTES_CACHE[f"USER_EXPORT_GR_Import_BNF_EXP_{export_id}_{len(docs)}LRs.xlsx"] = user_bytes
    _USER_EXCEL_BYTES_CACHE[export_id] = user_bytes
    if len(_USER_EXCEL_BYTES_CACHE) > 50:
        first_k = next(iter(_USER_EXCEL_BYTES_CACHE))
        _USER_EXCEL_BYTES_CACHE.pop(first_k, None)

    # 3. Save backend snapshot audit copy into backend/export/snapshots_excel/
    # (Do NOT save user-downloaded Excel file to backend disk)
    user_filename, _, audit_filename, backend_audit_path = audit_snapshot.save_dual_exports(
        user_bytes=user_bytes,
        audit_bytes=audit_bytes,
        export_id=export_id,
        lr_count=len(docs),
        lr_tag="",
        prefix="GR_Import_BNF"
    )
    _USER_EXCEL_BYTES_CACHE[user_filename] = user_bytes

    # 4. Register Excel metadata in lifecycle tracker with unified export_id
    excel_meta = file_lifecycle_service.record_file_creation(
        file_path=os.path.join(UPLOAD_LR_DIR, user_filename),
        file_type="excel",
        user_name=user_name,
        user_mobile=user_mobile,
        file_bytes=None,
        file_id=export_id,
        custom_meta={
            "total_records": len(docs),
            "format_type": req.format_type or "gr_bnf_49",
            "export_id": export_id,
            "user_export_filename": user_filename,
            "audit_copy": audit_filename,
            "generated_by": user_name,
            "generated_at": exported_at
        }
    )
    # Also register the backend audit copy in lifecycle tracker
    file_lifecycle_service.record_file_creation(
        file_path=backend_audit_path,
        file_type="excel_audit",
        user_name=user_name,
        user_mobile=user_mobile,
        file_bytes=audit_bytes,
        file_id=f"{export_id}_audit",
        custom_meta={
            "is_audit_copy": True,
            "total_records": len(docs),
            "original_filename": user_filename,
            "generated_by": user_name,
            "generated_at": exported_at
        }
    )

    file_lifecycle_service.record_file_export(
        file_id_or_path=user_filename,
        user_name=user_name,
        destination="browser_download"
    )

    # Tag underlying bilty documents as exported in lifecycle registry
    try:
        with file_lifecycle_service._lock:
            reg = file_lifecycle_service._load_registry()
            reg_updated = False
            for doc in docs:
                d_map = _get_doc_data(doc)
                doc_fn = getattr(doc, "filename", None) or (doc.get("filename") if isinstance(doc, dict) else None) or ""
                doc_lr = str(d_map.get("lrno") or d_map.get("LR No *") or d_map.get("grno") or "").strip()

                for fid, entry in reg.items():
                    if entry.get("file_type") not in ("bilty_image", "bilty_pdf"):
                        continue
                    cm = entry.get("custom_meta") or {}
                    match = False
                    if doc_fn and doc_fn in (entry.get("file_name"), cm.get("original_filename"), cm.get("saved_filename"), cm.get("upload_id")):
                        match = True
                    elif doc_lr and (doc_lr == cm.get("lr_no") or doc_lr == str(entry.get("current_data", {}).get("LR No *") or "").strip()):
                        match = True

                    if match:
                        entry["is_exported"] = True
                        entry["exported_at"] = exported_at
                        entry["export_batch_id"] = export_id
                        if "edit_history" not in entry:
                            entry["edit_history"] = []
                        entry["edit_history"].append({
                            "timestamp": file_lifecycle_service.get_current_timestamp(),
                            "user": user_name,
                            "action": "export",
                            "export_id": export_id,
                            "details": f"Included in Excel export {user_filename}"
                        })
                        reg_updated = True
            if reg_updated:
                file_lifecycle_service._save_registry(reg)
    except Exception as ex_tag:
        print(f"[Lifecycle Export Tag Notice] {ex_tag}")

    # 5. Record export audit (with reference to both user download file and backend audit copy)
    audit_info = audit_snapshot.generate_lightweight_snapshot(
        export_id=export_id,
        filename=user_filename,
        user_name=user_name,
        user_mobile=user_mobile,
        documents=[d.model_dump() if hasattr(d, "model_dump") else d for d in docs],
        file_bytes=audit_bytes,
        audit_filename=audit_filename,
        user_export_filename=user_filename
    )
    audit_snapshot.record_export_audit(audit_info)

    file_size_kb = round(len(user_bytes) / 1024, 1)

    return {
        "success": True,
        "export_id": export_id,
        "filename": user_filename,
        "user_export_filename": user_filename,
        "audit_filename": audit_filename,
        "download_url": f"/api/download-export/{user_filename}",
        "audit_download_url": f"/api/download-audit-export/{audit_filename}",
        "file_size_kb": file_size_kb,
        "user_name": user_name,
        "export_date": export_date,
        "export_time": export_time,
        "exported_at": exported_at,
        "generated_by": user_name,
        "exported_by": user_name,
        "user_mobile": user_mobile,
        "mobile": user_mobile,
        "generated_on": exported_at,
        "timestamp": exported_at,
        "created_at": excel_meta.get("created_at"),
        "total_lrs": len(docs),
        "total_records": len(docs),
    }


@app.get("/api/download-export/{filename}")
async def download_exported_file(
    filename: str,
    user_name: str | None = None,
    authorization: str | None = Header(default=None)
):
    safe_name = os.path.basename(filename)
    actor_name = user_name or "Logistics User"
    if authorization:
        session_user = auth_service.get_session_user(authorization)
        if session_user:
            actor_name = session_user.get("name") or actor_name

    # 1. Primary path: Stream clean in-memory user bytes (Row 1 Headers, Rows 2+ Data, 0 metadata rows)
    clean_bytes = _USER_EXCEL_BYTES_CACHE.get(safe_name)
    if not clean_bytes:
        exp_match = re.search(r'EXP_[0-9]+_[a-f0-9]+', safe_name)
        if exp_match and exp_match.group(0) in _USER_EXCEL_BYTES_CACHE:
            clean_bytes = _USER_EXCEL_BYTES_CACHE[exp_match.group(0)]

    if clean_bytes:
        try:
            file_lifecycle_service.record_file_export(
                file_id_or_path=safe_name,
                user_name=actor_name,
                destination="device_download"
            )
        except Exception:
            pass

        return StreamingResponse(
            io.BytesIO(clean_bytes),
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            headers={
                "Content-Disposition": f'attachment; filename="{safe_name}"',
                "Access-Control-Expose-Headers": "Content-Disposition",
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "Pragma": "no-cache",
                "Expires": "0"
            }
        )

    # 2. Check if a clean user export exists on disk in legacy directories
    # (Never serve snapshots from snapshots_excel directly as user downloads!)
    file_path = None
    candidate_lr = os.path.join(UPLOAD_LR_DIR, safe_name)
    if os.path.isfile(candidate_lr):
        file_path = candidate_lr
    else:
        candidate_exp = os.path.join(audit_snapshot.EXPORTS_DIR, safe_name)
        if os.path.isfile(candidate_exp):
            file_path = candidate_exp

    if file_path and os.path.isfile(file_path):
        try:
            wb_test = openpyxl.load_workbook(file_path, read_only=True)
            has_history = "History" in wb_test.sheetnames
            wb_test.close()
            if not has_history:
                return FileResponse(
                    file_path,
                    media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    filename=safe_name,
                    headers={
                        "Content-Disposition": f'attachment; filename="{safe_name}"',
                        "Access-Control-Expose-Headers": "Content-Disposition",
                        "Cache-Control": "no-cache, no-store, must-revalidate",
                        "Pragma": "no-cache",
                        "Expires": "0"
                    }
                )
        except Exception:
            pass

    # 3. Dynamic fallback: Load internal audit snapshot from snapshots_excel and generate clean user report
    snap_path = audit_snapshot.resolve_snapshot_path(safe_name)
    if snap_path and os.path.isfile(snap_path):
        try:
            wb = openpyxl.load_workbook(snap_path)
            # Remove internal audit History sheet
            if "History" in wb.sheetnames:
                wb.remove(wb["History"])
            ws = wb["Sheet1"] if "Sheet1" in wb.sheetnames else wb.active
            # Remove top audit metadata rows so Row 1 is column headers and Rows 2+ are clean consignment data
            while ws.max_row > 1 and ws.cell(1, 1).value and str(ws.cell(1, 1).value).strip().startswith(("User Name:", "Export Date:", "Export Time:", "Exported At:")):
                ws.delete_rows(1, 1)

            buf = io.BytesIO()
            wb.save(buf)
            buf.seek(0)
            clean_bytes = buf.getvalue()

            # Cache the clean bytes for future downloads
            _USER_EXCEL_BYTES_CACHE[safe_name] = clean_bytes

            try:
                file_lifecycle_service.record_file_export(
                    file_id_or_path=safe_name,
                    user_name=actor_name,
                    destination="device_download"
                )
            except Exception:
                pass

            return StreamingResponse(
                io.BytesIO(clean_bytes),
                media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                headers={
                    "Content-Disposition": f'attachment; filename="{safe_name}"',
                    "Access-Control-Expose-Headers": "Content-Disposition",
                    "Cache-Control": "no-cache, no-store, must-revalidate",
                    "Pragma": "no-cache",
                    "Expires": "0"
                }
            )
        except Exception as e_stream:
            print(f"[Export Download Stream Error] {e_stream}")
            raise HTTPException(status_code=500, detail=f"Failed to generate clean download workbook: {e_stream}")

    raise HTTPException(status_code=404, detail="Exported Excel file not found.")


@app.get("/api/download-audit-export/{filename}")
async def download_audit_exported_file(filename: str):
    """Allows authorized inspection or download of the backend audit copy."""
    safe_name = os.path.basename(filename)
    file_path = audit_snapshot.resolve_file_path(safe_name)
    if not file_path:
        audit_name = safe_name.replace("USER_EXPORT_", "AUDIT_EXPORT_") if "USER_EXPORT_" in safe_name else (safe_name if safe_name.startswith("audit_") else f"audit_{safe_name}")
        file_path = audit_snapshot.resolve_file_path(audit_name)
    if not file_path:
        file_path = os.path.join(audit_snapshot.EXPORTS_DIR, safe_name)
    if file_path and os.path.exists(file_path):
        return FileResponse(
            file_path,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            filename=os.path.basename(file_path),
            headers={
                "Content-Disposition": f'attachment; filename="{os.path.basename(file_path)}"',
                "Access-Control-Expose-Headers": "Content-Disposition"
            }
        )
    raise HTTPException(status_code=404, detail="Backend audit Excel file not found.")


@app.get("/api/export-audit/snapshot/{export_id}")
async def get_audit_snapshot_image(export_id: str):
    raise HTTPException(status_code=404, detail="Snapshot image feature has been removed.")


@app.get("/api/export-audit/history")
async def get_export_audit_history(
    mobile: str | None = Query(default=None),
    authorization: str | None = Header(default=None)
):
    target_mobile = mobile
    if not target_mobile and authorization:
        session_user = auth_service.get_session_user(authorization)
        if session_user:
            target_mobile = session_user.get("mobile")

    logs = audit_snapshot.get_user_audit_history(user_mobile=target_mobile, limit=100)
    return {
        "success": True,
        "count": len(logs),
        "history": logs,
        "user_mobile": target_mobile or ""
    }


@app.delete("/api/export-audit/{target}")
@app.post("/api/export-audit/delete")
async def api_delete_export_audit(
    target: str | None = None,
    export_id: str | None = Query(default=None),
    filename: str | None = Query(default=None)
):
    key = target or export_id or filename
    if not key:
        raise HTTPException(status_code=400, detail="Missing export identifier or filename")
    deleted = audit_snapshot.delete_export_audit(key)
    return {"success": True, "deleted": deleted, "target": key}


@app.get("/api/export-audit/download-all")
async def download_all_user_exports(
    mobile: str | None = Query(default=None),
    authorization: str | None = Header(default=None)
):
    """Consolidates all of a user's exported LR records into a single 49-column Excel file."""
    target_mobile = mobile
    if authorization:
        session_user = auth_service.get_session_user(authorization)
        if session_user and not target_mobile:
            target_mobile = session_user.get("mobile")

    logs = audit_snapshot.get_user_audit_history(user_mobile=target_mobile, limit=500) if target_mobile else []
    if not logs:
        # Fallback to all export logs if user-specific logs are empty or mobile not provided
        logs = audit_snapshot.get_user_audit_history(limit=500)

    if not logs:
        raise HTTPException(status_code=404, detail="No exported LR data found in export history.")

    # Aggregate all documents from all exports
    all_docs = []
    seen_keys = set()
    for entry in logs:
        docs = entry.get("documents", [])
        for d in docs:
            d_dict = d if isinstance(d, dict) else {}
            d_fname = d_dict.get("filename", "document.jpg")
            d_data = d_dict.get("data", {})
            lr_id = str(d_data.get("grno (*)") or d_data.get("grno") or d_data.get("LR No *") or d_fname)
            doc_key = f"{d_fname}_{lr_id}"
            if doc_key not in seen_keys:
                seen_keys.add(doc_key)
                all_docs.append(SingleDocumentExport(
                    filename=d_fname,
                    document_title=d_dict.get("document_title", "Consignment LR"),
                    data=d_data
                ))

    if not all_docs:
        raise HTTPException(status_code=404, detail="No consignment records found in export history.")

    user_label = target_mobile or "Consolidated"
    wb, file_bytes, filename, export_id = _build_workbook_for_docs(all_docs, "gr_bnf_49", user_name=user_label, include_audit_meta=False)
    export_filename = f"All_Exported_LRs_{user_label}_{export_id}.xlsx"

    return StreamingResponse(
        io.BytesIO(file_bytes),
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={
            "Content-Disposition": f'attachment; filename="{export_filename}"',
            "Access-Control-Expose-Headers": "Content-Disposition",
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Pragma": "no-cache",
            "Expires": "0"
        }
    )


# =========================================================================
# ROUTE: PREVIOUSLY UPLOADED LRs (Images and PDFs) - User Isolated
# =========================================================================
@app.get("/api/previous-uploads")
async def get_previous_uploads(
    user_id: str | None = Query(default=None),
    user_mobile: str | None = Query(default=None),
    authorization: str | None = Header(default=None),
    only_pending: bool = Query(default=False),
    limit: int = 50
):
    """
    Returns verified previously uploaded LR documents (both images and PDFs)
    that physically exist on disk in UPLOAD_LR_DIR for the authenticated user only.
    Excludes any dummy test stubs, deleted items, or files belonging to other users.
    When only_pending=True (default), excludes already exported/completed LR documents.
    """
    try:
        actor = _resolve_user_from_request(
            authorization=authorization,
            user_id=user_id,
            user_mobile=user_mobile
        )
        req_user_id = actor.get("user_id") or ""
        req_mobile = actor.get("user_mobile") or ""

        # Strictly require valid user context to prevent any cross-user leakage
        if not req_user_id and not req_mobile:
            return {"success": True, "total": 0, "uploads": []}

        all_metadata = file_lifecycle_service.get_all_metadata(include_deleted=False, limit=200)
        items = []
        seen_filenames = set()

        for meta in all_metadata:
            if meta.get("is_deleted", False):
                continue
            if only_pending and (meta.get("is_exported", False) or meta.get("exported_at")):
                continue

            # User ownership check: must match user_id or user_mobile
            custom_meta = meta.get("custom_meta") or {}
            meta_user_id = meta.get("user_id") or custom_meta.get("user_id") or ""
            meta_mobile = meta.get("user_mobile") or custom_meta.get("user_mobile") or ""

            match_user = False
            if req_user_id and meta_user_id and req_user_id == meta_user_id:
                match_user = True
            elif req_mobile and meta_mobile and req_mobile == meta_mobile:
                match_user = True

            if not match_user:
                continue

            file_type = meta.get("file_type")
            if file_type not in ("bilty_image", "bilty_pdf"):
                continue

            saved_name = meta.get("file_name") or ""
            if not saved_name or saved_name in seen_filenames:
                continue

            full_path = os.path.join(UPLOAD_LR_DIR, saved_name)
            if not os.path.isfile(full_path):
                continue

            orig_name = custom_meta.get("original_filename") or saved_name

            # Exclude dummy mock placeholders
            lower_orig = orig_name.lower()
            if any(t in lower_orig for t in ("dummy", "mock", "placeholder", "fake_doc")):
                continue

            seen_filenames.add(saved_name)
            is_pdf = file_type == "bilty_pdf" or saved_name.lower().endswith(".pdf") or orig_name.lower().endswith(".pdf")
            file_id = meta.get("file_id") or f"lr_{int(os.path.getmtime(full_path))}"

            preview_url = None
            preview_pages = []
            if is_pdf:
                upload_prefix = custom_meta.get("upload_id") or ""
                base_stem = os.path.splitext(saved_name)[0]
                for f in sorted(os.listdir(UPLOAD_LR_DIR)):
                    if (upload_prefix and f.startswith(upload_prefix) and f.endswith(".jpg")) or \
                       (base_stem and base_stem[:25] in f and f.endswith(".jpg")):
                        if "preview" in f:
                            preview_url = f"/uploads/{f}"
                        if "page" in f or "preview" in f:
                            preview_pages.append(f"/uploads/{f}")
                if not preview_url and preview_pages:
                    preview_url = preview_pages[0]
            else:
                preview_url = f"/uploads/{saved_name}"

            data_payload = meta.get("current_data") or {}
            if not data_payload and meta.get("versions"):
                data_payload = meta["versions"][-1].get("snapshot_data") or {}

            lr_no = custom_meta.get("lr_no") or data_payload.get("LR No *") or data_payload.get("grno") or ""

            items.append({
                "id": file_id,
                "filename": orig_name,
                "saved_filename": saved_name,
                "file_url": f"/snapshots/{saved_name}",
                "preview_url": preview_url,
                "preview_pages": preview_pages,
                "page_count": max(len(preview_pages), 1) if is_pdf else 1,
                "file_type": file_type,
                "isPdf": is_pdf,
                "lrNo": lr_no,
                "createdAt": meta.get("created_at") or datetime.fromtimestamp(os.path.getmtime(full_path)).isoformat(),
                "data": data_payload
            })

            if len(items) >= limit:
                break

        return {"success": True, "total": len(items), "uploads": items}
    except Exception as e:
        print(f"[Previous Uploads API Error] {e}")
        return {"success": False, "total": 0, "uploads": [], "error": str(e)}


class DeletePreviousUploadRequest(BaseModel):
    file_id_or_name: str
    user_id: str | None = None
    user_mobile: str | None = None
    user_name: str | None = "Logistics User"


@app.post("/api/previous-uploads/delete")
async def delete_previous_upload(
    req: DeletePreviousUploadRequest,
    authorization: str | None = Header(default=None)
):
    """
    Soft-deletes a previously uploaded LR document for the authenticated user,
    ensuring it is removed from previous uploads and never reappears on reload or re-login.
    """
    actor = _resolve_user_from_request(
        authorization=authorization,
        user_id=req.user_id,
        user_mobile=req.user_mobile,
        user_name=req.user_name
    )
    user_display = actor.get("user_name") or req.user_name or "Logistics User"

    res = file_lifecycle_service.record_file_deletion(
        file_id_or_path=req.file_id_or_name,
        user_name=user_display,
        reason="Removed from previous uploads by user"
    )

    # If not found directly by file_id_or_path, try finding in registry via saved_filename or custom_meta
    if not res:
        with file_lifecycle_service._lock:
            reg = file_lifecycle_service._load_registry()
            matched_fid = None
            target_key = req.file_id_or_name.strip()
            for fid, entry in reg.items():
                cm = entry.get("custom_meta") or {}
                if target_key in (fid, entry.get("file_name"), cm.get("saved_filename"), cm.get("original_filename"), cm.get("upload_id")):
                    matched_fid = fid
                    break
            if matched_fid:
                res = file_lifecycle_service.record_file_deletion(
                    file_id_or_path=matched_fid,
                    user_name=user_display,
                    reason="Removed from previous uploads by user"
                )

    return {"success": True, "deleted": bool(res), "file_id_or_name": req.file_id_or_name}


class ClearAllPreviousUploadsRequest(BaseModel):
    user_id: str | None = None
    user_mobile: str | None = None
    user_name: str | None = "Logistics User"


@app.post("/api/previous-uploads/clear-all")
async def clear_all_previous_uploads(
    req: ClearAllPreviousUploadsRequest,
    authorization: str | None = Header(default=None)
):
    """
    Soft-deletes all previous LR document uploads for the authenticated user upon
    clicking 'Clear All', ensuring they do not reappear in previous uploads or batch on refresh.
    """
    actor = _resolve_user_from_request(
        authorization=authorization,
        user_id=req.user_id,
        user_mobile=req.user_mobile,
        user_name=req.user_name
    )
    req_user_id = actor.get("user_id") or req.user_id or ""
    req_mobile = actor.get("user_mobile") or req.user_mobile or ""
    user_display = actor.get("user_name") or req.user_name or "Logistics User"

    if not req_user_id and not req_mobile:
        return {"success": True, "cleared_count": 0}

    cleared_count = 0
    with file_lifecycle_service._lock:
        reg = file_lifecycle_service._load_registry()
        reg_updated = False
        now_ts = file_lifecycle_service.get_current_timestamp()

        for fid, entry in reg.items():
            if entry.get("file_type") not in ("bilty_image", "bilty_pdf"):
                continue
            if entry.get("is_deleted", False):
                continue

            cm = entry.get("custom_meta") or {}
            meta_uid = entry.get("user_id") or cm.get("user_id") or ""
            meta_mob = entry.get("user_mobile") or cm.get("user_mobile") or ""

            match_user = False
            if req_user_id and meta_uid and req_user_id == meta_uid:
                match_user = True
            elif req_mobile and meta_mob and req_mobile == meta_mob:
                match_user = True

            if match_user:
                entry["is_deleted"] = True
                entry["deleted_at"] = now_ts
                entry["deleted_by"] = user_display
                entry["deletion_reason"] = "Cleared via Clear All by user"
                if "edit_history" not in entry:
                    entry["edit_history"] = []
                entry["edit_history"].append({
                    "timestamp": now_ts,
                    "user": user_display,
                    "action": "clear_all",
                    "details": "Cleared via Clear All by user"
                })
                cleared_count += 1
                reg_updated = True

        if reg_updated:
            file_lifecycle_service._save_registry(reg)

    return {"success": True, "cleared_count": cleared_count}

# =========================================================================
# ROUTE 8: FILE LIFECYCLE & AUDIT METADATA ENDPOINTS
# =========================================================================
@app.get("/api/files/metadata")
async def get_files_lifecycle_metadata(file_type: str | None = None, include_deleted: bool = False):
    """Returns lifecycle history for all files (Excel, snapshots, screenshots, bilties)."""
    # Trigger automated 30-day snapshot purge
    try:
        file_lifecycle_service.purge_snapshots_older_than(days=30)
    except Exception:
        pass
    files = file_lifecycle_service.get_all_metadata(file_type=file_type, include_deleted=include_deleted)
    return {"success": True, "total": len(files), "files": files}


@app.get("/api/files/metadata/{file_id}")
async def get_single_file_metadata(file_id: str):
    """Returns specific file lifecycle history, including granular edit events."""
    meta = file_lifecycle_service.get_metadata_by_id(file_id)
    if not meta:
        raise HTTPException(status_code=404, detail="File metadata entry not found.")
    return {"success": True, "metadata": meta}


class RecordLifecycleEventRequest(BaseModel):
    file_id_or_name: str
    action: str  # "edit", "export", "delete", "create"
    user_name: str = "Logistics User"
    details: Any = None
    file_type: str | None = None
    diff: dict[str, Any] | None = None
    new_data: dict[str, Any] | None = None


@app.post("/api/files/metadata/record-event")
async def record_lifecycle_event(req: RecordLifecycleEventRequest):
    """Allows Web & Android clients to record granular edit, export, or deletion events."""
    action = (req.action or "").lower().strip()
    res = None
    if action == "edit":
        res = file_lifecycle_service.record_file_edit(
            file_id_or_path=req.file_id_or_name,
            user_name=req.user_name,
            action="manual_edit",
            details=req.details,
            diff=req.diff,
            new_data=req.new_data
        )
    elif action == "export":
        res = file_lifecycle_service.record_file_export(
            file_id_or_path=req.file_id_or_name,
            user_name=req.user_name,
            destination="client_export",
            extra_details={"details": req.details} if req.details else None
        )
    elif action == "delete":
        res = file_lifecycle_service.record_file_deletion(
            file_id_or_path=req.file_id_or_name,
            user_name=req.user_name,
            reason=str(req.details or "Deleted by user")
        )
    elif action == "create":
        res = file_lifecycle_service.record_file_creation(
            file_path=req.file_id_or_name,
            file_type=req.file_type or "unknown",
            user_name=req.user_name,
            custom_meta={"details": req.details} if req.details else None,
            initial_data=req.new_data
        )
    return {"success": True, "action": action, "entry": res}


@app.get("/api/files/deleted")
async def get_deleted_files():
    """Returns soft-deleted items with their Deleted At timestamps and reasons."""
    deleted_items = file_lifecycle_service.get_deleted_files()
    return {"success": True, "count": len(deleted_items), "deleted_files": deleted_items}


class RestoreDeletedRequest(BaseModel):
    file_id_or_name: str
    user_name: str = "Logistics User"


@app.post("/api/files/restore-deleted")
async def restore_deleted_file_endpoint(req: RestoreDeletedRequest):
    """Restores a previously deleted file back into the active list."""
    res = file_lifecycle_service.restore_deleted_file(req.file_id_or_name, req.user_name)
    if not res:
        raise HTTPException(status_code=404, detail="File not found or cannot be restored.")
    return {"success": True, "restored_file": res}


class RestoreVersionRequest(BaseModel):
    file_id_or_name: str
    target_version: int
    user_name: str = "Logistics User"


@app.post("/api/files/restore-version")
async def restore_version_endpoint(req: RestoreVersionRequest):
    """Restores an earlier version snapshot (v1, v2...) as a new active version."""
    res = file_lifecycle_service.restore_file_version(req.file_id_or_name, req.target_version, req.user_name)
    if not res:
        raise HTTPException(status_code=404, detail="Version not found or cannot be restored.")
    return {"success": True, "entry": res}


@app.get("/api/files/snapshots/{file_id}/{snapshot_file}")
async def get_vault_snapshot_file(file_id: str, snapshot_file: str):
    """Serves a historical version snapshot file from the vault."""
    safe_fid = os.path.basename(file_id)
    safe_sname = os.path.basename(snapshot_file)
    snap_path = os.path.join(file_lifecycle_service.SNAPSHOTS_DIR, safe_fid, safe_sname)
    if os.path.isfile(snap_path):
        media_type = "image/jpeg"
        if snap_path.endswith(".png"):
            media_type = "image/png"
        elif snap_path.endswith(".xlsx"):
            media_type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        elif snap_path.endswith(".json"):
            media_type = "application/json"
        return FileResponse(snap_path, media_type=media_type)
    raise HTTPException(status_code=404, detail="Snapshot file not found.")


@app.post("/api/export-audit/cleanup-expired")
async def cleanup_expired_snapshots(days: int = 30):
    """Automated or manual trigger to purge snapshots older than 30 days."""
    purged = file_lifecycle_service.purge_snapshots_older_than(days=days)
    return {"success": True, "purged_count": len(purged), "purged_files": purged, "retention_days": days}



if __name__ == "__main__":
    import uvicorn
    local_ip = get_local_ip()
    print("=" * 65)
    print("  OCR to Excel Studio - Server Starting")
    print(f"  Web Component (Browser) : http://localhost:8000")
    print(f"  Network / Phone Access  : http://{local_ip}:8000")
    print(f"  Download Android APK    : http://{local_ip}:8000/download-apk")
    print("=" * 65)
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
