<#
.SYNOPSIS
  Automated NVIDIA RTX exporter: newest DLSS (SR/RR/FG) + Streamline plugin DLLs across the
  NGX OTA staging/production channels and the official Streamline SDK GitHub releases.

.DESCRIPTION
  Pipeline (fully unattended):
  1. Gather sources: NGX OTA staging + production manifests, plus the latest Streamline SDK
     release on GitHub (its bin/x64 production DLLs carry both DLSS and Streamline builds).
  2. Download each source's payload: the OTA dlss_override bundle per channel (production's
     only when its pin beats staging's - otherwise OTA is served via raw per-component
     payloads), and the SDK zip (bin/x64 only).
  3. Pick the per-component winner (numeric compare; ties prefer the SDK repo): DLSS DLLs
     from one source, Streamline plugins from another - always the newest available of each.
  4. Verify: OTA payloads against NVIDIA's published SHA-256 sidecars; every exported file must be
     an MZ PE. Authenticode status is reported, but it is not a hard rejection for allowlisted sources.
5. Optional -Archive: package the output into a single 7z.

  Endpoints (reverse-engineered from NVIDIA's own Streamline OTA client, sl.ota/ota.cpp, registry
  NGXCore\CDNServerType = 0 production / 1 staging; verified live 2026-09-04; see README.md):
    Manifest: https://ngx.download.nvidia.com/{channel}/org/nvidia/team/ngx/models/config/versions/2/files/nvngx_server_config.txt
    Payload : https://ngx.download.nvidia.com/{channel}/org/nvidia/team/ngx/models/{component}/versions/{packed}/files/160_E658700{.bin|.zip}
    packed  = (major -shl 16) -bor (minor -shl 8) -bor patch
    SDK     : https://github.com/NVIDIA-RTX/Streamline/releases (asset streamline-sdk-v*.zip)

.PARAMETER OutDir
  Output folder for the exported DLLs. Default: <Downloads>\nvidia-ota-prerelease-<yyyyMMdd-HHmm>.

.PARAMETER Archive
  Also package OutDir into a single 7z next to it.

.PARAMETER Channel
  Newest (default) tracks every source; Sdk = Streamline SDK GitHub releases only;
  Staging / Production = force a single OTA channel.

.PARAMETER SkipGitHubCheck
  Drop the GitHub SDK source (offline / rate-limit friendly) - OTA channels only.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -Archive
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [switch]$Archive,
    [ValidateSet('Newest', 'Sdk', 'Staging', 'Production')]
    [string]$Channel = 'Newest',
    [switch]$SkipGitHubCheck
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'Ota.Common.psm1') -Force
# Host robustness: where PSModulePath carries PowerShell 7 dirs, by-name autoloading of
# Microsoft.PowerShell.Security can resolve to an incompatible copy and fail with
# "type data ... already present" (breaks Get-AuthenticodeSignature). Load the matching copy
# explicitly, by absolute path; fall back to by-name (pwsh / PowerShell 7 loads its own copy).
$securityPsd1 = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
try { Import-Module $securityPsd1 -ErrorAction Stop } catch { Import-Module 'Microsoft.PowerShell.Security' -ErrorAction Stop }

$ChannelRoots = @{
    Staging    = 'dev-models'
    Production = '3e933c08-ea30-45ae-93d1-5114edf9c3b9'
}
$ManifestPath = 'config/versions/2/files/nvngx_server_config.txt'
$GenericPayload = '160_E658700'
function Get-GitHubJson([string]$ApiPath) {
    # gh CLI (authenticated, 5000/h) when available; plain unauth REST (60/h per IP) otherwise.
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
        try {
            $json = gh api $ApiPath 2>$null
            if ($LASTEXITCODE -eq 0 -and $json) { return ($json | ConvertFrom-Json) }
        } catch { }
    }
    return Invoke-RestMethod -Uri "https://api.github.com/$ApiPath" -TimeoutSec 30
}

