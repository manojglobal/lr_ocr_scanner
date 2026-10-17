# Auto-Sync script: Watches the Android emulator for new Excel exports
# and automatically copies them to your laptop project folder and emulator Downloads folder.

$targetDir = "D:\AndroidDev\Projects\ocr_to_excel"
$remoteDir = "/sdcard/Android/data/com.example.ocr_to_excel/files"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Auto-Sync Active: Monitoring for new Excel exports...    " -ForegroundColor Green
Write-Host "  Target Folder: $targetDir" -ForegroundColor Yellow
Write-Host "  Press Ctrl+C to stop at any time.                       " -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Cyan

while ($true) {
    try {
        $rawOutput = adb shell "ls $remoteDir/*.xlsx 2>/dev/null"
        if ($rawOutput) {
            $files = $rawOutput -split "`r?`n" | Where-Object { $_ -match '\.xlsx$' }
            foreach ($remoteFile in $files) {
                $remoteFile = $remoteFile.Trim()
                if (-not $remoteFile) { continue }
                
                $fileName = [System.IO.Path]::GetFileName($remoteFile)
                $localPath = Join-Path $targetDir $fileName
                
                if (-not (Test-Path $localPath)) {
                    Write-Host "`n[+] New Excel export detected: $fileName" -ForegroundColor Magenta
                    
                    # Pull to laptop folder
                    adb pull $remoteFile $localPath | Out-Null
                    
                    if (Test-Path $localPath) {
                        Write-Host "[OK] Saved to laptop: $localPath" -ForegroundColor Green
                        
                        # Also copy to emulator's public Download folder
                        adb shell "cp $remoteFile /sdcard/Download/ && am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Download/$fileName" | Out-Null
                        Write-Host "[OK] Saved to emulator: /sdcard/Download/$fileName" -ForegroundColor Green
                        
                        # Highlight in Windows Explorer
                        explorer.exe /select,$localPath
                    }
                }
            }
        }
    } catch {
        # Ignore temporary adb communication glitches
    }
    Start-Sleep -Seconds 2
}
