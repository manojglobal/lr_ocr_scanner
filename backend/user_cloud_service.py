import os
import re
import json
import threading
from datetime import datetime
from typing import Any

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
CLOUD_DB_DIR = os.path.join(DATA_DIR, "cloud_db")
SNAPSHOTS_EXCEL_DIR = os.path.join(BASE_DIR, "export", "snapshots_excel")
UPLOAD_LR_DIR = os.path.join(BASE_DIR, "export", "upload_LR")
EXPORTS_DIR = os.path.join(BASE_DIR, "export")
os.makedirs(CLOUD_DB_DIR, exist_ok=True)

_lock = threading.Lock()


def _clean_mobile(mobile: Any) -> str:
    """Extracts clean 10-digit Indian mobile number."""
    digits = re.sub(r"\D", "", str(mobile or ""))
    if digits.startswith("91") and len(digits) == 12:
        digits = digits[2:]
    elif digits.startswith("0") and len(digits) == 11:
        digits = digits[1:]
    return digits


def _get_user_db_path(mobile: str) -> str:
    clean_mob = _clean_mobile(mobile) or "guest"
    return os.path.join(CLOUD_DB_DIR, f"{clean_mob}.json")


def _load_user_db(mobile: str, user_id: str | None = None, user_name: str | None = None) -> dict:
    """Loads user JSON DB or initializes default structure."""
    clean_mob = _clean_mobile(mobile) or "guest"
    db_path = _get_user_db_path(clean_mob)

    if os.path.isfile(db_path):
        try:
            with open(db_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    # Guarantee all expected keys exist
                    if "active_batch" not in data or not isinstance(data["active_batch"], list):
                        data["active_batch"] = []
                    if "uploaded_lrs" not in data or not isinstance(data["uploaded_lrs"], list):
                        data["uploaded_lrs"] = []
                    if "generated_excels" not in data or not isinstance(data["generated_excels"], list):
                        data["generated_excels"] = []
                    if "dismissed_uploads" not in data or not isinstance(data["dismissed_uploads"], list):
                        data["dismissed_uploads"] = []
                    if user_id and not data.get("user_id"):
                        data["user_id"] = user_id
                    if user_name and not data.get("user_name"):
                        data["user_name"] = user_name
                    return data
        except Exception as e:
            print(f"[UserCloudService] Notice reading user DB {db_path}: {e}")

    now_iso = datetime.now().astimezone().isoformat(timespec="seconds")
    return {
        "user_mobile": clean_mob,
        "user_id": user_id or "",
        "user_name": user_name or "Logistics User",
        "updated_at": now_iso,
        "active_batch": [],
        "uploaded_lrs": [],
        "generated_excels": []
    }


def _save_user_db(mobile: str, data: dict) -> bool:
    """Atomic write to prevent file corruption."""
    clean_mob = _clean_mobile(mobile) or "guest"
    db_path = _get_user_db_path(clean_mob)
    temp_path = f"{db_path}.tmp"

    data["updated_at"] = datetime.now().astimezone().isoformat(timespec="seconds")
    data["user_mobile"] = clean_mob

    try:
        with open(temp_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp_path, db_path)
        return True
    except Exception as e:
        print(f"[UserCloudService] Error saving user DB {db_path}: {e}")
        if os.path.exists(temp_path):
            try:
                os.remove(temp_path)
            except Exception:
                pass
        return False


def get_user_cloud_data(mobile: str, user_id: str | None = None) -> dict:
    """Retrieves full temporary cloud database for the user."""
    with _lock:
        return _load_user_db(mobile, user_id=user_id)


def save_user_active_batch(mobile: str, documents: list[dict], user_id: str | None = None, user_name: str | None = None) -> bool:
    """Updates active LR batch in the user's cloud JSON DB and synchronizes uploaded_lrs."""
    if not isinstance(documents, list):
        documents = []

    with _lock:
        data = _load_user_db(mobile, user_id=user_id, user_name=user_name)
        data["active_batch"] = documents

        # Keep matching records in uploaded_lrs updated with verified data
        uploaded_list = data.get("uploaded_lrs", [])
        if not isinstance(uploaded_list, list):
            uploaded_list = []

        dismissed_set = {str(d).strip().lower() for d in data.get("dismissed_uploads", []) if d}

        for doc in documents:
            if not isinstance(doc, dict):
                continue
            d_id = str(doc.get("id") or "").strip()
            d_sv = str(doc.get("saved_filename") or "").strip().lower()
            d_fn = str(doc.get("filename") or "").strip().lower()
            d_fid = str(doc.get("file_id") or "").strip().lower()

            # Check if this document was explicitly dismissed by user
            is_dismissed = False
            for cand in (d_id.lower(), d_sv, d_fn, d_fid):
                if cand and cand in dismissed_set:
                    is_dismissed = True
                    break
            if is_dismissed:
                continue

            matched_idx = -1
            for idx, u in enumerate(uploaded_list):
                u_id = str(u.get("id") or "").strip()
                u_sv = str(u.get("saved_filename") or "").strip().lower()
                u_fn = str(u.get("filename") or "").strip().lower()

                id_match = d_id and u_id and d_id == u_id
                sv_match = d_sv and u_sv and d_sv == u_sv
                fn_match = d_fn and u_fn and d_fn != "lr document" and u_fn != "lr document" and d_fn == u_fn

                if id_match or sv_match or fn_match:
                    matched_idx = idx
                    break

            if matched_idx >= 0:
                uploaded_list[matched_idx] = {
                    **uploaded_list[matched_idx],
                    "data": {**(uploaded_list[matched_idx].get("data") or {}), **(doc.get("data") or {})},
                    "editedAt": doc.get("editedAt") or doc.get("edited_at") or uploaded_list[matched_idx].get("editedAt"),
                    "current_version": doc.get("current_version", uploaded_list[matched_idx].get("current_version", 1)),
                    "versions": doc.get("versions") or uploaded_list[matched_idx].get("versions") or [],
                    "filename": doc.get("filename") if (doc.get("filename") and doc.get("filename") != "LR Document") else uploaded_list[matched_idx].get("filename"),
                    "saved_filename": doc.get("saved_filename") or uploaded_list[matched_idx].get("saved_filename"),
                    "file_url": doc.get("file_url") or uploaded_list[matched_idx].get("file_url"),
                    "preview_url": doc.get("preview_url") or uploaded_list[matched_idx].get("preview_url"),
                    "preview_pages": doc.get("preview_pages") or uploaded_list[matched_idx].get("preview_pages", []),
                    "page_count": doc.get("page_count", uploaded_list[matched_idx].get("page_count", 1)),
                    "isPdf": bool(doc.get("isPdf", uploaded_list[matched_idx].get("isPdf", False)))
                }
            else:
                # Add newly verified LR into uploaded_lrs so it persists in upload history across refresh
                safe_fn = doc.get("filename") or doc.get("saved_filename") or f"upload_{d_id or int(datetime.now().timestamp())}"
                doc_saved = doc.get("saved_filename")
                uploaded_list.insert(0, {
                    "id": d_id or f"lr_{int(datetime.now().timestamp())}",
                    "filename": safe_fn,
                    "saved_filename": doc_saved,
                    "file_url": doc.get("file_url") or (f"/snapshots/{doc_saved}" if doc_saved else None),
                    "preview_url": doc.get("preview_url") or doc.get("preview_image"),
                    "preview_pages": doc.get("preview_pages") or [],
                    "page_count": doc.get("page_count", 1),
                    "isPdf": bool(doc.get("isPdf") or (safe_fn and safe_fn.lower().endswith(".pdf")) or (doc_saved and str(doc_saved).lower().endswith(".pdf"))),
                    "data": doc.get("data") or {},
                    "createdAt": doc.get("createdAt") or doc.get("created_at") or datetime.now().astimezone().isoformat()
                })

        data["uploaded_lrs"] = uploaded_list
        return _save_user_db(mobile, data)


def record_uploaded_lr(mobile: str, lr_entry: dict, user_id: str | None = None, user_name: str | None = None) -> bool:
    """
    Appends or updates newly uploaded LR document in both active_batch and uploaded_lrs
    in the user's cloud JSON DB.
    """
    if not lr_entry or not isinstance(lr_entry, dict):
        return False

    with _lock:
        data = _load_user_db(mobile, user_id=user_id, user_name=user_name)

        doc_id = lr_entry.get("id") or lr_entry.get("file_id")
        doc_fn = lr_entry.get("filename") or lr_entry.get("file_name") or lr_entry.get("fileName")
        doc_saved = lr_entry.get("saved_filename")

        # 0. Undismiss: clear matching identifiers from dismissed_uploads so newly uploaded LR appears in history
        dismissed = data.get("dismissed_uploads", [])
        if dismissed:
            lr_data = lr_entry.get("data") or {}
            to_clear_lower = {
                str(x).strip().lower() for x in (
                    doc_id, doc_fn, doc_saved,
                    lr_entry.get("lrNo"),
                    lr_data.get("grno"),
                    lr_data.get("LR No *"),
                    lr_data.get("BNF LR No")
                ) if x and str(x).strip()
            }
            data["dismissed_uploads"] = [d for d in dismissed if str(d).strip().lower() not in to_clear_lower]

        # 1. Update uploaded_lrs
        uploaded_list = data.get("uploaded_lrs", [])
        existing_up_idx = -1
        for idx, u in enumerate(uploaded_list):
            id_match = doc_id and u.get("id") and str(u.get("id")).strip() == str(doc_id).strip()
            saved_match = doc_saved and u.get("saved_filename") and str(u.get("saved_filename")).strip().lower() == str(doc_saved).strip().lower()
            fn_match = doc_fn and u.get("filename") and \
                       str(doc_fn).strip().lower() != "lr document" and \
                       str(u.get("filename")).strip().lower() != "lr document" and \
                       str(u.get("filename")).strip().lower() == str(doc_fn).strip().lower()
            if id_match or saved_match or fn_match:
                existing_up_idx = idx
                break

        safe_fn = doc_fn or (doc_saved if doc_saved else f"upload_{doc_id or int(datetime.now().timestamp())}")
        upload_record = {
            "id": doc_id or f"lr_{int(datetime.now().timestamp())}",
            "filename": safe_fn,
            "saved_filename": doc_saved,
            "file_url": lr_entry.get("file_url") or (f"/snapshots/{doc_saved}" if doc_saved else None),
            "preview_url": lr_entry.get("preview_url") or lr_entry.get("preview_image"),
            "preview_pages": lr_entry.get("preview_pages") or [],
            "page_count": lr_entry.get("page_count", 1),
            "isPdf": bool(lr_entry.get("isPdf") or (safe_fn and safe_fn.lower().endswith(".pdf")) or (doc_saved and doc_saved.lower().endswith(".pdf"))),
            "data": lr_entry.get("data") or {},
            "createdAt": lr_entry.get("createdAt") or lr_entry.get("created_at") or datetime.now().astimezone().isoformat()
        }

        if existing_up_idx >= 0:
            uploaded_list[existing_up_idx] = {**uploaded_list[existing_up_idx], **upload_record}
        else:
            uploaded_list.insert(0, upload_record)
        data["uploaded_lrs"] = uploaded_list

        # 2. Update active_batch
        active_list = data.get("active_batch", [])
        existing_act_idx = -1
        for idx, a in enumerate(active_list):
            id_match = doc_id and a.get("id") and str(a.get("id")).strip() == str(doc_id).strip()
            saved_match = doc_saved and a.get("saved_filename") and str(a.get("saved_filename")).strip().lower() == str(doc_saved).strip().lower()
            fn_match = doc_fn and a.get("filename") and \
                       str(doc_fn).strip().lower() != "lr document" and \
                       str(a.get("filename")).strip().lower() != "lr document" and \
                       str(a.get("filename")).strip().lower() == str(doc_fn).strip().lower()
            if id_match or saved_match or fn_match:
                existing_act_idx = idx
                break

        batch_item = {
            "id": doc_id or upload_record["id"],
            "filename": doc_fn or upload_record["filename"],
            "saved_filename": doc_saved,
            "file_url": upload_record["file_url"],
            "preview_url": upload_record["preview_url"],
            "preview_image": lr_entry.get("preview_image") or upload_record["preview_url"],
            "preview_pages": upload_record["preview_pages"],
            "page_count": upload_record["page_count"],
            "data": lr_entry.get("data") or {},
            "ocrEngine": lr_entry.get("ocrEngine") or "surya_ocr",
            "createdAt": upload_record["createdAt"],
            "editedAt": lr_entry.get("editedAt") or lr_entry.get("edited_at"),
            "exportedAt": lr_entry.get("exportedAt") or lr_entry.get("exported_at"),
            "current_version": lr_entry.get("current_version", 1),
            "versions": lr_entry.get("versions") or [],
            "editHistory": lr_entry.get("editHistory") or lr_entry.get("edit_history") or []
        }

        if existing_act_idx >= 0:
            active_list[existing_act_idx] = {**active_list[existing_act_idx], **batch_item}
        else:
            active_list.append(batch_item)
        data["active_batch"] = active_list

        return _save_user_db(mobile, data)


def record_generated_excel(mobile: str, excel_entry: dict, user_id: str | None = None, user_name: str | None = None) -> bool:
    """Registers generated Excel file into the user's cloud JSON DB."""
    if not excel_entry or not isinstance(excel_entry, dict):
        return False

    with _lock:
        data = _load_user_db(mobile, user_id=user_id, user_name=user_name)
        excels = data.get("generated_excels", [])

        export_id = excel_entry.get("export_id") or f"exp_{int(datetime.now().timestamp())}"
        fn = excel_entry.get("filename") or excel_entry.get("user_export_filename") or "BNF_Bilty_Export.xlsx"

        existing_idx = -1
        for idx, ex in enumerate(excels):
            if ex.get("export_id") == export_id or ex.get("filename") == fn:
                existing_idx = idx
                break

        now_iso = datetime.now().astimezone().isoformat(timespec="seconds")
        clean_entry = {
            "export_id": export_id,
            "filename": fn,
            "download_url": excel_entry.get("download_url") or f"/api/download-export/{fn}",
            "audit_filename": excel_entry.get("audit_filename") or excel_entry.get("audit_copy"),
            "total_lrs": excel_entry.get("total_lrs") or excel_entry.get("total_records") or 1,
            "file_size_kb": excel_entry.get("file_size_kb") or 45,
            "generated_on": excel_entry.get("generated_on") or excel_entry.get("generated_at") or now_iso,
            "exported_by": excel_entry.get("generated_by") or excel_entry.get("user_name") or user_name or "Logistics User",
            "documents": excel_entry.get("documents") or []
        }

        if existing_idx >= 0:
            excels[existing_idx] = {**excels[existing_idx], **clean_entry}
        else:
            excels.insert(0, clean_entry)

        data["generated_excels"] = excels[:30]  # retain up to 30 recent exports
        return _save_user_db(mobile, data)


def is_excel_file_present(excel_entry: dict) -> bool:
    """Checks whether an Excel file physically exists on the backend server disk."""
    if not excel_entry or not isinstance(excel_entry, dict):
        return False

    fn = str(excel_entry.get("filename") or excel_entry.get("user_export_filename") or "").strip()
    audit_fn = str(excel_entry.get("audit_filename") or "").strip()
    export_id = str(excel_entry.get("export_id") or "").strip()

    candidates = []
    if audit_fn:
        candidates.append(os.path.join(SNAPSHOTS_EXCEL_DIR, audit_fn))
    if fn:
        candidates.append(os.path.join(UPLOAD_LR_DIR, fn))
        candidates.append(os.path.join(SNAPSHOTS_EXCEL_DIR, fn))
        candidates.append(os.path.join(EXPORTS_DIR, fn))

    for p in candidates:
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            return True

    # Check if any snapshot file contains export_id
    if export_id and os.path.isdir(SNAPSHOTS_EXCEL_DIR):
        try:
            for f in os.listdir(SNAPSHOTS_EXCEL_DIR):
                if export_id.lower() in f.lower() and f.lower().endswith(".xlsx"):
                    return True
        except Exception:
            pass

    return False


def prune_user_deleted_excels(mobile: str) -> list[dict]:
    """
    Automatically prunes Excel entries from the user's cloud JSON DB
    if their physical files were deleted from the backend server.
    """
    clean_mob = _clean_mobile(mobile) or "guest"
    with _lock:
        data = _load_user_db(clean_mob)
        excels = data.get("generated_excels", [])
        valid_excels = [ex for ex in excels if is_excel_file_present(ex)]
        if len(valid_excels) != len(excels):
            pruned_count = len(excels) - len(valid_excels)
            data["generated_excels"] = valid_excels
            _save_user_db(clean_mob, data)
            print(f"[UserCloudService] Pruned {pruned_count} deleted Excel files from user +91 {clean_mob} history.")
        return valid_excels


def clear_user_cloud_database(mobile: str, user_id: str | None = None, clear_history: bool = False) -> dict:
    """
    Clears only the active working batch and uploaded LRs for the current user:
    Resets active_batch = [], uploaded_lrs = [].
    PRESERVES generated_excels so the user's historical exported LR data remains available.
    (If clear_history=True is explicitly requested, also clears generated_excels).
    CRITICAL: Does NOT delete or modify any physical files in upload_LR/ or snapshots_excel/.
    All physical files remain permanently on the server disk.
    Ensures other users' data and files remain 100% unaffected.
    """
    clean_mob = _clean_mobile(mobile) or "guest"
    with _lock:
        data = _load_user_db(clean_mob, user_id=user_id)
        cleared_active_count = len(data.get("active_batch", []))
        cleared_uploads_count = len(data.get("uploaded_lrs", []))
        cleared_excels_count = 0

        # Reset active staging queues
        data["active_batch"] = []
        data["uploaded_lrs"] = []

        if clear_history:
            cleared_excels_count = len(data.get("generated_excels", []))
            data["generated_excels"] = []

        _save_user_db(clean_mob, data)

    print(f"[UserCloudService] Cleared active queue for user +91 {clean_mob}: "
          f"{cleared_active_count} active LRs, {cleared_uploads_count} uploads. "
          f"History preserved ({len(data.get('generated_excels', []))} exports). "
          f"Physical files in upload_LR/ and snapshots_excel/ preserved.")

    return {
        "success": True,
        "user_mobile": clean_mob,
        "cleared_active_batch_count": cleared_active_count,
        "cleared_uploads_count": cleared_uploads_count,
        "cleared_excels_count": cleared_excels_count,
        "history_preserved": not clear_history,
        "remaining_excels_count": len(data.get("generated_excels", [])),
        "physical_files_preserved": True
    }


def delete_user_lr_record(
    mobile: str,
    lr_identifiers: list[str] | str,
    user_id: str | None = None
) -> dict:
    """
    Permanently removes a specific LR record from the user's active_batch and uploaded_lrs
    in their dedicated cloud JSON DB.
    Matches against LR id, saved_filename, and original filename.
    Guarantees:
      - Does NOT affect other LR records belonging to this user.
      - Does NOT affect other users' databases or files (100% strict user isolation).
      - Does NOT delete physical files from disk.
    """
    clean_mob = _clean_mobile(mobile) or "guest"
    if not lr_identifiers:
        return {"success": False, "error": "lr_identifiers required"}

    # Normalize identifiers into a clean set of lookup strings
    if isinstance(lr_identifiers, str):
        target_keys = {lr_identifiers.strip()}
    elif isinstance(lr_identifiers, (list, tuple, set)):
        target_keys = {str(k).strip() for k in lr_identifiers if k and str(k).strip()}
    else:
        target_keys = {str(lr_identifiers).strip()}

    GENERIC_KEYS = {"lr document", "document", "item", "null", "none", "undefined", "-", "--", "n/a", "na", "", "default"}
    target_keys = {k for k in target_keys if k and k.lower().strip() not in GENERIC_KEYS and len(k.strip()) >= 3}
    if not target_keys:
        return {"success": False, "error": "No valid identifier provided"}

    target_keys_lower = {k.lower().strip() for k in target_keys}
    import urllib.parse
    for k in list(target_keys):
        try:
            unquoted = urllib.parse.unquote(k).strip().lower()
            if unquoted:
                target_keys_lower.add(unquoted)
        except Exception:
            pass

    def _matches(item: dict) -> bool:
        if not isinstance(item, dict):
            return False
        for field in ("id", "saved_filename", "filename", "file_name", "file_id", "upload_id"):
            val = str(item.get(field) or "").strip().lower()
            if val and val in target_keys_lower:
                return True
        d = item.get("data") or {}
        for df in ("grno", "LR No *", "BNF LR No"):
            val = str(d.get(df) or "").strip().lower()
            if val and val in target_keys_lower:
                return True
        return False

    with _lock:
        data = _load_user_db(clean_mob, user_id=user_id)

        # 1. Filter active_batch
        active_list = data.get("active_batch", [])
        orig_active_len = len(active_list)
        new_active = [item for item in active_list if not _matches(item)]
        removed_from_active = orig_active_len - len(new_active)
        data["active_batch"] = new_active

        # 2. Filter uploaded_lrs
        uploads_list = data.get("uploaded_lrs", [])
        orig_uploads_len = len(uploads_list)
        new_uploads = [item for item in uploads_list if not _matches(item)]
        removed_from_uploads = orig_uploads_len - len(new_uploads)
        data["uploaded_lrs"] = new_uploads

        # 3. Add to dismissed_uploads to guarantee persistence across server queries
        if "dismissed_uploads" not in data or not isinstance(data["dismissed_uploads"], list):
            data["dismissed_uploads"] = []
        for k in target_keys:
            if k and k not in data["dismissed_uploads"]:
                data["dismissed_uploads"].append(k)

        _save_user_db(clean_mob, data)

    print(f"[UserCloudService] Deleted LR {list(target_keys)} for user +91 {clean_mob}: "
          f"removed from active_batch: {removed_from_active}, removed from uploaded_lrs: {removed_from_uploads}")

    return {
        "success": True,
        "user_mobile": clean_mob,
        "deleted_identifiers": list(target_keys),
        "removed_from_active": removed_from_active,
        "removed_from_uploads": removed_from_uploads,
        "remaining_active": len(data["active_batch"]),
        "remaining_uploads": len(data["uploaded_lrs"])
    }



def delete_user_upload_history(
    mobile: str,
    lr_identifiers: list[str] | str,
    user_id: str | None = None
) -> dict:
    """
    Removes a specific LR from the user's uploaded_lrs (history) ONLY in cloud JSON DB.
    Does NOT touch data["active_batch"].
    Does NOT delete physical files from disk.
    Does NOT alter verification status or Excel export availability.
    """
    clean_mob = _clean_mobile(mobile) or "guest"
    if not lr_identifiers:
        return {"success": False, "error": "lr_identifiers required"}

    # Normalize identifiers into a clean set of lookup strings
    if isinstance(lr_identifiers, str):
        target_keys = {lr_identifiers.strip()}
    elif isinstance(lr_identifiers, (list, tuple, set)):
        target_keys = {str(k).strip() for k in lr_identifiers if k and str(k).strip()}
    else:
        target_keys = {str(lr_identifiers).strip()}

    GENERIC_KEYS = {"lr document", "document", "item", "null", "none", "undefined", "-", "--", "n/a", "na", "", "default"}
    target_keys = {k for k in target_keys if k and k.lower().strip() not in GENERIC_KEYS and len(k.strip()) >= 3}
    if not target_keys:
        return {"success": False, "error": "No valid identifier provided"}

    target_keys_lower = {k.lower().strip() for k in target_keys}
    import urllib.parse
    for k in list(target_keys):
        try:
            unquoted = urllib.parse.unquote(k).strip().lower()
            if unquoted:
                target_keys_lower.add(unquoted)
        except Exception:
            pass

    def _matches(item: dict) -> bool:
        if not isinstance(item, dict):
            return False
        for field in ("id", "saved_filename", "filename", "file_name", "file_id", "upload_id"):
            val = str(item.get(field) or "").strip().lower()
            if val and val in target_keys_lower:
                return True
        d = item.get("data") or {}
        for df in ("grno", "LR No *", "BNF LR No"):
            val = str(d.get(df) or "").strip().lower()
            if val and val in target_keys_lower:
                return True
        return False

    with _lock:
        data = _load_user_db(clean_mob, user_id=user_id)

        # Filter uploaded_lrs ONLY - active_batch remains completely untouched!
        uploads_list = data.get("uploaded_lrs", [])
        orig_uploads_len = len(uploads_list)
        new_uploads = [item for item in uploads_list if not _matches(item)]
        removed_from_uploads = orig_uploads_len - len(new_uploads)
        data["uploaded_lrs"] = new_uploads

        # Save dismissed identifiers in cloud DB
        if "dismissed_uploads" not in data or not isinstance(data["dismissed_uploads"], list):
            data["dismissed_uploads"] = []
        for k in target_keys:
            if k and k not in data["dismissed_uploads"]:
                data["dismissed_uploads"].append(k)

        _save_user_db(clean_mob, data)

    print(f"[UserCloudService] Dismissed upload history {list(target_keys)} for user +91 {clean_mob}: "
          f"removed from uploaded_lrs: {removed_from_uploads}, active_batch intact: {len(data.get('active_batch', []))}")

    return {
        "success": True,
        "user_mobile": clean_mob,
        "dismissed_identifiers": list(target_keys),
        "removed_from_uploads": removed_from_uploads,
        "active_batch_count": len(data.get("active_batch", [])),
        "remaining_uploads": len(data["uploaded_lrs"])
    }



def undismiss_user_upload(
    mobile: str,
    identifiers: list[str] | str,
    user_id: str | None = None
) -> dict:
    """
    Removes specified identifiers from dismissed_uploads in the user's cloud DB,
    allowing an uploaded or re-uploaded LR to display in Previously Uploaded LRs.
    """
    clean_mob = _clean_mobile(mobile) or "guest"
    if not identifiers:
        return {"success": False, "error": "identifiers required"}

    if isinstance(identifiers, str):
        target_keys = {identifiers.strip()}
    elif isinstance(identifiers, (list, tuple, set)):
        target_keys = {str(k).strip() for k in identifiers if k and str(k).strip()}
    else:
        target_keys = {str(identifiers).strip()}

    target_keys = {k for k in target_keys if k}
    if not target_keys:
        return {"success": False, "error": "No valid identifier provided"}

    target_keys_lower = {k.lower().strip() for k in target_keys}
    import urllib.parse
    for k in list(target_keys):
        try:
            unquoted = urllib.parse.unquote(k).strip().lower()
            if unquoted:
                target_keys_lower.add(unquoted)
        except Exception:
            pass

    with _lock:
        data = _load_user_db(clean_mob, user_id=user_id)
        dismissed = data.get("dismissed_uploads", [])
        orig_len = len(dismissed)
        data["dismissed_uploads"] = [d for d in dismissed if str(d).strip().lower() not in target_keys_lower]
        cleared_count = orig_len - len(data["dismissed_uploads"])
        if cleared_count > 0:
            _save_user_db(clean_mob, data)

    print(f"[UserCloudService] Undismissed {list(target_keys)} for user +91 {clean_mob}: removed {cleared_count} tombstone(s)")
    return {
        "success": True,
        "user_mobile": clean_mob,
        "cleared_count": cleared_count,
        "remaining_dismissed": len(data.get("dismissed_uploads", []))
    }