function Get-ChannelBaseUrl([string]$Ch) {
    "https://ngx.download.nvidia.com/$($ChannelRoots[$Ch])/org/nvidia/team/ngx/models"
}

# Driver's local OTA cache (populated by NVIDIA's own updater, nvngx_update.exe). Probed
# read-only: registry-declared NGXPath (newer drivers) first, then the two default locations.
$OtaCacheRoots = @(
    ((Get-ItemProperty 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore' -ErrorAction SilentlyContinue).NGXPath),
    (Join-Path $env:ProgramData 'NVIDIA\NGX'),
    (Join-Path $env:APPDATA 'NVIDIA\NGX')
) | Where-Object { $_ }
$OtaCacheRoots = @($OtaCacheRoots | Select-Object -Unique)

if (-not $OutDir) {
    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $OutDir = Join-Path $downloads "nvidia-ota-prerelease-$stamp"
}

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "    $Message" }
function Write-Warn2([string]$Message) { Write-Host "    ! $Message" -ForegroundColor Yellow }

function Get-UrlText([string]$Url) {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing
    if ($r.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($r.Content) }
    return [string]$r.Content
}

function Test-SidecarSha256([string]$FilePath, [string]$SidecarUrl) {
    try {
        $text = Get-UrlText $SidecarUrl
        $expected = ($text.Trim() -split '\s+')[0].ToLowerInvariant()
    } catch {
        Write-Warn2 "Sidecar SHA-256 not reachable ($SidecarUrl) - refusing file."
        return $false
    }
    if ($expected -notmatch '^[0-9a-f]{64}$') {
        Write-Warn2 "Sidecar content is not a SHA-256 digest - refusing file."
        return $false
    }
    $actual = Get-FileSha256 $FilePath
    if ($actual -ne $expected) {
        Write-Warn2 "SHA-256 MISMATCH: expected $expected, got $actual - refusing file."
        return $false
    }
    return $true
}

function Get-DllVerification([string]$Path) {
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $magic = New-Object byte[] 2
        [void]$fs.Read($magic, 0, 2)
        if (($magic[0] -ne 0x4D) -or ($magic[1] -ne 0x5A)) {
            Write-Warn2 "$([System.IO.Path]::GetFileName($Path)): not a PE image (MZ header missing)."
            return [pscustomobject]@{ Accepted = $false; Label = 'FAILED (not PE)'; Status = 'NotPE'; Signer = '' }
        }
    } finally { $fs.Dispose() }

    $status = 'Unavailable'
    $signer = ''
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path
        $status = [string]$sig.Status
        if ($sig.SignerCertificate) { $signer = [string]$sig.SignerCertificate.Subject }
    } catch { }
    $policy = Get-DllAcceptancePolicy $true $status $signer
    if ($policy.Label -like 'UNVERIFIED*') {
        Write-Warn2 "$([System.IO.Path]::GetFileName($Path)): signature $status, signer '$signer' - accepted as UNVERIFIED (PE-only policy)."
    }
    return [pscustomobject]@{
        Accepted = [bool]$policy.Accepted
        Label    = $policy.Label
        Status   = $status
        Signer   = $signer
    }
}

# All allowlisted core/SDK DLLs use PE-only acceptance with Authenticode status reported.
# The universal dlssnr asset is additionally protected by its exact SHA-256 pin; arbitrary
# mirror candidates use the same PE-only policy.
# ---------------------------------------------------------------- resolve sources (multi-source newest)
Add-Type -AssemblyName System.IO.Compression.FileSystem

$wantSdk         = (-not $SkipGitHubCheck) -and ($Channel -in @('Newest', 'Sdk'))
$wantStaging     = $Channel -in @('Newest', 'Staging')
$wantProduction  = $Channel -in @('Newest', 'Production')

