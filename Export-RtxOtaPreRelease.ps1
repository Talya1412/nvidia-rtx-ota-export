<#
.SYNOPSIS
  Automated NVIDIA RTX OTA pre-release exporter: DLSS (SR/RR/FG) + Streamline plugin DLLs.

.DESCRIPTION
  Pipeline (fully unattended):
    1. Fetch NVIDIA NGX OTA manifest (staging "dev-models" = pre-release channel, or production).
    2. Resolve latest versions of: dlss / dlssd / dlssg (DLSS runtime) and dlss_override
       (Streamline plugin bundle) on that channel.
    3. (Optional) Compare against latest public GitHub SDK releases (NVIDIA/DLSS, NVIDIA-RTX/Streamline).
    4. Download the dlss_override bundle ZIP from NVIDIA's OTA CDN, verify SHA-256 against the
       published .sha256 sidecar, extract all DLLs.
    5. If the per-component [dlss]/[dlssd]/[dlssg] OTA payload is newer than the DLL inside the
       bundle, fetch the raw .bin payload (same bytes NVIDIA serves the driver) and refresh it.
    6. Verify every exported file: MZ PE header + Authenticode signature signed by NVIDIA Corporation.
    7. Optional -Zip: package the output into a single ZIP in the Downloads folder.

  Endpoints (reverse-engineered from NVIDIA's own Streamline OTA client, sl.ota/ota.cpp, registry
  NGXCore\CDNServerType = 0 production / 1 staging; verified live 2026-09-04; see README.md):
    Manifest: https://ngx.download.nvidia.com/{channel}/org/nvidia/team/ngx/models/config/versions/2/files/nvngx_server_config.txt
    Payload : https://ngx.download.nvidia.com/{channel}/org/nvidia/team/ngx/models/{component}/versions/{packed}/files/160_E658700{.bin|.zip}
    packed  = (major -shl 16) -bor (minor -shl 8) -bor patch

.PARAMETER OutDir
  Output folder for the exported DLLs. Default: <Downloads>\nvidia-ota-prerelease-<yyyyMMdd-HHmm>.

.PARAMETER Zip
  Also package OutDir into a single ZIP next to it.

.PARAMETER Channel
  Staging (default, pre-release — runs ahead of production) or Production (what the driver serves normally).

.PARAMETER SkipGitHubCheck
  Skip the GitHub latest-release comparison (offline / rate-limit friendly).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -Zip
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [switch]$Zip,
    [ValidateSet('Staging', 'Production')]
    [string]$Channel = 'Staging',
    [switch]$SkipGitHubCheck
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ChannelRoots = @{
    Staging    = 'dev-models'
    Production = '3e933c08-ea30-45ae-93d1-5114edf9c3b9'
}
$BaseUrl = "https://ngx.download.nvidia.com/$($ChannelRoots[$Channel])/org/nvidia/team/ngx/models"
$ManifestUrl = "$BaseUrl/config/versions/2/files/nvngx_server_config.txt"
$SignerPattern = 'NVIDIA Corporation'
$GenericPayload = '160_E658700'

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

function Get-OtaManifest([string]$Url) {
    Get-UrlText $Url
}

function Get-OtaSectionVersion([string]$Manifest, [string]$Section) {
    $body = [regex]::Match($Manifest, "(?ms)^\[$([regex]::Escape($Section))\]\s*(.*?)(?=^\[|\z)")
    if (-not $body.Success) { return $null }
    $v = [regex]::Match($body.Groups[1].Value, 'app_E65870[03]\s*=\s*([0-9]+(?:\.[0-9]+)+)')
    if ($v.Success) { return $v.Groups[1].Value }
    return $null
}

function ConvertTo-PackedVersion([string]$Version) {
    $p = $Version.Split('.')
    $maj = [int]$p[0]; $min = if ($p.Length -gt 1) { [int]$p[1] } else { 0 }; $pat = if ($p.Length -gt 2) { [int]$p[2] } else { 0 }
    return ($maj -shl 16) -bor ($min -shl 8) -bor $pat
}

