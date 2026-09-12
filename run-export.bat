@echo off
rem Double-click launcher: exports the newest NVIDIA RTX OTA DLLs + ZIP into Downloads.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-RtxOtaPreRelease.ps1" -Channel Newest -Zip
echo.
pause
