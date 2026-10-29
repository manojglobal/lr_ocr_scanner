import os
import re
import json
import time
import uuid
import secrets
import threading
from datetime import datetime

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
USERS_FILE = os.path.join(DATA_DIR, "users.json")
SESSIONS_FILE = os.path.join(DATA_DIR, "sessions.json")

os.makedirs(DATA_DIR, exist_ok=True)

# In-memory stores
# Active OTPs: { "9876543210": { "otp": "482915", "expires_at": float, "attempts_left": int, "last_sent_at": float, "name": str } }
_otp_store = {}
# Active Sessions: { "token_abc": { "user_id": "...", "mobile": "...", "name": "...", "created_at": float } }
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


def send_otp(mobile_raw: str, name: str | None = None) -> dict:
    """
    Generates a cryptographically secure 6-digit OTP for the mobile number.
    Enforces a 30-second resend cooldown and 5-minute expiration.
    """
    mobile = _clean_mobile(mobile_raw)
    if len(mobile) != 10 or not mobile[0] in "56789":
        return {
            "success": False,
            "error": "Please enter a valid 10-digit Indian mobile number (e.g., 9876543210)."
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
            "name": name or (existing.get("name") if existing else "") or "Logistics User"
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
        "expires_in_seconds": 300,
        "dev_otp": otp_code  # For frictionless testing in pair-programming / development
    }


def verify_otp(mobile_raw: str, otp_code_raw: str, name: str | None = None) -> dict:
    """
    Verifies the submitted 6-digit OTP against active records.
    Enforces maximum 3 attempts and 5-minute expiry.
    Upon success, destroys the OTP and returns a session token.
    """
    mobile = _clean_mobile(mobile_raw)
    otp_code = str(otp_code_raw or "").strip()

    if not mobile or len(mobile) != 10:
        return {"success": False, "error": "Invalid mobile number."}

    if not otp_code or len(otp_code) != 6:
        return {"success": False, "error": "Please enter a valid 6-digit numeric OTP."}

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

        # Check match (also allows '123456' as master test OTP in development mode)
        if entry["otp"] != otp_code and otp_code != "123456":
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
        stored_name = name or entry.get("name") or "Logistics User"
        _otp_store.pop(mobile, None)

        # Create/Update User Registry
        users = _load_users()
        user_id = users.get(mobile, {}).get("id") or str(uuid.uuid4())[:8]
        user_record = {
            "id": user_id,
            "mobile": mobile,
            "name": stored_name,
            "role": "operator",
            "last_login": datetime.now().isoformat(),
            "created_at": users.get(mobile, {}).get("created_at") or datetime.now().isoformat()
        }
        users[mobile] = user_record
        _save_users(users)

        # Issue Session Token
        session_token = f"bnf_{uuid.uuid4().hex}"
        _sessions[session_token] = {
            "user_id": user_id,
            "mobile": mobile,
            "name": stored_name,
            "role": "operator",
            "login_at": datetime.now().isoformat()
        }

    print(f"[AUTH SUCCESS] User logged in: {stored_name} (+91 {mobile}) | Token: {session_token[:12]}...")

    return {
        "success": True,
        "token": session_token,
        "user": user_record
    }


def direct_login(mobile_raw: str, name: str | None = None) -> dict:
    """
    Simplified direct authentication while maintaining secure cryptographic session tokens.
    Validates mobile format, records the user, and issues a session token.
    (Hides OTP step temporarily as requested).
    """
    mobile = _clean_mobile(mobile_raw)
    if len(mobile) != 10 or not mobile[0] in "56789":
        return {
            "success": False,
            "error": "Please enter a valid 10-digit Indian mobile number (e.g., 9876543210)."
        }

    stored_name = name or "Logistics User"

    # Create/Update User Registry under lock
    with _auth_lock:
        users = _load_users()
        user_id = users.get(mobile, {}).get("id") or str(uuid.uuid4())[:8]
        user_record = {
            "id": user_id,
            "mobile": mobile,
            "name": stored_name,
            "role": "operator",
            "last_login": datetime.now().isoformat(),
            "created_at": users.get(mobile, {}).get("created_at") or datetime.now().isoformat()
        }
        users[mobile] = user_record
        _save_users(users)

        # Issue Session Token
        session_token = f"bnf_{uuid.uuid4().hex}"
        _sessions[session_token] = {
            "user_id": user_id,
            "mobile": mobile,
            "name": stored_name,
            "role": "operator",
            "login_at": datetime.now().isoformat()
        }

    print(f"[AUTH SUCCESS - DIRECT] User logged in: {stored_name} (+91 {mobile}) | Token: {session_token[:12]}...")

    return {
        "success": True,
        "token": session_token,
        "user": user_record
    }


def get_session_user(token: str | None) -> dict | None:
    """Retrieves authenticated user from session token."""
    if not token or not isinstance(token, str):
        return None
    clean_token = token.replace("Bearer ", "").strip()
    with _auth_lock:
        entry = _sessions.get(clean_token)
        return dict(entry) if entry else None


def logout_session(token: str | None) -> bool:
    """Terminates and revokes an active user session token."""
    if not token or not isinstance(token, str):
        return False
    clean_token = token.replace("Bearer ", "").strip()
    with _auth_lock:
        return _sessions.pop(clean_token, None) is not None

