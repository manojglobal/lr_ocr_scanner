import os
import io
import json
import uuid
import shutil
import hashlib
import threading
import subprocess
from datetime import datetime
from typing import Any, Optional

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
EXPORT_DIR = os.path.join(BASE_DIR, "export")
UPLOAD_LR_DIR = os.path.join(EXPORT_DIR, "upload_LR")
SNAPSHOTS_DIR = os.path.join(EXPORT_DIR, "snapshots_excel")
METADATA_DIR = os.path.join(EXPORT_DIR, "metadata")
REGISTRY_FILE = os.path.join(METADATA_DIR, "file_metadata_registry.json")

# Legacy compatibility fallback directories
EXPORTS_DIR = os.path.join(BASE_DIR, "exports")
LEGACY_METADATA_DIR = os.path.join(EXPORTS_DIR, "metadata")
LEGACY_REGISTRY_FILE = os.path.join(LEGACY_METADATA_DIR, "file_metadata_registry.json")

os.makedirs(UPLOAD_LR_DIR, exist_ok=True)
os.makedirs(SNAPSHOTS_DIR, exist_ok=True)
os.makedirs(METADATA_DIR, exist_ok=True)

_lock = threading.RLock()


def get_current_timestamp() -> str:
    """Returns local ISO-8601 formatted timestamp with timezone offset."""
    return datetime.now().astimezone().isoformat(timespec="seconds")


def compute_sha256(file_path_or_bytes: Any) -> str:
    """Computes SHA-256 hash string for file on disk or bytes."""
    h = hashlib.sha256()
    try:
        if isinstance(file_path_or_bytes, (bytes, bytearray)):
            h.update(file_path_or_bytes)
            return h.hexdigest()
        if isinstance(file_path_or_bytes, str) and os.path.isfile(file_path_or_bytes):
            with open(file_path_or_bytes, "rb") as f:
                while chunk := f.read(65536):
                    h.update(chunk)
            return h.hexdigest()
    except Exception:
        pass
    return ""


