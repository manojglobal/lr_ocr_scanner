import asyncio
import threading
import base64
import io
import json
import os
import re
import socket
import uuid
from datetime import datetime, date
from fastapi import FastAPI, File, Form, HTTPException, UploadFile, Header, Query, Request, Response, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from typing import Any
from pydantic import BaseModel, ConfigDict, Field, field_validator
from PIL import Image, ImageOps, ImageEnhance
import zipfile
import openpyxl
from openpyxl.styles import PatternFill, Font, Alignment, Border, Side
from openpyxl.styles import stylesheet as openpyxl_stylesheet
from openpyxl.utils import get_column_letter

# Ensure openpyxl cell styles serialize applyNumberFormat="1" for all styled number formats
_attrs = list(openpyxl_stylesheet.CellStyle.__attrs__)
if "applyNumberFormat" not in _attrs:
    _attrs.append("applyNumberFormat")
openpyxl_stylesheet.CellStyle.__attrs__ = tuple(_attrs)

_orig_from_array = openpyxl_stylesheet.CellStyle.from_array
@classmethod
def _patched_from_array(cls, style):
    xf = _orig_from_array.__func__(cls, style)
    if getattr(style, "numFmtId", 0) != 0:
        xf.applyNumberFormat = True
    return xf
openpyxl_stylesheet.CellStyle.from_array = _patched_from_array

import google.generativeai as genai
from google.generativeai.types import HarmCategory, HarmBlockThreshold

import auth_service
import audit_snapshot
import file_lifecycle_service
import user_cloud_service

# Top-level patch for pymupdf layout & onnxruntime to avoid runtime import collisions
import sys
for _m in ('pymupdf.layout', 'pymupdf4llm', 'onnxruntime'):
    if _m not in sys.modules:
        sys.modules[_m] = None


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


def get_server_host(default: str = "0.0.0.0") -> str:
    """Resolves bind host from HOST environment variable."""
    raw = os.getenv("HOST", "").strip()
    return raw if raw else default


def get_server_port(default: int = 8000) -> int:
    """Resolves bind port from CLI --port or PORT / BACKEND_PORT in .env."""
    for i, arg in enumerate(sys.argv):
        if arg.startswith("--port="):
            val = arg.split("=", 1)[1].strip()
            if val.isdigit() and 1 <= int(val) <= 65535:
                return int(val)
        elif arg == "--port" and i + 1 < len(sys.argv):
            val = sys.argv[i + 1].strip()
            if val.isdigit() and 1 <= int(val) <= 65535:
                return int(val)
    for env_name in ("PORT", "BACKEND_PORT"):
        raw = os.getenv(env_name, "").strip()
        if raw.isdigit() and 1 <= int(raw) <= 65535:
            return int(raw)
    return default


def get_public_server_url() -> str | None:
    """Returns optional PUBLIC_SERVER_URL / SERVER_URL override from .env."""
    for env_name in ("PUBLIC_SERVER_URL", "SERVER_URL"):
        raw = os.getenv(env_name, "").strip().rstrip("/")
        if raw:
            return raw
    return None


SERVER_HOST = get_server_host()
SERVER_PORT = get_server_port()

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
        os.path.join(BASE_DIR, "docs", *subpaths),
        os.path.join(os.path.dirname(BASE_DIR), "docs", *subpaths),
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

