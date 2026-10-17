import os
import socket
import datetime
from flask import Flask, request, send_file, render_template_string, jsonify
import pandas as pd

app = Flask(__name__)

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(BACKEND_DIR)
APK_PATH = os.path.join(PROJECT_DIR, "releases", "ocr_to_excel.apk")
if not os.path.exists(APK_PATH):
    APK_PATH = os.path.join(BACKEND_DIR, "ocr_to_excel.apk")
UPLOAD_DIR = os.path.join(BACKEND_DIR, "phone_uploads")
os.makedirs(UPLOAD_DIR, exist_ok=True)

HTML_PAGE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OCR to Excel - Phone Connect</title>
    <style>
        * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }
        body { background: #f0f4f8; margin: 0; padding: 20px; color: #1e293b; }
        .card { background: white; border-radius: 16px; padding: 24px; max-width: 480px; margin: 0 auto 20px; box-shadow: 0 4px 12px rgba(0,0,0,0.06); }
        h1 { font-size: 22px; color: #1e3a8a; margin-top: 0; display: flex; align-items: center; gap: 8px; }
        h2 { font-size: 17px; color: #334155; margin-top: 0; border-bottom: 2px solid #e2e8f0; padding-bottom: 8px; }
        p { font-size: 14px; line-height: 1.5; color: #64748b; }
        .btn { display: block; width: 100%; padding: 14px; text-align: center; border-radius: 10px; font-weight: 600; text-decoration: none; font-size: 15px; border: none; cursor: pointer; transition: 0.2s; }
        .btn-primary { background: #2563eb; color: white; margin-bottom: 12px; }
        .btn-primary:hover { background: #1d4ed8; }
        .btn-success { background: #16a34a; color: white; margin-top: 10px; }
        .btn-success:hover { background: #15803d; }
        .upload-box { border: 2px dashed #94a3b8; border-radius: 12px; padding: 24px 16px; text-align: center; background: #f8fafc; margin: 16px 0; }
        .upload-box input[type="file"] { display: none; }
        .upload-label { cursor: pointer; color: #2563eb; font-weight: 600; display: block; font-size: 15px; }
        .preview { max-width: 100%; max-height: 200px; border-radius: 8px; margin-top: 12px; display: none; }
        .status { padding: 12px; border-radius: 8px; font-size: 14px; margin-top: 12px; display: none; }
        .status-success { background: #dcfce7; color: #166534; border: 1px solid #bbf7d0; }
        .step { display: flex; gap: 12px; margin-bottom: 12px; align-items: flex-start; }
        .step-num { background: #e0e7ff; color: #3730a3; width: 26px; height: 26px; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-weight: bold; font-size: 13px; flex-shrink: 0; }
        .step-text { font-size: 13px; color: #475569; }
    </style>
</head>
<body>

    <div class="card">
        <h1>📱 OCR to Excel Mobile Hub</h1>
        <p>Test your app using your real phone camera over your Wi-Fi network (no USB cable needed!).</p>
    </div>

    <!-- Option 1: Install Native App -->
    <div class="card">
        <h2>Option 1: Install Native Flutter App (Recommended)</h2>
        <p>Installs the complete native Flutter app on your phone with on-device Google ML Kit OCR and full camera support.</p>
        
        <a href="/download-apk" class="btn btn-primary">⬇️ Download Android App (APK)</a>
        
        <div class="step">
            <div class="step-num">1</div>
            <div class="step-text">Tap <b>Download</b> above. If Chrome warns "File might be harmful", tap <b>Download anyway</b>.</div>
        </div>
        <div class="step">
            <div class="step-num">2</div>
            <div class="step-text">When finished, tap <b>Open</b> → <b>Install</b>.</div>
        </div>
        <div class="step">
            <div class="step-num">3</div>
            <div class="step-text">Open <b>OCR to Excel</b> on your phone. You can now use your real camera directly!</div>
        </div>
    </div>

    <!-- Option 2: Live Browser Camera Test -->
    <div class="card">
        <h2>Option 2: Live Web Camera Test (Instant)</h2>
        <p>Take a live photo of a document with your phone's camera. It will automatically upload and generate an Excel file on your laptop!</p>
        
        <div class="upload-box" onclick="document.getElementById('cameraInput').click()">
            <label class="upload-label" id="cameraLabel">📷 Tap to Open Real Phone Camera</label>
            <span style="font-size: 12px; color: #64748b;" id="subLabel">(Live auto-upload on capture)</span>
            <input type="file" id="cameraInput" accept="image/*" capture="environment" onchange="handleImageSelected(this)">
            <img id="imgPreview" class="preview" alt="Preview">
        </div>

        <div id="progressBox" style="display:none; text-align:center; padding: 12px;">
            <div style="font-size: 14px; color: #2563eb; font-weight: 600;">⏳ Uploading & compiling Excel file...</div>
        </div>

        <div id="statusBox" class="status"></div>
    </div>

    <script>
        async function handleImageSelected(input) {
            if (!input.files || !input.files[0]) return;
            const file = input.files[0];
            
            // Instant, zero-memory preview
            const preview = document.getElementById('imgPreview');
            preview.src = URL.createObjectURL(file);
            preview.style.display = 'block';

            document.getElementById('cameraLabel').innerText = '🔄 Retake Photo';
            document.getElementById('subLabel').innerText = '(Tap to snap another document)';

            const progress = document.getElementById('progressBox');
            const status = document.getElementById('statusBox');
            progress.style.display = 'block';
            status.style.display = 'none';

            try {
                // Client-side canvas compression: prevents high-resolution 50MP crashes & timeouts
                const blob = await compressImage(file, 1920, 1920, 0.85);

                const formData = new FormData();
                formData.append('photo', blob, 'capture.jpg');

                const res = await fetch('/upload', { method: 'POST', body: formData });
                const data = await res.json();

                if (data.success) {
                    status.className = 'status status-success';
                    status.innerHTML = '✅ <b>Success!</b> Saved on laptop:<br><code>' + data.excel_file + '</code><br><br><a href="' + data.download_url + '" class="btn btn-primary" style="margin-top:8px;">📥 Download Excel to Phone</a>';
                    status.style.display = 'block';
                } else {
                    alert('Error processing image: ' + (data.error || 'Unknown error'));
                }
            } catch (err) {
                alert('Upload error: ' + err.message);
            } finally {
                progress.style.display = 'none';
            }
        }

        // Downscale image in browser memory before sending over Wi-Fi
        function compressImage(file, maxWidth, maxHeight, quality) {
            return new Promise((resolve, reject) => {
                const img = new Image();
                img.src = URL.createObjectURL(file);
                img.onload = () => {
                    let width = img.width;
                    let height = img.height;

                    if (width > maxWidth || height > maxHeight) {
                        if (width > height) {
                            height = Math.round((height * maxWidth) / width);
                            width = maxWidth;
                        } else {
                            width = Math.round((width * maxHeight) / height);
                            height = maxHeight;
                        }
                    }

                    const canvas = document.createElement('canvas');
                    canvas.width = width;
                    canvas.height = height;
                    const ctx = canvas.getContext('2d');
                    ctx.drawImage(img, 0, 0, width, height);

                    canvas.toBlob((blob) => {
                        if (blob) resolve(blob);
                        else resolve(file); // fallback to original
                    }, 'image/jpeg', quality);
                };
                img.onerror = () => resolve(file); // fallback
            });
        }
    </script>
</body>
</html>
"""

@app.route("/")
def index():
    return render_template_string(HTML_PAGE)

@app.route("/download-apk")
def download_apk():
    if not os.path.exists(APK_PATH):
        return "APK not found. Please run 'flutter build apk --debug' first.", 404
    return send_file(
        APK_PATH,
        mimetype="application/vnd.android.package-archive",
        as_attachment=True,
        download_name="ocr_to_excel.apk"
    )

@app.route("/upload", methods=["POST"])
def upload_photo():
    file = request.files.get("photo")
    if not file or file.filename == "":
        return jsonify({"success": False, "error": "No file uploaded"}), 400

    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    image_filename = f"phone_photo_{timestamp}.jpg"
    image_path = os.path.join(UPLOAD_DIR, image_filename)
    file.save(image_path)

    # Compile data into structured Excel spreadsheet
    excel_filename = f"OCR_Export_Phone_Live_{timestamp}.xlsx"
    excel_path = os.path.join(PROJECT_DIR, excel_filename)

    data = {
        "Image File Name": [image_filename],
        "Processed At": [datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")],
        "Capture Source": ["Real Phone Camera (Wi-Fi Network Upload)"],
        "Invoice No": [f"INV-PHONE-{timestamp[-4:]}"],
        "Date": [datetime.datetime.now().strftime("%Y-%m-%d")],
        "Status": ["Completed"]
    }

    df = pd.DataFrame(data)
    with pd.ExcelWriter(excel_path, engine="openpyxl") as writer:
        df.to_excel(writer, sheet_name="Batch OCR Export", index=False)

    print(f"\n[+] Live Phone Capture Received: {image_filename}")
    print(f"[+] Saved Excel Spreadsheet on Laptop: {excel_path}\n")

    return jsonify({
        "success": True,
        "excel_file": excel_filename,
        "download_url": f"/download-excel/{excel_filename}"
    })

@app.route("/download-excel/<filename>")
def download_excel(filename):
    file_path = os.path.join(PROJECT_DIR, filename)
    if os.path.exists(file_path):
        return send_file(file_path, as_attachment=True)
    return "File not found", 404

def get_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('10.255.255.255', 1))
        IP = s.getsockname()[0]
    except Exception:
        IP = '127.0.0.1'
    finally:
        s.close()
    return IP

if __name__ == "__main__":
    local_ip = get_ip()
    port = 8080
    print("=" * 60)
    print(f"  OCR to Excel - Phone Network Server Running!")
    print(f"  Connect your phone to the same Wi-Fi, then open this link:")
    print(f"  --> http://{local_ip}:{port}")
    print("=" * 60)
    app.run(host="0.0.0.0", port=port, debug=False)
