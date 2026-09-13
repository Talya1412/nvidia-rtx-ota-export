@echo off
rem Double-click launcher: exports the newest NVIDIA RTX OTA DLLs + 7z into Downloads.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-RtxOtaPreRelease.ps1" -Channel Newest -Archive
echo.
pause
