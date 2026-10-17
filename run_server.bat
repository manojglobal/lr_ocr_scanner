@echo off
title OCR to Excel Backend Server
echo =================================================================
echo   Starting OCR to Excel Backend on port 8000...
echo =================================================================
cd /d "%~dp0backend"
python main.py
pause