def _load_registry() -> dict[str, dict[str, Any]]:
    """Loads file registry from disk (must be called with _lock held)."""
    target = REGISTRY_FILE if os.path.exists(REGISTRY_FILE) else LEGACY_REGISTRY_FILE
    if not os.path.exists(target):
        return {}
    try:
        with open(target, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def _save_registry(registry: dict[str, dict[str, Any]]) -> None:
    """Persists file registry to disk (must be called with _lock held)."""
    temp_file = f"{REGISTRY_FILE}.tmp_{uuid.uuid4().hex}"
    try:
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(registry, f, indent=2, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp_file, REGISTRY_FILE)
    except Exception as e:
        print(f"[FileLifecycleService] Error saving registry: {e}")
        if os.path.exists(temp_file):
            try:
                os.remove(temp_file)
            except Exception:
                pass


def is_exiftool_available() -> bool:
    """Checks whether the exiftool executable is available in PATH."""
    return shutil.which("exiftool") is not None


def apply_exiftool_metadata(file_path: str, tags: dict[str, str]) -> bool:
    """
    Executes ExifTool to write metadata tags into images or Excel files if available.
    Returns True if successfully executed, False otherwise.
    """
    if not is_exiftool_available() or not os.path.isfile(file_path):
        return False
    try:
        args = ["exiftool", "-overwrite_original", "-charset", "UTF8"]
        for k, v in tags.items():
            if v:
                args.append(f"-{k}={v}")
        args.append(file_path)
        res = subprocess.run(args, capture_output=True, text=True, timeout=10)
        return res.returncode == 0
    except Exception as e:
        print(f"[ExifTool] Execution error for {file_path}: {e}")
        return False


def _get_item_snapshot_dir(file_id: str) -> str:
    """Creates and returns the snapshot vault directory for a specific file/record."""
    vault = os.path.join(SNAPSHOTS_DIR, file_id)
    os.makedirs(vault, exist_ok=True)
    return vault


def record_file_creation(
    file_path: str,
    file_type: str,
    user_name: str = "Logistics User",
    user_mobile: str = "",
    file_bytes: Optional[bytes] = None,
    custom_meta: Optional[dict[str, Any]] = None,
    file_id: Optional[str] = None,
    initial_data: Optional[dict[str, Any]] = None,
    user_id: Optional[str] = None
) -> dict[str, Any]:
    """
    Registers the creation of a file (Excel, screenshot, snapshot, or bilty upload).
    Initializes Version 1 with full snapshot data and timestamp.
    """
    with _lock:
        registry = _load_registry()
        
        rel_path = os.path.relpath(file_path, BASE_DIR) if os.path.isabs(file_path) else file_path
        filename = os.path.basename(file_path)
        fid = file_id or f"fl_{datetime.now().strftime('%Y%m%d%H%M%S')}_{hashlib.md5(filename.encode()).hexdigest()[:6]}"
        now_ts = get_current_timestamp()

        size_bytes = 0
        sha = ""
        if file_bytes is not None:
            size_bytes = len(file_bytes)
            sha = compute_sha256(file_bytes)
        elif os.path.isfile(file_path):
            size_bytes = os.path.getsize(file_path)
            sha = compute_sha256(file_path)

        # Create Version 1 snapshot reference
        data_to_store = initial_data or (custom_meta.get("data") if custom_meta else None)
        parent_dir = os.path.abspath(os.path.dirname(os.path.abspath(file_path)))
        if parent_dir == os.path.abspath(SNAPSHOTS_DIR):
            snapshot_filename = f"snapshots_excel/{filename}"
        elif parent_dir == os.path.abspath(UPLOAD_LR_DIR):
            snapshot_filename = f"upload_LR/{filename}"
        elif file_type == "excel":
            # Clean user download Excel is not stored on backend disk
            snapshot_filename = None
        else:
            vault_dir = _get_item_snapshot_dir(fid)
            snapshot_filename = None
            if file_bytes:
                ext = os.path.splitext(filename)[1] or ".bin"
                snap_file = f"v1_created{ext}"
                snap_path = os.path.join(vault_dir, snap_file)
                try:
                    with open(snap_path, "wb") as sf:
                        sf.write(file_bytes)
                    snapshot_filename = f"snapshots/{fid}/{snap_file}"
                except Exception:
                    pass
            elif os.path.isfile(file_path):
                ext = os.path.splitext(filename)[1] or ".bin"
                snap_file = f"v1_created{ext}"
                snap_path = os.path.join(vault_dir, snap_file)
                try:
                    shutil.copyfile(file_path, snap_path)
                    snapshot_filename = f"snapshots/{fid}/{snap_file}"
                except Exception:
                    pass

        v1_record = {
            "version": 1,
            "timestamp": now_ts,
            "action": "create",
            "user": user_name,
            "details": "File created / uploaded",
            "diff": None,
            "snapshot_file": snapshot_filename,
            "snapshot_data": data_to_store,
            "sha256": sha
        }

        entry = {
            "file_id": fid,
            "file_name": filename,
            "file_type": file_type,  # 'excel', 'snapshot_screenshot', 'bilty_image', 'export'
            "file_path": rel_path.replace("\\", "/"),
            "file_size_bytes": size_bytes,
            "file_size_kb": round(size_bytes / 1024, 1),
            "sha256": sha,
            "created_at": now_ts,
            "edited_at": None,
            "exported_at": None,
            "deleted_at": None,
            "is_deleted": False,
            "created_by": user_name,
            "user_id": user_id or (custom_meta.get("user_id") if custom_meta else None),
            "user_mobile": user_mobile or (custom_meta.get("user_mobile") if custom_meta else ""),
            "last_edited_by": None,
            "current_version": 1,
            "versions": [v1_record],
            "edit_history": [
                {
                    "timestamp": now_ts,
                    "user": user_name,
                    "action": "create",
                    "details": "File registered in system"
                }
            ],
            "custom_meta": custom_meta or {},
            "current_data": data_to_store
        }

        registry[fid] = entry
        _save_registry(registry)

    # Attempt ExifTool tag stamping outside lock to avoid blocking concurrent requests
    if os.path.isfile(file_path):
        apply_exiftool_metadata(file_path, {
            "CreateDate": now_ts.replace("-", ":")[:19],
            "Artist": user_name,
            "UserComment": json.dumps({"file_id": fid, "created_at": now_ts})
        })

    return entry


def record_file_edit(
    file_id_or_path: str,
    user_name: str = "Logistics User",
    action: str = "edit",
    details: Any = None,
    new_bytes: Optional[bytes] = None,
    new_data: Optional[dict[str, Any]] = None,
    diff: Optional[dict[str, Any]] = None
) -> Optional[dict[str, Any]]:
    """
    Updates 'Edited At' timestamp, creates a new version snapshot (v2, v3...),
    preserves previous versions, and records an audit event in edit_history.
    """
    with _lock:
        registry = _load_registry()
        entry = _find_entry(registry, file_id_or_path)
        if not entry:
            return None

        now_ts = get_current_timestamp()
        fid = entry["file_id"]
        entry["edited_at"] = now_ts
        entry["last_edited_by"] = user_name

        curr_ver = entry.get("current_version", 1)
        new_ver = curr_ver + 1
        entry["current_version"] = new_ver

        if new_bytes is not None:
            entry["file_size_bytes"] = len(new_bytes)
            entry["file_size_kb"] = round(len(new_bytes) / 1024, 1)
            entry["sha256"] = compute_sha256(new_bytes)

        # Save physical version snapshot in vault
        vault_dir = _get_item_snapshot_dir(fid)
        snapshot_filename = None
        ext = os.path.splitext(entry["file_name"])[1] or ".bin"
        snap_file = f"v{new_ver}_{action}_{datetime.now().strftime('%H%M%S')}{ext}"
        snap_path = os.path.join(vault_dir, snap_file)

        if new_bytes is not None:
            try:
                with open(snap_path, "wb") as sf:
                    sf.write(new_bytes)
                snapshot_filename = f"snapshots/{fid}/{snap_file}"
            except Exception:
                pass

        if new_data is not None:
            entry["current_data"] = new_data

        version_record = {
            "version": new_ver,
            "timestamp": now_ts,
            "action": action,
            "user": user_name,
            "details": details or f"Modified snapshot #{new_ver}",
            "diff": diff,
            "snapshot_file": snapshot_filename,
            "snapshot_data": new_data,
            "sha256": entry["sha256"]
        }

        if "versions" not in entry:
            entry["versions"] = []
        entry["versions"].append(version_record)

        edit_event = {
            "timestamp": now_ts,
            "user": user_name,
            "action": action,
            "version": new_ver,
            "details": details or f"Record updated snapshot #{new_ver}"
        }
        entry["edit_history"].append(edit_event)

        # ExifTool update on physical file if exists
        abs_path = os.path.join(BASE_DIR, entry.get("file_path", "").replace("/", os.sep))
        if os.path.isfile(abs_path):
            apply_exiftool_metadata(abs_path, {
                "ModifyDate": now_ts.replace("-", ":")[:19],
                "UserComment": json.dumps({"file_id": fid, "version": new_ver, "edited_at": now_ts})
            })

        registry[fid] = entry
        _save_registry(registry)
        return entry


def restore_file_version(
    file_id_or_path: str,
    target_version: int,
    user_name: str = "Logistics User"
) -> Optional[dict[str, Any]]:
    """
    Restores an earlier version snapshot (v1, v2...) as a new active version.
    Preserves all previous versions and logs the restoration event.
    """
    with _lock:
        registry = _load_registry()
        entry = _find_entry(registry, file_id_or_path)
        if not entry:
            return None

        versions = entry.get("versions", [])
        matched = next((v for v in versions if v.get("version") == target_version), None)
        if not matched:
            return None

        now_ts = get_current_timestamp()
        curr_ver = entry.get("current_version", 1)
        new_ver = curr_ver + 1
        entry["current_version"] = new_ver
        entry["edited_at"] = now_ts
        entry["last_edited_by"] = user_name

        restored_data = matched.get("snapshot_data")
        if restored_data:
            entry["current_data"] = restored_data

        restored_record = {
            "version": new_ver,
            "timestamp": now_ts,
            "action": "restore",
            "user": user_name,
            "details": "Restored earlier snapshot",
            "diff": {"restored_from": target_version},
            "snapshot_file": matched.get("snapshot_file"),
            "snapshot_data": restored_data,
            "sha256": matched.get("sha256", entry.get("sha256"))
        }
        entry["versions"].append(restored_record)

        entry["edit_history"].append({
            "timestamp": now_ts,
            "user": user_name,
            "action": "restore_version",
            "details": "Reverted data to earlier snapshot"
        })

        registry[entry["file_id"]] = entry
        _save_registry(registry)
        return entry


def restore_deleted_file(
    file_id_or_path: str,
    user_name: str = "Logistics User"
) -> Optional[dict[str, Any]]:
    """
    Restores a soft-deleted file back into the active list.
    """
    with _lock:
        registry = _load_registry()
        entry = _find_entry(registry, file_id_or_path)
        if not entry:
            return None

        now_ts = get_current_timestamp()
        entry["is_deleted"] = False
        entry["deleted_at"] = None
        entry["edit_history"].append({
            "timestamp": now_ts,
            "user": user_name,
            "action": "restore_from_trash",
            "details": "Item restored from recycle bin / deleted items"
        })

        registry[entry["file_id"]] = entry
        _save_registry(registry)
        return entry


def record_file_export(
    file_id_or_path: str,
    user_name: str = "Logistics User",
    destination: str = "download",
    extra_details: Optional[dict[str, Any]] = None
) -> Optional[dict[str, Any]]:
    """
    Updates 'Exported At' timestamp and logs export event.
    """
    with _lock:
        registry = _load_registry()
        entry = _find_entry(registry, file_id_or_path)
        if not entry:
            return None

        now_ts = get_current_timestamp()
        entry["exported_at"] = now_ts
        export_event = {
            "timestamp": now_ts,
            "user": user_name,
            "action": "export",
            "destination": destination,
            "details": extra_details or {}
        }
        entry["edit_history"].append(export_event)

        registry[entry["file_id"]] = entry
        _save_registry(registry)
        return entry


def record_file_deletion(
    file_id_or_path: str,
    user_name: str = "Logistics User",
    reason: str = "User deleted item from queue"
) -> Optional[dict[str, Any]]:
    """
    Marks file as deleted, records 'Deleted At' timestamp, and keeps audit record & versions.
    """
    with _lock:
        registry = _load_registry()
        entry = _find_entry(registry, file_id_or_path)
        if not entry:
            return None

        now_ts = get_current_timestamp()
        entry["deleted_at"] = now_ts
        entry["is_deleted"] = True
        
        del_event = {
            "timestamp": now_ts,
            "user": user_name,
            "action": "delete",
            "reason": reason
        }
        entry["edit_history"].append(del_event)

        registry[entry["file_id"]] = entry
        _save_registry(registry)
        return entry


def get_all_metadata(
    file_type: Optional[str] = None,
    include_deleted: bool = False,
    limit: int = 200
) -> list[dict[str, Any]]:
    """Retrieves list of file lifecycle entries sorted by creation time descending."""
    with _lock:
        registry = _load_registry()
        items = list(registry.values())

    if not include_deleted:
        items = [i for i in items if not i.get("is_deleted", False)]
    if file_type:
        items = [i for i in items if i.get("file_type") == file_type]

    items.sort(key=lambda x: x.get("created_at", ""), reverse=True)
    return items[:limit]


def get_deleted_files(limit: int = 100) -> list[dict[str, Any]]:
    """Retrieves list of deleted files with their Deleted At timestamps and reasons."""
    with _lock:
        registry = _load_registry()
        items = [i for i in registry.values() if i.get("is_deleted", False)]
    items.sort(key=lambda x: x.get("deleted_at", ""), reverse=True)
    return items[:limit]


def get_metadata_by_id(file_id_or_path: str) -> Optional[dict[str, Any]]:
    """Fetches single metadata entry by file_id or file_name/path."""
    with _lock:
        registry = _load_registry()
        return _find_entry(registry, file_id_or_path)


def _find_entry(registry: dict[str, dict[str, Any]], key: str) -> Optional[dict[str, Any]]:
    """Helper to locate entry by file_id, file_name, relative path, or custom_meta filenames."""
    if not key:
        return None
    if key in registry:
        return registry[key]
    normalized_key = str(key).replace("\\", "/")
    base_target = os.path.basename(normalized_key)
    for entry in registry.values():
        if entry.get("file_id") == key:
            return entry
        if entry.get("file_name") == key or entry.get("file_name") == base_target:
            return entry
        cm = entry.get("custom_meta") or {}
        if cm.get("upload_id") == key or cm.get("saved_filename") == key or cm.get("saved_filename") == base_target:
            return entry
        if cm.get("original_filename") == key or cm.get("original_filename") == base_target:
            return entry
        fp = entry.get("file_path", "")
        if fp == normalized_key or fp.endswith("/" + base_target):
            return entry
    return None


def purge_snapshots_older_than(days: int = 30) -> list[str]:
    """
    Automatically deletes visual snapshot / screenshot files older than 30 days.
    Marks metadata with 'deleted_at' timestamp and logs 'auto_retention_purge' in audit trail.
    Preserves audit registry tombstones so historical records are not lost.
    """
    purged: list[str] = []
    now = datetime.now().astimezone()
    with _lock:
        registry = _load_registry()
        for fid, entry in list(registry.items()):
            created_str = entry.get("created_at")
            if not created_str:
                continue
            try:
                dt = datetime.fromisoformat(created_str)
                age_days = (now - dt).total_seconds() / 86400.0
                if age_days >= days:
                    # Check physical snapshot files inside the vault
                    vault_dir = os.path.join(SNAPSHOTS_DIR, fid)
                    if os.path.isdir(vault_dir):
                        try:
                            for f in os.listdir(vault_dir):
                                fp = os.path.join(vault_dir, f)
                                if os.path.isfile(fp):
                                    os.remove(fp)
                                    purged.append(f"{fid}/{f}")
                            shutil.rmtree(vault_dir, ignore_errors=True)
                        except Exception as ex:
                            print(f"[Retention] Could not clean vault {vault_dir}: {ex}")

                    if entry.get("file_type") in ("snapshot_screenshot", "screenshot") and not entry.get("is_deleted", False):
                        rel_path = entry.get("file_path", "")
                        abs_path = os.path.join(BASE_DIR, rel_path.replace("/", os.sep))
                        if os.path.isfile(abs_path):
                            try:
                                os.remove(abs_path)
                            except Exception as ex:
                                print(f"[Retention] Could not remove physical snapshot {abs_path}: {ex}")
                        
                        now_ts = get_current_timestamp()
                        entry["deleted_at"] = now_ts
                        entry["is_deleted"] = True
                        entry["is_purged"] = True
                        entry["edit_history"].append({
                            "timestamp": now_ts,
                            "user": "System (Retention Policy)",
                            "action": "auto_retention_purge",
                            "reason": f"Automatically purged after {days}-day snapshot retention period ({round(age_days, 1)} days old)"
                        })
                        registry[fid] = entry
                        purged.append(entry.get("file_name", fid))
            except Exception as e:
                print(f"[Retention] Error checking snapshot age for {fid}: {e}")

        # Also sweep any loose snapshot files in the base snapshots directory
        if os.path.isdir(SNAPSHOTS_DIR):
            for fn in os.listdir(SNAPSHOTS_DIR):
                fp = os.path.join(SNAPSHOTS_DIR, fn)
                if os.path.isfile(fp):
                    try:
                        mtime = datetime.fromtimestamp(os.path.getmtime(fp)).astimezone()
                        if (now - mtime).total_seconds() / 86400.0 >= days:
                            os.remove(fp)
                            if fn not in purged:
                                purged.append(fn)
                    except Exception:
                        pass

        if purged:
            _save_registry(registry)
            print(f"[Retention Policy] Automatically purged {len(purged)} snapshot(s) older than {days} days.")
            
    return purged
