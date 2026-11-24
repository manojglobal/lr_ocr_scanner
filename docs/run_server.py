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
    from main import get_local_ip, get_public_server_url, get_server_host, get_server_port

    local_ip = get_local_ip()
    host = get_server_host()
    port = get_server_port()
    public_url = get_public_server_url()
    print("=" * 65)
    print("  OCR to Excel Studio - Server Starting")
    print(f"  Bind Host / Port        : {host}:{port}")
    print(f"  Web Component (Browser) : http://localhost:{port}")
    print(f"  Network / Phone Access  : http://{local_ip}:{port}")
    if public_url:
        print(f"  Public Server URL       : {public_url}")
    print(f"  Download Android APK    : http://{local_ip}:{port}/download-apk")
    print("=" * 65)
    uvicorn.run("main:app", host=host, port=port, reload=True)