function Get-OtaChannelState([string]$Ch) {
    try { $m = Get-UrlText "$(Get-ChannelBaseUrl $Ch)/$ManifestPath" }
    catch { Write-Warn2 "$Ch OTA manifest unreachable: $($_.Exception.Message)"; return $null }
    $o = @{
        Dlss   = Get-OtaSectionVersion $m 'dlss'
        Dlssd  = Get-OtaSectionVersion $m 'dlssd'
        Dlssg  = Get-OtaSectionVersion $m 'dlssg'
        Sl     = Get-OtaSectionVersion $m 'dlss_override'
        Dlssnr = Get-OtaSectionVersion $m 'dlssnr'
    }
    if (-not ($o.Dlss -and $o.Dlssd -and $o.Dlssg -and $o.Sl)) {
        Write-Warn2 "$Ch manifest incomplete: dlss=$($o.Dlss) dlssd=$($o.Dlssd) dlssg=$($o.Dlssg) dlss_override=$($o.Sl) - dropping channel."
        return $null
    }
    return $o
}

function Expand-ZipSubset([string]$ZipPath, [string]$EntryPrefix, [string]$DestDir) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    $prefix = if ($EntryPrefix) { $EntryPrefix.Trim('/') + '/' } else { '' }
    $z = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($e in $z.Entries) {
            if (-not $e.FullName.StartsWith($prefix)) { continue }
            $rest = $e.FullName.Substring($prefix.Length)
            if ($rest.Contains('/') -or -not $rest.EndsWith('.dll')) { continue }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $DestDir $rest), $true)
        }
    } finally { $z.Dispose() }
}

$ota = @{}
if ($wantStaging)    { $s = Get-OtaChannelState 'Staging';    if ($s) { $ota['Staging'] = $s } }
if ($wantProduction) { $s = Get-OtaChannelState 'Production'; if ($s) { $ota['Production'] = $s } }
if (($wantStaging -or $wantProduction) -and $ota.Count -eq 0) { throw 'No OTA manifest reachable - aborting.' }

$sdk = $null
if ($wantSdk) {
    Write-Step 'Fetching latest Streamline SDK release (GitHub)'
    try {
        $rel = Get-GitHubJson 'repos/NVIDIA-RTX/Streamline/releases/latest'
        $zipName = Get-SdkZipAssetName (@($rel.assets) | ForEach-Object { $_.name })
        if (-not $zipName) { throw 'latest release has no zip asset' }
        $asset = @($rel.assets) | Where-Object { $_.name -eq $zipName } | Select-Object -First 1
        $tmpSdkZip = Join-Path $env:TEMP 'streamline-sdk-latest.zip'
        $tmpSdkDir = Join-Path $env:TEMP 'streamline-sdk-latest'
        if (Test-Path $tmpSdkDir) { Remove-Item $tmpSdkDir -Recurse -Force }
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpSdkZip -UseBasicParsing
        Expand-ZipSubset $tmpSdkZip 'bin/x64' $tmpSdkDir
        Remove-Item $tmpSdkZip -Force
        $sdk = @{
            Tag  = $rel.tag_name
            Dir  = $tmpSdkDir
            Dlss = ConvertTo-ShortVersion (Get-Item (Join-Path $tmpSdkDir 'nvngx_dlss.dll')).VersionInfo.FileVersion
            Sl   = ConvertTo-ShortVersion (Get-Item (Join-Path $tmpSdkDir 'sl.common.dll')).VersionInfo.FileVersion
        }
        Write-Info "Streamline SDK $($rel.tag_name): DLSS $($sdk.Dlss) / SL $($sdk.Sl)"
    } catch {
        Write-Warn2 "Streamline SDK source unavailable: $($_.Exception.Message) - continuing without it."
    }
}

# OTA bundles: staging always (its real SL version only exists inside the bundle); production
# only when its dlss_override pin beats staging's (only then can it win SL / serve as base).
$needProdBundle = $ota.ContainsKey('Production') -and (
    (-not $ota.ContainsKey('Staging')) -or (Compare-OtaNewer $ota['Production'].Sl $ota['Staging'].Sl))
