<#
.SYNOPSIS
  Check every tracked NVIDIA feed for a new version (per-component newest of OTA
  staging/production + Streamline SDK by default); only when strictly newer than every
  existing GitHub release, export the DLLs, package a 7z (flat layout) and publish a
  GitHub Release with changelog notes.

.DESCRIPTION
  Intended for a scheduled GitHub Actions workflow but works locally too (requires `gh` CLI).

  "New version" identity = exported DLSS version + Streamline version (real DLL FileVersions),
  encoded in the release tag:  v<dlss>-sl<sl>   e.g.  v310.9.1-sl2.14.1
  If the candidate is not strictly newer than every existing release, the script exits 0 without
  touching anything (a stale feed can never pull "Latest release" backwards).

  Changelog in the release notes contains:
    - per-component source table (which feed each component came from) + all feeds compared
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
    [ValidateSet('Newest', 'Sdk', 'Staging', 'Production')]
    [string]$Channel = 'Newest'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'Ota.Common.psm1') -Force

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$exportScript = Join-Path $repoRoot 'Export-RtxOtaPreRelease.ps1'

# ---------------------------------------------------------------- helpers

function Get-PreviousChecksums([string]$RepoFull, [string]$PrevTag) {
    # PS 5.1 mangles embedded double quotes in native args, so the name filter happens in
    # PowerShell instead of inside a --jq expression.
    try {
        $rel = gh api "repos/$RepoFull/releases/tags/$PrevTag" 2>$null | ConvertFrom-Json
        $asset = @($rel.assets) | Where-Object { $_.name -eq 'checksums.txt' } | Select-Object -First 1
        if (-not $asset) { return $null }
        $tmp = Join-Path $env:TEMP 'prev-checksums.txt'
        gh api -H 'Accept: application/octet-stream' "repos/$RepoFull/releases/assets/$($asset.id)" > $tmp 2>$null
        if ((Get-Item $tmp).Length -gt 0) { return (Get-Content $tmp) }
    } catch { }
    return $null
}

# ---------------------------------------------------------------- 0. cheap pre-gate (multi-feed probe)
# Reads 2 OTA manifests + 3 GitHub endpoints (no payload downloads) and compares against the
# probe-state.json asset attached to the newest release. When nothing changed anywhere, the
# heavy export is skipped entirely - scheduled polls cost seconds, not minutes.
if (-not $Repo) {
    $remote = git -C $repoRoot remote get-url origin
    $Repo = ($remote -replace '.*github\.com[:/]', '' -replace '\.git$', '')
}
$otaChannelRoots = @{ Staging = 'dev-models'; Production = '3e933c08-ea30-45ae-93d1-5114edf9c3b9' }
$otaManifestPath = 'config/versions/2/files/nvngx_server_config.txt'
$ghHeaders = if ($env:GH_TOKEN) { @{ Authorization = "Bearer $($env:GH_TOKEN)" } } else { @{} }
function Get-LatestTag([string]$RepoSlug) {
    try {
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases/latest" -Headers $ghHeaders -TimeoutSec 20
        return [string]$r.tag_name
    } catch { Write-Host "    ! $RepoSlug latest tag unreachable" -ForegroundColor Yellow; return '' }
}

Write-Host '==> Probing feeds (cheap pre-gate)' -ForegroundColor Cyan
$probeLive = [pscustomobject]@{
    stagingDlss     = $null
    stagingSl       = $null
    productionDlss  = $null
    productionSl    = $null
    sdkTag          = Get-LatestTag 'NVIDIA-RTX/Streamline'
    dlssRepoTag     = Get-LatestTag 'NVIDIA/DLSS'
    dlssnrMirrorMax = ''
}
foreach ($ch in 'Staging', 'Production') {
    try {
        $m = Invoke-RestMethod -Uri "https://ngx.download.nvidia.com/$($otaChannelRoots[$ch])/org/nvidia/team/ngx/models/$otaManifestPath" -TimeoutSec 30
        $body = if ($m -is [string]) { $m } else { [System.Text.Encoding]::UTF8.GetString($m) }
        $probeLive."$($ch.ToLower())Dlss" = Get-OtaSectionVersion $body 'dlss'
        $slSdk = Get-OtaSectionVersion $body 'sl_sdk_0'
        $probeLive."$($ch.ToLower())Sl" = if ($slSdk) { $slSdk } else { Get-OtaSectionVersion $body 'dlss_override' }
        if (-not $probeLive.dlssnrMirrorMax) { $probeLive.dlssnrMirrorMax = Get-OtaSectionVersion $body 'dlssnr' }
    } catch { Write-Host "    ! $ch manifest unreachable" -ForegroundColor Yellow }
}
try {
    $rhiRels = Invoke-RestMethod -Uri 'https://api.github.com/repos/RankFTW/rhi-repo/releases?per_page=100' -Headers $ghHeaders -TimeoutSec 20
    $snr = @(Get-RhiMirrorBuilds @($rhiRels) 'dlssnr')
    if ($snr.Count) {
        $mirrorMax = [string]$snr[0].Version
        $cur = $probeLive.dlssnrMirrorMax
        if (-not $cur -or (Compare-OtaNewer $mirrorMax $cur)) { $probeLive.dlssnrMirrorMax = $mirrorMax }
    }
} catch { Write-Host '    ! rhi-repo index unreachable' -ForegroundColor Yellow }

