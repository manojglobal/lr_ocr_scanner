import os
import io
import re
import json
import base64
import hashlib
import uuid
import shutil
from typing import Any
from datetime import datetime
from PIL import Image, ImageDraw, ImageFont

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
EXPORT_DIR = os.path.join(BASE_DIR, "export")
UPLOAD_LR_DIR = os.path.join(EXPORT_DIR, "upload_LR")
SNAPSHOTS_EXCEL_DIR = os.path.join(EXPORT_DIR, "snapshots_excel")
AUDIT_LOG_FILE = os.path.join(EXPORT_DIR, "export_audit_log.json")

os.makedirs(UPLOAD_LR_DIR, exist_ok=True)
os.makedirs(SNAPSHOTS_EXCEL_DIR, exist_ok=True)

# Legacy compatibility fallback directories
EXPORTS_DIR = os.path.join(BASE_DIR, "exports")
SNAPSHOTS_DIR = os.path.join(EXPORTS_DIR, "snapshots")

# -------------------------------------------------------------
# SNAPSHOTS STORAGE IN SNAPSHOTS_DIR
# Saves every uploaded LR document, audit Excel, and user-downloaded Excel
# with unique, descriptive filenames, timestamps, and IDs. Never overwrites historical files.
# Easily searchable via CMD and PowerShell.
# -------------------------------------------------------------
AUDIT_EXCEL_FILENAME = "audit_export.xlsx"
USER_EXCEL_FILENAME = "user_export.xlsx"
LR_DOC_PREFIX = "LR_"
USER_EXPORT_PREFIX = "USER_EXPORT_"
AUDIT_EXPORT_PREFIX = "AUDIT_EXPORT_"


def safe_atomic_write(target_path: str, data: bytes) -> None:
    """
    Safely writes binary data to target_path using atomic replacement to prevent
    file corruption, incomplete writes, or file-lock issues.
    """
    target_dir = os.path.dirname(os.path.abspath(target_path))
    os.makedirs(target_dir, exist_ok=True)
    temp_name = f".tmp_{uuid.uuid4().hex}_{os.path.basename(target_path)}"
    temp_path = os.path.join(target_dir, temp_name)
    try:
        with open(temp_path, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp_path, target_path)
    except Exception as e:
        if os.path.exists(temp_path):
            try:
                os.remove(temp_path)
            except Exception:
                pass
        raise e


def save_uploaded_lr_document(file_bytes: bytes, original_filename: str = "", lr_no: str = "") -> tuple[str, str]:
    """
    Saves every user-uploaded LR document into SNAPSHOTS_DIR with a unique,
    descriptive filename containing timestamp, unique ID, LR number, and original name.
    Never overwrites historical files. Easily searchable in CMD/PowerShell (Filter: LR_*).
    Returns (filename, absolute_path).
    """
    now_dt = datetime.now()
    timestamp = now_dt.strftime("%Y%m%d_%H%M%S")
    uid = uuid.uuid4().hex[:6]

    lr_clean = re.sub(r"[^a-zA-Z0-9]", "", str(lr_no or "")).strip()[:20]
    lr_tag = f"_LR_{lr_clean}" if lr_clean else ""

    orig_base = os.path.basename(original_filename or "uploaded_doc")
    orig_name, orig_ext = os.path.splitext(orig_base)
    if not orig_ext:
        orig_ext = ".pdf" if file_bytes.startswith(b"%PDF") else ".jpg"
    orig_ext = orig_ext.lower()
    if orig_ext == ".jpeg":
        orig_ext = ".jpg"

    clean_orig = re.sub(r"[^a-zA-Z0-9_\-]", "_", orig_name).strip("_")[:30]
    clean_orig_part = f"_{clean_orig}" if clean_orig else ""

    filename = f"LR_{timestamp}_{uid}{lr_tag}{clean_orig_part}{orig_ext}"
    target_path = os.path.join(UPLOAD_LR_DIR, filename)

    safe_atomic_write(target_path, file_bytes)
    return filename, target_path


