@echo off
title OCR to Excel Backend Server
echo =================================================================
echo   Starting OCR to Excel Backend on port 8000...
echo =================================================================
if exist "%~dp0.venv\Scripts\activate.bat" (
    call "%~dp0.venv\Scripts\activate.bat"
)
cd /d "%~dp0backend"
python main.py
pause
