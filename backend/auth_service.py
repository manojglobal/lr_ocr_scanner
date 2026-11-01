import os
import re
import json
import time
import uuid
import secrets
import shutil
import threading
from datetime import datetime

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
USERS_FILE = os.path.join(DATA_DIR, "users.json")
SESSIONS_FILE = os.path.join(DATA_DIR, "sessions.json")
CLOUD_DB_DIR = os.path.join(DATA_DIR, "cloud_db")
BACKUP_DIR = os.path.join(DATA_DIR, "backups")

os.makedirs(DATA_DIR, exist_ok=True)
os.makedirs(CLOUD_DB_DIR, exist_ok=True)
os.makedirs(BACKUP_DIR, exist_ok=True)

SESSION_TTL_SECONDS = 86400  # Exactly 24 hours

# In-memory stores
# Active OTPs: { "9876543210": { "otp": "482915", "expires_at": float, "attempts_left": int, "last_sent_at": float, "name": str } }
_otp_store = {}
# Active Sessions: { "token_abc": { "token": "...", "user_id": "...", "mobile": "...", "name": "...", "created_at_epoch": float, "expires_at_epoch": float } }
_sessions = {}
_auth_lock = threading.RLock()


def _clean_mobile(mobile: str) -> str:
    """Extracts clean 10-digit Indian mobile number."""
    digits = re.sub(r"\D", "", str(mobile or ""))
    if digits.startswith("91") and len(digits) == 12:
        digits = digits[2:]
    elif digits.startswith("0") and len(digits) == 11:
        digits = digits[1:]
    return digits


def _validate_mobile(mobile: str) -> tuple[bool, str]:
    """Validates that a mobile number is a valid 10-digit Indian mobile number."""
    clean = _clean_mobile(mobile)
    if len(clean) != 10:
        return False, "Mobile number must be exactly 10 digits."
    if clean[0] not in "56789":
        return False, "Indian mobile number must start with 5, 6, 7, 8, or 9."
    return True, clean


def _normalize_name(name: str | None) -> str:
    """Normalizes a name string by trimming whitespace and collapsing internal spaces."""
    if not name:
        return ""
    return re.sub(r"\s+", " ", str(name).strip())


