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
  4. Verify: OTA payloads against NVIDIA's published SHA-256 sidecars; every exported file
     must be an MZ PE signed (Valid) by NVIDIA Corporation.
  5. Optional -Zip: package the output into a single ZIP.

  Endpoints (reverse-engineered from NVIDIA's own Streamline OTA client, sl.ota/ota.cpp, registry
  NGXCore\CDNServerType = 0 production / 1 staging; verified live 2026-09-04; see README.md):
    Manifest: https://ngx.download.nvidia.com/{channel}/org/nvidia/team/ngx/models/config/versions/2/files/nvngx_server_config.txt
    Payload : https://ngx.download.nvidia.com/{channel}/org/nvidia/team/ngx/models/{component}/versions/{packed}/files/160_E658700{.bin|.zip}
    packed  = (major -shl 16) -bor (minor -shl 8) -bor patch
    SDK     : https://github.com/NVIDIA-RTX/Streamline/releases (asset streamline-sdk-v*.zip)

.PARAMETER OutDir
  Output folder for the exported DLLs. Default: <Downloads>\nvidia-ota-prerelease-<yyyyMMdd-HHmm>.

.PARAMETER Zip
  Also package OutDir into a single ZIP next to it.

.PARAMETER Channel
  Newest (default) tracks every source; Sdk = Streamline SDK GitHub releases only;
  Staging / Production = force a single OTA channel.

.PARAMETER SkipGitHubCheck
  Drop the GitHub SDK source (offline / rate-limit friendly) - OTA channels only.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -Zip
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [switch]$Zip,
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
$SignerPattern = 'NVIDIA Corporation'
$GenericPayload = '160_E658700'
function Get-ChannelBaseUrl([string]$Ch) {
    "https://ngx.download.nvidia.com/$($ChannelRoots[$Ch])/org/nvidia/team/ngx/models"
}

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

function Test-VerifiedNvidiaDll([string]$Path) {
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $magic = New-Object byte[] 2
        [void]$fs.Read($magic, 0, 2)
        if (($magic[0] -ne 0x4D) -or ($magic[1] -ne 0x5A)) {
            Write-Warn2 "$([System.IO.Path]::GetFileName($Path)): not a PE image (MZ header missing)."
            return $false
        }
    } finally { $fs.Dispose() }

    $sig = Get-AuthenticodeSignature -FilePath $Path
    if (($sig.Status -ne 'Valid') -or ($sig.SignerCertificate.Subject -notmatch $SignerPattern)) {
        Write-Warn2 "$([System.IO.Path]::GetFileName($Path)): signature $($sig.Status), signer '$($sig.SignerCertificate.Subject)'."
        return $false
    }
    return $true
}

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
    $prefix = $EntryPrefix.Trim('/') + '/'
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
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/NVIDIA-RTX/Streamline/releases/latest' -TimeoutSec 30
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
            $tmpBin = Join-Path $env:TEMP "$($c.Dll).ota.bin"
            Invoke-WebRequest -Uri $binUrl -OutFile $tmpBin -UseBasicParsing
            if (-not (Test-SidecarSha256 $tmpBin "$binUrl.sha256")) { throw "$ch/$($c.Section) payload failed SHA-256 sidecar verification." }
            Copy-Item $tmpBin $dllPath -Force
            Remove-Item $tmpBin -Force
        }
    }
}
if ($sdk -and (Test-Path $sdk.Dir)) { Remove-Item $sdk.Dir -Recurse -Force }

Write-Step 'Authenticode + PE verification of exported files'
$report = @()
$allValid = $true
Get-ChildItem $OutDir -Filter '*.dll' | Sort-Object Name | ForEach-Object {
    $ok = Test-VerifiedNvidiaDll $_.FullName
    if (-not $ok) { $allValid = $false }
    $report += [pscustomobject]@{
        File     = $_.Name
        SizeMB   = [math]::Round($_.Length / 1MB, 1)
        Version  = $_.VersionInfo.FileVersion
        Signed   = if ($ok) { 'Valid (NVIDIA)' } else { 'FAILED' }
        Sha256   = Get-FileSha256 $_.FullName
    }
}
$report | Format-Table File, SizeMB, Version, Signed -AutoSize
$summaryPath = Join-Path $OutDir 'export-summary.txt'
$report | ForEach-Object { "{0}`t{1}`t{2}`t{3}" -f $_.File, $_.Version, $_.Signed, $_.Sha256 } |
    Set-Content -Path $summaryPath -Encoding UTF8

if (-not $allValid) { throw 'One or more exported files failed verification - inspect output above.' }

if ($Zip) {
    Write-Step 'Packaging ZIP into Downloads'
    $zipPath = "$OutDir.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($OutDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    $z = Get-Item $zipPath
    Write-Info "$($z.FullName) - $([math]::Round($z.Length / 1MB, 1)) MB"
}

Write-Step 'DONE'
Write-Info "Output: $OutDir"