foreach ($ch in 'Staging', 'Production') {
    if (-not $ota.ContainsKey($ch)) { continue }
    if ($ch -eq 'Production' -and -not $needProdBundle) { continue }
    $o = $ota[$ch]
    $packed = ConvertTo-PackedVersion $o.Sl
    $tmpZip = Join-Path $env:TEMP "nvngx_ota_bundle_$packed.zip"
    $url = "$(Get-ChannelBaseUrl $ch)/dlss_override/versions/$packed/files/${GenericPayload}.zip"
    Write-Step "Downloading $ch dlss_override OTA bundle (pin $($o.Sl))"
    Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing
    if (-not (Test-SidecarSha256 $tmpZip "$url.sha256")) { throw "$ch dlss_override bundle failed SHA-256 sidecar verification." }
    $dir = Join-Path $env:TEMP "nvngx_ota_extract_$packed"
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $dir)
    $payload = Get-ChildItem $dir -Directory | Select-Object -First 1
    $o.Dir     = $payload.FullName
    $o.SlDll   = ConvertTo-ShortVersion (Get-Item (Join-Path $payload.FullName 'sl.common.dll')).VersionInfo.FileVersion
    $o.DlssDll = ConvertTo-ShortVersion (Get-Item (Join-Path $payload.FullName 'nvngx_dlss.dll')).VersionInfo.FileVersion
    Remove-Item $tmpZip -Force
    Write-Info "$ch bundle: DLSS $($o.DlssDll) / SL $($o.SlDll)"
}

$candidates = @()
foreach ($ch in 'Staging', 'Production') {
    if ($ota.ContainsKey($ch) -and $ota[$ch].SlDll) {
        $candidates += @{ Source = "ota-$($ch.ToLowerInvariant())"; Dlss = $ota[$ch].Dlss; Sl = $ota[$ch].SlDll }
    }
}
if ($sdk) { $candidates += @{ Source = 'sdk-streamline'; Dlss = $sdk.Dlss; Sl = $sdk.Sl } }
if (-not $candidates) { throw 'No usable source (OTA and SDK both unavailable).' }
$winners = Select-ComponentWinners $candidates
Write-Step "Winners: DLSS $($winners.DlssVersion) <- $($winners.DlssSource) | SL $($winners.SlVersion) <- $($winners.SlSource)"

# ---------------------------------------------------------------- compose export
if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$sources = @(
    "dlss=$($winners.DlssVersion)=$($winners.DlssSource)",
    "sl=$($winners.SlVersion)=$($winners.SlSource)"
)
foreach ($ch in 'Staging', 'Production') {
    if ($ota.ContainsKey($ch) -and $ota[$ch].SlDll) { $sources += "$($ch.ToLowerInvariant())=$($ota[$ch].Dlss)/$($ota[$ch].SlDll)" }
}
if ($sdk) { $sources += "sdk=$($sdk.Sl)" }
Set-Content -Path (Join-Path $OutDir 'export-sources.txt') -Value $sources -Encoding Ascii

# base set = the SL winner's full payload (production flavor everywhere)
if ($winners.SlSource -eq 'sdk-streamline') {
    Copy-Item (Join-Path $sdk.Dir '*.dll') $OutDir -Force
} else {
    $ch = if ($winners.SlSource -eq 'ota-staging') { 'Staging' } else { 'Production' }
    Copy-Item (Join-Path $ota[$ch].Dir '*.dll') $OutDir -Force
}

# DLSS fix-up: SDK won DLSS but the base set came from an OTA channel
if ($winners.DlssSource -eq 'sdk-streamline' -and $winners.SlSource -ne 'sdk-streamline') {
    foreach ($dll in 'nvngx_dlss.dll', 'nvngx_dlssd.dll', 'nvngx_dlssg.dll') {
        Copy-Item (Join-Path $sdk.Dir $dll) (Join-Path $OutDir $dll) -Force
    }
    Write-Info 'DLSS DLLs taken from the Streamline SDK (newer than the OTA set).'
}