def _load_users() -> dict:
    with _auth_lock:
        if os.path.exists(USERS_FILE):
            try:
                with open(USERS_FILE, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                return {}
        return {}


def _save_users(users: dict):
    with _auth_lock:
        temp_file = f"{USERS_FILE}.tmp_{uuid.uuid4().hex}"
        try:
            with open(temp_file, "w", encoding="utf-8") as f:
                json.dump(users, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.replace(temp_file, USERS_FILE)
        except Exception as e:
            print(f"[AuthService] Error saving users.json: {e}")
            if os.path.exists(temp_file):
                try:
                    os.remove(temp_file)
                except Exception:
                    pass


def _load_sessions() -> dict:
    with _auth_lock:
        if os.path.exists(SESSIONS_FILE):
            try:
                with open(SESSIONS_FILE, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, dict):
                        return data
            except Exception as e:
                print(f"[AuthService] Warning loading sessions.json: {e}")
        return {}


def _save_sessions(sessions: dict):
    with _auth_lock:
        temp_file = f"{SESSIONS_FILE}.tmp_{uuid.uuid4().hex}"
        try:
            with open(temp_file, "w", encoding="utf-8") as f:
                json.dump(sessions, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.replace(temp_file, SESSIONS_FILE)
        except Exception as e:
            print(f"[AuthService] Error saving sessions.json: {e}")
            if os.path.exists(temp_file):
                try:
                    os.remove(temp_file)
                except Exception:
                    pass


def _prune_expired_sessions(sessions: dict) -> bool:
    """Removes sessions that are older than 24 hours."""
    now = time.time()
    expired_keys = [
        k for k, s in list(sessions.items())
        if float(s.get("expires_at_epoch", 0)) < now
    ]
    for k in expired_keys:
        del sessions[k]
    return len(expired_keys) > 0


# Initialize in-memory sessions from disk and prune expired records
with _auth_lock:
    _sessions.update(_load_sessions())
    if _prune_expired_sessions(_sessions):
        _save_sessions(_sessions)


# =========================================================================
# DEVELOPER CLI USER MANAGEMENT OPERATIONS (Create, Edit, Delete, Count)
# =========================================================================

def get_total_users_count() -> int:
    """Returns the total number of registered users."""
    return len(_load_users())


def get_all_users() -> dict:
    """Returns a dictionary of all registered users."""
    return dict(_load_users())


def get_user_by_mobile(mobile_raw: str) -> dict | None:
    """Fetches a registered user record by mobile number."""
    clean = _clean_mobile(mobile_raw)
    users = _load_users()
    return dict(users[clean]) if clean in users else None


def create_user_record(name: str, mobile_raw: str) -> dict:
    """
    Developer Operation: Create a new user account with Name and Mobile Number.
    Enforces uniqueness: One mobile number = One account.
    """
    clean_name = _normalize_name(name)
    if not clean_name:
        return {"success": False, "error": "User name cannot be empty."}

    valid, clean_mobile = _validate_mobile(mobile_raw)
    if not valid:
        return {"success": False, "error": clean_mobile}

    with _auth_lock:
        users = _load_users()
        if clean_mobile in users:
            existing = users[clean_mobile]
            return {
                "success": False,
                "error": f"User with mobile +91 {clean_mobile} already exists ({existing.get('name', 'Unknown')})."
            }

        user_id = str(uuid.uuid4())[:8]
        user_record = {
            "id": user_id,
            "mobile": clean_mobile,
            "name": clean_name,
            "role": "operator",
            "last_login": None,
            "created_at": datetime.now().isoformat()
        }
        users[clean_mobile] = user_record
        _save_users(users)

    print(f"[USER CREATED] Name: {clean_name} | Mobile: +91 {clean_mobile} | ID: {user_id}")
    return {"success": True, "user": user_record}


def edit_user_record(
    mobile_raw: str,
    new_name: str | None = None,
    new_mobile_raw: str | None = None
) -> dict:
    """
    Developer Operation: Update an existing user's Name or Mobile Number.
    Safely migrates user cloud database if mobile number changes.
    """
    clean_mobile = _clean_mobile(mobile_raw)
    with _auth_lock:
        users = _load_users()
        if clean_mobile not in users:
            return {
                "success": False,
                "error": f"User with mobile +91 {clean_mobile} not found."
            }

        user_record = users[clean_mobile]
        old_mobile = clean_mobile
        target_mobile = clean_mobile

        # 1. Update Name if specified
        if new_name is not None:
            clean_new_name = _normalize_name(new_name)
            if not clean_new_name:
                return {"success": False, "error": "Name cannot be empty."}
            user_record["name"] = clean_new_name

        # 2. Update Mobile if specified and different
        if new_mobile_raw is not None:
            valid, clean_new_mob = _validate_mobile(new_mobile_raw)
            if not valid:
                return {"success": False, "error": clean_new_mob}

            if clean_new_mob != clean_mobile:
                if clean_new_mob in users:
                    return {
                        "success": False,
                        "error": f"Mobile number +91 {clean_new_mob} is already assigned to another user."
                    }

                # Migrate user key
                target_mobile = clean_new_mob
                user_record["mobile"] = clean_new_mob
                del users[clean_mobile]
                users[clean_new_mob] = user_record

                # Migrate associated cloud database file if it exists
                old_db_path = os.path.join(CLOUD_DB_DIR, f"{old_mobile}.json")
                new_db_path = os.path.join(CLOUD_DB_DIR, f"{clean_new_mob}.json")
                if os.path.isfile(old_db_path):
                    try:
                        shutil.move(old_db_path, new_db_path)
                        print(f"[AuthService] Migrated cloud DB from {old_mobile}.json to {clean_new_mob}.json")
                    except Exception as e:
                        print(f"[AuthService] Warning migrating cloud DB: {e}")

                # Update active sessions for old mobile
                sessions_updated = False
                for t, sess in list(_sessions.items()):
                    if sess.get("mobile") == old_mobile:
                        sess["mobile"] = clean_new_mob
                        sessions_updated = True
                if sessions_updated:
                    _save_sessions(_sessions)

        _save_users(users)

    print(f"[USER UPDATED] Mobile: +91 {target_mobile} | Name: {user_record.get('name')}")
    return {"success": True, "user": user_record}


def delete_user_record(mobile_raw: str, archive_data: bool = True) -> dict:
    """
    Developer Operation: Permanently remove a selected user account.
    Terminates active sessions and safely archives cloud data to prevent orphaned files.
    """
    clean_mobile = _clean_mobile(mobile_raw)
    with _auth_lock:
        users = _load_users()
        if clean_mobile not in users:
            return {
                "success": False,
                "error": f"User with mobile +91 {clean_mobile} not found."
            }

        deleted_user = users.pop(clean_mobile)
        _save_users(users)

        # Invalidate active sessions
        terminated_sessions = 0
        for token, sess in list(_sessions.items()):
            if sess.get("mobile") == clean_mobile:
                del _sessions[token]
                terminated_sessions += 1
        if terminated_sessions > 0:
            _save_sessions(_sessions)

        # Clear active OTPs
        _otp_store.pop(clean_mobile, None)

        # Archive cloud database to avoid orphaned files
        if archive_data:
            user_db_path = os.path.join(CLOUD_DB_DIR, f"{clean_mobile}.json")
            if os.path.isfile(user_db_path):
                archive_dir = os.path.join(BACKUP_DIR, "archived_users")
                os.makedirs(archive_dir, exist_ok=True)
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                archived_path = os.path.join(archive_dir, f"{clean_mobile}_{timestamp}.json")
                try:
                    shutil.move(user_db_path, archived_path)
                    print(f"[AuthService] Archived user cloud DB to: {archived_path}")
                except Exception as e:
                    print(f"[AuthService] Warning archiving user cloud DB: {e}")

    print(f"[USER DELETED] Name: {deleted_user.get('name')} | Mobile: +91 {clean_mobile} | Terminated Sessions: {terminated_sessions}")
    return {
        "success": True,
        "message": f"User '{deleted_user.get('name')}' (+91 {clean_mobile}) was successfully deleted.",
        "user": deleted_user
    }


# =========================================================================
# PUBLIC AUTHENTICATION & LOGIN GATES (Strict Pre-Registration Required)
# =========================================================================

def send_otp(mobile_raw: str, name: str | None = None) -> dict:
    """
    Generates a cryptographically secure 6-digit OTP for the mobile number.
    Strictly verifies that BOTH the mobile number and name match the developer-registered account.
    Enforces a 30-second resend cooldown and 5-minute expiration.
    """
    clean_name = _normalize_name(name)
    if not clean_name:
        return {
            "success": False,
            "error": "Please enter your name."
        }

    valid, mobile = _validate_mobile(mobile_raw)
    if not valid:
        return {
            "success": False,
            "error": "Please enter a valid 10-digit Indian mobile number (e.g., 9876543210)."
        }

    # Strict Security Gate: Only pre-registered users can request an OTP
    users = _load_users()
    if mobile not in users:
        return {
            "success": False,
            "error": f"Access denied. Mobile number (+91 {mobile}) is not registered. Please contact your administrator."
        }

    user_record = users[mobile]
    registered_name = _normalize_name(user_record.get("name", ""))

    # Strict Name Matching: Both mobile number and name must match the developer-registered account
    if clean_name.lower() != registered_name.lower():
        return {
            "success": False,
            "error": "Access denied. The entered name does not match the registered account for this mobile number."
        }

    now = time.time()
    with _auth_lock:
        existing = _otp_store.get(mobile)
        if existing:
            elapsed = now - existing.get("last_sent_at", 0)
            if elapsed < 30:
                remaining = int(30 - elapsed)
                return {
                    "success": False,
                    "error": f"Please wait {remaining} second{'s' if remaining != 1 else ''} before requesting a new OTP.",
                    "cooldown_remaining": remaining
                }

        # Generate 6-digit cryptographically random OTP
        otp_code = str(secrets.randbelow(900000) + 100000)
        expires_at = now + 300.0  # 5 minutes validity

        _otp_store[mobile] = {
            "otp": otp_code,
            "expires_at": expires_at,
            "attempts_left": 3,
            "last_sent_at": now,
            "name": registered_name
        }

    # Terminal visibility for testing & logs
    print("=" * 65)
    print("  [AUTH OTP GENERATED] [SMS]")
    print(f"  Mobile Number : +91 {mobile}")
    print(f"  One-Time Pass : {otp_code}")
    print(f"  Validity      : 5 Minutes (Expires at {datetime.fromtimestamp(expires_at).strftime('%H:%M:%S')})")
    print(f"  Attempts Left : 3")
    print("=" * 65)

    return {
        "success": True,
        "message": f"OTP successfully sent to +91 {mobile}.",
        "mobile": mobile,
        "resend_cooldown": 30,
        "expires_in_seconds": 300
    }


def verify_otp(mobile_raw: str, otp_code_raw: str, name: str | None = None) -> dict:
    """
    Verifies the submitted 6-digit OTP against active records.
    Strictly verifies that BOTH the mobile number and name match the developer-registered account.
    Enforces maximum 3 attempts and 5-minute expiry.
    Upon success, destroys the OTP and returns a session token.
    """
    clean_name = _normalize_name(name)
    valid, mobile = _validate_mobile(mobile_raw)
    otp_code = str(otp_code_raw or "").strip()

    if not clean_name:
        return {"success": False, "error": "Please enter your name."}

    if not valid:
        return {"success": False, "error": "Invalid mobile number."}

    if not otp_code or len(otp_code) != 6:
        return {"success": False, "error": "Please enter a valid 6-digit numeric OTP."}

    # Strict Security Gate: Only pre-registered users can verify OTP & log in
    users = _load_users()
    if mobile not in users:
        return {
            "success": False,
            "error": f"Access denied. Mobile number (+91 {mobile}) is not registered. Please contact your administrator."
        }

    user_record = users[mobile]
    registered_name = _normalize_name(user_record.get("name", ""))

    # Strict Name Matching: Both mobile number and name must match the developer-registered account
    if clean_name.lower() != registered_name.lower():
        return {
            "success": False,
            "error": "Access denied. The entered name does not match the registered account for this mobile number."
        }

    with _auth_lock:
        entry = _otp_store.get(mobile)
        if not entry:
            return {
                "success": False,
                "error": "No active OTP found for this mobile number. Please click 'Send OTP' first."
            }

        now = time.time()
        if now > entry["expires_at"]:
            _otp_store.pop(mobile, None)
            return {
                "success": False,
                "error": "OTP has expired. Please request a new OTP."
            }

        if entry["attempts_left"] <= 0:
            _otp_store.pop(mobile, None)
            return {
                "success": False,
                "error": "Maximum retry limit exceeded. Please request a fresh OTP."
            }

        # Verify OTP code matches the cryptographically generated code
        if entry["otp"] != otp_code:
            entry["attempts_left"] -= 1
            rem = entry["attempts_left"]
            if rem <= 0:
                _otp_store.pop(mobile, None)
                return {
                    "success": False,
                    "error": "Incorrect OTP. Maximum retry attempts reached. Please request a new OTP."
                }
            return {
                "success": False,
                "error": f"Incorrect OTP. You have {rem} attempt{'s' if rem != 1 else ''} remaining.",
                "attempts_left": rem
            }

        # OTP Verified Successfully -> Single-Use Consumption
        _otp_store.pop(mobile, None)

        # Retrieve registered user and update last_login (No public auto-registration / name alteration)
        users = _load_users()
        user_record = users.get(mobile, user_record)
        user_id = user_record.get("id") or str(uuid.uuid4())[:8]
        user_record["id"] = user_id
        user_record["last_login"] = datetime.now().isoformat()
        # Authoritative registered name preserved strictly
        stored_name = registered_name or user_record.get("name", "Logistics User")
        user_record["name"] = stored_name
        _save_users(users)

        # Issue 24-Hour Session Token
        now = time.time()
        expires_at = now + SESSION_TTL_SECONDS
        session_token = f"bnf_{secrets.token_hex(24)}"
        _sessions[session_token] = {
            "token": session_token,
            "user_id": user_id,
            "mobile": mobile,
            "name": stored_name,
            "role": user_record.get("role", "operator"),
            "login_at": datetime.now().isoformat(),
            "created_at_epoch": now,
            "expires_at_epoch": expires_at
        }
        _save_sessions(_sessions)

    print(f"[AUTH SUCCESS] User logged in: {stored_name} (+91 {mobile}) | Token: {session_token[:12]}... (24h valid)")

    return {
        "success": True,
        "token": session_token,
        "user": user_record,
        "expires_at": expires_at,
        "expires_in": SESSION_TTL_SECONDS
    }


def direct_login(mobile_raw: str, name: str | None = None) -> dict:
    """
    Direct authentication endpoint for pre-registered users.
    Strictly verifies that BOTH the mobile number and name match the developer-registered account.
    """
    clean_name = _normalize_name(name)
    if not clean_name:
        return {
            "success": False,
            "error": "Please enter your name."
        }

    valid, mobile = _validate_mobile(mobile_raw)
    if not valid:
        return {
            "success": False,
            "error": "Please enter a valid 10-digit Indian mobile number (e.g., 9876543210)."
        }

    # Strict Security Gate: Only pre-registered users can log in
    users = _load_users()
    if mobile not in users:
        return {
            "success": False,
            "error": f"Access denied. Mobile number (+91 {mobile}) is not registered. Please contact your administrator."
        }

    user_record = users[mobile]
    registered_name = _normalize_name(user_record.get("name", ""))

    # Strict Name Matching: Both mobile number and name must match the developer-registered account
    if clean_name.lower() != registered_name.lower():
        return {
            "success": False,
            "error": "Access denied. The entered name does not match the registered account for this mobile number."
        }

    with _auth_lock:
        users = _load_users()
        user_record = users.get(mobile, user_record)
        user_id = user_record.get("id") or str(uuid.uuid4())[:8]
        user_record["id"] = user_id
        user_record["last_login"] = datetime.now().isoformat()
        # Authoritative registered name preserved strictly (cannot be altered by login)
        stored_name = registered_name or user_record.get("name", "Logistics User")
        user_record["name"] = stored_name
        _save_users(users)

        # Issue 24-Hour Session Token
        now = time.time()
        expires_at = now + SESSION_TTL_SECONDS
        session_token = f"bnf_{secrets.token_hex(24)}"
        _sessions[session_token] = {
            "token": session_token,
            "user_id": user_id,
            "mobile": mobile,
            "name": stored_name,
            "role": user_record.get("role", "operator"),
            "login_at": datetime.now().isoformat(),
            "created_at_epoch": now,
            "expires_at_epoch": expires_at
        }
        _save_sessions(_sessions)

    print(f"[AUTH SUCCESS - DIRECT] User logged in: {stored_name} (+91 {mobile}) | Token: {session_token[:12]}... (24h valid)")

    return {
        "success": True,
        "token": session_token,
        "user": user_record,
        "expires_at": expires_at,
        "expires_in": SESSION_TTL_SECONDS
    }


def get_session_user(token: str | None) -> dict | None:
    """
    Retrieves authenticated user from session token.
    Enforces strict 24-hour expiration and developer account active verification.
    """
    if not token or not isinstance(token, str):
        return None
    clean_token = token.replace("Bearer ", "").strip()
    if not clean_token:
        return None

    now = time.time()
    with _auth_lock:
        entry = _sessions.get(clean_token)
        if not entry:
            # Fallback check from sessions.json in case saved by another process/worker
            _sessions.update(_load_sessions())
            entry = _sessions.get(clean_token)

        if not entry:
            return None

        # 1. Enforce 24-Hour Expiration Check
        expires_at = float(entry.get("expires_at_epoch", 0))
        if expires_at <= 0 or now > expires_at:
            print(f"[AuthService] Session expired for {entry.get('mobile')} (Token: {clean_token[:10]}...)")
            _sessions.pop(clean_token, None)
            _save_sessions(_sessions)
            return None

        # 2. Enforce Developer Active Account Check
        users = _load_users()
        mobile = entry.get("mobile")
        if mobile not in users:
            print(f"[AuthService] Session revoked for deleted/inactive user: {mobile}")
            _sessions.pop(clean_token, None)
            _save_sessions(_sessions)
            return None

        res = dict(entry)
        res["remaining_seconds"] = max(0, int(expires_at - now))
        return res


def logout_session(token: str | None) -> bool:
    """Terminates and revokes an active user session token."""
    if not token or not isinstance(token, str):
        return False
    clean_token = token.replace("Bearer ", "").strip()
    with _auth_lock:
        removed = _sessions.pop(clean_token, None)
        if removed is not None:
            _save_sessions(_sessions)
            print(f"[AuthService] Session logged out & revoked: {clean_token[:10]}...")
            return True
        return False
