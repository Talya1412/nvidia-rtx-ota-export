#!/usr/bin/env bash
# Double-click/one-shot launcher (Linux + macOS): exports the newest NVIDIA RTX DLLs + 7z.
# Requires PowerShell 7 (pwsh): https://learn.microsoft.com/powershell/scripting/install/installing-powershell
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pwsh -NoProfile -ExecutionPolicy Bypass -File "$DIR/Export-RtxOtaPreRelease.ps1" -Channel Newest -Archive
echo
read -r -p "Press Enter to close..." _
