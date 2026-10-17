"""
OCR to Excel - Convenience Server Runner
Starts the FastAPI OCR backend from any working directory.
"""
import os
import sys

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.join(BASE_DIR, "backend")

if __name__ == "__main__":
    if BACKEND_DIR not in sys.path:
        sys.path.insert(0, BACKEND_DIR)
    os.chdir(BACKEND_DIR)

    import uvicorn
    from main import get_local_ip

    local_ip = get_local_ip()
    print("=" * 65)
    print("  OCR to Excel Studio - Starting Server")
    print(f"  Web Component (Browser) : http://localhost:8000")
    print(f"  Network / Phone Access  : http://{local_ip}:8000")
    print(f"  Download Android APK    : http://{local_ip}:8000/download-apk")
    print("=" * 65)
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