LR_FORMAT_52_HEADERS = [
    "Branch", "GrNo", "GrDate", "GrType", "Customer", "CustomerDepartment",
    "Countername", "TransitDays", "Origen", "Destination", "PickupPoint",
    "DeliveryPoint", "Consignor", "ConsignorGST", "Consignee", "ConsigneeGST",
    "ProductName", "Packing", "PMark", "Goods", "VehicleNo", "VehicleTypeName",
    "DriverName", "DriverMobileNo", "DrivingLicenseNo", "DrivingValidUpto",
    "LoadingStartDate", "Freight", "OtherAmount", "CGST", "SGST", "IGST",
    "Received", "Advance", "CollectionBranch", "FTL", "PCS", "OrderWeight",
    "ActualWeight", "ChargableWeight", "ContractWeight", "ExtraMt",
    "CustomerRefcode", "staxpaidby", "DeliveryType", "EwayBillNo",
    "EwayBillDate", "ValidUpto", "InvoiceNo", "InvoieDate",
    "ValueOfGoods", "viaborder"
]
LR_FORMAT_49_HEADERS = LR_FORMAT_52_HEADERS
GR_BNF_52_HEADERS = LR_FORMAT_52_HEADERS
GR_BNF_49_HEADERS = LR_FORMAT_52_HEADERS
_OLD_GR_BNF_49_HEADERS = [
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
GR_BNF_50_HEADERS = GR_BNF_52_HEADERS

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

STEP_0_AUTHENTICITY_RULES = """### STEP 0: MANDATORY DOCUMENT AUTHENTICITY VALIDATION (FAIL-SAFE)
You MUST evaluate whether the image or document dossier is a genuine Logistics Consignment / Freight Transport document (Lorry Receipt, Bilty, or Consignment Note).

CRITICAL CLASSIFICATION RULES:
1. GENUINE LR / BILTY / CONSIGNMENT NOTE:
   - Contains a Consignment Note / Lorry Receipt (LR) / Bilty (or C-Note / G.R. / Goods Receipt) from a transporter (e.g., Box N Freight, Patanjali Parivahan, Unicharm, Himalaya, Gold Plus, or third-party Indian logistics carriers).
   - Even if handwritten, faint carbon copy, low-light, folded, stamped, or customer-specific format, it is a genuine LR.
   - If the dossier is a multi-page document containing an LR plus attached E-Way Bill, Tax Invoice, Gate Pass, or Driver License, it is VALID.
   - Set:
     * `has_consignment_note`: true
     * `is_valid_lr`: true
     * `document_type`: "lorry_receipt" or "bilty" or "consignment_note"

2. STANDALONE NON-LR LOGISTICS DOCUMENTS (STRICTLY INVALID BY THEMSELVES):
   - Standalone E-Way Bill (Form GST EWB-01) WITHOUT any LR or Bilty in the document dossier -> REJECT.
     Set `has_consignment_note`: false, `is_valid_lr`: false, `document_type`: "standalone_eway_bill", `rejection_reason`: "Standalone E-Way bill without LR/Bilty".
   - Standalone Gate Pass / Security Movement Slip WITHOUT any LR or Bilty -> REJECT.
     Set `has_consignment_note`: false, `is_valid_lr`: false, `document_type`: "standalone_gate_pass", `rejection_reason`: "Standalone Gate Pass without LR/Bilty".
   - Standalone Commercial Tax Invoice / Packing List WITHOUT any LR or Bilty -> REJECT.
     Set `has_consignment_note`: false, `is_valid_lr`: false, `document_type`: "standalone_invoice", `rejection_reason`: "Standalone Tax Invoice without LR/Bilty".

3. UNRELATED / NON-LOGISTICS DOCUMENTS (STRICTLY INVALID):
   - Selfies, human portraits, faces, photos of people or random physical objects.
     Set `has_consignment_note`: false, `is_valid_lr`: false, `document_type`: "selfie", `rejection_reason`: "Selfie / photo of person".
   - Mobile screenshots of WhatsApp chats, apps, social media, games, homescreen.
     Set `has_consignment_note`: false, `is_valid_lr`: false, `document_type`: "screenshot", `rejection_reason`: "Phone screenshot".
   - Blank or underexposed photos with no document text, plain blank paper/floors/walls.
     Set `has_consignment_note`: false, `is_valid_lr`: false, `document_type`: "blank", `rejection_reason`: "Blank image with no document content".
   - Non-freight receipts: restaurant bills, food slips, grocery store shopping receipts, personal letters, school notes.
     Set `has_consignment_note`: false, `is_valid_lr`: false, `document_type`: "unrelated", `rejection_reason`: "Unrelated non-freight document".

4. MULTI-SIGNAL INDICATORS:
   - Set `has_parties_or_movement`: true if consignor, consignee, origin, or destination are present.
   - Set `has_cargo_or_vehicle`: true if package count, cargo description, weight, or vehicle plate are present.
   - Set `has_freight_terms`: true if freight amount, payment terms (TBB/To Pay/Paid), or transport rate are present."""

DEFAULT_HANDWRITTEN_OCR_PROMPT = """
You are the Master OCR and Document Information Scraping Engine for 'BOX N FREIGHT LOGISTICS SOLUTIONS PVT. LTD.' and its enterprise logistics clients.
Inspect ALL pages in the provided document dossier thoroughly (including Consignment Note Bilty, Commercial Tax Invoices, GST E-Way Bills, Vehicle RC Form 23A, and Commercial Driving Licences DL) and map the extracted data strictly into the 49 standardized columns:

""" + STEP_0_AUTHENTICITY_RULES + """

### STEP 1: AUTOMATIC COMPANY & DOCUMENT PROFILE IDENTIFICATION
Visually examine the document header, company logo, billing parties, and stamps to classify the customer profile:
- UNICHARM PROFILE: Headers, Tax Invoices, or consignor/consignee mention 'UNICHARM INDIA PVT. LTD.', 'Vuicharm', 'Uvicharm', or 'GLOBAL MARKETING-MT'.
- PATANJALI PROFILE: Headers mention 'PATANJALI PARIVAHAN PVT. LTD.', 'PATANJALI FOODS LIMITED', 'Ruchi Soya', or display Patanjali C Note layout.
- HIMALAYA PROFILE: Headers mention 'Himalaya Wellness Company' or 'Makali Bangalore'.
- GOLD PLUS PROFILE: Headers, Tax Invoices, or gate passes mention 'GOLD PLUS FLOAT GLASS PVT. LTD.' or 'Kanagala Belagavi'.
- GENERIC BNF PROFILE: Standard Box N Freight printed bilty or other enterprise customer from the manifest.

### STEP 2: APPLY CUSTOMER EXTRACTION RULES (1. Present, 2. partially Present, 3. absent)

================================================================================
A. UNICHARM (COMPANY NAME)
================================================================================
1. Present:
- "grno" / "LR No *": Primary Consignment / LR Tracking Number. Extract bold 5-digit number printed in 'CONSIGNMENT NOTE: No.' box at top right of the Box N Freight bilty (e.g. 32298, 32299, 32300, 33306), or verify from 'Transporter LR No' on the Unicharm Tax Invoice / E-Way Bill Part B.
- "grdt": Consignment booking date in 'Date' box (strictly DD/MM/YYYY, e.g., 27/09/2026).
- "stockdt": Consignment entry date (matches grdt).
- "Customer Name *": Corporate billed entity: "UNICHARM INDIA PVT. LTD.".
- "cngr": "UNICHARM INDIA PVT. LTD., Village Mau, Tehsil Pataudi, District Gurugram, Haryana - 122414" (or Sanand, Gujarat).
- "cngrgstno": "06AABCU0113A2ZA".
- "cnge": "GLOBAL MARKETING-MT, Khasra No. 240, Hamidpur Narela Village, New Delhi - 110036" (or Ambala).
- "cngegstno": "07AJYPK4522G1ZX".
- "orgrefcode": "MAU", "GURGAON", or "SANAND". "destrefcode": "DELHI", "SOUTH DELHI", or "AMBALA".
- "collectionstncode": Matches orgrefcode.
- "bookedpckgs" / "stockpckgs": Integer package count from Tax Invoice 'Total Cases' or bilty 'No. of Packages' (e.g. 1375, 2064, 1251, 797).
- "packing": "Cases" or "Carton box".
- "goods": Commodity description from Tax Invoice (e.g., "Baby Diapers", "MPP All Night Absorb COCO L40"). (Do NOT include seal numbers or invoice numbers in the goods description).
- "bookedaweight" / "stockaweight": Actual gross weight in KG from Tax Invoice or bilty.
- "bookedcweight" / "stockcweight": Charged weight in KG from bilty or Tax Invoice.
- "invoiceno": Commercial invoice number from Tax Invoice (e.g., 10906I26-001898, 10906F26-001407, 3324726-000484).
- "invoiedt": Commercial invoice date from Tax Invoice (DD/MM/YYYY).
- "valgoods": Total declared invoice value of goods from Tax Invoice (numeric without commas, e.g. 2112307.00, 2817236.00).
- "ewaybillno": 12-digit GST E-Way Bill number from E-Way Bill page (e.g., 362343603918).
- "Valid Upto": E-Way Bill validity expiry date (strictly DD/MM/YYYY, e.g., 28/09/2026).
- "Transit Days": Calculated integer difference between grdt and Valid Upto.
- "Vehicle No *": Indian motor vehicle registration plate from bilty 'Tempo/Truck No.', mParivahan RC status, or truck photo (e.g., HR55AX5490, RJ18GB7132, NL01AFS826).
- "Vehicle Type *": Vehicle body type: "Market" (or "32 FT CONTAINER").
- "Loading Start date *": Booking date (matches grdt).
- "ftl": Vehicle container/service type: "FTL" (Dedicated 32 FT container).
- "staxpaidby": GST on freight paying party: "C" (Consignor).
- "dlvtype": Delivery type: "D" (Door Delivery).
- "grtype": Payment terms from bilty: "TBB" (To Be Billed).

2. partially Present:
- "pmark" (Container / Transit Seal Number):
  * TOP HEADER/MARGIN CASE: Written near top right header/logo (e.g. 'Seal. No- 03386', 'Seal No - 03330') -> extract pure digits ('03386').
  * MIDDLE OF LR/GOODS TABLE CASE: Stamped or written in the middle of 'Description (Said to Contain)' goods area (e.g. 'Seal no: 002765') -> extract pure digits ('002765') into pmark. NEVER treat this middle seal as LR No, and NEVER keep it inside goods description.
  * If no physical container seal was applied, return strictly empty string "".
- "Driver Name *": Driver full legal name from the attached Indian Union Driving Licence (DL) card (typically on Page 5 or 6, e.g., "OM PRAKASH", "JITENDRA JHA", "SRI SANT RAM", "DEVIDAS"). If no DL is attached, leave strictly as empty string "" for manual operator entry.
- "Mobile no   *": Driver 10-digit mobile number. Extracted ONLY if explicitly written for the driver on the bilty or documents. If absent, leave strictly as "". Shipper/transporter contact numbers are never auto-filled.
- "Liscense No *": Commercial driving licence number from the attached DL card (e.g., "UP33 20170006650", "BR10 20000001762", "UP75 20110022749", "UP81 20170010781"). If absent, leave strictly as "".
- "Valid Up to *": Transport validity expiry date on the attached DL card (strictly the 'TR' transport date, e.g. 'Validity(TR)', strictly formatted DD/MM/YYYY, e.g., "27/03/2027", "11/05/2027", "25/04/2030", "04/04/2027"). If absent, leave strictly as "".
- "productcode": Product / HSN code from Tax Invoice (e.g., "96190030"). Left empty "" if not itemized.
- "custrefcode": Customer reference code (e.g., "UNICHARM" or party code). Left empty "" if omitted.
- "Depatment Name": Designated warehouse department name (e.g., "GLOBAL-BANGLORE", "GLOBAL MARKETING-MT"). Left empty "" if not specified.
- "branchrefcode" / "Counter name": Hub center code (e.g., "GURGAON", "DELHI", "SANAND") if specified in bilty header.
- "oamount": Other charges (unloading, hamali, detention, misc charges). Extract numeric value ONLY if explicitly written in the bilty or notes (e.g. 'Unloading charge 1000/-' -> 1000.00). If absent or FTL without additional charges, return strictly 0.00. NEVER copy the invoice goods value (valgoods) into oamount.

3. absent:
- "BNF LR No": Permanently removed / discontinued from Excel schema. Never extract.
- "freight  *": Full Truck Load (FTL) contract billed centrally -> return 0.
- "cgst", "sgst": Freight tax -> return 0.00.
- "igst": Always output 0.00 (or 0) for manual entry compliance.
- "received", "advance": Cash received/advanced at booking -> return 0.00.
- "Order Weight", "Contract wt", "Extra Mt": Industrial contract metrics -> return strictly empty string "".
- "viaborder": Transit border checkpost -> return strictly empty string "".

================================================================================
B. PATANJALI (COMPANY NAME)
================================================================================
1. Present:
- "grdt": Consignment booking date printed in 'Bkg. Date' box (strictly DD/MM/YYYY, e.g., 05/02/2026, 09/10/2026).
- "stockdt": Consignment entry date (matches grdt).
- "Customer Name *": "Patanjali Parivahan Private Limited" (always default Customer Name for Patanjali LRs to "Patanjali Parivahan Private Limited").
- "custrefcode": Billing customer/party code (e.g., "BL653", "BL652", or default "CM001").
- "branchrefcode" / "Counter name": Center or branch code printed above title (e.g., "INDORE", "KOLKATA").
- "orgrefcode": Origin station / city printed in 'From City' box (e.g., "INDORE", "KARNPURA SSRM").
- "destrefcode": Destination station / city printed in 'To City' box (e.g., "BANGALORE", "VARANASI", "SUGAULI").
- "collectionstncode": Matches orgrefcode.
- "cngr": Consignor name and full street address printed in 'CONSIGNOR' box (e.g., "PFL20 : PATANJALI FOODS LTD - INDORE, TALAWALI CHANDA OPP MANGALIYAGAON RLY STATION INDUSTRIAL AREA A.B. ROAD INDORE, 453771").
- "cngrgstno": Consignor 15-character GSTIN (e.g., "05AAFCF1505P1ZD").
- "cnge": Consignee name and destination address printed in 'CONSIGNEE' box (e.g., "8888 : PATANJALI FOODS LIMITED, BANGALORE").
- "bookedpckgs": Integer package count printed under 'No. of Package' or 'Total Charged No of Packages' (e.g., 410, 419, 845).
- "packing": Packaging type under 'Packaging Type' (e.g., "BAG", "Carton box").
- "goods": Commodity description under 'Said to Contain' (e.g., "SOYABADI", "BISCUITS").
- "bookedaweight": Actual gross weight in KG printed under 'Actual Wt(Kgs)' (e.g., 7500, 6567).
- "bookedcweight": Charged weight in KG printed under 'Total Charged Weight' (e.g., 7500, 7000).
- "invoiceno": Commercial invoice number from INVOICE DETAILS table (e.g., 8501817437, 8501817324, 8604510455).
- "invoiedt": Commercial invoice date (strictly DD/MM/YYYY).
- "valgoods": Declared invoice value of goods printed under 'Declared Value' without commas (e.g., 476204, 519158).
- "ewaybillno": 12-digit GST E-Way Bill number printed under 'Eway Bill No' (e.g., 612053161654, 811752253963).
- "Vehicle No *": Indian motor vehicle registration plate printed in 'Vehicle Number' box or attached RC Form 23A (e.g., RJ32GC5386, UP21FT4643, BR03K4305).
- "Vehicle Type *": Vehicle body type: "Market".
- "Loading Start date *": Booking date (matches grdt).
- "grtype": Payment terms printed under 'Payment Type': "TBB".
- "ftl": Vehicle load type: "FTL".
- "staxpaidby": Service tax / GST paying party: "C" (Consignor).
- "dlvtype": Delivery type: "D" (Door Delivery) or "G" (Godown).

2. partially Present:
- "grno" / "LR No *" (Strict Pen/Pencil Outer Margin Rule):
  * Check top-left and top-right outer sections (margins outside printed borders) for an independent handwritten/penciled number (e.g., 21349, 21348).
  * If present, extract that exact number.
  * If NOTHING is written in pen/pencil in the outer margins, leave strictly empty ("").
  * CRITICAL: DO NOT fall back to printed 7-digit 'C Note No.' (e.g. 9325388, 9421832) - this is an internal SAP number, NOT the LR number.
  * NEVER confuse vehicle registration numbers with LR number.
- "pmark": Extract ONLY if an explicit seal code is stamped (e.g., CJ007567). If only generic notes appear ('all seal ok'), return strictly "".
- "Driver Name *": Driver full name. Extract ONLY if an official Commercial DL is attached in the multi-page dossier (e.g., "MANOJ SINGH"). If absent, leave strictly as "".
- "Mobile no   *": Driver 10-digit mobile number. Extract ONLY if explicitly written for the driver. Consignor telephone (8209435149) or dummy numbers (9999999999) are strictly ignored.
- "Liscense No *": Commercial driving licence number from attached DL card (e.g., "BR44 20110036047"). If absent, leave strictly as "".
- "Valid Up to *": Transport validity expiry date on attached DL card (DD/MM/YYYY, e.g., "10/02/2027"). If absent, leave strictly as "".
- "cngegstno": Consignee 15-character GSTIN if printed; else "".
- "Depatment Name": Destination depot name if printed in Consignee block (e.g., "Depot Popular -Varanasi"); else "".
- "Valid Upto": E-Way Bill validity date from attached E-Way Bill page (DD/MM/YYYY); else "".
- "Transit Days": Integer difference between grdt and Valid Upto; else "".
- "oamount": Other charges (unloading, hamali, detention). Extract numeric value ONLY if explicitly written in bilty or notes (e.g., 'Unloading charge 1000/-' -> 1000.00). If absent or FTL without extra charges, return strictly 0.00. NEVER copy valgoods into oamount.
- "productcode": Product code if itemized; else "".

3. absent:
- "BNF LR No": Permanently removed from schema. Never extract.
- "freight  *": Printed as 'xxxx' across all rows on bilty face (FTL TBB contract) -> return 0.
- "cgst", "sgst": Printed as 'xxxx' -> return 0.00.
- "igst": Always output 0.00 (or 0) for manual entry compliance.
- "received", "advance": Printed as 'xxxx' -> return 0.00.
- "Order Weight", "Contract wt", "Extra Mt", "viaborder": Return strictly empty string "".

================================================================================
C. HIMALAYA (COMPANY NAME)
================================================================================
1. Present:
- "grno" / "LR No *": Primary Consignment / LR Tracking Number. Bold printed 5-digit number in 'CONSIGNMENT NOTE: No.' box at top right (e.g., 32752, 32754, 32760, 32978, 33118). Never confuse truck plate with LR number.
- "grdt": Consignment booking date written in 'Date' box (strictly DD/MM/YYYY, e.g., 12/10/2026).
- "stockdt": Consignment entry date (matches grdt).
- "Customer Name *": Corporate billed account: "Himalaya Wellness Company".
- "cngr": Full Consignor Name & street address from 'Consignor's Name & Address' box or attached Tax Invoice/E-Way Bill (e.g., Makali Bangalore central warehouse).
- "cngrgstno": Consignor 15-character GSTIN: "29AADFT3025B2ZK" for Makali Bangalore.
- "cnge": Full Consignee Name & destination address (e.g., Indore CFA, Kolkata CFA).
- "cngegstno": Consignee 15-character GSTIN ("23AADFT3025B1ZX" for Indore, "19AADFT3025B1ZM" for Kolkata).
- "orgrefcode": Origin station / city in 'From' box (e.g., "Bangalore (MWH)", "Prithampur", "Jalgaon").
- "destrefcode": Destination station / city in 'To' box (e.g., "Indore (MWH)", "Kolkata (MWH)", "Bangalore").
- "collectionstncode": Matches orgrefcode.
- "bookedpckgs": Integer count under 'No. of Packages' (e.g., 2812, 2750, 650).
- "packing": Packaging format ("Box", "Cartons", "Barrels").
- "goods": Nature of commodity ("AYURVEDIC MEDICINES & BABY CARE PRODUCTS").
- "bookedaweight": Actual gross cargo weight in KG. (If specified as '15 mt' on bilty face -> convert to 15000; or record exact KG from Tax Invoice like 14979).
- "bookedcweight": Charged weight in KG.
- "invoiceno": Commercial shipper invoice number (e.g., 5526701832, 5526701889, MPR 2627/BOS01035).
- "invoiedt": Commercial invoice date (DD/MM/YYYY).
- "valgoods": Declared invoice value of goods in INR (numeric without commas, e.g., 11488522.00, 7646623.00).
- "ewaybillno": 12-digit GST E-Way Bill number from bilty or attached E-Way Bill (e.g., 102566549518).
- "Valid Upto": E-Way Bill validity date from E-Way Bill header (DD/MM/YYYY).
- "Transit Days": Calculated integer difference between grdt and Valid Upto.
- "Vehicle No *": Indian motor vehicle registration plate (e.g., GJ05BZ0237, RJ14GT3819, MP09HH0830).
- "Vehicle Type *": Vehicle body type: "32FT CONTAINER", "22FT / 6 MT", "32FT MXL", or "Market".
- "Loading Start date *": Booking date (matches grdt).
- "ftl": Vehicle load type: "FTL".
- "staxpaidby": Party paying GST on freight: "C" (Consignor).
- "dlvtype": Delivery type: "D" (Door Delivery).
- "grtype": Payment terms: "TBB" (To Be Billed).

2. partially Present:
- "pmark" (Container Seal Number / Private Mark):
  * Extract ONLY pure digits or seal code (e.g., 00153, 00105, CJ007567) from top margin, description notes, or attached bottle seal photograph.
  * Strictly strip and ignore prefixes like 'Seal', 'Seal No', 'No', '=', ':'.
  * CRITICAL: The seal number must NEVER be mapped into the LR number.
  * If no physical seal is present, leave strictly as empty string "".
- "Driver Name *": Driver full legal name. Extract ONLY if an official Commercial Driving Licence (DL) or PAN card is attached in the multi-page dossier (e.g., "JAYMANGAL RAI", "AARIF"). If absent (e.g. single-page uploads), leave strictly as empty string "".
- "Mobile no   *": Driver 10-digit phone number. Extract ONLY if explicitly written for the driver; else "".
- "Liscense No *": Commercial driving licence number from attached DL card (e.g., "MH02 20040039639"). If absent, leave strictly as "".
- "Valid Up to *": Transport validity expiry date on attached DL card ('TR' date, DD/MM/YYYY, e.g., "27/08/2030"). If absent, leave strictly as "".
- "oamount": Other charges (unloading, hamali, detention). If handwritten margin notes specify unloading charges (e.g., "Unloading charges RS. 4200./-", "unloading Charge = 1500/-"), capture numeric (4200 or 1500). If absent or FTL without extra charges, return strictly 0.00. NEVER copy valgoods into oamount.
- "Depatment Name": Destination department name matched against manifest (e.g., "HIMALAYA-INDORE", "HIMALAYA-KOLKATA").
- "custrefcode", "productcode", "branchrefcode" / "Counter name": Extract if present; else "".

3. absent:
- "BNF LR No": Permanently removed from schema. Never extract.
- "freight  *": Contracted under Full Truck Load (FTL) -> return 0.
- "cgst", "sgst": Freight tax under FTL / RCM -> return 0.00.
- "igst": Always output 0.00 (or 0) for manual entry compliance.
- "received", "advance": Cash received/advanced at booking -> return 0.00.
- "stcharges", "fuelcharges", "handlingcharges", "hamali", "doorcharges", "insurancecharges": Return 0.00.
- "Order Weight", "Contract wt", "Extra Mt", "viaborder": Return strictly empty string "".

================================================================================
D. GOLD PLUS (COMPANY NAME)
================================================================================
1. Present:
- "grno" / "LR No *": Primary Consignment / LR Tracking Number. Bold printed 5-digit number in 'CONSIGNMENT NOTE: No.' box at top right of Box N Freight bilty (e.g., 31745, 31746, 31744, 31878), or from Tax Invoice 'LR No'.
- "grdt": Consignment booking date in 'Date' box (strictly DD/MM/YYYY, e.g., 01/10/2026).
- "stockdt": Consignment entry date (matches grdt).
- "Customer Name *": Corporate billed entity: "GOLD PLUS FLOAT GLASS PRIVATE LIMITED".
- "cngr": "M/S. GOLD PLUS FLOAT GLASS PVT. LTD., Road No. 10-14, Kanagala Industrial Area Kiadb, Tal. Hukkeri, Dist. Belagavi, Karnataka - 591225".
- "cngrgstno": "29AAICG7897C1Z1".
- "cnge": Full Consignee Name & destination address from bilty or Tax Invoice (e.g., "M/S. FORTUNE SAFETY GLASS, Udupi, Karnataka").
- "cngegstno": Consignee 15-character GSTIN (e.g., "29AAFFF7172H1Z5").
- "orgrefcode": Origin station / city from 'From' box on bilty: "Kanagal" (or "Belgaum" / "Belagavi").
- "destrefcode": Destination station / city from 'To' box on bilty: "Udupi" (or "Mangalore", "Bangalore").
- "collectionstncode": Matches orgrefcode.
- "bookedpckgs" / "stockpckgs": Package count under 'No. of Packages' (e.g., 12).
- "packing": Packaging format: "Boxes" or "Frames".
- "goods": Commodity description: "Float Glass" or "Clear Float Glass".
- "bookedaweight" / "stockaweight": Actual cargo gross weight in KG. Bilty specifies Metric Tons (e.g., '29.460 MT'), convert to exact kilograms: 29460. Cross-verified against Weighment Slip Net Weight.
- "bookedcweight" / "stockcweight": Charged weight in KG (matches actual weight 29460).
- "invoiceno": Commercial invoice number from bilty or Tax Invoice (e.g., 26271010344 or 262710344).
- "invoiedt": Commercial invoice date from Tax Invoice (DD/MM/YYYY, e.g., 01/10/2026).
- "valgoods": Declared invoice value / Total invoice amount without commas (e.g., 1285094.81).
- "ewaybillno": 12-digit GST E-Way Bill number from bilty or E-Way Bill page (e.g., 132567309121).
- "Valid Upto": E-Way Bill validity expiry date from E-Way Bill header (DD/MM/YYYY, e.g., 04/10/2026).
- "Transit Days": Calculated integer difference between booking date (01/10/2026) and E-Way validity (04/10/2026) = 3.
- "Vehicle No *": Indian motor vehicle registration plate from bilty, Gate Pass, or Weighment Slip (e.g., KA25AB2955, KA22D0257, KA23A5937).
- "Vehicle Type *": Vehicle body type: "Market".
- "Loading Start date *": Booking date (matches grdt).
- "ftl": Vehicle load type: "FTL" (Full Truck Load).
- "staxpaidby": Party paying GST on freight: "C" (Consignor).
- "dlvtype": Delivery type: "D" (Door Delivery).
- "grtype": Payment terms: "TBB" (To Be Billed).

2. partially Present:
- "Mobile no   *": Driver 10-digit mobile number. In Gold Plus dossiers, inspect the Tax Invoice header under 'Driver No:' (e.g., 7338673806). Extract if printed; else "".
- "pmark": Extract seal or stencil mark if printed/stamped on bilty; else "".
- "Driver Name *": Driver full name. Captured ONLY if an official Driving Licence (DL) is attached or driver signature/name is written; otherwise strictly "".
- "Liscense No *" & "Valid Up to *": Captured ONLY from attached DL card; otherwise strictly "".
- "Depatment Name": Destination department matched against manifest ("GOLD PLUS-BELGUAM").
- "branchrefcode" / "Counter name": Hub center code (e.g., "BEL" / "BELGAUM") if printed.
- "custrefcode": Customer account code (e.g., "GOLDPLUS" or party code) if printed.
- "productcode": Product / HSN code if itemized (e.g., "7005" for float glass).
- "oamount": Other charges (unloading, hamali, detention). Extract numeric value ONLY if explicitly written; if absent or FTL without extra charges, return strictly 0.00. NEVER copy valgoods into oamount.

3. absent:
- "BNF LR No": Permanently removed from schema. Never extract.
- "freight  *": Full Truck Load (FTL) contract billed centrally -> return 0.
- "cgst", "sgst": Freight tax under FTL / RCM -> return 0.00.
- "igst": Always output 0.00 (or 0) for manual entry compliance.
- "received", "advance": Cash received/advanced at booking -> return 0.00.
- "stcharges", "fuelcharges", "handlingcharges", "hamali", "doorcharges", "insurancecharges": Return 0.00.
- "Order Weight", "Contract wt", "Extra Mt", "viaborder": Return strictly empty string "".

================================================================================
E. GENERIC BNF & OTHER CLIENTS (MANI-FEST)
================================================================================
- Apply standard Box N Freight layout extraction.
- Extract primary bold printed Consignment Note number as "grno" and "LR No *".
- For orange/yellow paper bilties: BNF LR No is permanently removed / blank.
- Capture driver credentials ONLY if explicitly written or attached; never invent.
- Under FTL freight contracts, return 0 for freight.

### STEP 2.5: CANONICAL 49-COLUMN KEY NAMES FOR KEY_VALUE_PAIRS
When outputting `key_value_pairs`, every extracted field MUST use the standardized canonical BNF schema key names below (NEVER use raw form labels like 'Consignment Note No', 'Tempo/Truck No', 'Consignor Name & Address', 'Description (Said to Contain)', 'No. of Packages'):
- "grno" and "LR No *": Primary Consignment / LR Tracking Number (e.g. bold 5-digit number like 30035, 33118).
- "grdt" and "grdt *": Consignment booking date (strictly DD/MM/YYYY, e.g. 05/08/2026).
- "Vehicle No *": Indian motor vehicle registration plate (e.g. PB13AR4739, MH43Y5002).
- "Vehicle Type *": Vehicle body type (e.g. Market, 32 FT, 22 FT).
- "Customer Name *": Corporate billed entity (e.g. Himalaya Wellness Company, UNICHARM INDIA PVT. LTD., PATANJALI FOODS LTD).
- "cngr" and "cngr *": Consignor name & full address.
- "cnge" and "cnge *": Consignee name & destination address.
- "cngrgstno" and "cngrgstno *": Consignor 15-character GSTIN.
- "cngegstno" and "cngegstno *": Consignee 15-character GSTIN.
- "orgrefcode": Origin station / city from 'From' box (e.g. HYDERABAD, Bangalore).
- "destrefcode": Destination station / city from 'To' box (e.g. Haryana (Ambada), Kolkata).
- "goods": Commodity description / material from 'Description (Said to Contain)'.
- "bookedpckgs" and "stockpckgs": Integer package count from 'No. of Packages'.
- "bookedaweight" and "stockaweight": Actual weight in KG.
- "bookedcweight" and "stockcweight": Charged weight in KG.
- "invoiceno": Commercial invoice number.
- "invoiedt": Commercial invoice date (DD/MM/YYYY).
- "valgoods": Declared invoice goods value (numeric without commas).
- "ewaybillno": 12-digit GST E-Way Bill number.
- "Valid Upto": E-Way Bill validity expiry date (DD/MM/YYYY).
- "Transit Days": Days difference between booking date and E-Way validity.
- "grtype": Payment terms ('TBB', 'TO PAY', 'PAID').
- "pmark": Container seal number (digits only, e.g. 001678).
- "packing": Packaging format (Box, Bag, Cartons, Barrels).
- "Driver Name *": Driver full name from attached DL.
- "Mobile no   *": Driver 10-digit mobile number.
- "Liscense No *": Driver commercial licence number from attached DL.
- "Valid Up to *": Driver DL transport validity expiry date (DD/MM/YYYY).
- "Loading Start date *": Booking date (DD/MM/YYYY).
- "freight  *": Freight amount (0 if FTL contract).
- "oamount": Other charges (0.00 if absent).
- "ftl": Load type (FTL, LTL, N).
- "staxpaidby": GST paying party (C, E, T).
- "dlvtype": Delivery type (D, G).

### STEP 3: STRICT ZERO-HALLUCINATION ENFORCEMENT
1. If any field is classified as absent or is not visibly present in the document/attachments, return strictly empty string "" (or 0.00 / 0 for numeric amounts).
2. Never auto-fill fake or dummy driver names, license numbers, or phone numbers.
3. Return valid JSON matching all 49 keys exactly.
"""

DEFAULT_HIMALAYA_OCR_PROMPT = STEP_0_AUTHENTICITY_RULES + "\n\n" + """
You are an expert OCR and document information scraping engine specialized in reading transport bilties, consignment notes, and associated multi-page vehicle/driver compliance packets for 'BOX N FREIGHT LOGISTICS SOLUTIONS PVT. LTD.' and 'Himalaya Wellness Company'.

DOCUMENT & MULTI-PAGE DOSSIER INSTRUCTIONS:
This document dossier contains:
- Primary BNF Consignment Note / Bilty.
- GST E-Way Bill (12-digit tracking, dispatch addresses, exact distance).
- Himalaya Wellness Company Tax Invoice (commercial invoice number, billing party, gross weight in KG, declared value).
- Vehicle Registration Certificate (RC Form 23A) and Commercial Driving Licence (DL).
- Physical container bottle-seal lock photograph.
Inspect ALL pages thoroughly and map the data strictly into the 49 target columns:

1. Present:
- "grno" / "LR No *": Primary Consignment / LR Tracking Number. Bold printed 5-digit number in the 'CONSIGNMENT NOTE: No.' box at top right (e.g., 32752, 32754, 32760, 32978, 33118). Never confuse the truck registration number with the Consignment Note number. Note: 'BNF LR' is discontinued.
- "grdt": Consignment booking date written in 'Date' box (strictly DD/MM/YYYY, e.g., 12/10/2026).
- "stockdt": Consignment entry date (matches grdt).
- "Customer Name *": Corporate billed account: "Himalaya Wellness Company".
- "cngr": Full Consignor Name & street address from 'Consignor's Name & Address' box or attached Tax Invoice/E-Way Bill (e.g., Makali Bangalore central warehouse).
- "cngrgstno": Consignor 15-character GSTIN: "29AADFT3025B2ZK" for Makali Bangalore.
- "cnge": Full Consignee Name & destination address (e.g., Indore CFA, Kolkata CFA).
- "cngegstno": Consignee 15-character GSTIN ("23AADFT3025B1ZX" for Indore, "19AADFT3025B1ZM" for Kolkata).
- "orgrefcode": Origin station / city in 'From' box (e.g., "Bangalore (MWH)", "Prithampur", "Jalgaon").
- "destrefcode": Destination station / city in 'To' box (e.g., "Indore (MWH)", "Kolkata (MWH)", "Bangalore").
- "collectionstncode": Matches orgrefcode.
- "bookedpckgs": Integer count under 'No. of Packages' (e.g., 2812, 2750, 650).
- "packing": Packaging format ("Box", "Cartons", "Barrels").
- "goods": Nature of commodity ("AYURVEDIC MEDICINES & BABY CARE PRODUCTS").
- "bookedaweight": Actual gross cargo weight in KG. (If specified as '15 mt' on bilty face -> convert to 15000; or record exact KG from Tax Invoice like 14979).
- "bookedcweight": Charged weight in KG.
- "invoiceno": Commercial shipper invoice number (e.g., 5526701832, 5526701889, MPR 2627/BOS01035).
- "invoiedt": Commercial invoice date (DD/MM/YYYY).
- "valgoods": Declared invoice value of goods in INR (numeric without commas, e.g., 11488522.00, 7646623.00).
- "ewaybillno": 12-digit GST E-Way Bill number from bilty or attached E-Way Bill (e.g., 102566549518).
- "Valid Upto": E-Way Bill validity date from E-Way Bill header (DD/MM/YYYY).
- "Transit Days": Calculated integer difference between grdt and Valid Upto.
- "Vehicle No *": Indian motor vehicle registration plate (e.g., GJ05BZ0237, RJ14GT3819, MP09HH0830).
- "Vehicle Type *": Vehicle body type: "32FT CONTAINER", "22FT / 6 MT", "32FT MXL", or "Market".
- "Loading Start date *": Booking date (matches grdt).
- "ftl": Vehicle load type: "FTL".
- "staxpaidby": Party paying GST on freight: "C" (Consignor).
- "dlvtype": Delivery type: "D" (Door Delivery).
- "grtype": Payment terms: "TBB" (To Be Billed).

2. partially Present:
- "pmark" (Container Seal Number / Private Mark):
  * Extract ONLY pure digits or seal code (e.g., 00153, 00105, CJ007567) from top margin, description notes, or attached bottle seal photograph.
  * Strictly strip and ignore prefixes like 'Seal', 'Seal No', 'No', '=', ':'.
  * CRITICAL: The seal number must NEVER be mapped into the LR number.
  * If no physical seal is present, leave strictly as empty string "".
- "Driver Name *": Driver full legal name. Extract ONLY if an official Commercial Driving Licence (DL) or PAN card is attached in the multi-page dossier (e.g., "JAYMANGAL RAI", "AARIF"). If absent (e.g. single-page uploads), leave strictly as empty string "".
- "Mobile no   *": Driver 10-digit phone number. Extract ONLY if explicitly written for the driver; else "".
- "Liscense No *": Commercial driving licence number from attached DL card (e.g., "MH02 20040039639"). If absent, leave strictly as "".
- "Valid Up to *": Transport validity expiry date on attached DL card ('TR' date, DD/MM/YYYY, e.g., "27/08/2030"). If absent, leave strictly as "".
- "oamount": Other charges (unloading, hamali, detention). If handwritten margin notes specify unloading charges (e.g., "Unloading charges RS. 4200./-", "unloading Charge = 1500/-"), capture numeric (4200 or 1500). If absent or FTL without extra charges, return strictly 0.00. NEVER copy valgoods into oamount.
- "Depatment Name": Destination department name matched against manifest (e.g., "HIMALAYA-INDORE", "HIMALAYA-KOLKATA").
- "custrefcode", "productcode", "branchrefcode" / "Counter name": Extract if present; else "".

3. absent:
- "BNF LR No": Permanently removed from schema. Never extract.
- "freight  *": Contracted under Full Truck Load (FTL) -> return 0.
- "cgst", "sgst": Freight tax under FTL / RCM -> return 0.00.
- "igst": Always output 0.00 (or 0) for manual entry compliance.
- "received", "advance": Cash received/advanced at booking -> return 0.00.
- "stcharges", "fuelcharges", "handlingcharges", "hamali", "doorcharges", "insurancecharges": Return 0.00.
- "Order Weight", "Contract wt", "Extra Mt", "viaborder": Return strictly empty string "".

Produce valid JSON object matching all 49 keys exactly.
"""

DEFAULT_GOLD_PLUS_OCR_PROMPT = STEP_0_AUTHENTICITY_RULES + "\n\n" + """
You are an expert OCR and document information scraping engine specialized in reading transport bilties, commercial tax invoices, returnable gate passes, E-Way bills, and weighbridge slips for 'BOX N FREIGHT LOGISTICS SOLUTIONS PVT. LTD.' and 'GOLD PLUS FLOAT GLASS PRIVATE LIMITED'.

DOCUMENT & MULTI-PAGE DOSSIER INSTRUCTIONS:
This document dossier contains:
- Box N Freight Consignment Note (Bilty).
- Returnable Gate Pass (Out).
- Official Tax Invoice (with Driver No explicitly listed).
- GST E-Way Bill (with distance and validity date).
- Weighment Slip (Gross, Tare, Net weights in MT).
Inspect ALL pages thoroughly and map the data strictly into the 49 target columns:

1. Present:
- "grno" / "LR No *": Primary Consignment / LR Tracking Number. Bold printed 5-digit number in 'CONSIGNMENT NOTE: No.' box at top right of Box N Freight bilty (e.g., 31745, 31746, 31744, 31878), or from Tax Invoice 'LR No'.
- "grdt": Consignment booking date in 'Date' box (strictly DD/MM/YYYY, e.g., 01/10/2026).
- "stockdt": Consignment entry date (matches grdt).
- "Customer Name *": Corporate billed entity: "GOLD PLUS FLOAT GLASS PRIVATE LIMITED".
- "cngr": "M/S. GOLD PLUS FLOAT GLASS PVT. LTD., Road No. 10-14, Kanagala Industrial Area Kiadb, Tal. Hukkeri, Dist. Belagavi, Karnataka - 591225".
- "cngrgstno": "29AAICG7897C1Z1".
- "cnge": Full Consignee Name & destination address from bilty or Tax Invoice (e.g., "M/S. FORTUNE SAFETY GLASS, Udupi, Karnataka").
- "cngegstno": Consignee 15-character GSTIN (e.g., "29AAFFF7172H1Z5").
- "orgrefcode": Origin station / city from 'From' box on bilty: "Kanagal" (or "Belgaum" / "Belagavi").
- "destrefcode": Destination station / city from 'To' box on bilty: "Udupi" (or "Mangalore", "Bangalore").
- "collectionstncode": Matches orgrefcode.
- "bookedpckgs" / "stockpckgs": Package count under 'No. of Packages' (e.g., 12).
- "packing": Packaging format: "Boxes" or "Frames".
- "goods": Commodity description: "Float Glass" or "Clear Float Glass".
- "bookedaweight" / "stockaweight": Actual cargo gross weight in KG. Bilty specifies Metric Tons (e.g., '29.460 MT'), convert to exact kilograms: 29460. Cross-verified against Weighment Slip Net Weight.
- "bookedcweight" / "stockcweight": Charged weight in KG (matches actual weight 29460).
- "invoiceno": Commercial invoice number from bilty or Tax Invoice (e.g., 26271010344 or 262710344).
- "invoiedt": Commercial invoice date from Tax Invoice (DD/MM/YYYY, e.g., 01/10/2026).
- "valgoods": Declared invoice value / Total invoice amount without commas (e.g., 1285094.81).
- "ewaybillno": 12-digit GST E-Way Bill number from bilty or E-Way Bill page (e.g., 132567309121).
- "Valid Upto": E-Way Bill validity expiry date from E-Way Bill header (DD/MM/YYYY, e.g., 04/10/2026).
- "Transit Days": Calculated integer difference between booking date (01/10/2026) and E-Way validity (04/10/2026) = 3.
- "Vehicle No *": Indian motor vehicle registration plate from bilty, Gate Pass, or Weighment Slip (e.g., KA25AB2955, KA22D0257, KA23A5937).
- "Vehicle Type *": Vehicle body type: "Market".
- "Loading Start date *": Booking date (matches grdt).
- "ftl": Vehicle load type: "FTL" (Full Truck Load).
- "staxpaidby": Party paying GST on freight: "C" (Consignor).
- "dlvtype": Delivery type: "D" (Door Delivery).
- "grtype": Payment terms: "TBB" (To Be Billed).

2. partially Present:
- "Mobile no   *": Driver 10-digit mobile number. In Gold Plus dossiers, inspect the Tax Invoice header under 'Driver No:' (e.g., 7338673806). Extract if printed; else "".
- "pmark": Extract seal or stencil mark if printed/stamped on bilty; else "".
- "Driver Name *": Driver full name. Captured ONLY if an official Driving Licence (DL) is attached or driver signature/name is written; otherwise strictly "".
- "Liscense No *" & "Valid Up to *": Captured ONLY from attached DL card; otherwise strictly "".
- "Depatment Name": Destination department matched against manifest ("GOLD PLUS-BELGUAM").
- "branchrefcode" / "Counter name": Hub center code (e.g., "BEL" / "BELGAUM") if printed.
- "custrefcode": Customer account code (e.g., "GOLDPLUS" or party code) if printed.
- "productcode": Product / HSN code if itemized (e.g., "7005" for float glass).
- "oamount": Other charges (unloading, hamali, detention). Extract numeric value ONLY if explicitly written; if absent or FTL without extra charges, return strictly 0.00. NEVER copy valgoods into oamount.

3. absent:
- "BNF LR No": Permanently removed from schema. Never extract.
- "freight  *": Full Truck Load (FTL) contract billed centrally -> return 0.
- "cgst", "sgst": Freight tax under FTL / RCM -> return 0.00.
- "igst": Always output 0.00 (or 0) for manual entry compliance.
- "received", "advance": Cash received/advanced at booking -> return 0.00.
- "stcharges", "fuelcharges", "handlingcharges", "hamali", "doorcharges", "insurancecharges": Return 0.00.
- "Order Weight", "Contract wt", "Extra Mt", "viaborder": Return strictly empty string "".

Produce valid JSON object matching all 49 keys exactly.
"""

DEFAULT_PATANJALI_OCR_PROMPT = STEP_0_AUTHENTICITY_RULES + "\n\n" + """
You are an expert OCR and document information scraping engine specialized in reading transport bilties, consignment notes, and driver/vehicle compliance credentials for 'PATANJALI PARIVAHAN PVT. LTD.' and 'PATANJALI FOODS LIMITED' (formerly Ruchi Soya Industries Limited).

DOCUMENT & MULTI-PAGE DOSSIER INSTRUCTIONS:
This document may contain a single page (white printed consignment note) or multiple pages (including Form 23A Vehicle Registration Certificate RC and Commercial Driving Licence DL).
Inspect ALL pages thoroughly and map the data strictly into the 49 target columns:

1. Present:
- "grdt": Consignment booking date printed in 'Bkg. Date' box (strictly DD/MM/YYYY, e.g., 05/02/2026, 09/10/2026).
- "stockdt": Consignment entry date (matches grdt).
- "Customer Name *": "Patanjali Parivahan Private Limited" (always default Customer Name for Patanjali LRs to "Patanjali Parivahan Private Limited").
- "custrefcode": Billing customer/party code (e.g., "BL653", "BL652", or default "CM001").
- "branchrefcode" / "Counter name": Center or branch code printed above title (e.g., "INDORE", "KOLKATA").
- "orgrefcode": Origin station / city printed in 'From City' box (e.g., "INDORE", "KARNPURA SSRM").
- "destrefcode": Destination station / city printed in 'To City' box (e.g., "BANGALORE", "VARANASI", "SUGAULI").
- "collectionstncode": Matches orgrefcode.
- "cngr": Consignor name and full street address printed in 'CONSIGNOR' box (e.g., "PFL20 : PATANJALI FOODS LTD - INDORE, TALAWALI CHANDA OPP MANGALIYAGAON RLY STATION INDUSTRIAL AREA A.B. ROAD INDORE, 453771").
- "cngrgstno": Consignor 15-character GSTIN (e.g., "05AAFCF1505P1ZD").
- "cnge": Consignee name and destination address printed in 'CONSIGNEE' box (e.g., "8888 : PATANJALI FOODS LIMITED, BANGALORE").
- "bookedpckgs": Integer package count printed under 'No. of Package' or 'Total Charged No of Packages' (e.g., 410, 419, 845).
- "packing": Packaging type under 'Packaging Type' (e.g., "BAG", "Carton box").
- "goods": Commodity description under 'Said to Contain' (e.g., "SOYABADI", "BISCUITS").
- "bookedaweight": Actual gross weight in KG printed under 'Actual Wt(Kgs)' (e.g., 7500, 6567).
- "bookedcweight": Charged weight in KG printed under 'Total Charged Weight' (e.g., 7500, 7000).
- "invoiceno": Commercial invoice number from INVOICE DETAILS table (e.g., 8501817437, 8501817324, 8604510455).
- "invoiedt": Commercial invoice date (strictly DD/MM/YYYY).
- "valgoods": Declared invoice value of goods printed under 'Declared Value' without commas (e.g., 476204, 519158).
- "ewaybillno": 12-digit GST E-Way Bill number printed under 'Eway Bill No' (e.g., 612053161654, 811752253963).
- "Vehicle No *": Indian motor vehicle registration plate printed in 'Vehicle Number' box or attached RC Form 23A (e.g., RJ32GC5386, UP21FT4643, BR03K4305).
- "Vehicle Type *": Vehicle body type: "Market".
- "Loading Start date *": Booking date (matches grdt).
- "grtype": Payment terms printed under 'Payment Type': "TBB".
- "ftl": Vehicle load type: "FTL".
- "staxpaidby": Service tax / GST paying party: "C" (Consignor).
- "dlvtype": Delivery type: "D" (Door Delivery) or "G" (Godown).

2. partially Present:
- "grno" / "LR No *" (Strict Pen/Pencil Outer Margin Rule):
  * Check top-left and top-right outer sections (margins outside printed borders) for an independent handwritten/penciled number (e.g., 21349, 21348).
  * If present, extract that exact number.
  * If NOTHING is written in pen/pencil in the outer margins, leave strictly empty ("").
  * CRITICAL: DO NOT fall back to printed 7-digit 'C Note No.' (e.g. 9325388, 9421832) - this is an internal SAP number, NOT the LR number.
  * NEVER confuse vehicle registration numbers with LR number.
- "pmark": Extract ONLY if an explicit seal code is stamped (e.g., CJ007567). If only generic notes appear ('all seal ok'), return strictly "".
- "Driver Name *": Driver full name. Extract ONLY if an official Commercial DL is attached in the multi-page dossier (e.g., "MANOJ SINGH"). If absent, leave strictly as "".
- "Mobile no   *": Driver 10-digit mobile number. Extract ONLY if explicitly written for the driver. Consignor telephone (8209435149) or dummy numbers (9999999999) are strictly ignored.
- "Liscense No *": Commercial driving licence number from attached DL card (e.g., "BR44 20110036047"). If absent, leave strictly as "".
- "Valid Up to *": Transport validity expiry date on attached DL card (DD/MM/YYYY, e.g., "10/02/2027"). If absent, leave strictly as "".
- "cngegstno": Consignee 15-character GSTIN if printed; else "".
- "Depatment Name": Destination depot name if printed in Consignee block (e.g., "Depot Popular -Varanasi"); else "".
- "Valid Upto": E-Way Bill validity date from attached E-Way Bill page (DD/MM/YYYY); else "".
- "Transit Days": Integer difference between grdt and Valid Upto; else "".
- "oamount": Other charges (unloading, hamali, detention). Extract numeric value ONLY if explicitly written in bilty or notes (e.g., 'Unloading charge 1000/-' -> 1000.00). If absent or FTL without extra charges, return strictly 0.00. NEVER copy valgoods into oamount.
- "productcode": Product code if itemized; else "".

3. absent:
- "BNF LR No": Permanently removed from schema. Never extract.
- "freight  *": Printed as 'xxxx' across all rows on bilty face (FTL TBB contract) -> return 0.
- "cgst", "sgst": Printed as 'xxxx' -> return 0.00.
- "igst": Always output 0.00 (or 0) for manual entry compliance.
- "received", "advance": Printed as 'xxxx' -> return 0.00.
- "Order Weight", "Contract wt", "Extra Mt", "viaborder": Return strictly empty string "".

Produce valid JSON object matching all 49 keys exactly.
"""

DEFAULT_UNICHARM_OCR_PROMPT = STEP_0_AUTHENTICITY_RULES + "\n\n" + """
You are an expert OCR and document information scraping engine specialized in reading transport bilties, commercial tax invoices, E-Way bills, and driver/vehicle compliance credentials for 'UNICHARM INDIA PVT. LTD.' (Vuicharm / Uvicharm) transported by 'BOX N FREIGHT LOGISTICS SOLUTIONS PVT. LTD.'.

DOCUMENT & MULTI-PAGE DOSSIER INSTRUCTIONS:
This document dossier contains multiple pages (including Box N Freight Consignment Note Bilty, Unicharm Tax Invoice, E-Way Bill, mParivahan Vehicle RC Status, Truck Photo, and Commercial Driving Licence DL).
Inspect ALL pages thoroughly and map the data strictly into the 49 target columns:

1. Present:
- "grno" / "LR No *": Primary Consignment / LR Tracking Number. Extract bold 5-digit number printed in 'CONSIGNMENT NOTE: No.' box at top right of the Box N Freight bilty (e.g. 32298, 32299, 32300, 33306), or verify from 'Transporter LR No' on the Unicharm Tax Invoice / E-Way Bill Part B.
- "grdt": Consignment booking date in 'Date' box (strictly DD/MM/YYYY, e.g., 27/09/2026).
- "stockdt": Consignment entry date (matches grdt).
- "Customer Name *": Corporate billed entity: "UNICHARM INDIA PVT. LTD.".
- "cngr": "UNICHARM INDIA PVT. LTD., Village Mau, Tehsil Pataudi, District Gurugram, Haryana - 122414" (or Sanand, Gujarat).
- "cngrgstno": "06AABCU0113A2ZA".
- "cnge": "GLOBAL MARKETING-MT, Khasra No. 240, Hamidpur Narela Village, New Delhi - 110036" (or Ambala).
- "cngegstno": "07AJYPK4522G1ZX".
- "orgrefcode": "MAU", "GURGAON", or "SANAND". "destrefcode": "DELHI", "SOUTH DELHI", or "AMBALA".
- "collectionstncode": Matches orgrefcode.
- "bookedpckgs" / "stockpckgs": Integer package count from Tax Invoice 'Total Cases' or bilty 'No. of Packages' (e.g. 1375, 2064, 1251, 797).
- "packing": "Cases" or "Carton box".
- "goods": Commodity description from Tax Invoice (e.g., "Baby Diapers", "MPP All Night Absorb COCO L40"). (Do NOT include seal numbers or invoice numbers in the goods description).
- "bookedaweight" / "stockaweight": Actual gross weight in KG from Tax Invoice or bilty.
- "bookedcweight" / "stockcweight": Charged weight in KG from bilty or Tax Invoice.
- "invoiceno": Commercial invoice number from Tax Invoice (e.g., 10906I26-001898, 10906F26-001407, 3324726-000484).
- "invoiedt": Commercial invoice date from Tax Invoice (DD/MM/YYYY).
- "valgoods": Total declared invoice value of goods from Tax Invoice (numeric without commas, e.g. 2112307.00, 2817236.00).
- "ewaybillno": 12-digit GST E-Way Bill number from E-Way Bill page (e.g., 362343603918).
- "Valid Upto": E-Way Bill validity expiry date (strictly DD/MM/YYYY, e.g., 28/09/2026).
- "Transit Days": Calculated integer difference between grdt and Valid Upto.
- "Vehicle No *": Indian motor vehicle registration plate from bilty 'Tempo/Truck No.', mParivahan RC status, or truck photo (e.g., HR55AX5490, RJ18GB7132, NL01AFS826).
- "Vehicle Type *": Vehicle body type: "Market" (or "32 FT CONTAINER").
- "Loading Start date *": Booking date (matches grdt).
- "ftl": Vehicle container/service type: "FTL" (Dedicated 32 FT container).
- "staxpaidby": GST on freight paying party: "C" (Consignor).
- "dlvtype": Delivery type: "D" (Door Delivery).
- "grtype": Payment terms from bilty: "TBB" (To Be Billed).

2. partially Present:
- "pmark" (Container / Transit Seal Number):
  * TOP HEADER/MARGIN CASE: Written near top right header/logo (e.g. 'Seal. No- 03386', 'Seal No - 03330') -> extract pure digits ('03386').
  * MIDDLE OF LR/GOODS TABLE CASE: Stamped or written in the middle of 'Description (Said to Contain)' goods area (e.g. 'Seal no: 002765') -> extract pure digits ('002765') into pmark. NEVER treat this middle seal as LR No, and NEVER keep it inside goods description.
  * If no physical container seal was applied, return strictly empty string "".
- "Driver Name *": Driver full legal name from the attached Indian Union Driving Licence (DL) card (typically on Page 5 or 6, e.g., "OM PRAKASH", "JITENDRA JHA", "SRI SANT RAM", "DEVIDAS"). If no DL is attached, leave strictly as empty string "" for manual operator entry.
- "Mobile no   *": Driver 10-digit mobile number. Extracted ONLY if explicitly written for the driver on the bilty or documents. If absent, leave strictly as "". Shipper/transporter contact numbers are never auto-filled.
- "Liscense No *": Commercial driving licence number from the attached DL card (e.g., "UP33 20170006650", "BR10 20000001762", "UP75 20110022749", "UP81 20170010781"). If absent, leave strictly as "".
- "Valid Up to *": Transport validity expiry date on the attached DL card (strictly the 'TR' transport date, e.g. 'Validity(TR)', strictly formatted DD/MM/YYYY, e.g., "27/03/2027", "11/05/2027", "25/04/2030", "04/04/2027"). If absent, leave strictly as "".
- "productcode": Product / HSN code from Tax Invoice (e.g., "96190030"). Left empty "" if not itemized.
- "custrefcode": Customer reference code (e.g., "UNICHARM" or party code). Left empty "" if omitted.
- "Depatment Name": Designated warehouse department name (e.g., "GLOBAL-BANGLORE", "GLOBAL MARKETING-MT"). Left empty "" if not specified.
- "branchrefcode" / "Counter name": Hub center code (e.g., "GURGAON", "DELHI", "SANAND") if specified in bilty header.
- "oamount": Other charges (unloading, hamali, detention, misc charges). Extract numeric value ONLY if explicitly written in the bilty or notes (e.g. 'Unloading charge 1000/-' -> 1000.00). If absent or FTL without additional charges, return strictly 0.00. NEVER copy the invoice goods value (valgoods) into oamount.

3. absent:
- "BNF LR No": Permanently removed / discontinued from Excel schema. Never extract.
- "freight  *": Full Truck Load (FTL) contract billed centrally -> return 0.
- "cgst", "sgst": Freight tax -> return 0.00.
- "igst": Always output 0.00 (or 0) for manual entry compliance.
- "received", "advance": Cash received/advanced at booking -> return 0.00.
- "Order Weight", "Contract wt", "Extra Mt": Industrial contract metrics -> return strictly empty string "".
- "viaborder": Transit border checkpost -> return strictly empty string "".

Produce valid JSON object matching all 49 keys exactly.
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


def is_blank_or_solid_image(pil_img: Image.Image) -> bool:
    """
    Safe check: only returns True if image is a pure, solid monochrome digital block
    with near-zero pixel variation across the entire image (std dev < 1.5 on 0-255 scale).
    Never rejects faded carbon-copies, low-light photos, or faint handwriting.
    """
    try:
        thumb = pil_img.convert("L").resize((64, 64))
        pixels = list(thumb.getdata())
        if not pixels:
            return True
        mean = sum(pixels) / len(pixels)
        variance = sum((p - mean) ** 2 for p in pixels) / len(pixels)
        std_dev = variance ** 0.5
        return std_dev < 1.5
    except Exception:
        return False


def _clean_pmark(raw) -> str:
    """
    Extract ONLY the actual seal code or digits (e.g., CJ007567 or 00153).
    Strictly strip and ignore any prefixes, labels, or symbols like Seal, Sealv0, Seaimot, No, =, or : from the extracted value.
    """
    if raw is None:
        return ""
    import re
    s = str(raw).strip()
    if s == "0":
        return "0"
    if not s or s.lower() in ("none", "null", "nan"):
        return ""
    # Strip prefixes like Seal, Sealv0, Seaimot, Seuinol, Seuinoł, Seal No, No, =, :, -, # without eating leading zeros of the seal digits
    s2 = re.sub(r'^(?:(?:seal|seaimot|seuinol|seuino\w?)[\.\s]*(?:no\.?|v0|[a-z]+)?|no[\.:\s]+|[=:#\-\s])+', '', s, flags=re.IGNORECASE).strip()
    s3 = re.sub(r'^[^a-zA-Z0-9]+', '', s2).strip()
    return re.sub(r'[^a-zA-Z0-9]+$', '', s3).strip()


def _clean_grno(raw) -> str:
    """
    Extract the Consignment Note number from the 'CONSIGNMENT NOTE: No.' box.
    If it's a 5-digit number or any valid consignment serial, capture it accurately without dropping it.
    """
    if raw is None:
        return ""
    import re
    s = str(raw).strip()
    if s == "0":
        return "0"
    if not s or s.lower() in ("none", "null", "nan"):
        return ""
    # If it contains an exact standalone 5-digit number (e.g. 32760, 30135, 32754)
    m5 = re.search(r'(?<!\d)(\d{5})(?!\d)', s)
    if m5:
        return m5.group(1)
    # Strip label prefixes like 'CONSIGNMENT NOTE: No.', 'No:', 'CN No.', 'LR No.', 'LR:'
    cleaned = re.sub(
        r'^(?:consign(?:ment)?\s*note\s*:?\s*|c\s*note\s*:?\s*|lr\s*(?:no\.?)?\s*:?\s*|no[\.:\s]+)',
        '',
        s,
        flags=re.IGNORECASE
    ).strip()
    return cleaned or s


def _format_date_ddmmyyyy(raw) -> str:
    """
    Normalizes any date string (e.g., '12-OCT-2026', '12-Oct-26', '2026-10-12', '05 Oct 26')
    strictly into DD-MM-YYYY format (e.g., '12-10-2026').
    If unparseable or empty, returns original stripped string or ''.
    """
    if raw is None:
        return ""
    import re
    from datetime import datetime

    s = str(raw).strip()
    if not s or s.lower() in ("none", "null", "nan"):
        return ""

    # Discard time portions if attached (e.g. '12-OCT-2026 11:59:00 PM' or '2026-10-12T15:30:00' -> '12-OCT-2026')
    s_clean = re.sub(r'T\d{2}:.*$', '', s.strip())
    s_clean = re.sub(r'\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s*[AaPp][Mm])?.*$', '', s_clean).strip()

    # Pattern 1: DD/MM/YYYY, DD-MM-YYYY, DD.MM.YYYY
    m = re.match(r'^(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{2,4})$', s_clean)
    if m:
        day, month, year = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if year < 100:
            year += 2000
        try:
            d = datetime(year, month, day).date()
            return d.strftime("%d-%m-%Y")
        except ValueError:
            pass

    # Pattern 2: DD-Mon-YYYY, DD Mon YYYY, etc. (e.g. 12-OCT-2026, 05 Oct 26)
    for fmt in (
        "%d-%b-%Y", "%d-%b-%y", "%d-%B-%Y", "%d-%B-%y",
        "%d %b %Y", "%d %b %y", "%d %B %Y", "%d %B %y",
        "%d/%b/%Y", "%d/%b/%y",
        "%Y-%m-%d", "%Y/%m/%d", "%Y.%m.%d",
        "%d/%m/%Y", "%d-%m-%Y", "%d.%m.%Y"
    ):
        try:
            d = datetime.strptime(s_clean, fmt).date()
            return d.strftime("%d-%m-%Y")
        except ValueError:
            pass
    return s


DATE_COLUMN_KEYS = {
    "grdate", "drivingvalidupto", "loadingstartdate", "ewaybilldate", "ewaybilldt",
    "validupto", "invoiedate", "stockdt", "grdt", "invoiedt", "exportdate",
    "date", "biltydate", "lrdate", "bookingdate", "deliverydate", "dispatchdate",
    "entrydate", "invoicedate", "dlvalidupto", "dlvalidtill", "valid_up_to"
}


def _parse_to_datetime_obj(raw) -> datetime | None:
    """
    Parses any date string (e.g., '12-OCT-2026', '12-10-2026', '2026-10-12', '12/10/2026')
    or datetime/date object into a native datetime.datetime object (with midnight time).
    Returns None if raw is empty, invalid or unparseable.
    """
    if raw is None:
        return None
    if isinstance(raw, datetime):
        return raw.replace(hour=0, minute=0, second=0, microsecond=0)
    if isinstance(raw, date):
        return datetime(raw.year, raw.month, raw.day, 0, 0)

    s = str(raw).strip()
    if not s or s.lower() in ("none", "null", "nan", ""):
        return None

    # Discard time portions if attached
    s_clean = re.sub(r'T\d{2}:.*$', '', s)
    s_clean = re.sub(r'\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s*[AaPp][Mm])?.*$', '', s_clean).strip()

    # Pattern 1: DD/MM/YYYY, DD-MM-YYYY, DD.MM.YYYY
    m = re.match(r'^(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{2,4})$', s_clean)
    if m:
        day, month, year = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if year < 100:
            year += 2000
        try:
            return datetime(year, month, day, 0, 0)
        except ValueError:
            pass

    for fmt in (
        "%d-%b-%Y", "%d-%b-%y", "%d-%B-%Y", "%d-%B-%y",
        "%d %b %Y", "%d %b %y", "%d %B %y",
        "%d/%b/%Y", "%d/%b/%y",
        "%Y-%m-%d", "%Y/%m/%d", "%Y.%m.%d",
        "%d/%m/%Y", "%d-%m-%Y", "%d.%m.%Y"
    ):
        try:
            parsed = datetime.strptime(s_clean, fmt)
            return parsed.replace(hour=0, minute=0, second=0, microsecond=0)
        except ValueError:
            pass

    return None


def ensure_excel_date_number_formats(excel_bytes: bytes) -> bytes:
    """
    Guarantees that all cellXfs with numFmtId != 0 in xl/styles.xml explicitly have applyNumberFormat="1".
    Skips re-zipping completely when xl/styles.xml already satisfies this requirement.
    """
    if not excel_bytes or not isinstance(excel_bytes, (bytes, bytearray)):
        return excel_bytes
    try:
        in_buf = io.BytesIO(excel_bytes)
        with zipfile.ZipFile(in_buf, "r") as zin:
            if "xl/styles.xml" not in zin.namelist():
                return bytes(excel_bytes)
            styles_text = zin.read("xl/styles.xml").decode("utf-8")

            needs_patch = False
            for m in re.finditer(r'<xf\b[^>]*>', styles_text):
                xf_str = m.group(0)
                num_fmt_match = re.search(r'numFmtId="([^"]+)"', xf_str)
                if num_fmt_match and num_fmt_match.group(1) not in ("0", "") and 'applyNumberFormat=' not in xf_str:
                    needs_patch = True
                    break

            if not needs_patch:
                return bytes(excel_bytes)

            def _patch_xf(match):
                xf_str = match.group(0)
                num_fmt_match = re.search(r'numFmtId="([^"]+)"', xf_str)
                if num_fmt_match and num_fmt_match.group(1) not in ("0", "") and 'applyNumberFormat=' not in xf_str:
                    return re.sub(r'(<xf\b)', r'\1 applyNumberFormat="1"', xf_str, count=1)
                return xf_str

            patched_bytes = re.sub(r'<xf\b[^>]*>', _patch_xf, styles_text).encode("utf-8")
            out_buf = io.BytesIO()
            with zipfile.ZipFile(out_buf, "w", zipfile.ZIP_DEFLATED) as zout:
                for item in zin.infolist():
                    content = patched_bytes if item.filename == "xl/styles.xml" else zin.read(item.filename)
                    zout.writestr(item, content)
            return out_buf.getvalue()
    except Exception as e:
        print(f"[Excel Number Format Patch Notice] {e}")
        return bytes(excel_bytes)



def _calculate_transit_days(start_val, end_val) -> int | str:
    """
    Calculates 'transit_days' by finding the integer difference in days between
    'grdt' (booking date) and 'Valid Upto' (E-Way Bill expiry date) formatted as DD/MM/YYYY.
    If either date is missing, unparseable, or invalid, returns an empty string ("").
    """
    if not start_val or not end_val:
        return ""
    import re
    from datetime import datetime

    def _parse_d(d):
        if not d:
            return None
        s = str(d).strip()
        if not s or s.lower() in ("none", "null", "nan", ""):
            return None
        # Discard time portions if attached (e.g. '08/10/2026 11:59:00 PM' or '2026-10-08T15:30:00' -> '08/10/2026')
        s = re.sub(r'T\d{2}:.*$', '', s.strip())
        s = re.sub(r'\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s*[AaPp][Mm])?.*$', '', s).strip()
        # Primary pattern: DD/MM/YYYY or DD-MM-YYYY or DD.MM.YYYY
        m = re.match(r'^(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{2,4})$', s)
        if m:
            day, month, year = int(m.group(1)), int(m.group(2)), int(m.group(3))
            if year < 100:
                year += 2000
            try:
                return datetime(year, month, day).date()
            except ValueError:
                return None
        # Alternate patterns (e.g. YYYY-MM-DD or DD-Mon-YYYY)
        for fmt in ("%Y-%m-%d", "%Y/%m/%d", "%d-%b-%Y", "%d %b %Y", "%d-%b-%y", "%d %B %Y"):
            try:
                return datetime.strptime(s, fmt).date()
            except ValueError:
                pass
        return None

    d1 = _parse_d(start_val)
    d2 = _parse_d(end_val)
    if d1 and d2:
        diff = (d2 - d1).days
        if diff >= 0:
            return diff
    return ""


def map_to_gr_row(data: dict[str, str], headers: list[str], web_mode: bool = False) -> list:
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
    grno = _clean_grno(get_val("grno", "grno (*)", "LR No *", "LR No", "gr number", "bilty no", "bilty number", "lr no", "lr number", "consignment no", "cn no"))
    grdt = _format_date_ddmmyyyy(get_val("grdt", "grdt *", "gr date", "bilty date", "lr date", "booking date", "date"))
    stockdt = _format_date_ddmmyyyy(get_val("stockdt", "stockdt ", "stock date", "entry date", default=grdt))
    branch = get_val("branchrefcode", "branch", "branch code")
    org = get_val("orgrefcode", "from", "origin", "from station", "booking station")
    dest = get_val("destrefcode", "to", "destination", "to station", "delivery station")
    pickup_point = get_val("PickupPoint", "pickup_point", "pickuppoint", default=org)
    delivery_point = get_val("DeliveryPoint", "delivery_point", "deliverypoint", default=dest)
    cngr = get_val("cngr", "cngr *", "consignor", "sender", "shipper", "consignor name", "from party")
    cnge = get_val("cnge", "cnge *", "consignee", "receiver", "consignee name", "to party")
    cngrgst = get_val("cngrgstno", "cngrgstno *", "consignor gst", "consignor gstin", "sender gst")
    if cngrgst:
        cngrgst = re.sub(r'\s+', '', str(cngrgst)).upper()
    cngegst = get_val("cngegstno", "cngegstno *", "consignee gst", "consignee gstin", "receiver gst")
    if cngegst:
        cngegst = re.sub(r'\s+', '', str(cngegst)).upper()
    packing = get_val("packing", "packaging", "package type")
    pmark = ""  # Private marka strictly blank per business rule
    raw_goods_direct = data.get("goods") or data.get("Goods") or data.get("Description of Goods")
    goods = str(raw_goods_direct).strip() if (raw_goods_direct and str(raw_goods_direct).strip()) else get_val("goods", "goods description", "commodity", "item description", "material")
    # Freight: Must be mandatory manual input. Extract entered value, keep empty if not provided.
    freight_raw = clean_num(get_val("freight  *", "freight", "Freight", "freight charges", "freight charge", "freight amount"))
    freight = freight_raw if (freight_raw is not None and str(freight_raw).strip() != "") else ""

    valgoods = clean_num(get_val("valgoods", "value of goods", "declared value", "goods value", "invoice value"))
    oamount_raw = clean_num(get_val("oamount", "other amount", "other charges", "hamali", "loading charges", "unloading charges", "aoc", "labour", "st charge", "st. charge", "statistical charge", "misc charges", "misc", "ch post"))
    if oamount_raw is not None and oamount_raw != "":
        oamount = oamount_raw
    else:
        oamount = 0.0

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
    eway_dt = _format_date_ddmmyyyy(
        get_val("EwayBillDate", "ewaybilldate", "ewaybilldt", "eway_bill_date", "E-Way Bill Date", "e-way bill date", "ewb date", default=grdt)
    )
    invno = get_val("invoiceno", "invoice no", "bill no", "invoice number")
    invdt = _format_date_ddmmyyyy(get_val("invoiedt", "invoice date", "bill date", default=grdt))

    vehno = get_val("Vehicle No *", "Vehicle No", "vehicle no", "truck no", "lorry no", "veh no", "reg no", "registration no", "rc no")
    raw_vehcategory = data.get("Vehicle Category *") or data.get("Vehicle Category") or get_val("Vehicle Category *", "Vehicle Category", "vehicle category", default="Market")
    vehcategory = "Market" if not raw_vehcategory or str(raw_vehcategory).strip() in ("", "None", "none", "null") else str(raw_vehcategory).strip()
    raw_vehtype = data.get("Vehicle Type *") or data.get("Vehicle Type") or data.get("VehicleTypeName") or get_val("Vehicle Type *", "Vehicle Type", "vehicle type", "truck type", "lorry type", "body type")
    vehtype = str(raw_vehtype).strip() if (raw_vehtype and str(raw_vehtype).strip() and str(raw_vehtype).strip().lower() not in ("none", "null", "nan")) else ""
    driver = get_val("Driver Name *", "Driver Name", "driver name", "driver", "pilot", "owner/driver name", "owner or driver name", "driver/owner name", "owner name", "driver_name")
    mobile = get_val("Mobile no   *", "Mobile no *", "mobile no", "driver mobile", "phone no", "mobile", "contact no", "driver_mobile", "driver phone")
    license = get_val("Liscense No *", "Liscense No", "license no", "dl no", "driving license", "licence no", "driving licence no", "driving licence number", "dl number", "license_no")
    # Decouple Driver Licence Transport validity (Valid Up to *) from E-Way Bill validity (Valid Upto)
    raw_dl_upto = None
    for k, v in data.items():
        k_str = str(k).strip()
        if k_str in ("Valid Up to *", "Valid Up to", "valid_up_to", "dl valid till", "dl_valid_till", "license valid", "driving licence valid"):
            raw_dl_upto = v
            break
        elif "*" in k_str or any(w in k_str.lower() for w in ("dl", "license", "licence", "driver")):
            if clean(k_str) in ("validupto", "licensevalid", "dlvalidtill"):
                if raw_dl_upto is None:
                    raw_dl_upto = v
    if not raw_dl_upto:
        raw_dl_upto = get_val("dl valid till", "license valid", "dl_valid_till", "driving licence valid", "permit valid", "fitness valid")
    valid_up_to = _format_date_ddmmyyyy(raw_dl_upto) if raw_dl_upto else ""

    loading_date = _format_date_ddmmyyyy(get_val("Loading Start date *", "Loading Start date", "loading start date", "loading date", "dispatch date", default=grdt))
    # Customer Name: Directly prioritize user edits from Customer Name * or Customer to prevent stale alias collisions
    raw_cust_direct = data.get("Customer Name *") or data.get("Customer") or data.get("Customer Name") or data.get("customer")
    if raw_cust_direct and str(raw_cust_direct).strip() and str(raw_cust_direct).strip().lower() not in ("none", "null", "nan"):
        customer = str(raw_cust_direct).strip()
    else:
        customer = get_val("Customer Name *", "Customer Name", "customer name", "customer", "party name", "billed to", "account name", default=cngr)
    if web_mode and (not customer or _contains_unicharm_marker(customer)) and _is_unicharm_document(data):
        customer = WEB_UNICHARM_DEFAULT_CUSTOMER
    lrno = _clean_grno(get_val("grno (*)", "grno", "LR No *", "LR No", "lr no", "lr number", "lorry receipt no", "lr #", default=grno)) or grno
    bnflr = get_val("BNF LR No", "bnf lr no", "bnf lr", "bnf no")
    # Auto-detect Department from Origin City matched against ManiFest.xlsx
    dept_raw = data.get("Depatment Name") or data.get("department") or get_val("Depatment Name", "department name", "department", "dept")
    dept = auto_detect_department(origin_city=org, customer=customer, dept_raw=dept_raw)

    # Auto-detect Counter from Origin City matched against BookingCounterMast.xlsx
    counter_raw = data.get("Counter name") or data.get("Counter") or data.get("counter") or get_val("Counter name", "counter name", "counter", "booking counter")
    counter_name = auto_detect_counter(origin_city=org, counter_raw=counter_raw, branch_raw=branch)

    # Strictly extract E-Way Bill expiry date (never fall back to driver license valid_up_to)
    raw_ewb_upto = None
    for k, v in data.items():
        k_str = str(k).strip()
        if k_str in ("Valid Upto", "valid_upto", "ewb valid upto", "ewb_valid_upto", "e-way bill valid upto", "E-way Bill Valid Upto", "ewb validity"):
            raw_ewb_upto = v
            break
        elif clean(k_str) in ("validupto", "ewbvalidupto") and "*" not in k_str and not any(w in k_str.lower() for w in ("dl", "license", "licence", "driver")):
            if raw_ewb_upto is None:
                raw_ewb_upto = v
    valid_upto = _format_date_ddmmyyyy(raw_ewb_upto) if raw_ewb_upto else ""

    # Calculate 'transit_days' by finding the integer difference in days between 'grdt' (booking date)
    # and 'Valid Upto' (E-Way Bill expiry date) formatted as DD/MM/YYYY.
    # If either date is missing, unparseable, or invalid, return an empty string ("") instead of any default fallback number.
    calc_days = _calculate_transit_days(grdt, valid_upto)
    if calc_days != "":
        transit_days = calc_days
    else:
        explicit_transit = clean_num(get_val("Transit Days", "transit days", "transit_days"))
        transit_days = explicit_transit if explicit_transit is not None and str(explicit_transit).strip() != "" else ""

    grtype = get_val("grtype", "grtype(Don’t know)", "grtype(don't know)", "payment type", "pay type", "paid type")
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

    # igst: Always output 0.00 or 0 for manual data entry purposes
    igst = "0.00"
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

    if web_mode:
        custref = ""
        staxpaidby = ""
        dlvtype = ""
        effective_branch = get_branch_name_for_counter(counter_name)
    else:
        effective_branch = branch

    val_map = {
        "stockdt": stockdt,
        "stockdt ": stockdt,
        "branchrefcode": effective_branch,
        "grno": grno or lrno,
        "grno (*)": grno or lrno,
        "grdt": grdt,
        "grdt *": grdt,
        "grtype": grtype,
        "grtype(Don’t know)": grtype,
        "Customer Name *": customer,
        "LR No *": lrno or grno,
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
        "productcode": (
            "" if data.get("productcode") in {"Surface-FTL", "Surface-PTL", "Global-TT", "Global-MT", "AIR"}
            else (data.get("productcode") or get_val("productcode", "Product Code", "product code", default=""))
        ),
        "product_type": (
            data.get("product_type") or data.get("Product Type") or get_val("product_type", "Product Type", "producttype")
            or "Surface-FTL"
        ),
        "packing": packing,
        "pmark": pmark,
        "goods": goods,
        "Vehicle No *": vehno,
        "Vehicle Type *": vehtype,
        "Vehicle Category": vehcategory,
        "Vehicle Category *": vehcategory,
        "Driver Name *": driver,
        "Mobile no   *": mobile,
        "Liscense No *": license,
        "Valid Up to *": valid_up_to,
        "Loading Start date *": loading_date,
        "freight": str(data.get("freight  *") or data.get("freight") or "").strip(),
        "freight  *": str(data.get("freight  *") or data.get("freight") or "").strip(),
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
        "ewaybilldt": eway_dt,
        "Valid Upto": valid_upto,
        "invoiceno": invno,
        "invoiedt": invdt,
        "valgoods": valgoods,
        "viaborder": get_val("viaborder"),
        # Customer_Master_GTInfiniti-Consignment_Entry.xlsx exact 52 headers
        "Branch": effective_branch if web_mode else (branch or counter_name or ""),
        "GrNo": grno or lrno,
        "GrDate": grdt,
        "GrType": grtype,
        "Customer": customer,
        "CustomerDepartment": dept,
        "Countername": counter_name,
        "TransitDays": transit_days,
        "Origen": org,
        "Destination": dest,
        "PickupPoint": pickup_point,
        "DeliveryPoint": delivery_point,
        "Consignor": cngr,
        "ConsignorGST": cngrgst,
        "Consignee": cnge,
        "ConsigneeGST": cngegst,
        "ProductName": (
            data.get("product_type") or data.get("Product Type") or get_val("product_type", "Product Type", "producttype")
            or "Surface-FTL"
        ),
        "Packing": packing,
        "PMark": pmark,
        "Goods": goods,
        "VehicleNo": vehno,
        "VehicleTypeName": vehtype,
        "DriverName": driver,
        "DriverMobileNo": mobile,
        "DrivingLicenseNo": license,
        "DrivingValidUpto": valid_up_to,
        "LoadingStartDate": loading_date,
        "Freight": freight,
        "OtherAmount": oamount,
        "CGST": cgst,
        "SGST": sgst,
        "IGST": igst,
        "Received": received,
        "Advance": advance,
        "CollectionBranch": coll_stn,
        "FTL": ftl,
        "PCS": pkgs,
        "OrderWeight": order_wt,
        "ActualWeight": aweight,
        "ChargableWeight": cweight,
        "ContractWeight": contract_wt,
        "ExtraMt": extra_mt,
        "CustomerRefcode": custref,
        "DeliveryType": dlvtype,
        "EwayBillNo": eway,
        "EwayBillDate": eway_dt,
        "InvoiceNo": invno,
        "InvoieDate": invdt,
        "ValueOfGoods": valgoods
    }

    norm_val_map = {clean(k): v for k, v in val_map.items()}
    row = []
    for h in headers:
        if h in ("igst", "IGST"):
            row.append("0.00")
            continue
        v = val_map.get(h)
        if v is None and h is not None:
            v = norm_val_map.get(clean(str(h)))
        if h in ("grno", "grno (*)", "LR No *", "LR No", "GrNo"):
            cleaned_lr = _clean_grno(v or val_map.get("GrNo") or val_map.get("grno (*)") or val_map.get("LR No *") or val_map.get("grno"))
            is_patanjali_data = (
                "patanjali" in str(val_map.get("Customer Name *") or "").lower()
                or "patanjali" in str(val_map.get("cngr") or "").lower()
                or "patanjali" in str(val_map.get("cngr *") or "").lower()
            )
            if is_patanjali_data and (cleaned_lr == "0" or not cleaned_lr):
                v = None
            elif cleaned_lr == "0":
                v = 0
            elif cleaned_lr:
                v = cleaned_lr
            else:
                v = None
        if h in ("pmark", "PMark"):
            v = None
        if h in ("grdt", "grdt *", "stockdt", "stockdt ", "Loading Start date *", "invoiedt", "ewaybilldt", "Valid Upto", "Valid Up to *", "GrDate", "DrivingValidUpto", "LoadingStartDate", "EwayBillDate", "InvoieDate"):
            v = _format_date_ddmmyyyy(v) or None
        if v is not None and isinstance(v, str):
            if h in ("Depatment Name", "Counter name", "Counter"):
                v_str = v
            else:
                v_str = v.strip()
            if not v_str or v_str.lower() in ("none", "null", "nan"):
                v = None
            elif v_str.isdigit():
                # Preserve leading zeros for seal numbers, codes, and identifiers (e.g. '00153', '00105')
                if v_str.startswith("0") and len(v_str) > 1:
                    v = v_str
                else:
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


MULTI_DOCUMENT_CONSIGNMENT_RULE = """
### STEP 0B: MANDATORY PAGE-BY-PAGE CONSIGNMENT AUDIT & MULTI-LR CHECK
Before extracting fields, inspect EVERY labeled page from Page 1 through the FINAL page (do NOT stop after reading the first LR):
1. `page_lr_entries`: Output one entry for EACH attached page (`page_label`, `is_consignment_note`, `lr_number`, `doc_type`):
   - Set `is_consignment_note: true` ONLY when that page itself is a Lorry Receipt / Consignment Note / Bilty / C-Note receipt, and extract its LR tracking number into `lr_number`.
   - For Tax Invoices, E-Way Bills, Driving Licences, Vehicle RC, or photos, set `is_consignment_note: false` and `lr_number: ""`.
   - CRITICAL: Never treat invoice numbers, vehicle numbers, GSTINs, e-way bill numbers, or seal numbers as LR numbers.
2. `detected_lr_numbers`: Output all unique Consignment Note / LR tracking numbers seen across all Consignment Note / Bilty pages.
3. `has_multiple_different_lrs`:
   - If two or more Consignment Note / Bilty pages carry DIFFERENT LR tracking numbers (multiple shipments uploaded together) -> set `has_multiple_different_lrs: true` and `rejection_reason: 'Multiple LR documents detected. Please upload documents belonging to only one LR at a time.'`.
   - If all pages belong to ONE LR (even with multiple invoices, E-Way bills, RC, or DL) -> set `has_multiple_different_lrs: false` and list that single LR number in `detected_lr_numbers`.
4. DRIVER LICENCE SCANNING: Inspect ALL attached pages through the end of the dossier (including back/trailing pages behind invoices) for any Driving Licence (DL) card. If a DL is attached, extract "Driver Name *", "Liscense No *", and "Valid Up to *" (preferring 'Validity(TR)' expiry date formatted DD/MM/YYYY); if no DL is attached, leave them strictly "".
"""


def _extract_lr_candidates_from_text(text: str) -> set[str]:
    """Extracts Consignment Note / LR tracking numbers from raw text using standard patterns."""
    if not text:
        return set()
    found = set()
    for m in re.finditer(r'(?i)(?:consignment\s*note\s*:?\s*no\.?|c\s*note\s*:?\s*no\.?|lr\s*no\.?|bilty\s*no\.?)[\s:]*([A-Za-z0-9\-]+)', text):
        val = _clean_grno(m.group(1))
        if val and val != "0" and len(val) >= 3:
            found.add(val.lower())
    return found


class PageLrScan(BaseModel):
    is_consignment_note: bool = False
    lr_number: str = ""
    doc_type: str = ""


class PageLrEntry(BaseModel):
    page_label: str
    is_consignment_note: bool = False
    lr_number: str = ""
    doc_type: str = ""


class CombinedLrPreScan(BaseModel):
    pages: list[PageLrEntry] = Field(default_factory=list)
    has_multiple_different_lrs: bool = False
    unique_lrs_found: list[str] = Field(default_factory=list)


COMBINED_LR_PRE_SCAN_PROMPT = """Inspect the attached document pages in sequence.
For EACH page, determine:
1. Is this page a primary Consignment Note / Bilty receipt? (Only set is_consignment_note: true if this page itself IS the transport Consignment Note / Bilty receipt. If it is a Tax Invoice, Delivery Challan, Packing List, E-Way Bill, Driver License, or RC card, set is_consignment_note: false and lr_number: "").
2. If is_consignment_note is true, extract the primary Consignment Note / LR tracking number into lr_number. (Never confuse invoice numbers, GSTIN, or vehicle numbers as LR numbers).
3. If different pages contain DIFFERENT Consignment Note numbers -> set has_multiple_different_lrs: true.
4. Output the page_label (e.g. page_1, page_2...) and classification for every page.
"""


PAGE_LR_PROMPT = """Inspect this transport document page carefully.
Determine whether this page is a primary Consignment Note / Lorry Receipt (Bilty / C-Note / G.R. No).
If it IS a Consignment Note / LR / Bilty:
- Set is_consignment_note: true
- Extract the primary Consignment Note / LR / Bilty / G.R. tracking number into lr_number.
CRITICAL RULES:
- Do NOT confuse Tax Invoice numbers, Bill numbers, GSTIN, Vehicle registration numbers, or E-Way Bill numbers as the LR number.
- If this page is a Tax Invoice, Delivery Challan, Packing List, E-Way Bill, Driver License, or other supporting document (even if it mentions an LR number in reference or notes), set is_consignment_note: false and lr_number: "".
- Only set is_consignment_note: true if this page itself IS the transport Consignment Note / Bilty receipt.
"""


def _normalize_lr_candidate(s: str) -> str:
    if not s:
        return ""
    cleaned = re.sub(r'[^a-zA-Z0-9]', '', str(s).strip()).lower()
    if cleaned.isdigit() and len(cleaned) > 1:
        cleaned = str(int(cleaned))
    return cleaned


class GeminiOCRResponse(BaseModel):
    document_title: str
    is_valid_lr: bool = False
    document_type: str = "unknown"
    has_consignment_note: bool = False
    has_parties_or_movement: bool = False
    has_cargo_or_vehicle: bool = False
    has_freight_terms: bool = False
    rejection_reason: str = ""
    page_lr_entries: list[PageLrEntry] = Field(default_factory=list)
    detected_lr_numbers: list[str] = Field(default_factory=list)
    has_multiple_different_lrs: bool = False
    key_value_pairs: list[KeyValuePair]
    confidence_notes: str


def _to_gemini_compatible_schema(pydantic_cls_or_dict):
    """
    Transforms a Pydantic model or schema dictionary into a Google Gemini-compatible
    schema by recursively stripping unsupported schema properties (e.g. 'default', 'title', '$schema', '$defs')
    while preserving field types, properties, items, required fields, and enums.
    Preserves Pydantic defaults on the application Python class.
    """
    from google.generativeai.types import content_types
    if isinstance(pydantic_cls_or_dict, type) and issubclass(pydantic_cls_or_dict, BaseModel):
        raw_schema = content_types._schema_for_class(pydantic_cls_or_dict)
    elif isinstance(pydantic_cls_or_dict, dict):
        raw_schema = pydantic_cls_or_dict
    else:
        return pydantic_cls_or_dict

    def _clean_node(node):
        if not isinstance(node, dict):
            if isinstance(node, list):
                return [_clean_node(item) for item in node]
            return node
        cleaned = {}
        for k, v in node.items():
            if k in ("default", "title", "$schema", "definitions", "$defs"):
                continue
            cleaned[k] = _clean_node(v)
        return cleaned

    return _clean_node(raw_schema)


class ParsedDocument(BaseModel):
    filename: str | None = None
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
    client_source: str | None = None


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
        "port": get_server_port()
    }


# --- ROUTE 2A: Zero-Config Wi-Fi LAN Auto-Discovery ---
DISCOVERY_MAGIC = "OCR_TO_EXCEL_DISCOVER"
DISCOVERY_UDP_PORT = int(os.getenv("DISCOVERY_UDP_PORT", "8001"))

_lan_discovery_stop = threading.Event()
_lan_discovery_lock = threading.Lock()
_lan_discovery_socket: socket.socket | None = None
_lan_discovery_thread: threading.Thread | None = None


def _build_discovery_payload(request_port: int | None = None) -> dict[str, Any]:
    port = request_port or get_server_port()
    payload: dict[str, Any] = {
        "service": "ocr_to_excel",
        "status": "online",
        "ip": get_local_ip(),
        "port": port,
        "model": MODEL_NAME,
    }
    public_url = get_public_server_url()
    if public_url:
        payload["public_server_url"] = public_url
    return payload


@app.get("/api/discover")
def discover_server(request: Request):
    """Lightweight identity endpoint for same-Wi-Fi Android LAN auto-discovery."""
    return _build_discovery_payload(request_port=request.url.port)


def _lan_discovery_loop(sock: socket.socket) -> None:
    while not _lan_discovery_stop.is_set():
        try:
            data, addr = sock.recvfrom(1024)
            msg = data.decode("utf-8", errors="ignore").strip()
            if msg == DISCOVERY_MAGIC or msg.startswith(DISCOVERY_MAGIC):
                reply = json.dumps(_build_discovery_payload()).encode("utf-8")
                sock.sendto(reply, addr)
        except socket.timeout:
            continue
        except OSError:
            break
        except Exception:
            continue


def start_lan_discovery_responder(udp_port: int | None = None) -> int | None:
    """Starts the non-blocking daemon UDP broadcast responder for local Wi-Fi discovery."""
    global _lan_discovery_socket, _lan_discovery_thread
    if os.getenv("DISABLE_LAN_DISCOVERY", "").strip().lower() in ("1", "true", "yes"):
        return None
    target_port = DISCOVERY_UDP_PORT if udp_port is None else int(udp_port)
    with _lan_discovery_lock:
        if _lan_discovery_thread is not None and _lan_discovery_thread.is_alive() and _lan_discovery_socket is not None:
            try:
                return int(_lan_discovery_socket.getsockname()[1])
            except Exception:
                return target_port
        _lan_discovery_stop.clear()
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sock.settimeout(1.0)
            sock.bind(("0.0.0.0", target_port))
            bound_port = int(sock.getsockname()[1])
        except OSError:
            try:
                sock.close()
            except Exception:
                pass
            return None

        _lan_discovery_socket = sock
        t = threading.Thread(
            target=_lan_discovery_loop,
            args=(sock,),
            name="lan-udp-discovery",
            daemon=True,
        )
        _lan_discovery_thread = t
        t.start()
        return bound_port


def stop_lan_discovery_responder() -> None:
    """Stops the UDP LAN discovery responder cleanly on server shutdown."""
    global _lan_discovery_socket, _lan_discovery_thread
    _lan_discovery_stop.set()
    with _lan_discovery_lock:
        sock = _lan_discovery_socket
        _lan_discovery_socket = None
        _lan_discovery_thread = None
    if sock is not None:
        try:
            sock.close()
        except Exception:
            pass


@app.on_event("startup")
def _on_startup_lan_discovery() -> None:
    start_lan_discovery_responder()


@app.on_event("shutdown")
def _on_shutdown_lan_discovery() -> None:
    stop_lan_discovery_responder()


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


# --- ROUTE 3A: Excel Template Download ---
@app.get("/download-template")
@app.get("/api/template/download")
def download_excel_template():
    tpl_file = _resolve_project_file("docs", "Customer_Master_GTInfiniti-Consignment_Entry.xlsx")
    tpl_name = "Customer_Master_GTInfiniti-Consignment_Entry.xlsx"
    if not (tpl_file and os.path.exists(tpl_file)):
        tpl_file = _resolve_project_file("docs", "LR_Format.xlsx")
        tpl_name = "LR_Format.xlsx"
    if tpl_file and os.path.exists(tpl_file):
        return FileResponse(
            tpl_file,
            filename=tpl_name,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            headers={"Content-Disposition": f'attachment; filename="{tpl_name}"'}
        )
    raise HTTPException(status_code=404, detail="Template file Customer_Master_GTInfiniti-Consignment_Entry.xlsx not found.")


def _derive_ws_url(http_url: str) -> str:
    clean = http_url.strip().rstrip("/")
    if clean.startswith("https://"):
        return f"wss://{clean[len('https://'):]}/ws"
    if clean.startswith("http://"):
        return f"ws://{clean[len('http://'):]}/ws"
    return f"ws://{clean}/ws"


# --- ROUTE 3B: Centralized Remote Configuration Endpoint ---
@app.get("/api/config")
def get_server_config():
    """
    Returns the centralized server configuration including active base URL,
    websocket URL, fallback endpoints, and minimum app requirements.
    Respects .env PUBLIC_SERVER_URL and PORT settings without breaking server_config.json.
    """
    config_path = os.path.join(BASE_DIR, "server_config.json")
    if not os.path.exists(config_path):
        config_path = os.path.join(os.path.dirname(BASE_DIR), "server_config.json")

    file_cfg: dict[str, Any] | None = None
    if os.path.exists(config_path):
        try:
            with open(config_path, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                if isinstance(loaded, dict):
                    file_cfg = loaded
        except Exception as e:
            print(f"[Warning] Failed to read server_config.json: {e}")

    public_url = get_public_server_url()
    port = get_server_port()
    local_ip = get_local_ip()

    if public_url:
        base_cfg = dict(file_cfg) if file_cfg else {}
        base_cfg.update({
            "server_url": public_url,
            "websocket_url": _derive_ws_url(public_url),
            "fallback_urls": [public_url],
        })
        base_cfg.setdefault("config_version", 2)
        base_cfg.setdefault("app_min_version", "1.0.0")
        base_cfg.setdefault("maintenance_mode", False)
        return base_cfg

    is_local_env = os.getenv("APP_ENV", "").strip().lower() in ("local", "dev", "development")
    if port == 8000 or is_local_env:
        local_url = f"http://{local_ip}:{port}"
        return {
            "server_url": local_url,
            "websocket_url": f"ws://{local_ip}:{port}/ws",
            "fallback_urls": [local_url],
            "config_version": (file_cfg or {}).get("config_version", 1),
            "app_min_version": (file_cfg or {}).get("app_min_version", "1.0.0"),
            "maintenance_mode": (file_cfg or {}).get("maintenance_mode", False),
        }

    if file_cfg:
        return file_cfg

    local_url = f"http://{local_ip}:{port}"
    return {
        "server_url": local_url,
        "websocket_url": f"ws://{local_ip}:{port}/ws",
        "fallback_urls": [local_url],
        "config_version": 1,
        "app_min_version": "1.0.0",
        "maintenance_mode": False,
    }


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
    resolved_id = str(user_id).strip() if (user_id and isinstance(user_id, str)) else ""
    resolved_mobile = str(user_mobile).strip() if (user_mobile and isinstance(user_mobile, str)) else ""
    resolved_name = str(user_name).strip() if (user_name and isinstance(user_name, str)) else ""
    auth_header = authorization if (authorization and isinstance(authorization, str)) else None

    # 1. First attempt to resolve via active session token
    if auth_header:
        session_user = auth_service.get_session_user(auth_header)
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



UNICHARM_MARKERS = ("unicharm", "uvicharm", "vuicharm", "micharm")
WEB_UNICHARM_DEFAULT_CUSTOMER = "Global Marketing"


def _contains_unicharm_marker(val: Any) -> bool:
    low = str(val or "").lower()
    return any(w in low for w in UNICHARM_MARKERS)


def _is_unicharm_document(data: dict[str, Any], prompt_type: str | None = None) -> bool:
    if prompt_type == "Unicharm OCR":
        return True
    if not isinstance(data, dict):
        return False
    return any(
        _contains_unicharm_marker(data.get(k))
        for k in ("Customer Name *", "Customer Name", "Customer", "customer", "cngr *", "cngr", "cnge *", "cnge")
    )


def _apply_web_unicharm_customer_default(data: dict[str, Any], prompt_type: str | None = None) -> bool:
    """Defaults Customer to 'Global Marketing' for Unicharm LRs in Web flows without modifying Consignor."""
    if not isinstance(data, dict) or not _is_unicharm_document(data, prompt_type=prompt_type):
        return False
    current_cust = str(
        data.get("Customer Name *") or data.get("Customer Name") or data.get("Customer") or data.get("customer") or ""
    ).strip()
    if not current_cust or _contains_unicharm_marker(current_cust):
        for cust_key in ("Customer Name *", "Customer Name", "Customer", "customer"):
            data[cust_key] = WEB_UNICHARM_DEFAULT_CUSTOMER
        return True
    return False


PATANJALI_DEFAULT_CUSTOMER = "Patanjali Parivahan Private Limited"
_PATANJALI_MARKER_RE = re.compile(
    r"pat[aehi]?n[gj][aeil1oy]{1,5}|ruchi\s*soya|\brsil\b",
    re.IGNORECASE,
)


def _edit_distance_le_two(a: str, b: str) -> bool:
    if abs(len(a) - len(b)) > 2:
        return False
    prev = list(range(len(b) + 1))
    for ca in a:
        cur = [prev[0] + 1]
        for j, cb in enumerate(b, 1):
            cost = 0 if ca == cb else 1
            cur.append(min(cur[-1] + 1, prev[j] + 1, prev[j - 1] + cost))
        if min(cur) > 2:
            return False
        prev = cur
    return prev[-1] <= 2


def _contains_patanjali_marker(val: Any) -> bool:
    s = str(val or "").strip()
    if not s:
        return False
    if _PATANJALI_MARKER_RE.search(s):
        return True
    for tok in re.findall(r"[a-zA-Z0-9]+", s.lower()):
        alpha = tok.replace("1", "l").replace("0", "o")
        if len(alpha) >= 7 and alpha.startswith("p") and _edit_distance_le_two(alpha, "patanjali"):
            return True
    return False


def _is_patanjali_document(
    data: dict[str, Any],
    prompt_type: str | None = None,
    filename: str | None = None,
) -> bool:
    if prompt_type == "Patanjali OCR":
        return True
    if filename and _contains_patanjali_marker(filename):
        return True
    if not isinstance(data, dict):
        return False
    return any(
        _contains_patanjali_marker(data.get(k))
        for k in (
            "Customer Name *", "Customer Name", "Customer", "customer", "customer_name",
            "cngr *", "cngr", "consignor", "cnge *", "cnge", "consignee", "Depatment Name", "department",
        )
    )


def _apply_patanjali_customer_default(
    data: dict[str, Any],
    prompt_type: str | None = None,
    filename: str | None = None,
) -> bool:
    """Defaults Customer to 'Patanjali Parivahan Private Limited' for Patanjali LRs without modifying Consignor."""
    if not isinstance(data, dict) or not _is_patanjali_document(
        data, prompt_type=prompt_type, filename=filename
    ):
        return False
    current_cust = str(
        data.get("Customer Name *")
        or data.get("Customer Name")
        or data.get("Customer")
        or data.get("customer")
        or data.get("customer_name")
        or ""
    ).strip()
    if not current_cust or _contains_patanjali_marker(current_cust):
        for cust_key in ("Customer Name *", "Customer Name", "Customer", "customer", "customer_name"):
            data[cust_key] = PATANJALI_DEFAULT_CUSTOMER
        return True
    return False


def canonicalize_extracted_data(data_dict: dict, web_mode: bool = False) -> dict:
    """
    Normalizes extracted OCR fields from any prompt or document format into
    canonical keys compatible with:
    1. GR_BNF_49_HEADERS (49 Columns)
    2. GR_STOCK_38_HEADERS (38 Columns)
    3. Web BNF table column lookup (getBnfFieldValue)
    4. Android BatchItem and EditableDataTable (resolveField & direct key lookup)
    """
    if not isinstance(data_dict, dict):
        return {}

    norm_map = {}
    for k, v in data_dict.items():
        if v is not None and str(v).strip() != "":
            clean_k = re.sub(r'[^a-zA-Z0-9]', '', str(k)).lower()
            norm_map[clean_k] = str(v).strip()

    def get_val(*candidates, default=""):
        for c in candidates:
            if c in data_dict and data_dict[c] is not None and str(data_dict[c]).strip() != "":
                return str(data_dict[c]).strip()
            clean_c = re.sub(r'[^a-zA-Z0-9]', '', str(c)).lower()
            if clean_c in norm_map and norm_map[clean_c] != "":
                return norm_map[clean_c]
        return default

    # 1. LR / Consignment Note Number
    raw_lr = get_val(
        "grno (*)", "grno", "LR No *", "LR No", "lrno", "bilty no", "biltyno", "bilty number",
        "consignment note no", "consignment note number", "consignment note", "consignment no",
        "c note no", "c note", "c-note", "cn no", "cn number", "lr #", "lr number", "gr number",
        "bilty_no"
    )
    cleaned_lr = _clean_grno(raw_lr)
    if cleaned_lr:
        data_dict["grno"] = cleaned_lr
        data_dict["grno (*)"] = cleaned_lr
        data_dict["LR No *"] = cleaned_lr
        data_dict["LR No"] = cleaned_lr
        data_dict["lrno"] = cleaned_lr
        data_dict["biltyno"] = cleaned_lr

    # 2. Consignment Booking Date
    raw_date = get_val(
        "grdt *", "grdt", "stockdt", "stockdt ", "date", "bkg date", "booking date",
        "lr date", "bilty date", "consignment date", "loading start date *", "loading start date",
        "dispatch date"
    )
    formatted_date = _format_date_ddmmyyyy(raw_date)
    if formatted_date:
        data_dict["grdt"] = formatted_date
        data_dict["grdt *"] = formatted_date
        data_dict["stockdt"] = formatted_date
        data_dict["stockdt "] = formatted_date
        if not data_dict.get("Loading Start date *"):
            data_dict["Loading Start date *"] = formatted_date
    raw_ewb_dt = get_val("EwayBillDate", "ewaybilldate", "ewaybilldt", "eway_bill_date", "E-Way Bill Date", "e-way bill date", "ewb date", default=formatted_date)
    formatted_ewb_dt = _format_date_ddmmyyyy(raw_ewb_dt) if raw_ewb_dt else formatted_date
    if formatted_ewb_dt:
        data_dict["ewaybilldt"] = formatted_ewb_dt
        data_dict["EwayBillDate"] = formatted_ewb_dt

    # 3. Vehicle Number
    raw_veh = get_val(
        "Vehicle No *", "Vehicle No", "vehno", "tempo/truck no", "tempo / truck no",
        "tempo truck no", "truck no", "truck no.", "lorry no", "vehicle number", "veh no",
        "reg no", "registration no", "rc no", "tempo no", "vehicle_no"
    )
    if raw_veh:
        clean_veh = re.sub(r'\s+', '', str(raw_veh)).upper()
        data_dict["Vehicle No *"] = clean_veh
        data_dict["Vehicle No"] = clean_veh
        data_dict["vehno"] = clean_veh

    # 4. Vehicle Category & Vehicle Type (decoupled)
    raw_veh_cat = get_val("Vehicle Category *", "Vehicle Category", "vehicle category", default="Market")
    veh_cat_val = "Market" if not raw_veh_cat or str(raw_veh_cat).strip().lower() in ("none", "null", "nan", "") else str(raw_veh_cat).strip()
    data_dict["Vehicle Category *"] = veh_cat_val
    data_dict["Vehicle Category"] = veh_cat_val

    raw_veh_type = get_val(
        "Vehicle Type *", "Vehicle Type", "VehicleTypeName", "truck type", "lorry type",
        "body type"
    )
    veh_type_val = str(raw_veh_type).strip() if (raw_veh_type and str(raw_veh_type).strip().lower() not in ("none", "null", "nan", "", "market")) else ""
    data_dict["Vehicle Type *"] = veh_type_val
    data_dict["Vehicle Type"] = veh_type_val
    data_dict["VehicleTypeName"] = veh_type_val

    # 5. Consignor (cngr)
    raw_cngr = get_val(
        "cngr *", "cngr", "consignor name & address", "consignor name and address",
        "consignor's name & address", "consignor name", "consignor", "sender", "shipper",
        "from party", "consignor address"
    )
    if raw_cngr:
        data_dict["cngr *"] = raw_cngr
        data_dict["cngr"] = raw_cngr

    # 6. Consignee (cnge)
    raw_cnge = get_val(
        "cnge *", "cnge", "consignee name & address", "consignee name and address",
        "consignee's name & address", "consignee name", "consignee", "receiver",
        "to party", "consignee address"
    )
    if raw_cnge:
        data_dict["cnge *"] = raw_cnge
        data_dict["cnge"] = raw_cnge

    # 7. Customer Name
    raw_cust = get_val(
        "Customer Name *", "Customer Name", "customer name", "customer", "billed to",
        "party name", "account name", "corporate billed account", "client name"
    )
    if not raw_cust:
        cngr_low = str(raw_cngr or "").lower()
        cnge_low = str(raw_cnge or "").lower()
        if "himalaya" in cngr_low or "himalaya" in cnge_low:
            raw_cust = "Himalaya Wellness Company"
        elif any(w in cngr_low or w in cnge_low for w in UNICHARM_MARKERS):
            raw_cust = WEB_UNICHARM_DEFAULT_CUSTOMER if web_mode else "UNICHARM INDIA PVT. LTD."
        elif _contains_patanjali_marker(cngr_low) or _contains_patanjali_marker(cnge_low):
            raw_cust = PATANJALI_DEFAULT_CUSTOMER
        elif any(w in cngr_low or w in cnge_low for w in ["gold plus", "gold_plus", "goldplus"]):
            raw_cust = "GOLD PLUS FLOAT GLASS PRIVATE LIMITED"
        elif raw_cngr:
            raw_cust = raw_cngr.split(",")[0].split("-")[0].strip()
    if raw_cust:
        data_dict["Customer Name *"] = raw_cust
        data_dict["Customer Name"] = raw_cust
        data_dict["customer"] = raw_cust
    if web_mode:
        _apply_web_unicharm_customer_default(data_dict)
    _apply_patanjali_customer_default(data_dict)

    # 8. Consignor GSTIN & Consignee GSTIN
    raw_cngr_gst = get_val("cngrgstno *", "cngrgstno", "consignor gst", "consignor gstin", "cngr gst", "sender gst")
    if raw_cngr_gst:
        data_dict["cngrgstno *"] = raw_cngr_gst
        data_dict["cngrgstno"] = raw_cngr_gst
    raw_cnge_gst = get_val("cngegstno *", "cngegstno", "consignee gst", "consignee gstin", "cnge gst", "receiver gst")
    if raw_cnge_gst:
        data_dict["cngegstno *"] = raw_cnge_gst
        data_dict["cngegstno"] = raw_cnge_gst

    # 9. Origin, Destination, PickupPoint & DeliveryPoint
    raw_org = get_val("orgrefcode", "from", "from city", "origin", "origin station", "booking station", "from station")
    if raw_org:
        data_dict["orgrefcode"] = raw_org
    raw_dest = get_val("destrefcode", "to", "to city", "destination", "destination station", "delivery station", "to station")
    if raw_dest:
        data_dict["destrefcode"] = raw_dest
    raw_pickup = get_val("PickupPoint", "pickup_point", "pickuppoint", default=raw_org)
    if raw_pickup:
        data_dict["PickupPoint"] = raw_pickup
    raw_delivery = get_val("DeliveryPoint", "delivery_point", "deliverypoint", default=raw_dest)
    if raw_delivery:
        data_dict["DeliveryPoint"] = raw_delivery

    # 10. Goods Description (Blank if extracted OCR value does not match GoodsMaster source data)
    raw_goods = get_val(
        "goods", "description (said to contain)", "description", "said to contain",
        "nature of goods", "commodity", "item description", "material", "goods description"
    )
    if raw_goods and str(raw_goods).strip().lower() not in ("none", "null", "nan", ""):
        try:
            goods_lookup = _load_goods_lookup()
        except Exception:
            goods_lookup = {}
        clean_raw_g = str(raw_goods).strip().lower()
        matched_goods = goods_lookup.get(clean_raw_g)
        if matched_goods:
            data_dict["goods"] = matched_goods
            data_dict["Goods"] = matched_goods
        else:
            # If extracted OCR value does not match available source data, leave blank
            data_dict["goods"] = ""
            data_dict["Goods"] = ""
    else:
        data_dict["goods"] = ""
        data_dict["Goods"] = ""

    # 11. Packages
    raw_pkgs = get_val(
        "pckgs", "bookedpckgs", "stockpckgs", "stockpkgs", "no. of packages", "no of packages",
        "no. of pkgs", "no of pkgs", "total packages", "packages", "pkgs", "quantity", "qty",
        "total cases", "cases", "no of articles"
    )
    if raw_pkgs:
        cleaned_pkgs = re.sub(r'[^0-9\+]', '', str(raw_pkgs)).strip()
        if not cleaned_pkgs:
            cleaned_pkgs = str(raw_pkgs).strip()
        data_dict["pckgs"] = cleaned_pkgs
        data_dict["bookedpckgs"] = cleaned_pkgs
        data_dict["stockpckgs"] = cleaned_pkgs
        data_dict["stockpkgs"] = cleaned_pkgs

    # 12. Actual & Charged Weights
    raw_awt = get_val(
        "aweight", "bookedaweight", "stockaweight", "actual wt(kgs)", "actual weight",
        "actual wt", "gross weight", "act wt", "weight", "net weight"
    )
    if raw_awt:
        data_dict["aweight"] = str(raw_awt)
        data_dict["bookedaweight"] = str(raw_awt)
        data_dict["stockaweight"] = str(raw_awt)

    raw_cwt = get_val(
        "cweight", "bookedcweight", "stockcweight", "charged weight", "charged wt",
        "total charged weight", "chg wt", default=raw_awt
    )
    if raw_cwt:
        data_dict["cweight"] = str(raw_cwt)
        data_dict["bookedcweight"] = str(raw_cwt)
        data_dict["stockcweight"] = str(raw_cwt)

    # 13. Invoice No & Date
    raw_inv = get_val("invoiceno", "invoice no", "invoice no.", "invoice number", "bill no", "inv no", "tax invoice no")
    if raw_inv:
        data_dict["invoiceno"] = raw_inv

    raw_invdt = get_val("invoiedt", "invoice date", "bill date", "inv date", "tax invoice date", default=formatted_date)
    if raw_invdt:
        data_dict["invoiedt"] = _format_date_ddmmyyyy(raw_invdt)

    # 14. Declared Value of Goods
    raw_val = get_val(
        "valgoods", "declared value", "value of goods", "value as per invoice",
        "goods value", "invoice value", "total invoice amount", "invoice amount", "total value"
    )
    if raw_val:
        data_dict["valgoods"] = re.sub(r'[^0-9\.]', '', str(raw_val).replace(',', ''))

    # 15. E-Way Bill Number
    raw_ewb = get_val("ewaybillno", "e-way bill no", "e-way bill no.", "eway bill no", "e-way bill", "ewb no", "ewaybill")
    if raw_ewb:
        data_dict["ewaybillno"] = re.sub(r'[^0-9]', '', str(raw_ewb))

    # 16. E-Way Bill Validity (decoupled from Driver DL Valid Up to *)
    raw_ewb_upto = ""
    for k, v in data_dict.items():
        if v is None or str(v).strip() == "":
            continue
        k_str = str(k).strip()
        k_low = k_str.lower()
        k_clean = re.sub(r'[^a-zA-Z0-9]', '', k_low)
        if k_str in ("Valid Upto", "valid_upto", "Valid Upto (EWB)", "ewb valid upto", "ewb_valid_upto", "e-way bill valid upto", "eway validity"):
            raw_ewb_upto = str(v).strip()
            break
        if "*" not in k_str and not any(w in k_low for w in ("dl", "license", "licence", "driver", "driving", "up to")):
            if k_clean in ("validupto", "validuptoewb", "ewbvalidupto", "ewaybillvalidupto", "ewayvalidity"):
                raw_ewb_upto = str(v).strip()
                break
    if raw_ewb_upto:
        data_dict["Valid Upto"] = _format_date_ddmmyyyy(raw_ewb_upto)
    elif data_dict.get("Valid Upto"):
        data_dict["Valid Upto"] = _format_date_ddmmyyyy(data_dict["Valid Upto"])

    # 17. Transit Days
    calc_td = _calculate_transit_days(data_dict.get("grdt", ""), data_dict.get("Valid Upto", ""))
    if calc_td:
        data_dict["Transit Days"] = str(calc_td)
    else:
        raw_td = get_val("Transit Days", "transit days", "transit_days")
        if raw_td:
            data_dict["Transit Days"] = str(raw_td)

    # 18. Payment Terms (grtype)
    raw_grtype = get_val("grtype", "grtype(Don’t know)", "grtype(don't know)", "freight terms", "payment terms", "payment type", "pay type", "freight term")
    if raw_grtype:
        u_gt = str(raw_grtype).strip().upper()
        if "TO PAY" in u_gt or "TOPAY" in u_gt or u_gt == "T":
            norm_gt = "TO PAY"
        elif "TBB" in u_gt:
            norm_gt = "TBB"
        elif "PAID" in u_gt:
            norm_gt = "PAID"
        else:
            norm_gt = str(raw_grtype).strip()
        data_dict["grtype"] = norm_gt
        data_dict["grtype(Don’t know)"] = norm_gt

    # 19. Freight, Charges, Taxes
    raw_fr = get_val("freight  *", "freight", "freight charge", "basic freight", "total freight", "freight amount")
    data_dict["freight  *"] = str(raw_fr) if (raw_fr and str(raw_fr).strip() not in ("0", "0.0", "0.00", "xxxx", "XXXX")) else ""
    data_dict["freight"] = str(raw_fr) if (raw_fr and str(raw_fr).strip() not in ("0", "0.0", "0.00", "xxxx", "XXXX")) else ""

    raw_oamt = get_val("oamount", "other charges", "other amount", "hamali", "unloading charges", "loading charges", "aoc", "misc")
    if raw_oamt and str(raw_oamt).strip() not in ("", "0", "0.00", "None", "null", "nan"):
        data_dict["oamount"] = str(raw_oamt).strip()
    else:
        data_dict["oamount"] = "0.00"

    data_dict["cgst"] = str(get_val("cgst", "cgst amount", default="0"))
    data_dict["sgst"] = str(get_val("sgst", "sgst amount", default="0"))
    data_dict["igst"] = "0.00"
    data_dict["received"] = str(get_val("received", "amount received", default="0"))
    data_dict["advance"] = str(get_val("advance", "advance amount", default="0"))

    # 20. FTL, staxpaidby, dlvtype
    raw_ftl = get_val("ftl", "full truck load", "ftl flag", "load type")
    if raw_ftl:
        u_ftl = str(raw_ftl).strip().upper()
        if u_ftl in ("FTL", "LTL", "Y", "N"):
            data_dict["ftl"] = u_ftl
        elif "FTL" in u_ftl or "32 FT" in u_ftl or "7 MT" in u_ftl or "FULL" in u_ftl or u_ftl.startswith("Y"):
            data_dict["ftl"] = "FTL"
        elif "LTL" in u_ftl or "PART" in u_ftl or u_ftl.startswith("N"):
            data_dict["ftl"] = "LTL"
        else:
            data_dict["ftl"] = u_ftl
    else:
        data_dict["ftl"] = "N"

    raw_stax = get_val("staxpaidby", "service tax paid by", "stax paid by", "gst paid by")
    if raw_stax:
        u_stax = str(raw_stax).strip().upper()
        data_dict["staxpaidby"] = "E" if (u_stax.startswith("E") or "CONSIGNEE" in u_stax) else ("T" if (u_stax.startswith("T") or "TRANSPORTER" in u_stax) else "C")
    else:
        is_to_pay = "TO PAY" in str(data_dict.get("grtype") or "").upper()
        data_dict["staxpaidby"] = "E" if is_to_pay else "C"

    raw_dlv = get_val("dlvtype", "delivery type", "dlv type", "delivery mode")
    if raw_dlv:
        u_dlv = str(raw_dlv).strip().upper()
        data_dict["dlvtype"] = "D" if (u_dlv.startswith("D") or "DOOR" in u_dlv) else "G"
    else:
        data_dict["dlvtype"] = "G"

    # 21. Station & Customer references
    raw_cntr = get_val("Counter name", "Counter", "counter name", "counter", "booking counter", "branchrefcode")
    if raw_cntr:
        data_dict["Counter name"] = raw_cntr
        data_dict["Counter"] = raw_cntr
        data_dict["counter"] = raw_cntr
        data_dict["branchrefcode"] = raw_cntr

    if not data_dict.get("collectionstncode"):
        coll = data_dict.get("orgrefcode") or data_dict.get("branchrefcode") or data_dict.get("Counter") or ""
        if coll:
            data_dict["collectionstncode"] = coll
        else:
            data_dict["collectionstncode"] = data_dict.get("destrefcode", "") if ("TO PAY" in str(data_dict.get("grtype", "")).upper()) else ""

    if not data_dict.get("custrefcode"):
        data_dict["custrefcode"] = get_val("custrefcode", "party code", "customer code", default="CM001")

    # 22. Seal / Private Marka (pmark) - strictly forced blank per business rules
    data_dict["pmark"] = ""
    data_dict["PMark"] = ""
    data_dict["Private Mark"] = ""

    # 23. Driver compliance fields
    data_dict["Driver Name *"] = get_val("Driver Name *", "driver name", "driver", "pilot", default="")
    data_dict["Mobile no   *"] = get_val("Mobile no   *", "mobile no *", "mobile no", "driver mobile", default="")
    data_dict["Liscense No *"] = get_val("Liscense No *", "license no *", "license no", "dl no", default="")
    # Keep Driver DL validity strictly decoupled from E-Way Bill 'Valid Upto'
    raw_dl_up = ""
    for k, v in data_dict.items():
        if v is None or str(v).strip() == "":
            continue
        k_str = str(k).strip()
        k_low = k_str.lower()
        k_clean = re.sub(r'[^a-zA-Z0-9]', '', k_low)
        if k_str in ("Valid Up to *", "Valid Up to", "valid up to *", "valid_up_to", "dl valid till", "dl_valid_till", "license valid", "driving licence valid", "DrivingValidUpto"):
            raw_dl_up = str(v).strip()
            break
        if ("*" in k_str or any(w in k_low for w in ("dl", "license", "licence", "driver", "driving", "up to"))) and k_clean in ("validupto", "drivingvalidupto", "licensevalid", "dlvalidtill", "drivinglicencevalid"):
            raw_dl_up = str(v).strip()
            break
    data_dict["Valid Up to *"] = _format_date_ddmmyyyy(raw_dl_up) if raw_dl_up else ""

    # Sanitize dummy mobile numbers
    if str(data_dict.get("Mobile no   *") or "").strip() in ("9999999999", "0000000000", "99999 99999"):
        data_dict["Mobile no   *"] = ""

    # 24. Packaging & Product Code
    raw_pack = get_val("packing", "packaging", "package type", "packaging format")
    if raw_pack:
        data_dict["packing"] = raw_pack
    raw_prod = get_val("productcode", "product code", "hsn", "hsn code")
    if raw_prod and raw_prod not in {"Surface-FTL", "Surface-PTL", "Global-TT", "Global-MT", "AIR"}:
        data_dict["productcode"] = raw_prod
    elif data_dict.get("productcode") in {"Surface-FTL", "Surface-PTL", "Global-TT", "Global-MT", "AIR"}:
        data_dict["productcode"] = ""

    # 25. Contract weights & border
    for extra_k in ("Order Weight", "Contract wt", "Extra Mt", "viaborder"):
        data_dict[extra_k] = get_val(extra_k, default="")

    return data_dict


# --- Helper: Assemble Multi-Page PDF API ---
@app.post("/api/assemble-pdf")
async def api_assemble_pdf(files: list[UploadFile] = File(...)):
    """
    Assembles multiple uploaded images into a single multi-page PDF document.
    Enforces maximum 15 pages validation.
    """
    if not files:
        raise HTTPException(status_code=400, detail="No files provided for PDF assembly.")
    if len(files) > 15:
        return JSONResponse(
            status_code=422,
            content={
                "success": False,
                "error_code": "PAGE_LIMIT_EXCEEDED",
                "title": "Page Limit Exceeded",
                "message": "Maximum 15 pages are allowed per upload. Please upload documents containing 15 pages or fewer.",
                "detail": "Maximum 15 pages are allowed per upload. Please upload documents containing 15 pages or fewer."
            }
        )
    import fitz
    doc = fitz.open()
    for uf in files:
        b = await uf.read()
        try:
            img = fitz.open(stream=b, filetype="jpeg")
            pdf_bytes = img.convert_to_pdf()
            img_pdf = fitz.open("pdf", pdf_bytes)
            doc.insert_pdf(img_pdf)
        except Exception:
            try:
                pil_img = Image.open(io.BytesIO(b))
                if pil_img.mode in ("RGBA", "P"):
                    pil_img = pil_img.convert("RGB")
                jbuf = io.BytesIO()
                pil_img.save(jbuf, format="JPEG", quality=95)
                img = fitz.open(stream=jbuf.getvalue(), filetype="jpeg")
                pdf_bytes = img.convert_to_pdf()
                img_pdf = fitz.open("pdf", pdf_bytes)
                doc.insert_pdf(img_pdf)
            except Exception as e:
                print(f"[Assemble PDF error] {e}")
    out_bytes = doc.tobytes()
    return Response(content=out_bytes, media_type="application/pdf")


def _detect_customer_prompt_from_text(
    txt_low: str,
    active_prompt: str,
    prompt_type: str,
) -> tuple[str, str]:
    """Selects customer-specific OCR prompt when unambiguous keywords appear in text."""
    if not txt_low or prompt_type == "Custom":
        return active_prompt, prompt_type
    if _contains_patanjali_marker(txt_low):
        return DEFAULT_PATANJALI_OCR_PROMPT, "Patanjali OCR"
    if any(w in txt_low for w in ("unicharm", "uvicharm", "vuicharm", "micharm")):
        return DEFAULT_UNICHARM_OCR_PROMPT, "Unicharm OCR"
    if "himalaya" in txt_low:
        return DEFAULT_HIMALAYA_OCR_PROMPT, "Himalaya OCR"
    if any(w in txt_low for w in ("gold plus", "gold_plus", "goldplus", "gold float glass")):
        return DEFAULT_GOLD_PLUS_OCR_PROMPT, "Gold Plus OCR"
    return active_prompt, prompt_type


def _is_blank_jpeg_bytes(jpeg_bytes: bytes) -> bool:
    """Checks rendered JPEG bytes for blank/solid pages safely."""
    try:
        with Image.open(io.BytesIO(jpeg_bytes)) as im:
            return is_blank_or_solid_image(im)
    except Exception:
        return False


def _select_gemini_pages_for_pdf(
    preview_bytes_list: list[bytes],
    page_texts: list[str],
    target_page_idx: int,
    page_labels: list[str] | None = None,
    is_multi_file: bool = False,
) -> tuple[list[bytes], list[str]]:
    """
    Filters blank pages and, for text-layer multi-page PDF packets, selects highest-signal
    consignment/invoice/E-Way/DL/scanned pages along with aligned page/file labels.
    """
    labels = (
        page_labels
        if (page_labels is not None and len(page_labels) == len(preview_bytes_list))
        else [f"Page {i + 1}" for i in range(len(preview_bytes_list))]
    )
    if not preview_bytes_list:
        return [], []
    if len(preview_bytes_list) == 1:
        return preview_bytes_list, labels

    cap = 10 if is_multi_file else 8
    small_limit = 8 if is_multi_file else 6
    if is_multi_file and len(preview_bytes_list) <= small_limit:
        return preview_bytes_list, labels

    non_blank: list[tuple[int, bytes, str, str]] = []
    for idx, pb in enumerate(preview_bytes_list):
        txt = page_texts[idx] if idx < len(page_texts) else ""
        if len(txt.strip()) == 0 and _is_blank_jpeg_bytes(pb):
            continue
        non_blank.append((idx, pb, txt, labels[idx]))

    if not non_blank:
        return preview_bytes_list[:1], labels[:1]

    # Always preserve scanned image pages (no embedded PDF text) so trailing DL/RC cards and second bilties are never dropped
    scanned_count = sum(1 for _, _, txt, _ in non_blank if len(txt.strip()) < 50)
    if len(non_blank) <= small_limit or scanned_count == len(non_blank):
        return [item[1] for item in non_blank], [item[3] for item in non_blank]

    priority_kw = (
        "consign", "lorry", "bilty", "c note", "c-note", "cngr", "cnge",
        "tax invoice", "invoice", "e-way", "ewb", "driving", "licen", "dl no",
        "form 23", "vehicle", "gstin", "weight", "packages", "freight",
    )
    boilerplate_kw = (
        "national permit", "goods carriage permit", "insurance policy",
        "pollution under control", "terms and conditions",
    )

    scored: list[tuple[int, int, bytes, str, bool]] = []
    for idx, pb, txt, lbl in non_blank:
        t_low = txt.lower()
        is_scanned = len(txt.strip()) < 50
        score = 0
        if idx == 0 or idx == target_page_idx:
            score += 100
        if any(k in t_low for k in priority_kw):
            score += 10
        elif is_scanned:
            score += 5
        if any(k in t_low for k in boilerplate_kw) and "consign" not in t_low and "invoice" not in t_low:
            score -= 8
        scored.append((score, idx, pb, lbl, is_scanned))

    kept_indices = {
        idx for _, idx, _, _, is_scanned in scored
        if is_scanned or idx == 0 or idx == target_page_idx
    }
    remaining_budget = max(0, cap - len(kept_indices))
    if remaining_budget > 0:
        text_candidates = [
            x for x in scored
            if not x[4] and x[1] != 0 and x[1] != target_page_idx
        ]
        for _, idx, _, _, _ in sorted(text_candidates, key=lambda x: (-x[0], x[1]))[:remaining_budget]:
            kept_indices.add(idx)

    selected = [(pb, lbl) for _, idx, pb, lbl, _ in scored if idx in kept_indices]
    return [x[0] for x in selected], [x[1] for x in selected]


def _normalize_image_to_jpeg_bytes(
    raw_bytes: bytes,
    quality: int = 90,
    reject_blank: bool = True,
) -> tuple[bytes, int, int, bool, bool]:
    """
    Decodes an uploaded image, applies EXIF transpose, checks color/blankness,
    downscales if oversize (>2600px -> 2400px), and encodes JPEG bytes.
    """
    with Image.open(io.BytesIO(raw_bytes)) as raw_im:
        try:
            pil_img = ImageOps.exif_transpose(raw_im)
        except Exception:
            pil_img = raw_im
        orig_w, orig_h = pil_img.size
        is_yellow = is_orange_yellow_image(pil_img)
        if reject_blank and is_blank_or_solid_image(pil_img):
            return b"", orig_w, orig_h, is_yellow, True
        if max(orig_w, orig_h) > 2600:
            scale = 2400.0 / max(orig_w, orig_h)
            pil_img = pil_img.resize((int(orig_w * scale), int(orig_h * scale)), Image.Resampling.LANCZOS)
        if pil_img.mode in ("RGBA", "P", "CMYK"):
            pil_img = pil_img.convert("RGB")
        buf = io.BytesIO()
        pil_img.save(buf, format="JPEG", quality=quality)
        return buf.getvalue(), orig_w, orig_h, is_yellow, False


def _preprocess_uploads_sync(
    upload_meta: list[tuple[str, str, bytes]],
    custom_prompt: str | None,
) -> dict[str, Any]:
    """
    Runs synchronous CPU-bound PDF parsing/rasterization and PIL resizing off the asyncio
    event loop in a single fitz pass per PDF document.
    """
    import fitz

    MAX_UPLOAD_PAGES_LIMIT = 15
    total_files_count = len(upload_meta)
    primary_filename = upload_meta[0][0]
    lower_filename = primary_filename.lower()

    if isinstance(custom_prompt, str) and custom_prompt.strip():
        active_prompt = custom_prompt.strip()
        prompt_type = "Custom"
    elif _contains_patanjali_marker(lower_filename):
        active_prompt = DEFAULT_PATANJALI_OCR_PROMPT
        prompt_type = "Patanjali OCR"
    elif any(w in lower_filename for w in ["unicharm", "uvicharm", "vuicharm", "micharm"]):
        active_prompt = DEFAULT_UNICHARM_OCR_PROMPT
        prompt_type = "Unicharm OCR"
    elif "himalaya" in lower_filename or bool(re.search(r'(?:^|[^a-z])him(?:[^a-z]|$)', lower_filename)):
        active_prompt = DEFAULT_HIMALAYA_OCR_PROMPT
        prompt_type = "Himalaya OCR"
    elif any(w in lower_filename for w in ["gold_plus", "gold plus", "goldplus", "gold float glass"]):
        active_prompt = DEFAULT_GOLD_PLUS_OCR_PROMPT
        prompt_type = "Gold Plus OCR"
    else:
        active_prompt = DEFAULT_HANDWRITTEN_OCR_PROMPT
        prompt_type = "Default Master OCR"

    opened_pdfs: list[Any] = []
    try:
        total_batch_pages = 0
        pdf_docs_by_idx: dict[int, Any] = {}
        is_pdf_flags: list[bool] = []

        for idx, (fname, ctype, fbytes) in enumerate(upload_meta):
            fn_low = (fname or "").lower()
            is_pdf_file = fn_low.endswith(".pdf") or "pdf" in (ctype or "").lower() or (len(fbytes) >= 4 and fbytes[:4] == b"%PDF")
            is_pdf_flags.append(is_pdf_file)
            if is_pdf_file:
                try:
                    pdf_handle = fitz.open(stream=fbytes, filetype="pdf")
                    opened_pdfs.append(pdf_handle)
                    pdf_docs_by_idx[idx] = pdf_handle
                    total_batch_pages += len(pdf_handle)
                except Exception as e_pdf:
                    print(f"[Page Count Notice] Could not count PDF pages for {fname}: {e_pdf}")
                    total_batch_pages += 1
            else:
                total_batch_pages += 1

        if total_batch_pages > MAX_UPLOAD_PAGES_LIMIT:
            print(f"[Validation Rejected] Upload batch exceeds page limit: {total_batch_pages} pages > {MAX_UPLOAD_PAGES_LIMIT} max.")
            return {
                "rejected": JSONResponse(
                    status_code=422,
                    content={
                        "success": False,
                        "error_code": "PAGE_LIMIT_EXCEEDED",
                        "title": "Page Limit Exceeded",
                        "message": "Maximum 15 pages are allowed per upload. Please upload documents containing 15 pages or fewer.",
                        "detail": "Maximum 15 pages are allowed per upload. Please upload documents containing 15 pages or fewer.",
                        "total_pages": total_batch_pages,
                        "max_pages": MAX_UPLOAD_PAGES_LIMIT,
                    },
                )
            }

        is_yellow_image = False
        preview_image_data_url = None
        pdf_all_preview_bytes: list[bytes] = []
        pdf_page_texts: list[str] = []
        pdf_page_labels: list[str] = []
        gemini_page_bytes: list[bytes] = []
        gemini_page_labels: list[str] = []
        pdf_page_count = 1
        target_page_idx = 0
        detected_text_lrs: set[str] = set()
        raw_upload_bytes = b""
        image_bytes = b""
        mime_type = "image/jpeg"

        if total_files_count > 1:
            print(f"[Multi-Upload] Combining {total_files_count} files in original sequence...")
            combined_pdf = fitz.open()
            try:
                for idx, (fname, ctype, fbytes) in enumerate(upload_meta):
                    short_fname = os.path.basename(fname or f"doc_{idx+1}")[:40]
                    if is_pdf_flags[idx] and idx in pdf_docs_by_idx:
                        sub_doc = pdf_docs_by_idx[idx]
                        try:
                            for p_idx, p in enumerate(sub_doc):
                                txt = p.get_text()
                                pdf_page_texts.append(txt)
                                active_prompt, prompt_type = _detect_customer_prompt_from_text(
                                    txt.lower(), active_prompt, prompt_type
                                )
                                for cand in _extract_lr_candidates_from_text(txt):
                                    detected_text_lrs.add(cand)
                                try:
                                    pix = p.get_pixmap(dpi=120)
                                    pdf_all_preview_bytes.append(pix.tobytes("jpeg", jpg_quality=85))
                                    pdf_page_labels.append(f"File {idx+1} ({short_fname}) / Page {p_idx+1}")
                                except Exception as p_err:
                                    print(f"[Multi-Upload Render Error] File '{fname}' page {p_idx+1}: {p_err}")
                            combined_pdf.insert_pdf(sub_doc)
                        except Exception as ex_pdf:
                            print(f"[Multi-Upload PDF Open Error] '{fname}': {ex_pdf}")
                    else:
                        try:
                            jbytes, _, _, img_yellow, _ = _normalize_image_to_jpeg_bytes(
                                fbytes, quality=88, reject_blank=False
                            )
                            with Image.open(io.BytesIO(jbytes)) as pim:
                                w_px, h_px = pim.size
                            img_page = combined_pdf.new_page(width=w_px, height=h_px)
                            img_page.insert_image(img_page.rect, stream=jbytes)
                            pdf_all_preview_bytes.append(jbytes)
                            pdf_page_texts.append("")
                            pdf_page_labels.append(f"File {idx+1} ({short_fname})")
                            if len(pdf_all_preview_bytes) == 1:
                                is_yellow_image = img_yellow
                        except Exception as ex_img:
                            print(f"[Multi-Upload Image Convert Error] '{fname}': {ex_img}")

                if len(detected_text_lrs) > 1:
                    print(f"[Validation Rejected] Multiple different LR numbers found in document text: {detected_text_lrs}")
                    return {
                        "rejected": JSONResponse(
                            status_code=422,
                            content={
                                "success": False,
                                "error_code": "MULTIPLE_LRS",
                                "title": "Multiple LRs Not Allowed",
                                "message": "Multiple LR documents detected. Please upload documents belonging to only one LR at a time.",
                                "detail": "Multiple LR documents detected. Please upload documents belonging to only one LR at a time.",
                            },
                        )
                    }

                raw_upload_bytes = combined_pdf.tobytes()
            finally:
                combined_pdf.close()

            image_bytes = raw_upload_bytes
            mime_type = "application/pdf"
            pdf_page_count = len(pdf_all_preview_bytes)
            print(f"[Multi-Upload Combined] Successfully combined into a single {pdf_page_count}-page PDF ({len(raw_upload_bytes)} bytes).")

            if pdf_all_preview_bytes:
                pdf_preview_bytes = pdf_all_preview_bytes[0]
                b64_str = base64.b64encode(pdf_preview_bytes).decode("utf-8")
                preview_image_data_url = f"data:image/jpeg;base64,{b64_str}"
                try:
                    with Image.open(io.BytesIO(pdf_preview_bytes)) as pdf_pil:
                        is_yellow_image = is_orange_yellow_image(pdf_pil)
                except Exception:
                    pass
                gemini_page_bytes, gemini_page_labels = _select_gemini_pages_for_pdf(
                    pdf_all_preview_bytes, pdf_page_texts, target_page_idx=0,
                    page_labels=pdf_page_labels, is_multi_file=True
                )
        else:
            fname, ctype, fbytes = upload_meta[0]
            image_bytes = fbytes
            raw_upload_bytes = fbytes

            mime_type = ctype
            if not mime_type or mime_type == "application/octet-stream":
                if lower_filename.endswith(".jpg") or lower_filename.endswith(".jpeg"):
                    mime_type = "image/jpeg"
                elif lower_filename.endswith(".webp"):
                    mime_type = "image/webp"
                elif lower_filename.endswith(".pdf"):
                    mime_type = "application/pdf"
                else:
                    mime_type = "image/png"
            elif lower_filename.endswith(".pdf") or "pdf" in (mime_type or "").lower():
                mime_type = "application/pdf"

            if mime_type == "application/pdf":
                print(f"[DocType] Classified as PDF document ({len(image_bytes)} bytes). Preparing pages for Gemini.")
                try:
                    pdf_doc = pdf_docs_by_idx.get(0)
                    if pdf_doc is None:
                        pdf_doc = fitz.open(stream=image_bytes, filetype="pdf")
                        opened_pdfs.append(pdf_doc)
                    pdf_page_count = len(pdf_doc)
                    print(f"[PDF Detection] Document contains {pdf_page_count} page(s).")

                    found_target_page = False
                    for p_idx, p in enumerate(pdf_doc):
                        page_txt = p.get_text()
                        pdf_page_texts.append(page_txt)
                        txt_low = page_txt.lower()
                        active_prompt, prompt_type = _detect_customer_prompt_from_text(
                            txt_low, active_prompt, prompt_type
                        )
                        if not found_target_page and any(w in txt_low for w in ("consignment", "lorry receipt", "c note", "bilty", "cngr")):
                            target_page_idx = p_idx
                            found_target_page = True
                        for cand in _extract_lr_candidates_from_text(page_txt):
                            detected_text_lrs.add(cand)

                    if len(detected_text_lrs) > 1:
                        print(f"[Validation Rejected] Multiple different LR numbers found in document text: {detected_text_lrs}")
                        return {
                            "rejected": JSONResponse(
                                status_code=422,
                                content={
                                    "success": False,
                                    "error_code": "MULTIPLE_LRS",
                                    "title": "Multiple LRs Not Allowed",
                                    "message": "Multiple LR documents detected. Please upload documents belonging to only one LR at a time.",
                                    "detail": "Multiple LR documents detected. Please upload documents belonging to only one LR at a time.",
                                },
                            )
                        }

                    for p_idx, p in enumerate(pdf_doc):
                        try:
                            pix = p.get_pixmap(dpi=120)
                            pdf_all_preview_bytes.append(pix.tobytes("jpeg", jpg_quality=85))
                            pdf_page_labels.append(f"Page {p_idx+1}")
                        except Exception as p_ex:
                            print(f"[PDF Preview Error] Failed rendering page {p_idx+1}: {p_ex}")

                    if pdf_all_preview_bytes:
                        t_idx = target_page_idx if target_page_idx < len(pdf_all_preview_bytes) else 0
                        pdf_preview_bytes = pdf_all_preview_bytes[t_idx]
                        b64_str = base64.b64encode(pdf_preview_bytes).decode("utf-8")
                        preview_image_data_url = f"data:image/jpeg;base64,{b64_str}"
                        print(f"[PDF Preview] Rendered {len(pdf_all_preview_bytes)} page(s) at 120 DPI (primary page: {t_idx+1})")
                        try:
                            with Image.open(io.BytesIO(pdf_preview_bytes)) as pdf_pil:
                                is_yellow_image = is_orange_yellow_image(pdf_pil)
                            if is_yellow_image:
                                print("[DocType] PDF Bilty classified as Orange/Yellow handwritten bilty (BNF LR No will be forced to blank)")
                            else:
                                print("[DocType] PDF Bilty classified as White printed consignment page")
                        except Exception as c_err:
                            print(f"[DocType Color Check Notice]: {c_err}")

                        gemini_page_bytes, gemini_page_labels = _select_gemini_pages_for_pdf(
                            pdf_all_preview_bytes, pdf_page_texts, target_page_idx=t_idx,
                            page_labels=pdf_page_labels, is_multi_file=False
                        )
                except Exception as ex:
                    print(f"[PDF Preview Error]: {ex}")
            else:
                try:
                    jbytes, orig_w, orig_h, is_yellow_image, is_blank = _normalize_image_to_jpeg_bytes(
                        image_bytes, quality=92, reject_blank=True
                    )
                    if is_yellow_image:
                        print("[DocType] Classified as Orange/Yellow handwritten bilty (BNF LR No will be forced to blank)")
                    else:
                        print("[DocType] Classified as White printed consignment page")
                    if is_blank:
                        print(f"[Validation Rejected] File '{primary_filename}' rejected: solid monochrome/blank image.")
                        return {
                            "rejected": JSONResponse(
                                status_code=422,
                                content={
                                    "success": False,
                                    "error_code": "INVALID_LR",
                                    "title": "Invalid LR",
                                    "message": "Invalid LR – Please upload a valid LR document.",
                                    "detail": "Invalid LR – Please upload a valid LR document.",
                                },
                            )
                        }
                    image_bytes = jbytes
                    mime_type = "image/jpeg"
                    b64_str = base64.b64encode(image_bytes).decode("utf-8")
                    preview_image_data_url = f"data:image/jpeg;base64,{b64_str}"
                    print(f"[Optimize] Ready image: {orig_w}x{orig_h} ({len(image_bytes)} bytes)")
                except Exception as img_err:
                    print(f"[Notice] Image resize pass-through: {img_err}")

        return {
            "rejected": None,
            "active_prompt": active_prompt,
            "prompt_type": prompt_type,
            "is_yellow_image": is_yellow_image,
            "preview_image_data_url": preview_image_data_url,
            "pdf_all_preview_bytes": pdf_all_preview_bytes,
            "gemini_page_bytes": gemini_page_bytes,
            "gemini_page_labels": gemini_page_labels,
            "pdf_page_count": pdf_page_count,
            "raw_upload_bytes": raw_upload_bytes,
            "image_bytes": image_bytes,
            "mime_type": mime_type,
        }
    finally:
        for h in opened_pdfs:
            try:
                h.close()
            except Exception:
                pass


def _persist_extracted_document_sync(
    *,
    upload_id: str,
    now_ts: str,
    lr_clean: str,
    lr_tag: str,
    clean_name: str,
    orig_ext: str,
    primary_filename: str,
    display_filename: str,
    bytes_to_save: bytes,
    mime_type: str,
    pdf_all_preview_bytes: list[bytes],
    pdf_page_count: int,
    preview_image_data_url: str | None,
    data_dict: dict[str, Any],
    kv_pairs: list[dict[str, str]],
    raw_result: dict[str, Any],
    actor: dict[str, Any],
    user_mobile: str | None,
    user_id: str | None,
    user_name: str | None,
) -> ParsedDocument:
    """Persists uploaded LR document, preview pages, lifecycle metadata, and cloud record off the event loop."""
    snapshot_lr_filename, snapshot_lr_path = audit_snapshot.save_uploaded_lr_document(
        file_bytes=bytes_to_save,
        original_filename=f"{clean_name}{orig_ext}",
        lr_no=lr_clean,
    )
    print(f"[Upload Vault] Successfully saved LR document to {snapshot_lr_path}")

    preview_saved_url = None
    preview_pages_urls: list[str] = []
    if mime_type == "application/pdf" and pdf_all_preview_bytes:
        for p_idx, p_bytes in enumerate(pdf_all_preview_bytes):
            page_suffix = "_preview.jpg" if p_idx == 0 else f"_page_{p_idx + 1}.jpg"
            p_filename = f"{upload_id}{lr_tag}_{clean_name}{page_suffix}"
            p_file_path = os.path.join(UPLOAD_LR_DIR, p_filename)
            try:
                with open(p_file_path, "wb") as f_prev:
                    f_prev.write(p_bytes)
                preview_pages_urls.append(f"/uploads/{p_filename}")
            except Exception as e_prev:
                print(f"[Upload Vault Error] Failed to save page {p_idx+1} preview: {e_prev}")
        if preview_pages_urls:
            preview_saved_url = preview_pages_urls[0]
            print(f"[Upload Vault] Successfully saved {len(preview_pages_urls)} preview image(s) (primary: {preview_saved_url})")

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
                "original_filename": primary_filename,
                "snapshot_path": snapshot_lr_path,
                "user_id": actor.get("user_id") or "",
                "user_mobile": actor.get("user_mobile") or "",
                "created_by": actor.get("user_name") or "Logistics User",
            },
            initial_data=data_dict,
        )
    except Exception as ex:
        print(f"[Lifecycle] Non-critical image registration error: {ex}")

    v1_list = reg_entry.get("versions", []) if reg_entry else [
        {
            "version": 1,
            "timestamp": now_ts,
            "action": "create",
            "details": "Document created from OCR",
            "snapshot_data": data_dict,
        }
    ]

    rel_saved_path = os.path.relpath(snapshot_lr_path, BASE_DIR).replace("\\", "/")

    parsed_output = ParsedDocument(
        filename=display_filename,
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
        page_count=pdf_page_count,
        preview_pages=preview_pages_urls,
    )

    try:
        user_mob = actor.get("user_mobile") or user_mobile or ""
        user_uid = actor.get("user_id") or user_id or ""
        user_dname = actor.get("user_name") or user_name or "Logistics User"
        if user_mob:
            user_cloud_service.record_uploaded_lr(
                mobile=user_mob,
                lr_entry=parsed_output.model_dump() if hasattr(parsed_output, "model_dump") else parsed_output.dict(),
                user_id=user_uid,
                user_name=user_dname,
            )
    except Exception as cloud_err:
        print(f"[UserCloudService] Notice recording uploaded LR: {cloud_err}")

    return parsed_output


# --- ROUTE 4: Image Extraction API (Web & Android) ---
@app.post("/extract-handwriting", response_model=ParsedDocument)
async def extract_handwriting(
    request: Request,
    file: UploadFile | None = File(default=None),
    files: list[UploadFile] | None = File(default=None),
    custom_prompt: str | None = Form(default=None),
    user_id: str | None = Form(default=None),
    user_mobile: str | None = Form(default=None),
    user_name: str | None = Form(default=None),
    client_source: str | None = Form(default=None),
    authorization: str | None = Header(default=None),
):
    actor = _resolve_user_from_request(
        authorization=authorization,
        user_id=user_id,
        user_mobile=user_mobile,
        user_name=user_name
    )

    is_web = str(client_source or "").strip().lower() == "web"
    # Collect all uploaded files from multipart form
    all_uploads: list[UploadFile] = []
    try:
        form = await request.form()
        if not is_web:
            is_web = str(form.get("client_source") or "").strip().lower() == "web"
        for f in form.getlist("files"):
            if isinstance(f, UploadFile):
                all_uploads.append(f)
        for f in form.getlist("file"):
            if isinstance(f, UploadFile) and f not in all_uploads:
                all_uploads.append(f)
    except Exception as e_form:
        print(f"[Upload] Form parsing notice: {e_form}")

    if not all_uploads:
        if file and hasattr(file, "filename") and hasattr(file, "read"):
            all_uploads = [file]
        elif files and isinstance(files, (list, tuple)):
            all_uploads = [f for f in files if hasattr(f, "filename") and hasattr(f, "read")]

    if not all_uploads:
        raise HTTPException(status_code=400, detail="No files uploaded.")

    MAX_FILE_SIZE_BYTES = 10 * 1024 * 1024
    total_files_count = len(all_uploads)
    primary_filename = all_uploads[0].filename or "uploaded_doc"
    display_filename = primary_filename if total_files_count == 1 else f"{primary_filename} (+{total_files_count - 1} files)"

    print(f"\n[Step 1/5] Received {total_files_count} file(s). Primary: '{primary_filename}'")

    # Read and validate each file size
    upload_bytes_list: list[bytes] = []
    for uf in all_uploads:
        try:
            await uf.seek(0)
        except Exception:
            pass
        b = await uf.read()
        if len(b) == 0:
            print(f"[Upload Error] Uploaded file '{uf.filename}' is empty (0 bytes).")
            raise HTTPException(status_code=400, detail=f"Uploaded file '{uf.filename}' is empty.")
        if len(b) > MAX_FILE_SIZE_BYTES:
            size_mb = len(b) / (1024 * 1024)
            print(f"[Size Limit Error] Uploaded file '{uf.filename}' ({size_mb:.2f} MB) exceeds 10 MB limit.")
            raise HTTPException(
                status_code=413,
                detail=f"File '{uf.filename}' ({size_mb:.2f} MB) exceeds the allowed limit of 10 MB per file. Please upload files under 10 MB."
            )
        upload_bytes_list.append(b)

    # Single non-blocking worker pass for page count limit, text/LR detection, and image/PDF rendering
    upload_meta = [
        (uf.filename or f"doc_{idx+1}", uf.content_type or "", b)
        for idx, (uf, b) in enumerate(zip(all_uploads, upload_bytes_list))
    ]
    prep = await asyncio.to_thread(_preprocess_uploads_sync, upload_meta, custom_prompt)
    if prep.get("rejected") is not None:
        return prep["rejected"]

    active_prompt = prep["active_prompt"]
    prompt_type = prep["prompt_type"]
    is_yellow_image = prep["is_yellow_image"]
    preview_image_data_url = prep["preview_image_data_url"]
    pdf_all_preview_bytes = prep["pdf_all_preview_bytes"]
    gemini_page_bytes = prep["gemini_page_bytes"]
    gemini_page_labels = prep.get("gemini_page_labels") or []
    pdf_page_count = prep["pdf_page_count"]
    raw_upload_bytes = prep["raw_upload_bytes"]
    image_bytes = prep["image_bytes"]
    mime_type = prep["mime_type"]

    print(f"[Step 3/5] Initializing Gemini model ('{MODEL_NAME}') with [{prompt_type}] prompt...")
    model = genai.GenerativeModel(MODEL_NAME)

    print(f"[Step 4/5] Sending request to Gemini API (MIME type: {mime_type})...")

    try:
        gemini_parts = []
        is_multi_page_input = False
        if mime_type == "application/pdf" and (gemini_page_bytes or pdf_all_preview_bytes):
            pages_to_send = gemini_page_bytes or pdf_all_preview_bytes
            is_multi_page_input = len(pages_to_send) > 1 or pdf_page_count > 1
            print(f"[Gemini Input] Sending {len(pages_to_send)}/{len(pdf_all_preview_bytes)} rendered page image(s) to Gemini for single-call extraction & multi-LR validation.")
            for idx_p, p_bytes in enumerate(pages_to_send):
                if len(pages_to_send) > 1:
                    lbl = gemini_page_labels[idx_p] if idx_p < len(gemini_page_labels) else f"Page {idx_p + 1}"
                    gemini_parts.append(f"--- {lbl} ---")
                gemini_parts.append({"mime_type": "image/jpeg", "data": p_bytes})
        else:
            gemini_parts.append({"mime_type": mime_type, "data": image_bytes})

        if is_multi_page_input:
            gemini_parts.append(MULTI_DOCUMENT_CONSIGNMENT_RULE + "\n\n" + active_prompt)
        else:
            gemini_parts.append(active_prompt + "\n" + MULTI_DOCUMENT_CONSIGNMENT_RULE)

        def _sync_gemini_call():
            return model.generate_content(
                gemini_parts,
                generation_config=genai.GenerationConfig(
                    response_mime_type="application/json",
                    response_schema=_to_gemini_compatible_schema(GeminiOCRResponse),
                    temperature=0.0,
                ),
                safety_settings=SAFETY_SETTINGS,
            )

        response = await asyncio.to_thread(_sync_gemini_call)
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

        # Canonicalize all fields to 49 BNF schema & standard aliases
        data_dict = canonicalize_extracted_data(data_dict, web_mode=is_web)

        # === MULTI-LR DETECTION VALIDATION GATE ===
        has_multi_lrs = bool(raw_result.get("has_multiple_different_lrs", False))
        detected_lrs = raw_result.get("detected_lr_numbers", [])
        page_entries = raw_result.get("page_lr_entries", [])

        cleaned_lrs: dict[str, str] = {}

        def _add_lr_candidate(raw_lr_val: Any) -> None:
            raw_s = str(raw_lr_val or "").strip()
            if not raw_s:
                return
            c = _normalize_lr_candidate(_clean_grno(raw_s))
            if c and c != "0" and len(c) >= 2 and c not in cleaned_lrs:
                cleaned_lrs[c] = raw_s

        if isinstance(page_entries, list):
            for p_entry in page_entries:
                if isinstance(p_entry, dict) and p_entry.get("is_consignment_note"):
                    _add_lr_candidate(p_entry.get("lr_number"))

        if isinstance(detected_lrs, list):
            for lr_cand in detected_lrs:
                _add_lr_candidate(lr_cand)

        _add_lr_candidate(data_dict.get("LR No *") or data_dict.get("grno") or data_dict.get("grno (*)"))

        if len(cleaned_lrs) > 1:
            has_multi_lrs = True

        if has_multi_lrs:
            all_found = list(cleaned_lrs.values()) or (detected_lrs if isinstance(detected_lrs, list) else [])
            print(f"[Validation Rejected] Multiple different LR documents detected across pages/files: {all_found}")
            return JSONResponse(
                status_code=422,
                content={
                    "success": False,
                    "error_code": "MULTIPLE_LRS",
                    "title": "Multiple LRs Not Allowed",
                    "message": "Multiple LR documents detected. Please upload documents belonging to only one LR at a time.",
                    "detail": "Multiple LR documents detected. Please upload documents belonging to only one LR at a time."
                }
            )

        # === FAIL-SAFE GENUINE LR VALIDATION GATE ===
        is_valid_lr = bool(raw_result.get("is_valid_lr", False))
        has_consignment = bool(raw_result.get("has_consignment_note", False))
        doc_type = str(raw_result.get("document_type", "unknown")).lower()
        rejection_reason = str(raw_result.get("rejection_reason", "")).strip()

        has_lr_no = bool(str(data_dict.get("LR No *") or data_dict.get("grno") or data_dict.get("BNF LR No") or "").strip())
        has_parties = bool(
            raw_result.get("has_parties_or_movement")
            or str(data_dict.get("cngr *") or data_dict.get("cngr") or "").strip()
            or str(data_dict.get("cnge *") or data_dict.get("cnge") or "").strip()
            or str(data_dict.get("Customer Name *") or "").strip()
            or str(data_dict.get("orgrefcode") or "").strip()
            or str(data_dict.get("destrefcode") or "").strip()
        )
        has_cargo = bool(
            raw_result.get("has_cargo_or_vehicle")
            or str(data_dict.get("Vehicle No *") or data_dict.get("truckno") or "").strip()
            or str(data_dict.get("stockpckgs") or data_dict.get("bookedpckgs") or data_dict.get("packages") or "").strip()
            or str(data_dict.get("stockaweight") or data_dict.get("bookedaweight") or "").strip()
            or str(data_dict.get("goods") or "").strip()
        )
        has_freight = bool(
            raw_result.get("has_freight_terms")
            or str(data_dict.get("grtype") or data_dict.get("staxpaidby") or "").strip()
            or str(data_dict.get("valgoods") or data_dict.get("invoiceno") or "").strip()
        )

        supporting_signals_count = sum([has_parties, has_cargo, has_freight, has_lr_no])

        is_rejected_type = any(
            t in doc_type for t in [
                "standalone_eway", "standalone_invoice", "standalone_gate_pass",
                "selfie", "screenshot", "blank", "unrelated"
            ]
        )

        is_genuine_lr = (
            is_valid_lr
            and has_consignment
            and not is_rejected_type
            and supporting_signals_count >= 2
        )

        if not is_genuine_lr:
            print(f"[Validation Rejected] File '{primary_filename}' rejected: is_valid={is_valid_lr}, has_consignment={has_consignment}, doc_type='{doc_type}', signals={supporting_signals_count}, reason='{rejection_reason}'")
            return JSONResponse(
                status_code=422,
                content={
                    "success": False,
                    "error_code": "INVALID_LR",
                    "title": "Invalid LR",
                    "message": "Invalid LR – Please upload a valid LR document.",
                    "detail": "Invalid LR – Please upload a valid LR document."
                }
            )

        # Ensure Driver details remain strictly empty if absent from the document (driver_master auto-fetch disabled)
        for drv_key in ("Driver Name *", "Mobile no   *", "Liscense No *", "Valid Up to *"):
            if not data_dict.get(drv_key):
                data_dict[drv_key] = ""
            for item in kv_pairs:
                if item.get("key") == drv_key and not item.get("value"):
                    item["value"] = ""

        # Sanitize dummy values
        if str(data_dict.get("Mobile no   *") or "").strip() in ("9999999999", "0000000000", "99999 99999"):
            data_dict["Mobile no   *"] = ""
            for item in kv_pairs:
                if item.get("key") == "Mobile no   *":
                    item["value"] = ""

        # Clean pmark
        pmark_candidate = (
            data_dict.get("pmark")
            or data_dict.get("Private Mark")
            or data_dict.get("pmark (*)")
            or data_dict.get("Seal No")
            or data_dict.get("Seal Number")
            or data_dict.get("Seal")
            or ""
        )
        cleaned_pmark = _clean_pmark(pmark_candidate)
        data_dict["pmark"] = cleaned_pmark
        for item in kv_pairs:
            if item.get("key") in ("pmark", "Private Mark", "pmark (*)", "Seal No", "Seal Number"):
                item["value"] = cleaned_pmark

        # Unnumbered bilty handling
        raw_lr = data_dict.get("grno") or data_dict.get("grno (*)") or data_dict.get("LR No *") or data_dict.get("lrno")
        is_orange_yellow_doc = is_yellow_image or prompt_type in ("Custom", "Default Master OCR")
        if (raw_lr == "0" or str(data_dict.get("LR No *") or "").strip() == "0") and is_orange_yellow_doc:
            data_dict["grno"] = "0"
            data_dict["grno (*)"] = "0"
            data_dict["LR No *"] = "0"
            data_dict["LR No"] = "0"
            data_dict["lrno"] = "0"

        # Freight: Must be mandatory manual input
        data_dict["freight  *"] = ""
        data_dict["freight"] = ""

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

            if data_dict.get("cngrgstno *"):
                data_dict["cngrgstno *"] = re.sub(r'\s+', '', str(data_dict["cngrgstno *"])).upper()
                data_dict["cngrgstno"] = data_dict["cngrgstno *"]
            if data_dict.get("cngegstno *"):
                data_dict["cngegstno *"] = re.sub(r'\s+', '', str(data_dict["cngegstno *"])).upper()
                data_dict["cngegstno"] = data_dict["cngegstno *"]
        except Exception as e_gst:
            print(f"[Master] Party GST auto-lookup notice: {e_gst}")

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

        data_dict["freight  *"] = ""
        data_dict["freight"] = ""

        oamt_raw = data_dict.get("oamount") or data_dict.get("other amount") or data_dict.get("other charges") or data_dict.get("hamali")
        if oamt_raw and str(oamt_raw).strip() not in ("", "0", "0.00", "None", "null", "nan"):
            data_dict["oamount"] = str(oamt_raw).strip()
        else:
            data_dict["oamount"] = "0.00"

        # Special customer rules
        if prompt_type == "Himalaya OCR" or "himalaya" in str(data_dict.get("Customer Name *") or "").lower():
            if not data_dict.get("Customer Name *"):
                data_dict["Customer Name *"] = "HIMALAYA WELLNESS COMPANY"
            data_dict["freight  *"] = ""
            data_dict["freight"] = ""
            data_dict["cgst"] = "0.00"
            data_dict["sgst"] = "0.00"
            data_dict["igst"] = "0.00"
            data_dict["received"] = "0.00"
            data_dict["advance"] = "0.00"

        is_unicharm = _is_unicharm_document(data_dict, prompt_type=prompt_type)
        if is_unicharm:
            if is_web:
                _apply_web_unicharm_customer_default(data_dict, prompt_type=prompt_type)
            elif not data_dict.get("Customer Name *"):
                data_dict["Customer Name *"] = "UNICHARM INDIA PVT. LTD."
            data_dict["freight  *"] = ""
            data_dict["freight"] = ""
            if not data_dict.get("cgst"):
                data_dict["cgst"] = "0.00"
            if not data_dict.get("sgst"):
                data_dict["sgst"] = "0.00"
            data_dict["igst"] = "0.00"
            if not data_dict.get("received"):
                data_dict["received"] = "0.00"
            if not data_dict.get("advance"):
                data_dict["advance"] = "0.00"
            if not data_dict.get("ftl"):
                data_dict["ftl"] = "FTL"
            if not data_dict.get("staxpaidby"):
                data_dict["staxpaidby"] = "C"
            if not data_dict.get("dlvtype"):
                data_dict["dlvtype"] = "D"
            if not data_dict.get("Vehicle Type *"):
                data_dict["Vehicle Type *"] = "Market"

        if _is_patanjali_document(data_dict, prompt_type=prompt_type, filename=primary_filename):
            _apply_patanjali_customer_default(data_dict, prompt_type=prompt_type, filename=primary_filename)

        data_dict["igst"] = "0.00"
        if not data_dict.get("cgst"):
            data_dict["cgst"] = "0"
        if not data_dict.get("sgst"):
            data_dict["sgst"] = "0"

        for date_key in ("grdt", "grdt *", "stockdt", "stockdt ", "Loading Start date *", "invoiedt", "Valid Upto", "Valid Up to *"):
            if data_dict.get(date_key):
                data_dict[date_key] = _format_date_ddmmyyyy(data_dict[date_key])

        data_dict = canonicalize_extracted_data(data_dict, web_mode=is_web)
        kv_pairs = [{"key": k, "value": v} for k, v in data_dict.items()]

        now_ts = file_lifecycle_service.get_current_timestamp()
        now_dt = datetime.now()
        upload_id = f"LR_{now_dt.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"

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

        if total_files_count > 1:
            first_base = os.path.basename(primary_filename)
            orig_name_part, _ = os.path.splitext(first_base)
            orig_name_part = f"{orig_name_part}_combined_{total_files_count}_files"
            orig_ext = ".pdf"
        else:
            orig_base = os.path.basename(primary_filename)
            orig_name_part, orig_ext = os.path.splitext(orig_base)
            if not orig_ext:
                orig_ext = ".pdf" if mime_type == "application/pdf" else ".jpg"

        clean_name = re.sub(r'[^a-zA-Z0-9_\-\.]', '_', orig_name_part)[:35]
        bytes_to_save = raw_upload_bytes if raw_upload_bytes else image_bytes

        parsed_output = await asyncio.to_thread(
            _persist_extracted_document_sync,
            upload_id=upload_id,
            now_ts=now_ts,
            lr_clean=lr_clean,
            lr_tag=lr_tag,
            clean_name=clean_name,
            orig_ext=orig_ext,
            primary_filename=primary_filename,
            display_filename=display_filename,
            bytes_to_save=bytes_to_save,
            mime_type=mime_type,
            pdf_all_preview_bytes=pdf_all_preview_bytes,
            pdf_page_count=pdf_page_count,
            preview_image_data_url=preview_image_data_url,
            data_dict=data_dict,
            kv_pairs=kv_pairs,
            raw_result=raw_result,
            actor=actor,
            user_mobile=user_mobile,
            user_id=user_id,
            user_name=user_name,
        )

        print(f"[Success] Extracted {len(data_dict)} key-value pair(s)")
        print(f"[Output Title] {parsed_output.document_title}")
        return parsed_output

    except Exception as e:
        print(f"[Error] Inference pipeline failed: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Inference pipeline failed: {str(e)}")


def _validate_export_docs(docs: list[SingleDocumentExport]) -> None:
    """Validates Department, Counter, GSTIN spacing, and mandatory Freight before export."""
    manifest_map = _load_manifest_data()
    for doc in docs:
        d_dict = _get_doc_data(doc)
        dept = d_dict.get("Depatment Name") or d_dict.get("department") or ""
        cust = d_dict.get("Customer Name *") or d_dict.get("cngr *") or ""
        if dept and not validate_department_exact(str(dept), str(cust) if cust in manifest_map else None):
            raise HTTPException(status_code=400, detail=f"Validation Error: Department '{dept}' is not recognized in ManiFest.xlsx. It must match the master Excel exactly.")
        cntr = d_dict.get("Counter name") or d_dict.get("Counter") or d_dict.get("counter") or ""
        if cntr and not validate_counter_exact(str(cntr)):
            raise HTTPException(status_code=400, detail=f"Validation Error: Counter '{cntr}' is not recognized in BookingCounterMast.xlsx. It must match the master Excel exactly.")
        cngr_gst = str(d_dict.get("cngrgstno *") or d_dict.get("cngrgstno") or "")
        if " " in cngr_gst or "\t" in cngr_gst:
            raise HTTPException(status_code=400, detail=f"Validation Error: Consignor GSTIN '{cngr_gst}' contains spaces. Spaces are strictly prohibited.")
        cnge_gst = str(d_dict.get("cngegstno *") or d_dict.get("cngegstno") or "")
        if " " in cnge_gst or "\t" in cnge_gst:
            raise HTTPException(status_code=400, detail=f"Validation Error: Consignee GSTIN '{cnge_gst}' contains spaces. Spaces are strictly prohibited.")
        frt = str(d_dict.get("freight  *") or d_dict.get("freight") or "").strip()
        if not frt:
            raise HTTPException(status_code=400, detail="Validation Error: Freight is mandatory. Please enter Freight before exporting.")


def _resolve_export_format(format_type: str | None, docs: list[SingleDocumentExport]) -> str:
    """Resolves normalized export format token for a batch of documents."""
    fmt = (format_type or "").lower().strip()
    if not fmt or fmt == "auto":
        for d in docs:
            k_lower = "".join(d.data.keys()).lower()
            if any(term in k_lower for term in ("grno", "gr_no", "bilty", "lr", "cngr", "cnge", "consignor", "consignee", "eway", "freight", "vehicle", "driver")):
                return "gr_bnf_49"
        return "dynamic"
    return fmt


def _build_workbook_for_docs(
    docs: list[SingleDocumentExport],
    format_type: str = "gr_bnf_49",
    user_name: str = "Logistics User",
    export_id: str | None = None,
    include_audit_meta: bool = True,
    web_mode: bool = False,
    precomputed_rows: list[list] | None = None,
    skip_validation: bool = False,
) -> tuple[openpyxl.Workbook, bytes, str, str]:
    # Strict validation: verify all documents have valid exact Department and Counter values and space-free GSTIN
    if not skip_validation:
        _validate_export_docs(docs)

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

    fmt = _resolve_export_format(format_type, docs)

    # Clean uncolored styling (no yellow, no red fills)
    no_fill = PatternFill(fill_type=None)
    header_font_clean = Font(name="Calibri", size=10, bold=True, color="000000")
    mapped_49_rows_cache: list[list] | None = None

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
            row_vals = map_to_gr_row(_get_doc_data(doc), headers, web_mode=web_mode)
            ws1.row_dimensions[r_idx].height = 20
            for col_idx, (h, val) in enumerate(zip(headers, row_vals), start=1):
                c = ws1.cell(row=r_idx, column=col_idx)
                c.font = data_font
                c.border = thin_border
                c.alignment = left_align
                c.fill = no_fill
                clean_h = re.sub(r'[^a-zA-Z0-9]', '', str(h or '')).lower()
                if clean_h in DATE_COLUMN_KEYS:
                    dt_val = _parse_to_datetime_obj(val)
                    if dt_val is not None:
                        c.value = dt_val
                        c.number_format = 'dd-mm-yyyy'
                    else:
                        c.value = None if str(val or '').strip().lower() in ("", "none", "null", "nan") else val
                        c.number_format = 'dd-mm-yyyy'
                else:
                    c.value = val

        for col in ws1.columns:
            max_len = max(len(str(cell.value or '')) for cell in col)
            col_letter = get_column_letter(col[0].column)
            ws1.column_dimensions[col_letter].width = max(13, min(max_len + 3, 38))

    # =========================================================================
    # OPTION 2: Exact 52-Column BNF Import Format (Customer_Master_GTInfiniti-Consignment_Entry.xlsx)
    # Includes all 52 Columns with pure clean uncolored styling (no yellow/red)
    # =========================================================================
    elif fmt in ("gr_bnf_52", "gr_bnf_50", "gr_bnf_49", "gr_bnf", "bnf"):
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
        mapped_49_rows_cache = (
            precomputed_rows
            if (precomputed_rows is not None and len(precomputed_rows) == len(docs))
            else [map_to_gr_row(_get_doc_data(doc), headers, web_mode=web_mode) for doc in docs]
        )
        for r_offset, row_vals in enumerate(mapped_49_rows_cache):
            curr_row = data_start_row + r_offset
            for col_idx, (h, val) in enumerate(zip(headers, row_vals), start=1):
                c = ws1.cell(row=curr_row, column=col_idx)
                c.font = data_font
                c.border = thin_border
                c.alignment = left_align
                c.fill = no_fill
                clean_h = re.sub(r'[^a-zA-Z0-9]', '', str(h or '')).lower()
                if clean_h in DATE_COLUMN_KEYS:
                    dt_val = _parse_to_datetime_obj(val)
                    if dt_val is not None:
                        c.value = dt_val
                        c.number_format = 'dd-mm-yyyy'
                    else:
                        c.value = None if str(val or '').strip().lower() in ("", "none", "null", "nan") else val
                        c.number_format = 'dd-mm-yyyy'
                else:
                    c.value = val
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

            for col_idx, (h, val) in enumerate(zip(headers, row_vals), start=1):
                cell = ws1.cell(row=row_num, column=col_idx)
                cell.font = data_font
                cell.border = thin_border
                cell.alignment = center_align if col_idx == 1 else left_align
                if r_idx % 2 == 0:
                    cell.fill = zebra_fill
                clean_h = re.sub(r'[^a-zA-Z0-9]', '', str(h or '')).lower()
                if clean_h in DATE_COLUMN_KEYS:
                    dt_val = _parse_to_datetime_obj(val)
                    if dt_val is not None:
                        cell.value = dt_val
                        cell.number_format = 'dd-mm-yyyy'
                    else:
                        cell.value = None if str(val or '').strip().lower() in ("", "none", "null", "nan") else val
                        cell.number_format = 'dd-mm-yyyy'
                else:
                    cell.value = val

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

        # Rows 6+: Data Rows (reusing precomputed 49-col mapped rows when available)
        for idx_doc, doc in enumerate(docs):
            r_idx = 6 + idx_doc
            if mapped_49_rows_cache is not None:
                gr_49_vals = mapped_49_rows_cache[idx_doc]
            elif precomputed_rows is not None and len(precomputed_rows) == len(docs) and len(precomputed_rows[idx_doc]) == len(GR_BNF_49_HEADERS):
                gr_49_vals = precomputed_rows[idx_doc]
            else:
                gr_49_vals = map_to_gr_row(_get_doc_data(doc), GR_BNF_49_HEADERS, web_mode=web_mode)
            row_vals = [user_name, export_date, export_time, exported_at, *gr_49_vals]
            for col_idx, (h, val) in enumerate(zip(history_full_headers, row_vals), start=1):
                c = ws_history.cell(row=r_idx, column=col_idx)
                c.font = data_font
                c.border = thin_border
                c.alignment = left_align
                c.fill = no_fill
                clean_h = re.sub(r'[^a-zA-Z0-9]', '', str(h or '')).lower()
                if clean_h in DATE_COLUMN_KEYS:
                    dt_val = _parse_to_datetime_obj(val)
                    if dt_val is not None:
                        c.value = dt_val
                        c.number_format = 'dd-mm-yyyy'
                    else:
                        c.value = None if str(val or '').strip().lower() in ("", "none", "null", "nan") else val
                        c.number_format = 'dd-mm-yyyy'
                else:
                    c.value = val
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
    file_bytes = ensure_excel_date_number_formats(buf.getvalue())

    if fmt in ("gr_stock_38", "gr_stock", "importgrstock"):
        prefix = "ImportGRStock"
    elif fmt in ("gr_bnf_52", "gr_bnf_50", "gr_bnf_49", "gr_bnf", "bnf"):
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
    is_web = str(getattr(req, "client_source", "") or "").strip().lower() == "web"
    wb, file_bytes, filename, export_id = await asyncio.to_thread(
        _build_workbook_for_docs,
        docs, req.format_type or "gr_bnf_49", user_name=user_name, include_audit_meta=False, web_mode=is_web
    )
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
async def api_direct_login(req: DirectLoginRequest, response: Response, request: Request):
    res = auth_service.direct_login(req.mobile, req.name)
    if not res.get("success"):
        raise HTTPException(status_code=400, detail=res.get("error"))
    token = res.get("token")
    if token:
        response.set_cookie(
            key="bnf_session_token",
            value=token,
            max_age=86400,
            httponly=True,
            samesite="lax",
            secure=request.url.is_secure
        )
    return res


@app.post("/api/auth/send-otp")
async def api_send_otp(req: SendOtpRequest):
    res = auth_service.send_otp(req.mobile, req.name)
    if not res.get("success"):
        raise HTTPException(status_code=400, detail=res.get("error"))
    return res


@app.post("/api/auth/verify-otp")
async def api_verify_otp(req: VerifyOtpRequest, response: Response, request: Request):
    res = auth_service.verify_otp(req.mobile, req.otp, req.name)
    if not res.get("success"):
        raise HTTPException(status_code=400, detail=res.get("error"))
    token = res.get("token")
    if token:
        response.set_cookie(
            key="bnf_session_token",
            value=token,
            max_age=86400,
            httponly=True,
            samesite="lax",
            secure=request.url.is_secure
        )
    return res


@app.get("/api/auth/me")
async def api_get_me(request: Request, authorization: str | None = Header(default=None)):
    token = authorization or request.cookies.get("bnf_session_token")
    user = auth_service.get_session_user(token)
    if not user:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return {
        "authenticated": True,
        "user": user,
        "expires_at": user.get("expires_at_epoch"),
        "remaining_seconds": user.get("remaining_seconds")
    }


@app.post("/api/auth/logout")
async def api_logout(response: Response, request: Request, authorization: str | None = Header(default=None)):
    token = authorization or request.cookies.get("bnf_session_token")
    auth_service.logout_session(token)
    response.delete_cookie(key="bnf_session_token")
    return {"success": True, "message": "Logged out successfully"}


# =========================================================================
# ROUTE: MASTER DATA (ManiFest.xlsx, BookingCounterMast.xlsx, Driver Registry)
# =========================================================================
MANIFEST_FILE_PATH = _resolve_project_file("ManiFest.xlsx")
COUNTERS_FILE_PATH = _resolve_project_file("BookingCounterMast.xlsx")
VEHICLE_TYPE_MASTER_PATH = _resolve_project_file("VehicleTypeMaster.xlsx")
GOODS_MASTER_PATH = _resolve_project_file("GoodsMaster.xlsx")

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

_MANIFEST_CACHE_LOCK = threading.RLock()
_CACHED_MANIFEST_PARTIES = None
_CACHED_MANIFEST_DATA = None
_CACHED_COUNTERS_DATA = None
_CACHED_VEHICLE_TYPE_RECORDS = None
_CACHED_GOODS_MASTER_RECORDS = None
_CACHED_GOODS_LOOKUP = None

def _load_manifest_parties() -> tuple[list[dict[str, str]], dict[str, str]]:
    global _CACHED_MANIFEST_PARTIES
    with _MANIFEST_CACHE_LOCK:
        if _CACHED_MANIFEST_PARTIES is not None:
            return _CACHED_MANIFEST_PARTIES

        parties: list[dict[str, str]] = []
        gst_map: dict[str, str] = dict(KNOWN_BRAND_GSTS)
        if os.path.isfile(MANIFEST_FILE_PATH):
            wb = None
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
                    clean_g = re.sub(r'\s+', '', g).upper()
                    return len(clean_g) == 15 and bool(re.match(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{3}$', clean_g))

                def _set_gst(k: str, g: str):
                    if not k or not g:
                        return
                    clean_g = re.sub(r'\s+', '', g).upper()
                    if k not in gst_map:
                        gst_map[k] = clean_g
                    elif _is_standard_gst(clean_g) and not _is_standard_gst(gst_map[k]):
                        gst_map[k] = clean_g

                for row in ws.iter_rows(min_row=2, values_only=True):
                    if not row: continue
                    cust = str(row[cust_idx]).strip() if len(row) > cust_idx and row[cust_idx] is not None else ""
                    # Preserve exact Department string from ManiFest.xlsx without trim or case modification
                    dept = str(row[dept_idx]) if len(row) > dept_idx and row[dept_idx] is not None else ""
                    if dept in ("None", "none", "null"):
                        dept = ""
                    state = str(row[state_idx]).strip() if len(row) > state_idx and row[state_idx] is not None else ""
                    raw_gst = str(row[gst_idx]) if len(row) > gst_idx and row[gst_idx] is not None else ""
                    gst = re.sub(r'\s+', '', raw_gst).upper()
                    if gst in ("NONE", "NULL", ""): gst = ""
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
            finally:
                if wb:
                    try:
                        wb.close()
                    except Exception:
                        pass

        _CACHED_MANIFEST_PARTIES = (parties, gst_map)
        return _CACHED_MANIFEST_PARTIES

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
    global _CACHED_MANIFEST_DATA
    with _MANIFEST_CACHE_LOCK:
        if _CACHED_MANIFEST_DATA is not None:
            return _CACHED_MANIFEST_DATA
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

    # ManiFest.xlsx is the strict single source of truth - zero synthetic base_defaults
    _CACHED_MANIFEST_DATA = mapping
    return _CACHED_MANIFEST_DATA

_CACHED_COUNTERS_RECORDS = None

CITY_SPELLING_ALIASES: dict[str, str] = {
    "CALCUTTA": "KOLKATA",
    "BOMBAY": "MUMBAI",
    "BANGALORE": "BANGLORE",
    "BENGALURU": "BANGLORE",
    "BELGUAM": "BELGAUM",
    "BELAGAVI": "BELGAUM",
    "SECUNDERABAD": "HYDERABAD",
    "MADRAS": "CHENNAI",
    "MANGALORE": "MANGLORE",
    "MANGALURU": "MANGLORE",
    "TUMAKURU": "TUMKUR",
    "AHMEDABAD": "AHEMDABAD",
    "AHEMBADAB": "AHEMDABAD",
    "GURGAON": "GURUGRAM",
    "VIJAYAWADA": "VIJAYWADA",
}

def _load_booking_counter_records() -> list[dict[str, str]]:
    global _CACHED_COUNTERS_RECORDS
    with _MANIFEST_CACHE_LOCK:
        if _CACHED_COUNTERS_RECORDS is not None:
            return _CACHED_COUNTERS_RECORDS

        records: list[dict[str, str]] = []
        if os.path.isfile(COUNTERS_FILE_PATH):
            wb = None
            try:
                wb = openpyxl.load_workbook(COUNTERS_FILE_PATH, data_only=True)
                ws = wb.active
                # BookingCounterMast.xlsx header: ('ID', 'Counter Name', 'From Date', 'Close Date', 'Branch Name')
                for row in ws.iter_rows(min_row=2, values_only=True):
                    if not row or len(row) < 2 or row[1] is None:
                        continue
                    cnt_name = str(row[1]).strip()
                    if not cnt_name or cnt_name.lower() in ("none", "null", ""):
                        continue
                    branch_name = str(row[4]).strip() if len(row) > 4 and row[4] else ""
                    records.append({
                        "id": str(row[0]) if row[0] is not None else "",
                        "counter_name": cnt_name,
                        "branch_name": branch_name,
                    })
            except Exception as ex:
                print(f"[MasterData] Error loading BookingCounterMast.xlsx records: {ex}")
            finally:
                if wb:
                    try:
                        wb.close()
                    except Exception:
                        pass
        _CACHED_COUNTERS_RECORDS = records
        return _CACHED_COUNTERS_RECORDS

def _load_counters_data() -> list[str]:
    global _CACHED_COUNTERS_DATA
    with _MANIFEST_CACHE_LOCK:
        if _CACHED_COUNTERS_DATA is not None:
            return _CACHED_COUNTERS_DATA

        records = _load_booking_counter_records()
        counters: list[str] = []
        for r in records:
            c = r["counter_name"]
            if c not in counters:
                counters.append(c)

        # BookingCounterMast.xlsx is the strict single source of truth - zero synthetic std_counters
        _CACHED_COUNTERS_DATA = counters
        return _CACHED_COUNTERS_DATA

def get_branch_name_for_counter(counter_name: str | None) -> str:
    """Returns exact Branch Name from BookingCounterMast.xlsx for the given Counter Name."""
    if not counter_name:
        return ""
    cnt_str = str(counter_name).strip()
    if not cnt_str:
        return ""
    records = _load_booking_counter_records()
    for rec in records:
        if rec.get("counter_name") == cnt_str:
            return rec.get("branch_name", "")
    cnt_upper = cnt_str.upper()
    for rec in records:
        if (rec.get("counter_name") or "").strip().upper() == cnt_upper:
            return rec.get("branch_name", "")
    return ""

def _load_vehicle_type_records() -> list[dict[str, str]]:
    """Loads all vehicle types and categories from VehicleTypeMaster.xlsx."""
    global _CACHED_VEHICLE_TYPE_RECORDS
    with _MANIFEST_CACHE_LOCK:
        if _CACHED_VEHICLE_TYPE_RECORDS is not None:
            return _CACHED_VEHICLE_TYPE_RECORDS
        records = []
        if os.path.isfile(VEHICLE_TYPE_MASTER_PATH):
            wb = None
            try:
                wb = openpyxl.load_workbook(VEHICLE_TYPE_MASTER_PATH, data_only=True)
                ws = wb.active
                for row in ws.iter_rows(min_row=2, values_only=True):
                    if not row or len(row) < 4:
                        continue
                    t_name = str(row[3] or "").strip()
                    if not t_name or t_name.lower() in ("none", "null", ""):
                        continue
                    records.append({
                        "type_name": t_name,
                        "vehicle_type": str(row[1] or "").strip(),
                        "type_code": str(row[2] or "").strip(),
                        "category": str(row[4] or "").strip() if len(row) > 4 and row[4] else ""
                    })
            except Exception as ex:
                print(f"[MasterData] Error loading VehicleTypeMaster.xlsx: {ex}")
            finally:
                if wb:
                    try: wb.close()
                    except Exception: pass
        _CACHED_VEHICLE_TYPE_RECORDS = records
        return _CACHED_VEHICLE_TYPE_RECORDS

def _load_vehicle_type_names() -> list[str]:
    """Returns sorted unique Type Names from VehicleTypeMaster.xlsx."""
    recs = _load_vehicle_type_records()
    names = []
    for r in recs:
        tn = r["type_name"]
        if tn not in names:
            names.append(tn)
    return names

def _load_goods_master_records() -> list[dict[str, str]]:
    """Loads all active goods records (Active == 'Y') from GoodsMaster.xlsx."""
    global _CACHED_GOODS_MASTER_RECORDS
    with _MANIFEST_CACHE_LOCK:
        if _CACHED_GOODS_MASTER_RECORDS is not None:
            return _CACHED_GOODS_MASTER_RECORDS
        records = []
        if os.path.isfile(GOODS_MASTER_PATH):
            wb = None
            try:
                wb = openpyxl.load_workbook(GOODS_MASTER_PATH, data_only=True)
                ws = wb.active
                for row in ws.iter_rows(min_row=2, values_only=True):
                    if not row or len(row) < 2:
                        continue
                    g_name = str(row[1] or "").strip()
                    if not g_name or g_name.lower() in ("none", "null", ""):
                        continue
                    is_active = str(row[3] or "").strip().upper() == "Y"
                    if not is_active:
                        continue
                    records.append({
                        "goods_name": g_name,
                        "group_name": str(row[2] or "").strip() if len(row) > 2 and row[2] else "",
                        "hsn_code": str(row[5] or "").strip() if len(row) > 5 and row[5] else ""
                    })
            except Exception as ex:
                print(f"[MasterData] Error loading GoodsMaster.xlsx: {ex}")
            finally:
                if wb:
                    try: wb.close()
                    except Exception: pass
        _CACHED_GOODS_MASTER_RECORDS = records
        return _CACHED_GOODS_MASTER_RECORDS

def _load_goods_names() -> list[str]:
    """Returns list of active Goods Names from GoodsMaster.xlsx."""
    recs = _load_goods_master_records()
    return [r["goods_name"] for r in recs]

def _load_goods_lookup() -> dict[str, str]:
    """Returns cached lowercase-to-canonical active goods name mapping for O(1) lookup."""
    global _CACHED_GOODS_LOOKUP
    with _MANIFEST_CACHE_LOCK:
        if _CACHED_GOODS_LOOKUP is not None:
            return _CACHED_GOODS_LOOKUP
        lookup: dict[str, str] = {}
        for g in _load_goods_names():
            k = g.strip().lower()
            if k and k not in lookup:
                lookup[k] = g
        _CACHED_GOODS_LOOKUP = lookup
        return _CACHED_GOODS_LOOKUP

def validate_department_exact(dept: str, customer: str | None = None) -> bool:
    """Validates Department value strictly against ManiFest.xlsx.
    Preserves exact spelling, casing, whitespace, and special characters."""
    if not dept:
        return True
    mapping = _load_manifest_data()
    if customer:
        cust_depts = mapping.get(customer, [])
        if dept in cust_depts:
            return True
        for c_name, c_depts in mapping.items():
            if c_name.upper() == customer.upper() and dept in c_depts:
                return True
    all_depts = {d for depts in mapping.values() for d in depts}
    return dept in all_depts

def validate_counter_exact(counter: str) -> bool:
    """Validates Counter value strictly against BookingCounterMast.xlsx (Counter Name column).
    Preserves exact spelling, casing, whitespace, and special characters."""
    if not counter:
        return True
    counters = _load_counters_data()
    return counter in counters


def auto_detect_department(origin_city: str | None = None, customer: str | None = None, dept_raw: str | None = None, destination: str | None = None, consignee: str | None = None) -> str:
    """Matches extracted LR Origin City against ManiFest.xlsx.
    Extracts the Origin City from the scanned LR using OCR.
    Uses the extracted Origin City to find the matching Department from ManiFest.xlsx.
    Populates only the exact Department value available in the master Excel file.
    Do not use hardcoded values, generated values, or default fallbacks.
    If no reliable match is found, returns empty string '' to require manual selection."""
    mapping = _load_manifest_data()
    if not mapping:
        return ""

    # Filter candidate departments by customer if known
    candidate_depts: list[str] = []
    if customer:
        c_clean = re.sub(r'[^A-Za-z0-9]', '', customer.upper())
        for cust_name, depts in mapping.items():
            cust_clean = re.sub(r'[^A-Za-z0-9]', '', cust_name.upper())
            if c_clean in cust_clean or cust_clean in c_clean or any(token in cust_clean for token in c_clean.split() if len(token) > 3):
                candidate_depts.extend(depts)
    if not candidate_depts:
        candidate_depts = [d for depts in mapping.values() for d in depts]

    # Deduplicate candidate departments while preserving exact strings
    unique_candidates: list[str] = []
    for d in candidate_depts:
        if d not in unique_candidates:
            unique_candidates.append(d)

    # 1. Check for exact match first if dept_raw is explicitly provided
    if dept_raw:
        for d in unique_candidates:
            if d == dept_raw:
                return d
        dept_raw_clean = re.sub(r'[^A-Za-z0-9]', '', dept_raw.upper())
        exact_clean_matches = [d for d in unique_candidates if re.sub(r'[^A-Za-z0-9]', '', d.upper()) == dept_raw_clean]
        if len(exact_clean_matches) == 1:
            return exact_clean_matches[0]

    # 2. Match Origin City from scanned LR against Department location in ManiFest.xlsx
    if origin_city:
        norm_orig = re.sub(r'[^A-Z0-9]', '', str(origin_city).upper())
        for ak, av in CITY_SPELLING_ALIASES.items():
            if ak in norm_orig:
                norm_orig = norm_orig.replace(ak, av)

        matched_depts: list[str] = []
        for d in unique_candidates:
            tokens = [t.strip().upper() for t in re.split(r'[\-\s]+', d) if len(t.strip()) >= 3]
            for t in tokens:
                if t in ("HIM", "HIMALAYA", "PATAN", "PATANJALI", "GLOBAL", "MARKETING", "REYN", "GOLD", "PLUS", "SHREE", "CIMENT", "INDIRA", "INDRA", "VESCO", "MONTE", "CARLO", "HI", "TECH", "UM", "ORTHOTICS", "LIMITED", "PVT", "LTD", "COMPANY", "WELLNESS"):
                    continue
                t_norm = t
                for ak, av in CITY_SPELLING_ALIASES.items():
                    if ak in t_norm:
                        t_norm = t_norm.replace(ak, av)
                t_clean = re.sub(r'[^A-Z0-9]', '', t_norm)
                if t_clean and (t_clean in norm_orig or norm_orig in t_clean):
                    if d not in matched_depts:
                        matched_depts.append(d)
                    break

        if len(matched_depts) == 1:
            return matched_depts[0]

    return ""


def auto_detect_counter(origin_city: str | None = None, counter_raw: str | None = None, branch_raw: str | None = None, origin_raw: str | None = None) -> str:
    """Matches extracted LR Origin City against BookingCounterMast.xlsx.
    Extracts the Origin City from the scanned LR using OCR.
    Uses the extracted Origin City to find the matching Counter Name from BookingCounterMast.xlsx.
    Populates only the exact Counter Name available in the master Excel file.
    Do not use hardcoded values, generated values, or default fallbacks.
    If no reliable match is found, returns empty string '' to require manual selection."""
    records = _load_booking_counter_records()
    if not records:
        return ""

    # Primary clue is extracted Origin City from OCR; fall back to origin_raw, counter_raw, branch_raw if needed
    clues = [origin_city, origin_raw, counter_raw, branch_raw]
    for clue in clues:
        if not clue:
            continue
        clue_str = str(clue).strip()
        if not clue_str or clue_str.lower() in ("none", "null", "nan", ""):
            continue

        norm_clue = re.sub(r'[^A-Z0-9]', '', clue_str.upper())
        for ak, av in CITY_SPELLING_ALIASES.items():
            if ak in norm_clue:
                norm_clue = norm_clue.replace(ak, av)

        # 1. Exact match against Counter Name column in BookingCounterMast.xlsx
        for rec in records:
            c_clean = re.sub(r'[^A-Z0-9]', '', rec["counter_name"].upper())
            if c_clean == norm_clue:
                return rec["counter_name"]

        # 2. Match against primary branch station token (e.g. MUMBAI in MUMBAI_1, BANGLORE in BANGLORE)
        for rec in records:
            br_raw = rec["branch_name"].strip()
            if br_raw:
                primary = re.split(r'[\(_\s]', br_raw)[0].strip()
                p_norm = re.sub(r'[^A-Z0-9]', '', primary.upper())
                for ak, av in CITY_SPELLING_ALIASES.items():
                    if ak in p_norm:
                        p_norm = p_norm.replace(ak, av)
                if p_norm and p_norm == norm_clue:
                    return rec["counter_name"]

        # 3. Match against secondary tokens in Branch Name
        matched: list[str] = []
        for rec in records:
            b_name = rec["branch_name"].upper()
            tokens = [t for t in re.split(r'[^A-Z0-9]+', b_name) if t and t not in ("BRANCH", "HUB", "1")]
            for t in tokens:
                t_clean = re.sub(r'[^A-Z0-9]', '', t)
                for ak, av in CITY_SPELLING_ALIASES.items():
                    if ak in t_clean:
                        t_clean = t_clean.replace(ak, av)
                if len(t_clean) >= 4 and (t_clean in norm_clue or norm_clue in t_clean):
                    if rec["counter_name"] not in matched:
                        matched.append(rec["counter_name"])
                    break

        if len(matched) == 1:
            return matched[0]

    return ""

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

_DRIVER_MASTER_LOCK = threading.RLock()

def _save_driver_master(record: dict[str, str]):
    global MASTER_DRIVER_REGISTRY
    v_clean = "".join(c for c in record.get("vehicle_no", "").upper() if c.isalnum())
    if not v_clean:
        return
    with _DRIVER_MASTER_LOCK:
        MASTER_DRIVER_REGISTRY[v_clean] = record
        temp_file = f"{DRIVER_MASTER_FILE}.tmp_{uuid.uuid4().hex}"
        try:
            os.makedirs(os.path.dirname(DRIVER_MASTER_FILE), exist_ok=True)
            with open(temp_file, "w", encoding="utf-8") as f:
                json.dump(MASTER_DRIVER_REGISTRY, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.replace(temp_file, DRIVER_MASTER_FILE)
        except Exception as ex:
            print(f"[DriverMaster] Save error: {ex}")
            if os.path.exists(temp_file):
                try:
                    os.remove(temp_file)
                except Exception:
                    pass

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
    records = _load_booking_counter_records()
    return {"success": True, "counters": counters, "records": records}

@app.get("/api/master/vehicle-types")
async def api_get_master_vehicle_types():
    types = _load_vehicle_type_names()
    records = _load_vehicle_type_records()
    return {"success": True, "vehicle_types": types, "types": types, "vehicleTypes": types, "records": records}

@app.get("/api/master/goods-master")
async def api_get_master_goods():
    goods = _load_goods_names()
    records = _load_goods_master_records()
    return {"success": True, "goods": goods, "records": records}

@app.get("/api/master/goods")
async def api_get_master_goods_alias():
    return await api_get_master_goods()

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
    client_source: str | None = None


# In-memory ephemeral cache for clean user-facing Excel bytes (avoids saving user files to disk)
_USER_EXCEL_BYTES_CACHE: dict[str, bytes] = {}
_USER_EXCEL_CACHE_LOCK = threading.RLock()

def _build_dual_workbooks_sync(
    docs: list[SingleDocumentExport],
    format_type: str,
    user_name: str,
    web_mode: bool,
) -> tuple[bytes, bytes, str]:
    """
    Validates once, runs map_to_gr_row() once per LR for 49-col BNF exports,
    and builds both the audit workbook bytes and clean user workbook bytes.
    """
    _validate_export_docs(docs)
    fmt = _resolve_export_format(format_type, docs)
    precomputed_rows = None
    if fmt in ("gr_bnf_52", "gr_bnf_50", "gr_bnf_49", "gr_bnf", "bnf"):
        precomputed_rows = [
            map_to_gr_row(_get_doc_data(doc), GR_BNF_49_HEADERS, web_mode=web_mode)
            for doc in docs
        ]

    _, audit_bytes, _, export_id = _build_workbook_for_docs(
        docs, format_type, user_name=user_name, include_audit_meta=True,
        web_mode=web_mode, precomputed_rows=precomputed_rows, skip_validation=True
    )
    _, user_bytes, _, _ = _build_workbook_for_docs(
        docs, format_type, user_name=user_name, export_id=export_id, include_audit_meta=False,
        web_mode=web_mode, precomputed_rows=precomputed_rows, skip_validation=True
    )
    return audit_bytes, user_bytes, export_id


def _persist_export_outputs_sync(
    *,
    docs: list[SingleDocumentExport],
    user_bytes: bytes,
    audit_bytes: bytes,
    export_id: str,
    user_filename: str,
    audit_filename: str,
    user_name: str,
    user_mobile: str,
    active_token: str | None,
    format_type: str,
    exported_at: str,
) -> dict[str, Any]:
    """Saves snapshot Excel, updates lifecycle registry in one atomic write, and logs audit + cloud DB."""
    user_filename, _, audit_filename, backend_audit_path = audit_snapshot.save_dual_exports(
        user_bytes=user_bytes,
        audit_bytes=audit_bytes,
        export_id=export_id,
        lr_count=len(docs),
        lr_tag="",
        prefix="GR_Import_BNF",
        user_filename=user_filename,
        audit_filename=audit_filename
    )

    doc_refs = []
    plain_docs = []
    for doc in docs:
        d_map = _get_doc_data(doc)
        doc_fn = getattr(doc, "filename", None) or (doc.get("filename") if isinstance(doc, dict) else None) or ""
        doc_lr = str(d_map.get("lrno") or d_map.get("LR No *") or d_map.get("grno") or "").strip()
        doc_refs.append({"filename": doc_fn, "lr_no": doc_lr})
        plain_docs.append(doc.model_dump() if hasattr(doc, "model_dump") else (doc if isinstance(doc, dict) else {}))

    excel_meta = file_lifecycle_service.record_export_batch_lifecycle(
        export_id=export_id,
        user_excel_path=os.path.join(UPLOAD_LR_DIR, user_filename),
        user_filename=user_filename,
        audit_excel_path=backend_audit_path,
        audit_filename=audit_filename,
        audit_bytes=audit_bytes,
        user_name=user_name,
        user_mobile=user_mobile,
        format_type=format_type,
        exported_at=exported_at,
        doc_refs=doc_refs,
    )

    audit_info = audit_snapshot.generate_lightweight_snapshot(
        export_id=export_id,
        filename=user_filename,
        user_name=user_name,
        user_mobile=user_mobile,
        documents=plain_docs,
        file_bytes=audit_bytes,
        audit_filename=audit_filename,
        user_export_filename=user_filename
    )
    audit_snapshot.record_export_audit(audit_info)

    file_size_kb = round(len(user_bytes) / 1024, 1)
    try:
        if user_mobile:
            user_cloud_service.record_generated_excel(
                mobile=user_mobile,
                excel_entry={
                    "export_id": export_id,
                    "filename": user_filename,
                    "user_export_filename": user_filename,
                    "audit_filename": audit_filename,
                    "download_url": f"/api/download-export/{user_filename}",
                    "audit_download_url": f"/api/download-audit-export/{audit_filename}",
                    "file_size_kb": file_size_kb,
                    "total_lrs": len(docs),
                    "generated_on": exported_at,
                    "generated_by": user_name,
                    "documents": plain_docs,
                },
                user_id=active_token,
                user_name=user_name,
            )
    except Exception as cloud_ex:
        print(f"[UserCloudService] Notice recording generated Excel: {cloud_ex}")

    return {
        "user_filename": user_filename,
        "audit_filename": audit_filename,
        "file_size_kb": file_size_kb,
        "created_at": excel_meta.get("created_at"),
    }


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

    now = datetime.now()
    export_date = now.strftime("%d-%b-%Y")
    export_time = now.strftime("%I:%M:%S %p")
    exported_at = now.strftime("%d-%b-%Y %I:%M:%S %p")

    fmt_type = req.format_type or "gr_bnf_49"
    is_web = str(req.client_source or "").strip().lower() == "web"

    audit_bytes, user_bytes, export_id = await asyncio.to_thread(
        _build_dual_workbooks_sync,
        docs, fmt_type, user_name, is_web
    )

    user_filename, audit_filename = audit_snapshot.generate_export_filenames(now)

    with _USER_EXCEL_CACHE_LOCK:
        _USER_EXCEL_BYTES_CACHE[user_filename] = user_bytes
        _USER_EXCEL_BYTES_CACHE[audit_filename] = audit_bytes
        _USER_EXCEL_BYTES_CACHE[export_id] = user_bytes
        _USER_EXCEL_BYTES_CACHE[f"USER_EXPORT_GR_Import_BNF_EXP_{export_id}_{len(docs)}LRs.xlsx"] = user_bytes
        while len(_USER_EXCEL_BYTES_CACHE) > 50:
            first_k = next(iter(_USER_EXCEL_BYTES_CACHE))
            _USER_EXCEL_BYTES_CACHE.pop(first_k, None)

    persist_res = await asyncio.to_thread(
        _persist_export_outputs_sync,
        docs=docs,
        user_bytes=user_bytes,
        audit_bytes=audit_bytes,
        export_id=export_id,
        user_filename=user_filename,
        audit_filename=audit_filename,
        user_name=user_name,
        user_mobile=user_mobile,
        active_token=active_token,
        format_type=fmt_type,
        exported_at=exported_at,
    )
    user_filename = persist_res["user_filename"]
    audit_filename = persist_res["audit_filename"]
    file_size_kb = persist_res["file_size_kb"]

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
        "created_at": persist_res["created_at"],
        "total_lrs": len(docs),
        "total_records": len(docs),
    }


def _record_device_download_safe(file_name: str, actor_name: str) -> None:
    try:
        file_lifecycle_service.record_file_export(
            file_id_or_path=file_name,
            user_name=actor_name,
            destination="device_download",
        )
    except Exception:
        pass


def _load_fallback_download_bytes_sync(safe_name: str) -> bytes | None:
    """
    Loads legacy clean workbook bytes from disk or reconstructs a clean report
    from snapshots_excel off the asyncio event loop.
    """
    file_path = None
    candidate_lr = os.path.join(UPLOAD_LR_DIR, safe_name)
    if os.path.isfile(candidate_lr):
        file_path = candidate_lr
    else:
        candidate_exp = os.path.join(audit_snapshot.EXPORTS_DIR, safe_name)
        if os.path.isfile(candidate_exp):
            file_path = candidate_exp

    if file_path and os.path.isfile(file_path):
        wb_test = None
        try:
            wb_test = openpyxl.load_workbook(file_path, read_only=True)
            has_history = "History" in wb_test.sheetnames
            wb_test.close()
            wb_test = None
            if not has_history:
                with open(file_path, "rb") as f_disk:
                    disk_bytes = f_disk.read()
                return ensure_excel_date_number_formats(disk_bytes)
        except Exception:
            if wb_test is not None:
                try:
                    wb_test.close()
                except Exception:
                    pass

    snap_path = audit_snapshot.resolve_snapshot_path(safe_name)
    if snap_path and os.path.isfile(snap_path):
        wb = None
        try:
            wb = openpyxl.load_workbook(snap_path)
            if "History" in wb.sheetnames:
                wb.remove(wb["History"])
            ws = wb["Sheet1"] if "Sheet1" in wb.sheetnames else wb.active
            while ws.max_row > 1 and ws.cell(1, 1).value and str(ws.cell(1, 1).value).strip().startswith(("User Name:", "Export Date:", "Export Time:", "Exported At:")):
                ws.delete_rows(1, 1)

            buf = io.BytesIO()
            wb.save(buf)
            clean_bytes = ensure_excel_date_number_formats(buf.getvalue())
            with _USER_EXCEL_CACHE_LOCK:
                _USER_EXCEL_BYTES_CACHE[safe_name] = clean_bytes
            return clean_bytes
        except Exception as e_stream:
            print(f"[Export Download Stream Error] {e_stream}")
            raise HTTPException(status_code=500, detail=f"Failed to generate clean download workbook: {e_stream}")
        finally:
            if wb is not None:
                try:
                    wb.close()
                except Exception:
                    pass

    return None


@app.get("/api/download-export/{filename}")
async def download_exported_file(
    filename: str,
    user_name: str | None = None,
    authorization: str | None = Header(default=None),
    background_tasks: BackgroundTasks = None,
):
    safe_name = os.path.basename(filename)
    actor_name = user_name or "Logistics User"
    if authorization:
        session_user = auth_service.get_session_user(authorization)
        if session_user:
            actor_name = session_user.get("name") or actor_name

    # 1. Primary path: Stream cached clean in-memory user bytes immediately (already number-format patched)
    with _USER_EXCEL_CACHE_LOCK:
        clean_bytes = _USER_EXCEL_BYTES_CACHE.get(safe_name)
        if not clean_bytes:
            exp_match = re.search(r'EXP_[0-9]+_[a-f0-9]+', safe_name)
            if exp_match and exp_match.group(0) in _USER_EXCEL_BYTES_CACHE:
                clean_bytes = _USER_EXCEL_BYTES_CACHE[exp_match.group(0)]

    if clean_bytes:
        if background_tasks is not None:
            background_tasks.add_task(_record_device_download_safe, safe_name, actor_name)
        else:
            await asyncio.to_thread(_record_device_download_safe, safe_name, actor_name)

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

    # 2 & 3. Fallback disk read / snapshot reconstruction executed off the event loop
    fallback_bytes = await asyncio.to_thread(_load_fallback_download_bytes_sync, safe_name)
    if fallback_bytes is not None:
        if background_tasks is not None:
            background_tasks.add_task(_record_device_download_safe, safe_name, actor_name)
        else:
            await asyncio.to_thread(_record_device_download_safe, safe_name, actor_name)

        return StreamingResponse(
            io.BytesIO(fallback_bytes),
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            headers={
                "Content-Disposition": f'attachment; filename="{safe_name}"',
                "Access-Control-Expose-Headers": "Content-Disposition",
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "Pragma": "no-cache",
                "Expires": "0"
            }
        )

    raise HTTPException(status_code=404, detail="Exported Excel file not found.")


@app.get("/api/download-audit-export/{filename}")
async def download_audit_exported_file(filename: str):
    """Allows authorized inspection or download of the backend audit copy."""
    safe_name = os.path.basename(filename)
    file_path = audit_snapshot.resolve_file_path(safe_name)
    if not file_path:
        if safe_name.startswith("LR_Report_"):
            audit_name = f"Audit_{safe_name}"
            file_path = audit_snapshot.resolve_file_path(audit_name)
        else:
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

    if not target_mobile:
        # Strictly enforce user data isolation: unauthenticated requests must never access any user's history
        return {
            "success": True,
            "count": 0,
            "history": [],
            "user_mobile": ""
        }

    # Automatically prune any Excel exports whose physical files were deleted from the backend disk
    valid_excels = user_cloud_service.prune_user_deleted_excels(target_mobile)
    if isinstance(valid_excels, list) and len(valid_excels) > 0:
        return {
            "success": True,
            "count": len(valid_excels),
            "history": valid_excels,
            "user_mobile": target_mobile
        }

    logs = audit_snapshot.get_user_audit_history(user_mobile=target_mobile, limit=100)
    if logs and target_mobile:
        for l in logs:
            try:
                user_cloud_service.record_generated_excel(target_mobile, l)
            except Exception:
                pass
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
    client_source: str | None = Query(default=None),
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
    is_web = str(client_source or "").strip().lower() == "web"
    wb, file_bytes, filename, export_id = _build_workbook_for_docs(all_docs, "gr_bnf_49", user_name=user_label, include_audit_meta=False, web_mode=is_web)
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

        clean_req_mob = user_cloud_service._clean_mobile(req_mobile)
        items_map = {}
        dismissed_set = set()

        # 1. Check user's dedicated cloud JSON DB first for user isolation and cross-device sync
        if clean_req_mob:
            cloud_data = user_cloud_service.get_user_cloud_data(clean_req_mob)
            dismissed_set = set(str(d).strip().lower() for d in cloud_data.get("dismissed_uploads", []))
            cloud_uploads = cloud_data.get("uploaded_lrs")
            if isinstance(cloud_uploads, list):
                for u in cloud_uploads:
                    if not isinstance(u, dict):
                        continue
                    if any(str(u.get(k) or "").strip().lower() in dismissed_set for k in ("id", "saved_filename", "filename", "file_name", "file_id", "lrNo")):
                        continue
                    if u.get("error_code") == "INVALID_LR" or str(u.get("status", "")).lower() == "failed" or u.get("is_valid_lr") is False:
                        continue
                    key = str(u.get("saved_filename") or u.get("filename") or u.get("id") or "").strip().lower()
                    if key:
                        items_map[key] = dict(u)

        # 2. Query file lifecycle service and disk files strictly isolated to this authenticated user
        all_metadata = file_lifecycle_service.get_all_metadata(include_deleted=False, limit=200)
        try:
            upload_lr_jpgs = [f for f in sorted(os.listdir(UPLOAD_LR_DIR)) if f.endswith(".jpg")]
        except Exception:
            upload_lr_jpgs = []

        for meta in all_metadata:
            if meta.get("is_deleted", False):
                continue
            if only_pending and (meta.get("is_exported", False) or meta.get("exported_at")):
                continue

            # Strict user isolation check: must match user_id or user_mobile
            custom_meta = meta.get("custom_meta") or {}
            meta_user_id = str(meta.get("user_id") or custom_meta.get("user_id") or "").strip()
            meta_mobile = str(meta.get("user_mobile") or custom_meta.get("user_mobile") or "").strip()
            clean_meta_mob = user_cloud_service._clean_mobile(meta_mobile)

            match_user = False
            if req_user_id and meta_user_id and req_user_id == meta_user_id:
                match_user = True
            elif clean_req_mob and clean_meta_mob and clean_req_mob == clean_meta_mob:
                match_user = True

            # If this record does not belong to the authenticated user, strictly skip it
            if not match_user:
                continue

            file_type = meta.get("file_type")
            if file_type not in ("bilty_image", "bilty_pdf"):
                continue

            saved_name = meta.get("file_name") or ""
            if not saved_name:
                continue

            full_path = os.path.join(UPLOAD_LR_DIR, saved_name)
            if not os.path.isfile(full_path):
                continue

            orig_name = custom_meta.get("original_filename") or saved_name
            if custom_meta.get("is_valid_lr") is False or custom_meta.get("error_code") == "INVALID_LR":
                continue

            # Exclude dummy mock placeholders
            lower_orig = orig_name.lower()
            if any(t in lower_orig for t in ("dummy", "mock", "placeholder", "fake_doc")):
                continue

            file_id = meta.get("file_id") or f"lr_{int(os.path.getmtime(full_path))}"
            lr_no = custom_meta.get("lr_no") or ""
            data_payload = meta.get("current_data") or {}
            if not data_payload and meta.get("versions"):
                data_payload = meta["versions"][-1].get("snapshot_data") or {}
            if not lr_no:
                lr_no = data_payload.get("LR No *") or data_payload.get("grno") or ""

            if any(str(x).strip().lower() in dismissed_set for x in (file_id, saved_name, orig_name, lr_no) if x):
                continue

            is_pdf = file_type == "bilty_pdf" or saved_name.lower().endswith(".pdf") or orig_name.lower().endswith(".pdf")

            preview_url = None
            preview_pages = []
            if is_pdf:
                upload_prefix = custom_meta.get("upload_id") or ""
                base_stem = os.path.splitext(saved_name)[0]
                stem_prefix = base_stem[:25]
                for f in upload_lr_jpgs:
                    if (upload_prefix and f.startswith(upload_prefix)) or \
                       (stem_prefix and stem_prefix in f):
                        if "preview" in f:
                            preview_url = f"/uploads/{f}"
                        if "page" in f or "preview" in f:
                            preview_pages.append(f"/uploads/{f}")
                if not preview_url and preview_pages:
                    preview_url = preview_pages[0]
            else:
                preview_url = f"/uploads/{saved_name}"

            item_entry = {
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
            }

            key = saved_name.strip().lower()
            orig_key = orig_name.strip().lower()
            id_key = file_id.strip().lower()

            match_key = None
            for k in (key, orig_key, id_key):
                if k in items_map:
                    match_key = k
                    break

            if match_key:
                existing = items_map[match_key]
                items_map[match_key] = {
                    **item_entry,
                    **existing,
                    "preview_url": existing.get("preview_url") or preview_url,
                    "file_url": existing.get("file_url") or item_entry["file_url"],
                    "data": {**item_entry["data"], **(existing.get("data") or {})}
                }
            else:
                items_map[key] = item_entry

        combined_items = list(items_map.values())[:limit]
        return {"success": True, "total": len(combined_items), "uploads": combined_items}
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

    # Also remove from user's dedicated cloud JSON DB (active_batch & uploaded_lrs)
    req_mobile = actor.get("user_mobile") or req.user_mobile or ""
    if req_mobile:
        try:
            user_cloud_service.delete_user_lr_record(
                mobile=req_mobile,
                lr_identifiers=[req.file_id_or_name],
                user_id=actor.get("user_id") or req.user_id
            )
        except Exception as c_err:
            print(f"[UserCloudService] Delete LR notice: {c_err}")

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
# ROUTE 7C: USER TEMPORARY CLOUD STORAGE (JSON DB FORMAT)
# =========================================================================
class SaveUserCloudBatchRequest(BaseModel):
    documents: list[dict] = []
    user_mobile: str | None = None
    user_id: str | None = None
    user_name: str | None = "Logistics User"


class ClearUserCloudStorageRequest(BaseModel):
    user_mobile: str | None = None
    user_id: str | None = None
    clear_history: bool = False


@app.get("/api/user-cloud-storage")
async def get_user_cloud_storage(
    user_mobile: str | None = Query(default=None),
    user_id: str | None = Query(default=None),
    authorization: str | None = Header(default=None)
):
    """
    Retrieves the authenticated user's temporary cloud storage database (JSON DB format),
    containing their active LR batch, previously uploaded LRs, and generated Excel files.
    Allows viewing history and downloading Excels from any device or after browser closure.
    """
    actor = _resolve_user_from_request(
        authorization=authorization,
        user_id=user_id,
        user_mobile=user_mobile
    )
    req_mobile = actor.get("user_mobile") or user_mobile or ""
    req_user_id = actor.get("user_id") or user_id or ""

    if not req_mobile and not req_user_id:
        return {
            "success": True,
            "data": {
                "user_mobile": "",
                "active_batch": [],
                "uploaded_lrs": [],
                "generated_excels": []
            }
        }

    cloud_data = user_cloud_service.get_user_cloud_data(mobile=req_mobile, user_id=req_user_id)
    return {"success": True, "data": cloud_data}


@app.post("/api/user-cloud-storage/save-batch")
async def save_user_cloud_batch(
    req: SaveUserCloudBatchRequest,
    authorization: str | None = Header(default=None)
):
    """
    Persists the user's active LR batch into their dedicated server-side JSON database.
    """
    actor = _resolve_user_from_request(
        authorization=authorization,
        user_id=req.user_id,
        user_mobile=req.user_mobile,
        user_name=req.user_name
    )
    req_mobile = actor.get("user_mobile") or req.user_mobile or ""
    req_user_id = actor.get("user_id") or req.user_id or ""
    req_user_name = actor.get("user_name") or req.user_name or "Logistics User"

    if not req_mobile:
        return {"success": False, "error": "User mobile is required"}

    res = user_cloud_service.save_user_active_batch(
        mobile=req_mobile,
        documents=req.documents,
        user_id=req_user_id,
        user_name=req_user_name
    )
    return {"success": bool(res), "count": len(req.documents)}


@app.post("/api/user-cloud-storage/clear-all")
async def clear_user_cloud_storage(
    req: ClearUserCloudStorageRequest,
    authorization: str | None = Header(default=None)
):
    """
    Modifies Clear All to delete only the current user's data from their JSON database.
    Does NOT delete or modify any physical files in upload_LR/ or snapshots_excel/.
    Keeps all uploaded LR images, PDFs, previews, and generated Excel files on the server.
    Ensures other users' data and files remain 100% unaffected.
    """
    actor = _resolve_user_from_request(
        authorization=authorization,
        user_id=req.user_id,
        user_mobile=req.user_mobile
    )
    req_mobile = actor.get("user_mobile") or req.user_mobile or ""
    req_user_id = actor.get("user_id") or req.user_id or ""

    if not req_mobile:
        return {"success": False, "error": "User mobile is required"}

    result = user_cloud_service.clear_user_cloud_database(
        mobile=req_mobile,
        user_id=req_user_id,
        clear_history=req.clear_history
    )
    return result


class DeleteUserCloudLRRequest(BaseModel):
    lr_identifier: str | None = None
    lr_identifiers: list[str] = []
    user_mobile: str | None = None
    user_id: str | None = None


@app.post("/api/user-cloud-storage/delete-lr")
async def delete_user_cloud_lr(
    req: DeleteUserCloudLRRequest,
    authorization: str | None = Header(default=None)
):
    """
    Permanently removes a specific LR from the authenticated user's cloud JSON DB
    (both active_batch and uploaded_lrs).
    Does NOT affect other records or other users.
    Does NOT delete physical files from disk.
    """
    actor = _resolve_user_from_request(
        authorization=authorization,
        user_id=req.user_id,
        user_mobile=req.user_mobile
    )
    req_mobile = actor.get("user_mobile") or req.user_mobile or ""
    req_user_id = actor.get("user_id") or req.user_id or ""

    if not req_mobile:
        return {"success": False, "error": "User mobile is required"}

    ids_to_delete = list(req.lr_identifiers) if req.lr_identifiers else []
    if req.lr_identifier and req.lr_identifier not in ids_to_delete:
        ids_to_delete.append(req.lr_identifier)

    if not ids_to_delete:
        return {"success": False, "error": "lr_identifier or lr_identifiers is required"}

    result = user_cloud_service.delete_user_lr_record(
        mobile=req_mobile,
        lr_identifiers=ids_to_delete,
        user_id=req_user_id
    )

    # Also soft-delete in file_lifecycle_service so previous_uploads & lifecycle stay synchronized
    try:
        user_display = actor.get("user_name") or "Logistics User"
        for ident in ids_to_delete:
            ident_clean = str(ident).strip()
            if ident_clean:
                file_lifecycle_service.record_file_deletion(
                    file_id_or_path=ident_clean,
                    user_name=user_display,
                    reason="LR deleted from batch by user"
                )
    except Exception as e:
        logger.warning(f"[delete_user_cloud_lr] Lifecycle sync notice: {e}")

    return result

@app.post("/api/user-cloud-storage/delete-upload-history")
async def delete_user_cloud_upload_history(
    req: DeleteUserCloudLRRequest,
    authorization: str | None = Header(default=None)
):
    """
    Removes a specific LR from the authenticated user's uploaded_lrs (history) ONLY.
    Does NOT remove from active_batch.
    Does NOT affect verified LR records in the LR List or Excel exports.
    Does NOT delete physical files from disk.
    """
    actor = _resolve_user_from_request(
        authorization=authorization,
        user_id=req.user_id,
        user_mobile=req.user_mobile
    )
    req_mobile = actor.get("user_mobile") or req.user_mobile or ""
    req_user_id = actor.get("user_id") or req.user_id or ""

    if not req_mobile:
        return {"success": False, "error": "User mobile is required"}

    ids_to_delete = list(req.lr_identifiers) if req.lr_identifiers else []
    if req.lr_identifier and req.lr_identifier not in ids_to_delete:
        ids_to_delete.append(req.lr_identifier)

    if not ids_to_delete:
        return {"success": False, "error": "lr_identifier or lr_identifiers is required"}

    result = user_cloud_service.delete_user_upload_history(
        mobile=req_mobile,
        lr_identifiers=ids_to_delete,
        user_id=req_user_id
    )
    return result


@app.post("/api/user-cloud-storage/undismiss-upload")
async def undismiss_user_cloud_upload(
    req: DeleteUserCloudLRRequest,
    authorization: str | None = Header(default=None)
):
    """
    Clears specified identifiers from dismissed_uploads in the user's cloud DB,
    ensuring newly uploaded or re-uploaded LRs immediately appear in Previously Uploaded LRs.
    """
    actor = _resolve_user_from_request(
        authorization=authorization,
        user_id=req.user_id,
        user_mobile=req.user_mobile
    )
    req_mobile = actor.get("user_mobile") or req.user_mobile or ""
    req_user_id = actor.get("user_id") or req.user_id or ""

    if not req_mobile:
        return {"success": False, "error": "User mobile is required"}

    ids_to_clear = list(req.lr_identifiers) if req.lr_identifiers else []
    if req.lr_identifier and req.lr_identifier not in ids_to_clear:
        ids_to_clear.append(req.lr_identifier)

    result = user_cloud_service.undismiss_user_upload(
        mobile=req_mobile,
        identifiers=ids_to_clear,
        user_id=req_user_id
    )
    return result




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
    host = get_server_host()
    port = get_server_port()
    public_url = get_public_server_url()
    reload_enabled = os.getenv("UVICORN_RELOAD", "").strip().lower() in ("1", "true", "yes")
    print("=" * 65)
    print("  OCR to Excel Studio - Server Starting")
    print(f"  Bind Host / Port        : {host}:{port}")
    print(f"  Web Component (Browser) : http://localhost:{port}")
    print(f"  Network / Phone Access  : http://{local_ip}:{port}")
    if public_url:
        print(f"  Public Server URL       : {public_url}")
    print(f"  Download Android APK    : http://{local_ip}:{port}/download-apk")
    print("=" * 65)
    uvicorn.run("main:app", host=host, port=port, reload=reload_enabled)