# payload dirs are consumed by the composition above - clean them up only now
foreach ($ch in 'Staging', 'Production') {
    if ($ota.ContainsKey($ch) -and $ota[$ch].Dir) { Remove-Item $ota[$ch].Dir -Recurse -Force }
}

# OTA raw refresh: any reachable OTA manifest pin strictly newer than an exported DLL wins
foreach ($ch in 'Staging', 'Production') {
    if (-not $ota.ContainsKey($ch)) { continue }
    $o = $ota[$ch]
    foreach ($c in @(
        @{ Section = 'dlss';   Dll = 'nvngx_dlss.dll'   },
        @{ Section = 'dlssd';  Dll = 'nvngx_dlssd.dll'  },
        @{ Section = 'dlssg';  Dll = 'nvngx_dlssg.dll'  },
        @{ Section = 'dlssnr'; Dll = 'nvngx_dlssnr.dll' }
    )) {
        $pin = $o[$c.Section]
        if (-not $pin) { continue }
        $dllPath = Join-Path $OutDir $c.Dll
        $needFetch = $false
        if (-not (Test-Path $dllPath)) {
            Write-Warn2 "$($c.Dll) missing from export; $ch serves it at $pin - fetching raw payload."
            $needFetch = $true
        } else {
            $needFetch = Compare-OtaNewer $pin (ConvertTo-ShortVersion (Get-Item $dllPath).VersionInfo.FileVersion)
        }
        if ($needFetch) {
            Write-Info "$ch/$($c.Section): pin $pin > exported DLL - fetching raw payload."
            $packed = ConvertTo-PackedVersion $pin
            $binUrl = "$(Get-ChannelBaseUrl $ch)/$($c.Section)/versions/$packed/files/${GenericPayload}.bin"
            $cached = Find-OtaCachedPayload $OtaCacheRoots $c.Section $packed "${GenericPayload}.bin"
            if ($cached -and (Test-SidecarSha256 $cached "$binUrl.sha256")) {
                Copy-Item $cached $dllPath -Force
                Write-Info "$ch/$($c.Section): served from the driver's local OTA cache (SHA-256 verified against NVIDIA's sidecar)."
            } else {
                $tmpBin = Join-Path $env:TEMP "$($c.Dll).ota.bin"
                Invoke-WebRequest -Uri $binUrl -OutFile $tmpBin -UseBasicParsing
                if (-not (Test-SidecarSha256 $tmpBin "$binUrl.sha256")) { throw "$ch/$($c.Section) payload failed SHA-256 sidecar verification." }
                Copy-Item $tmpBin $dllPath -Force
                Remove-Item $tmpBin -Force
            }
        }
    }
}
if ($sdk -and (Test-Path $sdk.Dir)) { Remove-Item $sdk.Dir -Recurse -Force }