def save_snapshot_excel(
    audit_bytes: bytes,
    export_id: str,
    lr_count: int = 1,
    lr_tag: str = "",
    prefix: str = "GR_Import_BNF"
) -> tuple[str, str]:
    """
    Saves the backend snapshot audit Excel file into backend/export/snapshots_excel/
    using unique, descriptive filenames with matching timestamp and ID.
    Never overwrites historical files. Easily searchable in CMD/PowerShell.
    Returns (audit_filename, audit_path).
    """
    exp_tag = export_id if export_id.startswith("EXP_") else f"EXP_{export_id}"
    audit_filename = f"AUDIT_EXPORT_{prefix}_{exp_tag}{lr_tag}_{lr_count}LRs.xlsx"
    audit_path = os.path.join(SNAPSHOTS_EXCEL_DIR, audit_filename)
    safe_atomic_write(audit_path, audit_bytes)
    return audit_filename, audit_path


def save_dual_exports(
    user_bytes: bytes,
    audit_bytes: bytes,
    export_id: str,
    lr_count: int = 1,
    lr_tag: str = "",
    prefix: str = "GR_Import_BNF"
) -> tuple[str, str, str, str]:
    """
    Saves backend audit snapshot copy into backend/export/snapshots_excel/.
    Does NOT save user_bytes to disk on backend (streamed dynamically to user).
    Returns (user_filename, "", audit_filename, audit_path).
    """
    exp_tag = export_id if export_id.startswith("EXP_") else f"EXP_{export_id}"
    user_filename = f"USER_EXPORT_{prefix}_{exp_tag}{lr_tag}_{lr_count}LRs.xlsx"
    audit_filename, audit_path = save_snapshot_excel(
        audit_bytes=audit_bytes,
        export_id=export_id,
        lr_count=lr_count,
        lr_tag=lr_tag,
        prefix=prefix
    )
    # User-downloaded Excel is NOT saved to disk in backend as requested
    return user_filename, "", audit_filename, audit_path


def resolve_file_path(filename: str) -> str | None:
    """
    Resolves the absolute path for an exported file or LR document by searching
    backend/export/upload_LR, backend/export/snapshots_excel, and legacy folders.
    Note: For user-facing downloads (USER_EXPORT_*), snapshots are never returned
    as direct file paths to ensure the clean user report is always served.
    """
    if not filename:
        return None
    safe_name = os.path.basename(filename)
    is_user_export = safe_name.startswith("USER_EXPORT_")

    # 1. Direct path in upload_LR
    p_lr = os.path.join(UPLOAD_LR_DIR, safe_name)
    if os.path.isfile(p_lr):
        return p_lr

    # 2. Direct path in snapshots_excel (only for audit/snapshot files, never user exports)
    if not is_user_export:
        p_snap = os.path.join(SNAPSHOTS_EXCEL_DIR, safe_name)
        if os.path.isfile(p_snap):
            return p_snap

    # 3. Direct path in legacy SNAPSHOTS_DIR
    if not is_user_export:
        p1 = os.path.join(SNAPSHOTS_DIR, safe_name)
        if os.path.isfile(p1):
            return p1

    # 4. Direct path in legacy EXPORTS_DIR
    p2 = os.path.join(EXPORTS_DIR, safe_name)
    if os.path.isfile(p2):
        return p2

    # 5. Direct path in legacy uploads
    p3 = os.path.join(BASE_DIR, "uploads", safe_name)
    if os.path.isfile(p3):
        return p3

    # 6. Search in snapshots_excel by export ID (only for audit/snapshot requests, never user exports)
    if not is_user_export and os.path.isdir(SNAPSHOTS_EXCEL_DIR):
        for fn in os.listdir(SNAPSHOTS_EXCEL_DIR):
            if fn == safe_name:
                return os.path.join(SNAPSHOTS_EXCEL_DIR, fn)
            clean_id = safe_name.replace(".xlsx", "").replace("AUDIT_EXPORT_", "")
            if clean_id and clean_id in fn:
                return os.path.join(SNAPSHOTS_EXCEL_DIR, fn)

    # 7. Search in upload_LR by exact name
    if os.path.isdir(UPLOAD_LR_DIR):
        for fn in os.listdir(UPLOAD_LR_DIR):
            if fn == safe_name:
                return os.path.join(UPLOAD_LR_DIR, fn)

    return None