function Get-FileSha256([string]$Path) {
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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

function Get-FileMajorMinorPatch([string]$Path) {
    $v = (Get-Item $Path).VersionInfo.FileVersion
    $p = ($v -replace '[^0-9.]', '').Split('.')
    return ('{0}.{1}.{2}' -f $p[0], $p[1], $p[2])
}

function Compare-OtaNewer([string]$A, [string]$B) {
    # true when $A is strictly newer than $B
    try { return ([version]$A -gt [version]$B) } catch { return $false }
}

function Get-GitHubLatestTag([string]$Repo) {
    try {
        return (Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -TimeoutSec 20).tag_name
    } catch {
        return 'unavailable'
    }
}

# ---------------------------------------------------------------- pipeline
Write-Step "Channel: $Channel ($($ChannelRoots[$Channel]))"
$manifest = Get-OtaManifest $ManifestUrl
$verDlss   = Get-OtaSectionVersion $manifest 'dlss'
$verDlssd  = Get-OtaSectionVersion $manifest 'dlssd'
$verDlssg  = Get-OtaSectionVersion $manifest 'dlssg'
$verSl     = Get-OtaSectionVersion $manifest 'dlss_override'
if (-not ($verDlss -and $verDlssd -and $verDlssg -and $verSl)) {
    throw "Manifest incomplete: dlss=$verDlss dlssd=$verDlssd dlssg=$verDlssg dlss_override=$verSl"
}
Write-Info "DLSS (SR/RR/FG): $verDlss / $verDlssd / $verDlssg"
Write-Info "Streamline override bundle: $verSl"

if (-not $SkipGitHubCheck) {
    Write-Step 'Latest public GitHub SDK releases (for reference)'
    $ghDlss = Get-GitHubLatestTag 'NVIDIA/DLSS'
    $ghSl   = Get-GitHubLatestTag 'NVIDIA-RTX/Streamline'
    Write-Info "NVIDIA/DLSS            -> $ghDlss"
    Write-Info "NVIDIA-RTX/Streamline  -> $ghSl"
    if ($ghDlss -match 'v?310\.') {
        $ghNum = $ghDlss -replace '^v', ''
        if (Compare-OtaNewer $verDlss $ghNum) {
            Write-Info "OTA $Channel ($verDlss) is NEWER than public SDK ($ghNum) => pre-release."
        }
    }
}

Write-Step "Downloading dlss_override OTA bundle (Streamline $verSl + bundled DLSS DLLs)"
$slPacked = ConvertTo-PackedVersion $verSl
$bundleUrl = "$BaseUrl/dlss_override/versions/$slPacked/files/${GenericPayload}.zip"
$bundleSidecar = "$bundleUrl.sha256"
$tmpZip = Join-Path $env:TEMP "nvngx_ota_bundle_$slPacked.zip"
Invoke-WebRequest -Uri $bundleUrl -OutFile $tmpZip -UseBasicParsing
if (-not (Test-SidecarSha256 $tmpZip $bundleSidecar)) { throw 'dlss_override bundle failed SHA-256 sidecar verification.' }
Write-Info "Bundle verified: $(Get-FileSha256 $tmpZip)"

Write-Step 'Extracting + verifying DLLs'
if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$tmpExtract = Join-Path $env:TEMP "nvngx_ota_extract_$slPacked"
if (Test-Path $tmpExtract) { Remove-Item $tmpExtract -Recurse -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $tmpExtract)
$payloadDir = Get-ChildItem $tmpExtract -Directory | Select-Object -First 1
Get-ChildItem $payloadDir.FullName -Filter '*.dll' | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $OutDir $_.Name) -Force
}
Remove-Item $tmpExtract -Recurse -Force
Remove-Item $tmpZip -Force

# Refresh DLSS DLLs when the per-component OTA payload ([dlss]/[dlssd]/[dlssg]) is newer
$components = @(
    @{ Section = 'dlss';  Dll = 'nvngx_dlss.dll'  },
    @{ Section = 'dlssd'; Dll = 'nvngx_dlssd.dll' },
    @{ Section = 'dlssg'; Dll = 'nvngx_dlssg.dll' }
)
foreach ($c in $components) {
    $manifestVer = (Get-Variable -Name ("ver" + $c.Section)).Value
    $dllPath = Join-Path $OutDir $c.Dll
    if (-not (Test-Path $dllPath)) {
        Write-Warn2 "$($c.Dll) missing from bundle; fetching raw payload for $($manifestVer)."
        $needFetch = $true
    } else {
        $dllVer = Get-FileMajorMinorPatch $dllPath
        $needFetch = Compare-OtaNewer $manifestVer $dllVer
        if ($needFetch) { Write-Info "$($c.Section): manifest $manifestVer > bundle DLL $dllVer - refreshing from raw payload." }
    }
    if ($needFetch) {
        $packed = ConvertTo-PackedVersion $manifestVer
        $binUrl = "$BaseUrl/$($c.Section)/versions/$packed/files/${GenericPayload}.bin"
        $tmpBin = Join-Path $env:TEMP "$($c.Dll).ota.bin"
        Invoke-WebRequest -Uri $binUrl -OutFile $tmpBin -UseBasicParsing
        if (-not (Test-SidecarSha256 $tmpBin "$binUrl.sha256")) { throw "$($c.Section) payload failed SHA-256 sidecar verification." }
        Copy-Item $tmpBin $dllPath -Force
        Remove-Item $tmpBin -Force
    }
}

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
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = "$OutDir.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($OutDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    $z = Get-Item $zipPath
    Write-Info "$($z.FullName) - $([math]::Round($z.Length / 1MB, 1)) MB"
}

Write-Step 'DONE'
Write-Info "Output: $OutDir"