$storedProbe = $null
$newestRelTag = $null
try {
    $relList = gh api --paginate "repos/$Repo/releases?per_page=100" 2>$null | ConvertFrom-Json
    $newestRelTag = Get-NewestReleaseTag @($relList | ForEach-Object { $_.tag_name })
    $newestRel = @($relList) | Where-Object { $_.tag_name -eq $newestRelTag } | Select-Object -First 1
    if ($newestRel) {
        $probeAsset = @($newestRel.assets) | Where-Object { $_.name -eq 'probe-state.json' } | Select-Object -First 1
        if ($probeAsset) {
            $probeTmp = Join-Path $env:TEMP 'ota-probe-state.json'
            gh api -H 'Accept: application/octet-stream' "repos/$Repo/releases/assets/$($probeAsset.id)" > $probeTmp 2>$null
            if ((Get-Item $probeTmp).Length -gt 0) { $storedProbe = Get-Content $probeTmp -Raw | ConvertFrom-Json }
        }
    }
} catch { Write-Host '    ! probe state unavailable (will export)' -ForegroundColor Yellow }

# fail-open: an unhealthy probe (manifests unreachable) must NEVER skip the export - otherwise a
# down CDN could freeze the pipeline on a stale "no change" verdict while feeds move on
$probeHealthy = [bool]($probeLive.stagingDlss -or $probeLive.productionDlss)
if ($probeHealthy -and -not (Test-ProbeStateDiffers $probeLive $storedProbe)) {
    Write-Host "==> No feed changed since $newestRelTag. Nothing to do." -ForegroundColor Green
    exit 0
}
Write-Host '    Feed state changed - running the full export.' -ForegroundColor Cyan
$probeStatePath = Join-Path $env:TEMP 'probe-state.json'
$probeLive | ConvertTo-Json | Set-Content $probeStatePath -Encoding UTF8