def resolve_snapshot_path(filename: str) -> str | None:
    """
    Specifically resolves an internal audit snapshot workbook in backend/export/snapshots_excel/.
    """
    if not filename:
        return None
    safe_name = os.path.basename(filename)
    p_snap = os.path.join(SNAPSHOTS_EXCEL_DIR, safe_name)
    if os.path.isfile(p_snap):
        return p_snap

    audit_name = safe_name if safe_name.startswith("AUDIT_") else f"AUDIT_EXPORT_{safe_name.replace('USER_EXPORT_', '')}"
    p_audit = os.path.join(SNAPSHOTS_EXCEL_DIR, audit_name)
    if os.path.isfile(p_audit):
        return p_audit

    # Search by export ID
    exp_match = re.search(r'EXP_[0-9]+_[a-f0-9]+', safe_name)
    if exp_match and os.path.isdir(SNAPSHOTS_EXCEL_DIR):
        exp_id = exp_match.group(0)
        for fn in os.listdir(SNAPSHOTS_EXCEL_DIR):
            if exp_id in fn and fn.endswith(".xlsx"):
                return os.path.join(SNAPSHOTS_EXCEL_DIR, fn)

    return None


def get_font(size: int, bold: bool = False):
    """Safely loads standard TrueType font on Windows/Linux or falls back to default."""
    font_names = ["calibrib.ttf" if bold else "calibri.ttf", "arialbd.ttf" if bold else "arial.ttf", "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"]
    for fn in font_names:
        try:
            return ImageFont.truetype(fn, size)
        except Exception:
            pass
    try:
        return ImageFont.load_default()
    except Exception:
        return None


