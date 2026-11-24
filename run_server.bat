@echo off
title OCR to Excel Backend Server
echo =================================================================
echo   Starting OCR to Excel Backend (HOST and PORT loaded from .env)...
echo =================================================================
if exist "%~dp0.venv\Scripts\activate.bat" (
    call "%~dp0.venv\Scripts\activate.bat"
)
cd /d "%~dp0backend"
python main.py
pause
