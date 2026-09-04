<#
.SYNOPSIS
  Check NVIDIA OTA for a new pre-release version; only when newer than the last GitHub release,
  export the DLLs, package a 7z (flat layout) and publish a GitHub Release with changelog notes.

.DESCRIPTION
  Intended for a scheduled GitHub Actions workflow but works locally too (requires `gh` CLI).

  "New version" identity = DLSS manifest version + Streamline dlss_override version,
  encoded in the release tag:  v<dlss>-sl<sl>   e.g.  v310.9.0-sl2.14.0
  If a release with that tag already exists, the script exits 0 without touching anything.

  Changelog in the release notes contains:
    - version deltas vs the previous release (DLSS + Streamline + GitHub SDK lag)
    - per-file change list (added / changed / unchanged) computed from SHA-256 of the previous
      release's checksums.txt asset
    - the full checksum table

.EXAMPLE
  GH_TOKEN=... ./New-OtaRelease.ps1                     # inside GitHub Actions
  ./New-OtaRelease.ps1 -Repo Talya1412/nvidia-rtx-ota-export   # locally
#>
[CmdletBinding()]
param(
    [string]$Repo = '',
    [ValidateSet('Staging', 'Production')]
    [string]$Channel = 'Staging'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$exportScript = Join-Path $repoRoot 'Export-RtxOtaPreRelease.ps1'

# ---------------------------------------------------------------- helpers
function Get-DllShortVersion([string]$Path) {
    # FileVersion "310,9,0,0" -> "310.9.0"
    $v = (Get-Item $Path).VersionInfo.FileVersion -replace '[^0-9]', '.'
    $p = $v.Split('.') | Where-Object { $_ -ne '' }
    return ('{0}.{1}.{2}' -f $p[0], $p[1], $p[2])
}

function Resolve-7z {
    $candidates = @(
        (Get-Command 7z -ErrorAction SilentlyContinue),
        (Get-Command 7zr -ErrorAction SilentlyContinue)
    ) | Where-Object { $_ }
    foreach ($c in $candidates) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
                     "$env:ProgramFiles\NVIDIA Corporation\NVIDIA App\7z.exe")) {
        if (Test-Path $p) { return $p }
    }
    # official standalone console build, 7z format only
    $tmp = Join-Path $env:TEMP '7zr.exe'
    Invoke-WebRequest -Uri 'https://www.7-zip.org/a/7zr.exe' -OutFile $tmp -UseBasicParsing
    return $tmp
}

function Get-PreviousChecksums([string]$RepoFull, [string]$PrevTag) {
    try {
        $assets = gh api "repos/$RepoFull/releases/tags/$PrevTag" --jq '.assets[] | select(.name == "checksums.txt") | .url' 2>$null
        if (-not $assets) { return $null }
        $tmp = Join-Path $env:TEMP 'prev-checksums.txt'
        gh api -H 'Accept: application/octet-stream' "repos/$RepoFull/releases/assets/$($assets | Select-Object -First 1 | ForEach-Object { ($_ -split '/')[-1] })" > $tmp 2>$null
        if ((Get-Item $tmp).Length -gt 0) { return (Get-Content $tmp) }
    } catch { }
    return $null
}