BNF_49_COLUMNS = [
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
BNF_50_COLUMNS = BNF_49_COLUMNS

def _clean_str(s: str) -> str:
    return "".join(c for c in str(s).lower() if c.isalnum())


def _clean_mobile(mobile: Any) -> str:
    digits = re.sub(r"\D", "", str(mobile or ""))
    if digits.startswith("91") and len(digits) == 12:
        digits = digits[2:]
    elif digits.startswith("0") and len(digits) == 11:
        digits = digits[1:]
    return digits


def _extract_docs_from_xlsx(filename: str) -> list:
    """Extracts consignment data rows from exported Excel workbook for UI display."""
    if not filename:
        return []
    fp = resolve_file_path(filename)
    if not fp or not os.path.isfile(fp):
        return []
    try:
        import openpyxl
        wb = openpyxl.load_workbook(fp, data_only=True)
        sheet_name = "Sheet1" if "Sheet1" in wb.sheetnames else wb.sheetnames[0]
        ws = wb[sheet_name]
        
        # Detect header row: if cell A1 has "User Name", headers are at row 5; otherwise row 1
        first_val = str(ws.cell(1, 1).value or "").strip()
        header_row = 5 if first_val.lower().startswith("user name") else 1
        data_start_row = header_row + 1

        headers = [str(ws.cell(header_row, c).value or "").strip() for c in range(1, ws.max_column + 1)]
        records = []
        for r in range(data_start_row, ws.max_row + 1):
            row_dict = {}
            has_data = False
            for c in range(1, len(headers) + 1):
                h = headers[c - 1]
                v = ws.cell(r, c).value
                if h:
                    row_dict[h] = str(v) if v is not None else ""
                if v is not None and str(v).strip():
                    has_data = True
            if has_data:
                records.append({
                    "filename": filename,
                    "data": row_dict
                })
        return records
    except Exception:
        return []


def _get_val_from_dict(d: dict, col: str) -> str:
    if not isinstance(d, dict):
        return "-"
    if col in d and d[col] not in (None, ""):
        return str(d[col])
    norm_col = _clean_str(col)
    for k, v in d.items():
        if _clean_str(k) == norm_col and v not in (None, ""):
            return str(v)
    if col == "Customer Name *":
        return str(d.get("cngr *") or d.get("cngr") or d.get("consignor") or "-")
    if col == "LR No *":
        return str(d.get("grno") or d.get("biltyno") or "-")
    if col == "BNF LR No":
        return str(d.get("BNF LR No") or d.get("bnf lr no") or d.get("bnflrno") or d.get("bnflr") or "-")
    if col == "Loading Start date *":
        return str(d.get("grdt") or d.get("date") or "-")
    if col == "Valid Upto":
        return str(d.get("validupto") or "-")
    if col in ("stockdt ", "stockdt"):
        return str(d.get("stockdt") or d.get("grdt") or "-")
    return "-"

def generate_lightweight_snapshot(
    export_id: str,
    filename: str,
    user_name: str,
    user_mobile: str,
    documents: list,
    file_bytes: bytes | None = None,
    audit_filename: str | None = None,
    user_export_filename: str | None = None
) -> dict:
    timestamp_str = datetime.now().strftime("%d-%b-%Y %I:%M %p")

    clean_docs = []
    for d in documents:
        if isinstance(d, dict):
            c_doc = {
                "filename": d.get("filename") or "document.jpg",
                "document_title": d.get("document_title") or "Document",
                "lr_document_filename": d.get("lr_document_filename") or d.get("saved_filename"),
                "data": d.get("data") or {}
            }
            clean_docs.append(c_doc)
        elif hasattr(d, "data"):
            clean_docs.append({
                "filename": getattr(d, "filename", "document.jpg"),
                "document_title": getattr(d, "document_title", "Document"),
                "lr_document_filename": getattr(d, "lr_document_filename", getattr(d, "saved_filename", None)),
                "data": getattr(d, "data", {})
            })

    u_fn = user_export_filename or filename
    a_fn = audit_filename or (f"audit_{filename}" if not filename.startswith("AUDIT_") else filename)

    return {
        "export_id": export_id,
        "filename": u_fn,
        "file_name": u_fn,
        "user_export_filename": u_fn,
        "audit_filename": a_fn,
        "audit_export_filename": a_fn,
        "download_url": f"/api/download-export/{u_fn}",
        "audit_download_url": f"/api/download-audit-export/{a_fn}",
        "snapshot_filename": a_fn,
        "snapshot_path": os.path.join(SNAPSHOTS_EXCEL_DIR, a_fn),
        "snapshot_url": f"/api/download-audit-export/{a_fn}",
        "snapshot_base64": None,
        "snapshot_size_kb": None,
        "exported_by": user_name,
        "user_name": user_name,
        "user": user_name,
        "mobile": user_mobile,
        "user_mobile": user_mobile,
        "timestamp": timestamp_str,
        "iso_timestamp": datetime.now().astimezone().isoformat(),
        "total_lrs": len(documents),
        "lr_count": len(documents),
        "documents": clean_docs
    }


def purge_exports_older_than(days: int = 30) -> list[str]:
    """
    Automatically deletes exported Excel files, visual snapshots, and history/data
    when older than 30 days.
    """
    purged: list[str] = []
    now = datetime.now()
    cutoff_seconds = days * 86400

    if os.path.exists(AUDIT_LOG_FILE):
        try:
            with open(AUDIT_LOG_FILE, "r", encoding="utf-8") as f:
                logs = json.load(f)
        except Exception:
            logs = []

        kept_logs = []
        for entry in logs:
            ts_str = entry.get("iso_timestamp") or entry.get("created_at") or entry.get("timestamp")
            entry_dt = None
            if ts_str:
                for fmt in (
                    "%Y-%m-%dT%H:%M:%S%z",
                    "%Y-%m-%dT%H:%M:%S",
                    "%d-%b-%Y %I:%M:%S %p",
                    "%d-%b-%Y %I:%M %p",
                    "%Y-%m-%d %H:%M:%S"
                ):
                    try:
                        clean_ts = ts_str.replace("Z", "+00:00")[:19]
                        entry_dt = datetime.strptime(clean_ts, fmt[:19])
                        break
                    except Exception:
                        pass

            is_expired = False
            if entry_dt:
                age_seconds = (now - entry_dt).total_seconds()
                if age_seconds >= cutoff_seconds:
                    is_expired = True

            if is_expired:
                # 1. Delete Snapshot Excel file from snapshots_excel
                a_fname = entry.get("audit_filename") or entry.get("audit_export_filename") or entry.get("filename")
                if a_fname:
                    for folder in (SNAPSHOTS_EXCEL_DIR, EXPORTS_DIR):
                        fpath = os.path.join(folder, a_fname)
                        if os.path.isfile(fpath):
                            try:
                                os.remove(fpath)
                                purged.append(a_fname)
                            except Exception:
                                pass

                # 2. Delete source LR document from upload_LR
                sname = entry.get("snapshot_filename") or entry.get("lr_document_filename")
                if sname:
                    for folder in (UPLOAD_LR_DIR, SNAPSHOTS_DIR):
                        spath = os.path.join(folder, sname)
                        if os.path.isfile(spath):
                            try:
                                os.remove(spath)
                                purged.append(sname)
                            except Exception:
                                pass
            else:
                kept_logs.append(entry)

        if len(kept_logs) != len(logs):
            try:
                with open(AUDIT_LOG_FILE, "w", encoding="utf-8") as f:
                    json.dump(kept_logs, f, indent=2)
            except Exception:
                pass

    # Sweep any loose .xlsx files in exports older than 30 days
    if os.path.isdir(EXPORTS_DIR):
        for fn in os.listdir(EXPORTS_DIR):
            if fn.lower().endswith(".xlsx"):
                fp = os.path.join(EXPORTS_DIR, fn)
                try:
                    mtime = os.path.getmtime(fp)
                    if (now.timestamp() - mtime) >= cutoff_seconds:
                        os.remove(fp)
                        purged.append(fn)
                except Exception:
                    pass

    return purged


def record_export_audit(audit_entry: dict):
    """Appends export audit record to audit log JSON with 30-day auto-purge enforcement."""
    purge_exports_older_than(days=30)
    logs = []
    if os.path.exists(AUDIT_LOG_FILE):
        try:
            with open(AUDIT_LOG_FILE, "r", encoding="utf-8") as f:
                logs = json.load(f)
        except Exception:
            logs = []
    
    # Ensure mandatory fields
    if "filename" in audit_entry and "download_url" not in audit_entry:
        audit_entry["download_url"] = f"/api/download-export/{audit_entry['filename']}"
    if "iso_timestamp" not in audit_entry:
        audit_entry["iso_timestamp"] = datetime.now().astimezone().isoformat()
    if "lr_count" not in audit_entry and "total_lrs" in audit_entry:
        audit_entry["lr_count"] = audit_entry["total_lrs"]
    if "user" not in audit_entry:
        audit_entry["user"] = audit_entry.get("exported_by") or audit_entry.get("user_name") or "Logistics User"

    logs.insert(0, audit_entry)
    # Keep last 500 exports
    if len(logs) > 500:
        logs = logs[:500]

    with open(AUDIT_LOG_FILE, "w", encoding="utf-8") as f:
        json.dump(logs, f, indent=2)


def delete_export_audit(target: str) -> bool:
    """
    Deletes an export record and its physical files from the backend.
    Removes matching entries from AUDIT_LOG_FILE and deletes corresponding .xlsx files.
    """
    clean_target = os.path.basename(str(target or "")).strip()
    if not clean_target:
        return False

    deleted_any = False
    # 1. Search and delete physical files from export directories
    search_dirs = [SNAPSHOTS_EXCEL_DIR, SNAPSHOTS_DIR, EXPORTS_DIR]
    for d in search_dirs:
        if not os.path.isdir(d):
            continue
        for fn in os.listdir(d):
            if not fn.lower().endswith(".xlsx"):
                continue
            if (clean_target in fn) or (fn.lower() == clean_target.lower()):
                fp = os.path.join(d, fn)
                try:
                    if os.path.isfile(fp):
                        os.remove(fp)
                        deleted_any = True
                except Exception as ex:
                    print(f"[Audit Snapshot] Failed to remove file {fp}: {ex}")

    # 2. Synchronize AUDIT_LOG_FILE
    if os.path.exists(AUDIT_LOG_FILE):
        try:
            with open(AUDIT_LOG_FILE, "r", encoding="utf-8") as f:
                logs = json.load(f)
            remaining_logs = []
            for item in logs:
                eid = str(item.get("export_id") or "").strip()
                fn = str(item.get("filename") or "").strip()
                afn = str(item.get("audit_export_filename") or item.get("audit_filename") or "").strip()
                if clean_target and (clean_target == eid or clean_target in fn or clean_target in afn or clean_target.lower() == fn.lower() or clean_target.lower() == afn.lower()):
                    deleted_any = True
                    continue
                remaining_logs.append(item)
            if len(remaining_logs) != len(logs):
                safe_atomic_write(AUDIT_LOG_FILE, json.dumps(remaining_logs, indent=2).encode("utf-8"))
        except Exception as ex:
            print(f"[Audit Snapshot] Failed to update audit log on delete: {ex}")

    return deleted_any


def get_user_audit_history(user_mobile: str | None = None, limit: int = 100) -> list:
    """
    Reads export audit history strictly isolated for the given user's mobile number,
    enforcing 30-day auto-purge and populating exact 49-column documents for UI display.
    Excludes any records whose Excel files were deleted from the backend.
    """
    purge_exports_older_than(days=30)
    if not os.path.exists(AUDIT_LOG_FILE):
        return []
    try:
        with open(AUDIT_LOG_FILE, "r", encoding="utf-8") as f:
            logs = json.load(f)

        target_mobile = _clean_mobile(user_mobile) if user_mobile else ""
        user_logs = []
        available_files = []
        if os.path.isdir(SNAPSHOTS_EXCEL_DIR):
            available_files.extend([f for f in os.listdir(SNAPSHOTS_EXCEL_DIR) if f.lower().endswith(".xlsx")])
        if os.path.isdir(SNAPSHOTS_DIR):
            available_files.extend([f for f in os.listdir(SNAPSHOTS_DIR) if f.lower().endswith(".xlsx")])
        if os.path.isdir(EXPORTS_DIR):
            available_files.extend([f for f in os.listdir(EXPORTS_DIR) if f.lower().endswith(".xlsx")])

        available_lower = set(f.lower() for f in available_files)
        surviving_logs = []
        has_pruned_entries = False

        for item in logs:
            export_id = str(item.get("export_id") or "").strip()
            fn = str(item.get("filename") or "").strip()
            audit_file = str(item.get("audit_export_filename") or item.get("audit_filename") or "").strip()

            # Physical File Existence Check:
            # If an Excel file is deleted from the backend, it must NOT appear in History!
            file_exists_on_disk = False
            if audit_file and audit_file.lower() in available_lower:
                file_exists_on_disk = True
            elif fn and fn.lower() in available_lower:
                file_exists_on_disk = True
            elif export_id and any(export_id.lower() in af for af in available_lower):
                file_exists_on_disk = True
            elif audit_file and resolve_snapshot_path(audit_file):
                file_exists_on_disk = True
            elif fn and resolve_file_path(fn):
                file_exists_on_disk = True

            if not file_exists_on_disk:
                # File was deleted from the backend disk -> prune from history
                has_pruned_entries = True
                continue

            surviving_logs.append(item)

            item_mob = _clean_mobile(item.get("mobile") or item.get("user_mobile"))
            # Strict User Isolation: if user_mobile is provided, strictly filter
            if target_mobile and item_mob != target_mobile:
                continue

            if not item.get("filename"):
                matched = None
                for af in available_files:
                    if export_id and export_id in af and "AUDIT" not in af:
                        matched = af
                        break
                    elif item.get("total_lrs") and f"_{item['total_lrs']}LRs" in af and "AUDIT" not in af:
                        matched = af
                        break
                item["filename"] = matched or f"USER_EXPORT_BNF_{export_id or 'file'}.xlsx"

            if not item.get("download_url") and item.get("filename"):
                item["download_url"] = f"/api/download-export/{item['filename']}"

            if not item.get("audit_download_url") and audit_file:
                item["audit_download_url"] = f"/api/download-audit-export/{audit_file}"

            if not item.get("user"):
                item["user"] = item.get("exported_by") or item.get("user_name") or "Logistics User"

            if not item.get("lr_count"):
                item["lr_count"] = item.get("total_lrs", 1)

            # Ensure documents list with 49-column data is populated for UI table
            if not item.get("documents"):
                extracted = _extract_docs_from_xlsx(item.get("filename"))
                item["documents"] = extracted if extracted else []

            user_logs.append(item)

        # Automatically synchronize AUDIT_LOG_FILE if orphaned/deleted entries were purged
        if has_pruned_entries and len(surviving_logs) != len(logs):
            try:
                safe_atomic_write(AUDIT_LOG_FILE, json.dumps(surviving_logs, indent=2).encode("utf-8"))
            except Exception as e_prune:
                print(f"[Audit Snapshot] Notice during history pruning: {e_prune}")

        return user_logs[:limit]
    except Exception:
        return []


def get_audit_history(limit: int = 100, user_mobile: str | None = None) -> list:
    """Reads export audit history, optionally isolated by user mobile."""
    return get_user_audit_history(user_mobile=user_mobile, limit=limit)