# The user's tested all-RTX DLL is a deliberately hash-pinned exception. It is fetched from a
# release URL available to CI, checked against its immutable DLL SHA-256, labeled UNVERIFIED,
# and kept outside the main DLL set. Mirror fallbacks use the same PE-only policy.
$dlssnrNote = ''
if ($Channel -eq 'Newest' -and -not $SkipGitHubCheck) {
    Write-Step 'Checking dlssnr (pinned universal asset first; PE-only mirror fallback)'
    $unverifiedSpec = Get-UnverifiedDlssnrSpec
    $pinnedArchive = Join-Path $env:TEMP ("pinned-" + $unverifiedSpec.AssetName)
    $pinnedDir = Join-Path $env:TEMP 'dlssnr-pinned-universal'
    $pinnedAssetPath = Join-Path $OutDir $unverifiedSpec.AssetName
    try {
        Invoke-WebRequest -Uri $unverifiedSpec.Url -OutFile $pinnedArchive -UseBasicParsing
        Expand-7zArchive $pinnedArchive $pinnedDir
        $pinnedDll = Join-Path $pinnedDir 'nvngx_dlssnr.dll'
        $pinnedHash = Get-FileSha256 $pinnedDll
        if (-not (Test-Sha256Pin $pinnedHash $unverifiedSpec.Sha256)) {
            throw "pinned universal DLL SHA-256 mismatch: expected $($unverifiedSpec.Sha256), got $pinnedHash"
        }
        $pinnedVerification = Get-DllVerification $pinnedDll
        if (-not $pinnedVerification.Accepted) { throw 'pinned universal dlssnr is not a PE image' }
        $pinnedStage = Join-Path $env:TEMP 'dlssnr-pinned-stage'
        if (Test-Path $pinnedStage) { Remove-Item $pinnedStage -Recurse -Force }
        New-Item -ItemType Directory -Path $pinnedStage -Force | Out-Null
        Copy-Item $pinnedDll (Join-Path $pinnedStage 'nvngx_dlssnr.dll') -Force
        New-7zArchive $pinnedAssetPath (Join-Path $pinnedStage '*.dll') | Out-Null
        Remove-Item $pinnedStage -Recurse -Force
        $dlssnrNote = "- ``$($unverifiedSpec.AssetName)`` (user-pinned universal build, version $($unverifiedSpec.Version)): **UNVERIFIED** Authenticode status; exact DLL SHA-256 ``$pinnedHash`` matches the immutable pin. Source: ``$($unverifiedSpec.Source)``.`n"
        Write-Info "dlssnr universal: pinned SHA-256 verified; publishing $($unverifiedSpec.AssetName)."
    } catch {
        Write-Warn2 "Pinned universal dlssnr unavailable: $($_.Exception.Message) - trying PE-only mirror fallback."
        $dlssnrNote = "- Pinned universal asset unavailable: $($_.Exception.Message).`n"
    } finally {
        if (Test-Path $pinnedArchive) { Remove-Item $pinnedArchive -Force }
        if (Test-Path $pinnedDir) { Remove-Item $pinnedDir -Recurse -Force }
    }

    if (-not (Test-Path $pinnedAssetPath)) {
        try {
            $snrRels = Get-GitHubJson 'repos/RankFTW/rhi-repo/releases?per_page=100'
            $snrCands = @()
            foreach ($r in @($snrRels)) {
                if ($r.tag_name -notmatch '^dlssnr-(.+)$') { continue }
                $snrVer = $Matches[1]
                try { $null = [version]($snrVer -replace '-[A-Za-z0-9.]+$', '') } catch { continue }
                $snrAsset = @($r.assets) | Where-Object { $_.name -eq "nvngx_dlssnr_$snrVer.zip" } | Select-Object -First 1
                if ($snrAsset) { $snrCands += @{ Tag = $r.tag_name; Version = $snrVer; Asset = $snrAsset } }
            }
            $snrOrder = @($snrCands | Sort-Object -Property @{ Expression = { [version]($_.Version -replace '-[A-Za-z0-9.]+$', '') }; Descending = $true })
            $snrChecked = @()
            foreach ($cand in $snrOrder) {
                $snrZip = Join-Path $env:TEMP "dlssnr-$($cand.Version).zip"
                $snrDir = Join-Path $env:TEMP "dlssnr-$($cand.Version)"
                try {
                    Invoke-WebRequest -Uri $cand.Asset.browser_download_url -OutFile $snrZip -UseBasicParsing
                    Expand-ZipSubset $snrZip '' $snrDir
                    $snrDll = Join-Path $snrDir 'nvngx_dlssnr.dll'
                    $verOk = ConvertTo-ShortVersion (Get-Item $snrDll).VersionInfo.FileVersion
                    $snrPassed = (Get-DllVerification $snrDll).Accepted
                    $snrChecked += @{ Tag = $cand.Tag; Version = $verOk; Pass = $snrPassed }
                    if ($snrPassed) {
                        $assetArchive = Join-Path $OutDir "nvngx_dlssnr_$($cand.Version).7z"
                        $snrStage = Join-Path $env:TEMP "dlssnr-stage-$($cand.Version)"
                        if (Test-Path $snrStage) { Remove-Item $snrStage -Recurse -Force }
                        New-Item -ItemType Directory -Path $snrStage -Force | Out-Null
                        Copy-Item $snrDll (Join-Path $snrStage 'nvngx_dlssnr.dll') -Force
                        New-7zArchive $assetArchive (Join-Path $snrStage '*.dll') | Out-Null
                        Remove-Item $snrStage -Recurse -Force
                        $dlssnrNote += "- ``nvngx_dlssnr_$($cand.Version).7z`` (mirror tag ``$($cand.Tag)``): $((Get-DllVerification $snrDll).Label).`n"
                        break
                    } else {
                        Write-Warn2 "dlssnr $($cand.Version) ($($cand.Tag)): rejected because it is not a valid PE image."
                        $dlssnrNote += "- ``$($cand.Tag)``: not a valid PE image - rejected.`n"
                    }
                } catch {
                    Write-Warn2 "dlssnr candidate $($cand.Tag) failed: $($_.Exception.Message)"
                    $dlssnrNote += "- ``$($cand.Tag)``: fetch or validation failed ($($_.Exception.Message)).`n"
                } finally {
                    if (Test-Path $snrZip) { Remove-Item $snrZip -Force }
                    if (Test-Path $snrDir) { Remove-Item $snrDir -Recurse -Force }
                }
            }
            if (@($snrChecked | Where-Object { $_.Pass }).Count -eq 0) { Write-Info 'No PE dlssnr mirror build available - skipped.' }
        } catch {
            Write-Warn2 "dlssnr mirror unreachable: $($_.Exception.Message) - skipped."
        }
    }
}
if ($dlssnrNote) {
    $dlssnrNotePath = Join-Path $OutDir 'dlssnr-notes.txt'
    $dlssnrHeader = "DLSS 5 Neural Rendering (nvngx_dlssnr.dll) - per-GPU artifact, shipped separately from the main DLL set.`n"
    Set-Content -Path $dlssnrNotePath -Value ($dlssnrHeader + $dlssnrNote) -Encoding UTF8
}