# ---------------------------------------------------------------- 1. export current OTA state
Write-Host '==> Exporting current OTA pre-release state' -ForegroundColor Cyan
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("nvngx-release-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
powershell -NoProfile -ExecutionPolicy Bypass -File $exportScript -OutDir $work -Channel $Channel -SkipGitHubCheck
if ($LASTEXITCODE -ne 0) { throw 'Export step failed.' }

$dlls = Get-ChildItem $work -Filter '*.dll'
$dlssVer = Get-DllShortVersion (Join-Path $work 'nvngx_dlss.dll')
$slVer   = Get-DllShortVersion (Join-Path $work 'sl.common.dll')
$tag = "v$dlssVer-sl$slVer"
Write-Host "    DLSS $dlssVer / Streamline $slVer -> tag $tag"

# ---------------------------------------------------------------- 2. gate: only release on new version
if (-not $Repo) {
    $remote = git -C $repoRoot remote get-url origin
    $Repo = ($remote -replace '.*github\.com[:/]', '' -replace '\.git$', '')
}
$existing = gh api "repos/$Repo/releases?per_page=100" --jq '.[].tag_name' 2>$null
if ($existing -contains $tag) {
    Write-Host "==> No new OTA version (release $tag already exists). Nothing to do." -ForegroundColor Green
    Remove-Item $work -Recurse -Force
    exit 0
}

# ---------------------------------------------------------------- 3. package 7z (flat, drop-in)
Write-Host '==> Packaging 7z' -ForegroundColor Cyan
$sevenZip = Resolve-7z
$assetName = "streamline-ota-$($tag.TrimStart('v')).7z"
$assetPath = Join-Path $work $assetName
& $sevenZip a -t7z -mx=7 $assetPath (Join-Path $work '*') | Out-Null
if ($LASTEXITCODE -ne 0) { throw '7z packing failed.' }

# checksums file (machine-readable, also used for next release's changelog diff)
$checksumLines = $dlls | Sort-Object Name | ForEach-Object {
    $short = Get-DllShortVersion $_.FullName
    $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$($_.Name)`t$short`t$hash"
}
$checksumsPath = Join-Path $work 'checksums.txt'
$checksumLines | Set-Content $checksumsPath -Encoding UTF8

# ---------------------------------------------------------------- 4. changelog vs previous release
$prevTag = $existing | Select-Object -First 1
$prevSums = if ($prevTag) { Get-PreviousChecksums $Repo $prevTag } else { $null }
$changed = @(); $added = @(); $unchanged = @()
$prevMap = @{}
if ($prevSums) {
    foreach ($line in $prevSums) {
        $p = $line -split "`t"
        if ($p.Count -ge 3) { $prevMap[$p[0]] = $p[2] }
    }
}
foreach ($line in $checksumLines) {
    $p = $line -split "`t"
    if (-not $prevMap.ContainsKey($p[0])) { $added += $p[0] }
    elseif ($prevMap[$p[0]] -ne $p[2]) { $changed += $p[0] }
    else { $unchanged += $p[0] }
}

$ghDlss = try { (Invoke-RestMethod 'https://api.github.com/repos/NVIDIA/DLSS/releases/latest' -TimeoutSec 20).tag_name } catch { 'unavailable' }
$ghSl   = try { (Invoke-RestMethod 'https://api.github.com/repos/NVIDIA-RTX/Streamline/releases/latest' -TimeoutSec 20).tag_name } catch { 'unavailable' }

$notes = @"
# NVIDIA RTX OTA Pre-Release $tag

Exported from NVIDIA's NGX OTA **$Channel** channel (``dev-models``) — the feed that runs ahead of
public SDK releases. Every file is SHA-256-verified against NVIDIA's published sidecar and
Authenticode-signed by **NVIDIA Corporation**.

| Component | This release | Public SDK (GitHub) |
|---|---|---|
| DLSS (SR / RR / FG) | **$dlssVer** | $ghDlss |
| Streamline plugins | **$slVer** | $ghSl |

## Changelog

"@
if (-not $prevTag) {
    $notes += "`n- First tracked release. Baseline: DLSS $dlssVer, Streamline $slVer.`n"
} else {
    $notes += "`nCompared against ``$prevTag``:`n"
    if ($changed.Count)  { $notes += ($changed  | ForEach-Object { "- **changed**: ``$_``" }) + "`n" }
    if ($added.Count)    { $notes += ($added    | ForEach-Object { "- **added**: ``$_``" }) + "`n" }
    $removed = $prevMap.Keys | Where-Object { $changed -notcontains $_ -and $added -notcontains $_ -and ($checksumLines -notmatch [regex]::Escape("$_`t")) }
    if ($removed.Count)  { $notes += ($removed  | ForEach-Object { "- **removed**: ``$_``" }) + "`n" }
    if (-not $changed.Count -and -not $added.Count -and -not $removed.Count) { $notes += "- No file content changed (version bump only).`n" }
}
$fence = '```'
$notes += "`n## Checksums`n`n$fence`n" + ($checksumLines -join "`n") + "`n$fence"
$notes += @"

## Install (per-game / global override)

- ``nvngx_dlss.dll`` -> DLSS Super Resolution, ``nvngx_dlssd.dll`` -> Ray Reconstruction,
  ``nvngx_dlssg.dll`` -> Frame Generation, ``sl.*.dll`` -> Streamline runtime (games using SL).
- Drop next to the game exe (or via DLSS Swapper / NGX override). Flat layout, no subfolders.
- Staging builds are NVIDIA-signed pre-releases: the driver only serves them when an override points at them.

> Binaries are NVIDIA-copyrighted, fetched from NVIDIA's own CDN for personal use.
"@
$notesPath = Join-Path $work 'release-notes.md'
$notes | Set-Content $notesPath -Encoding UTF8

# ---------------------------------------------------------------- 5. publish
Write-Host "==> Creating GitHub release $tag" -ForegroundColor Cyan
gh release create $tag $assetPath $checksumsPath `
    --repo $Repo `
    --title "NVIDIA RTX OTA Pre-Release $tag" `
    --notes-file $notesPath
if ($LASTEXITCODE -ne 0) { throw 'gh release create failed.' }

Remove-Item $work -Recurse -Force
Write-Host "==> Released: $tag ($assetName)" -ForegroundColor Green
