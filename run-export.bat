@echo off
rem Double-click launcher: exports latest NVIDIA RTX OTA pre-release DLLs + ZIP into Downloads.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-RtxOtaPreRelease.ps1" -Zip
echo.
pause
