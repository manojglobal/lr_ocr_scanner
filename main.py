"""
OCR to Excel - Root Launcher Shim & Compatibility Layer
Delegates all execution and FastAPI app loading to backend/main.py
"""
import os
import sys
import importlib.util

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.join(BASE_DIR, "backend")

if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

os.chdir(BACKEND_DIR)

backend_main_path = os.path.join(BACKEND_DIR, "main.py")
spec = importlib.util.spec_from_file_location("backend_main", backend_main_path)
backend_main = importlib.util.module_from_spec(spec)
sys.modules["backend_main"] = backend_main
spec.loader.exec_module(backend_main)

app = backend_main.app
get_local_ip = backend_main.get_local_ip

if __name__ == "__main__":
    import uvicorn
    local_ip = get_local_ip()
    print("=" * 65)
    print("  OCR to Excel Studio - Server Starting (Root Shim)")
    print(f"  Web Component (Browser) : http://localhost:8000")
    print(f"  Network / Phone Access  : http://{local_ip}:8000")
    print(f"  Download Android APK    : http://{local_ip}:8000/download-apk")
    print("=" * 65)
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