Write-Step 'PE validation + signature reporting'
$report = @()
$allAccepted = $true
Get-ChildItem $OutDir -Filter '*.dll' | Sort-Object Name | ForEach-Object {
    $verification = Get-DllVerification $_.FullName
    $ok = $verification.Accepted
    if (-not $ok) { $allAccepted = $false }
    $report += [pscustomobject]@{
        File     = $_.Name
        SizeMB   = [math]::Round($_.Length / 1MB, 1)
        Version  = $_.VersionInfo.FileVersion
        Signed   = $verification.Label
        Sha256   = Get-FileSha256 $_.FullName
    }
}
$report | Format-Table File, SizeMB, Version, Signed -AutoSize
$summaryPath = Join-Path $OutDir 'export-summary.txt'
$report | ForEach-Object { "{0}`t{1}`t{2}`t{3}" -f $_.File, $_.Version, $_.Signed, $_.Sha256 } |
    Set-Content -Path $summaryPath -Encoding UTF8

if (-not $allAccepted) { throw 'One or more exported files failed PE validation - inspect output above.' }

if ($Archive) {
    Write-Step 'Packaging 7z next to the output'
    $archivePath = "$OutDir.7z"
    if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
    New-7zArchive $archivePath (Join-Path $OutDir '*.dll') | Out-Null
    $z = Get-Item $archivePath
    Write-Info "$($z.FullName) - $([math]::Round($z.Length / 1MB, 1)) MB"
}

Write-Step 'DONE'
Write-Info "Output: $OutDir"