Write-Host '==> Exporting current newest state' -ForegroundColor Cyan
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("nvngx-release-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
powershell -NoProfile -ExecutionPolicy Bypass -File $exportScript -OutDir $work -Channel $Channel
if ($LASTEXITCODE -ne 0) { throw 'Export step failed.' }
$sourcesFile = Join-Path $work 'export-sources.txt'
$dlssSource = 'unknown'; $slSource = 'unknown'; $feedState = @{}
if (Test-Path $sourcesFile) {
    foreach ($line in (Get-Content $sourcesFile)) {
        $p = $line -split '=', 3
        if ($p.Count -lt 2) { continue }
        if ($p[0] -eq 'dlss') { $dlssSource = $p[2] }
        elseif ($p[0] -eq 'sl') { $slSource = $p[2] }
        else { $feedState[$p[0]] = $p[1] }
    }
}

$dlls = Get-ChildItem $work -Filter '*.dll'
$dlssVer = ConvertTo-ShortVersion (Get-Item (Join-Path $work 'nvngx_dlss.dll')).VersionInfo.FileVersion
$slVer   = ConvertTo-ShortVersion (Get-Item (Join-Path $work 'sl.common.dll')).VersionInfo.FileVersion
$tag = "v$dlssVer-sl$slVer"
Write-Host "    DLSS $dlssVer / Streamline $slVer -> tag $tag"
$signatureRows = @()
if (Test-Path (Join-Path $work 'export-summary.txt')) {
    foreach ($line in (Get-Content (Join-Path $work 'export-summary.txt'))) {
        $p = $line -split "`t"
        if ($p.Count -ge 3 -and $p[2] -match 'UNVERIFIED') { $signatureRows += "- ``$($p[0])``: **$($p[2])**" }
    }
}

# ---------------------------------------------------------------- 2. gate: only release on new version
if (-not $Repo) {
    $remote = git -C $repoRoot remote get-url origin
    $Repo = ($remote -replace '.*github\.com[:/]', '' -replace '\.git$', '')
}
$existing = gh api --paginate "repos/$Repo/releases?per_page=100" --jq '.[].tag_name' 2>$null
$maxTag = Get-NewestReleaseTag @($existing)
if ($maxTag -and -not (Test-ReleaseTagNewer $dlssVer $slVer $maxTag)) {
    Write-Host "==> Candidate $tag is not newer than the newest existing release $maxTag. Nothing to do." -ForegroundColor Green
    # persist the probe state so later polls can skip the heavy export again
    if ($probeStatePath -and (Test-Path $probeStatePath)) {
        gh release upload $maxTag $probeStatePath --repo $Repo --clobber 2>$null
    }
    Remove-Item $work -Recurse -Force
    exit 0
}

Write-Host '==> Packaging 7z' -ForegroundColor Cyan
$assetName = "streamline-ota-$($tag.TrimStart('v')).7z"
$assetPath = Join-Path $work $assetName
New-7zArchive $assetPath (Join-Path $work '*.dll') | Out-Null

# checksums file (machine-readable, also used for next release's changelog diff)
$checksumLines = $dlls | Sort-Object Name | ForEach-Object {
    $short = ConvertTo-ShortVersion $_.VersionInfo.FileVersion
    $hash = Get-FileSha256 $_.FullName
    "$($_.Name)`t$short`t$hash"
}
$checksumsPath = Join-Path $work 'checksums.txt'
$checksumLines | Set-Content $checksumsPath -Encoding UTF8

# ---------------------------------------------------------------- 4. changelog vs previous release
$prevTag = $maxTag
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
# NVIDIA RTX OTA $tag

Exported from the **newest available feed** - per-component winner across NGX OTA
staging/production and the official Streamline SDK releases
([NVIDIA-RTX/Streamline](https://github.com/NVIDIA-RTX/Streamline)). Every exported DLL is a
valid PE/MZ image. Authenticode status is recorded for transparency; OTA payloads are also
SHA-256-verified against NVIDIA's published sidecars.

| Component | This release | Source |
|---|---|---|
| DLSS (SR / RR / FG) | **$dlssVer** | $dlssSource |
| Streamline plugins | **$slVer** | $slSource |

Feeds compared: staging ``$(if ($feedState['staging']) { $feedState['staging'] } else { 'n/a' })`` |
production ``$(if ($feedState['production']) { $feedState['production'] } else { 'n/a' })`` |
Streamline SDK ``$(if ($feedState['sdk']) { $feedState['sdk'] } else { 'n/a' })``
Public SDK (reference): DLSS $ghDlss, Streamline $ghSl

## Changelog

"@
if ($signatureRows.Count) {
    $notes += "`n## Signature status warnings`n`n" + ($signatureRows -join "`n") + "`n"
}
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
# DLSS 5 Neural Rendering (dlssnr) section when the export produced one
$snrAssets = @(Get-ChildItem $work -Filter 'nvngx_dlssnr*.7z' -ErrorAction SilentlyContinue)
if ($snrAssets.Count -gt 0) {
    $snrNotePath = Join-Path $work 'dlssnr-notes.txt'
    if (Test-Path $snrNotePath) {
        $notes += "`n## DLSS 5 Neural Rendering (dlssnr)`n`n" + ((Get-Content $snrNotePath -Raw) -replace "`r`n", "`n")
    }
}
$fence = '```'
$notes += "`n## Checksums`n`n$fence`n" + ($checksumLines -join "`n") + "`n$fence"
$notes += @"

## Install (per-game / global override)

- ``nvngx_dlss.dll`` -> DLSS Super Resolution, ``nvngx_dlssd.dll`` -> Ray Reconstruction,
  ``nvngx_dlssg.dll`` -> Frame Generation, ``sl.*.dll`` -> Streamline runtime (games using SL).
- Drop next to the game exe (or via DLSS Swapper / NGX override). Flat layout, no subfolders.

> Binaries are NVIDIA-copyrighted, fetched from NVIDIA's own CDN / official SDK releases / explicitly pinned user artifacts for personal use.
"@
$notesPath = Join-Path $work 'release-notes.md'
$notes | Set-Content $notesPath -Encoding UTF8

# ---------------------------------------------------------------- 5. publish
Write-Host "==> Creating GitHub release $tag" -ForegroundColor Cyan
gh release create $tag $assetPath $checksumsPath $snrAssets $probeStatePath `
    --repo $Repo `
    --title "NVIDIA RTX OTA $tag" `
    --notes-file $notesPath
if ($LASTEXITCODE -ne 0) { throw 'gh release create failed.' }

Remove-Item $work -Recurse -Force
Write-Host "==> Released: $tag ($assetName)" -ForegroundColor Green
