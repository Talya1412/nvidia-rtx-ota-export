<#
.SYNOPSIS
  Automated NVIDIA RTX exporter: newest DLSS (SR/RR/FG) + Streamline plugin DLLs across the
  NGX OTA staging/production channels and the official Streamline SDK GitHub releases.

.DESCRIPTION
  Pipeline (fully unattended):
  1. Gather sources: NGX OTA staging + production manifests (whose sl_sdk_0 section carries the
     real Streamline version, so the SL race needs no bundle download), the latest Streamline SDK
     release on GitHub (bin/x64 production DLLs), and the NVIDIA/DLSS GitHub release (official
     nvngx_dlss.dll inside the Windows demo zip). rhi-repo mirror builds (dlss/dlssd/dlssg/
     streamline/dlssnr) are indexed as a hash-verified rescue/redundancy path, never raced.
  2. Download the payloads that are actually needed: the winning OTA channel's dlss_override
     bundle only (plus raw per-component .bin payloads whenever a manifest pin is strictly newer).
  3. Pick the per-component winner (numeric compare; ties prefer the SDK repo, then OTA staging,
     production, then NVIDIA/DLSS): DLSS DLLs from one source, Streamline plugins from another.
  4. Verify: OTA payloads against NVIDIA's published SHA-256 sidecars; every exported file must be
     an MZ PE. Authenticode status is reported, but it is not a hard rejection for allowlisted sources.
  5. dlssnr (DLSS 5 Neural Rendering) as its own newest-wins asset: user-pinned universal build
     (immutable SHA-256) against rhi-repo mirror builds, PE-gated.
  6. Optional -Archive: package the output into a single 7z.

  Endpoints (reverse-engineered from NVIDIA's own Streamline OTA client, sl.ota/ota.cpp, registry
  NGXCore\CDNServerType = 0 production / 1 staging; verified live 2026-09-04; see README.md):
    Manifest: https://ngx.download.nvidia.com/{channel}/org/nvidia/team/ngx/models/config/versions/2/files/nvngx_server_config.txt
    Payload : https://ngx.download.nvidia.com/{channel}/org/nvidia/team/ngx/models/{component}/versions/{packed}/files/160_E658700{.bin|.zip}
    packed  = (major -shl 16) -bor (minor -shl 8) -bor patch
    SDK     : https://github.com/NVIDIA-RTX/Streamline/releases (asset streamline-sdk-v*.zip)
    DLSS    : https://github.com/NVIDIA/DLSS/releases (asset ngx_dlss_demo_windows.zip)
    Mirror  : https://github.com/RankFTW/rhi-repo/releases (dlss-/dlssd-/dlssg-/streamline-/dlssnr-)

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
$securityPsd1 = $null
if (Test-WindowsHost) {
    $securityPsd1 = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
}
try { if ($securityPsd1) { Import-Module $securityPsd1 -ErrorAction Stop } } catch { Import-Module 'Microsoft.PowerShell.Security' -ErrorAction SilentlyContinue }

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
    if (Test-WindowsHost) {
        try {
            $sig = Get-AuthenticodeSignature -FilePath $Path
            $status = [string]$sig.Status
            if ($sig.SignerCertificate) { $signer = [string]$sig.SignerCertificate.Subject }
        } catch { }
    } else {
        $status = 'Unavailable (non-Windows)'
    }
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
$wantDlssRepo    = (-not $SkipGitHubCheck) -and ($Channel -eq 'Newest')

function Get-OtaChannelState([string]$Ch) {
    try { $m = Get-UrlText "$(Get-ChannelBaseUrl $Ch)/$ManifestPath" }
    catch { Write-Warn2 "$Ch OTA manifest unreachable: $($_.Exception.Message)"; return $null }
    $o = @{
        Dlss   = Get-OtaSectionVersion $m 'dlss'
        Dlssd  = Get-OtaSectionVersion $m 'dlssd'
        Dlssg  = Get-OtaSectionVersion $m 'dlssg'
        Sl     = Get-OtaSectionVersion $m 'dlss_override'
        # sl_sdk_0 carries the real Streamline runtime version. Verified live to equal the
        # sl.common.dll FileVersion inside that channel's dlss_override bundle (2.14.0 staging /
        # 2.12.128 production), so the SL race runs on manifest pins alone and only the winning
        # channel's bundle is ever downloaded.
        SlSdk  = Get-OtaSectionVersion $m 'sl_sdk_0'
        Dlssnr = Get-OtaSectionVersion $m 'dlssnr'
    }
    if (-not ($o.Dlss -and $o.Dlssd -and $o.Dlssg -and ($o.Sl -or $o.SlSdk))) {
        Write-Warn2 "$Ch manifest incomplete: dlss=$($o.Dlss) dlssd=$($o.Dlssd) dlssg=$($o.Dlssg) dlss_override=$($o.Sl) sl_sdk=$($o.SlSdk) - dropping channel."
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

$sdkSource = $null
if ($wantSdk) {
    Write-Step 'Fetching latest Streamline SDK release (GitHub, redirect probe - no API quota)'
    try {
        $sdkTag = Get-LatestReleaseTagViaRedirect 'NVIDIA-RTX/Streamline'
        if (-not $sdkTag) { throw 'latest tag unreachable via redirect' }
        $sdkAsset = Get-SdkZipAssetName @("streamline-sdk-$sdkTag.zip")
        if (-not $sdkAsset) { $sdkAsset = "streamline-sdk-$sdkTag.zip" }
        $sdkUrl = "https://github.com/NVIDIA-RTX/Streamline/releases/download/$sdkTag/$sdkAsset"
        $tmpSdkZip = Join-Path (Get-TempRoot) 'streamline-sdk-latest.zip'
        $tmpSdkDir = Join-Path (Get-TempRoot) 'streamline-sdk-latest'
        if (Test-Path $tmpSdkDir) { Remove-Item $tmpSdkDir -Recurse -Force }
        Invoke-WebRequest -Uri $sdkUrl -OutFile $tmpSdkZip -UseBasicParsing
        Expand-ZipSubset $tmpSdkZip 'bin/x64' $tmpSdkDir
        Remove-Item $tmpSdkZip -Force
        $sdkSource = @{
            Tag  = $sdkTag
            Dir  = $tmpSdkDir
            Dlss = ConvertTo-ShortVersion (Get-FilePeVersion (Join-Path $tmpSdkDir 'nvngx_dlss.dll'))
            Sl   = ConvertTo-ShortVersion (Get-FilePeVersion (Join-Path $tmpSdkDir 'sl.common.dll'))
        }
        Write-Info "Streamline SDK ${sdkTag}: DLSS $($sdkSource.Dlss) / SL $($sdkSource.Sl)"
    } catch {
        Write-Warn2 "Streamline SDK source unavailable: $($_.Exception.Message) - continuing without it."
    }
}

# NVIDIA/DLSS GitHub releases ship the official runtime demo (ngx_dlss_demo_windows.zip) with the
# production nvngx_dlss.dll inside bin/ngx_dlss_demo - an official DLSS origin (SR only). Verified
# live: 310.9.1 there is bit-identical to the Streamline SDK and the rhi-repo mirror bytes.
$dlssRepo = $null
if ($wantDlssRepo) {
    Write-Step 'Fetching latest NVIDIA/DLSS release (GitHub, redirect probe - no API quota)'
    try {
        $dlssTag = Get-LatestReleaseTagViaRedirect 'NVIDIA/DLSS'
        if (-not $dlssTag) { throw 'latest tag unreachable via redirect' }
        $demoUrl = "https://github.com/NVIDIA/DLSS/releases/download/$dlssTag/ngx_dlss_demo_windows.zip"
        $tmpDemoZip = Join-Path (Get-TempRoot) 'dlss-demo-latest.zip'
        $tmpDemoDir = Join-Path (Get-TempRoot) 'dlss-demo-latest'
        if (Test-Path $tmpDemoDir) { Remove-Item $tmpDemoDir -Recurse -Force }
        Invoke-WebRequest -Uri $demoUrl -OutFile $tmpDemoZip -UseBasicParsing
        Expand-ZipSubset $tmpDemoZip 'DLSS_Sample_App/bin/ngx_dlss_demo' $tmpDemoDir
        Remove-Item $tmpDemoZip -Force
        $dlssRepo = @{
            Tag  = $dlssTag
            Dir  = $tmpDemoDir
            Dlss = ConvertTo-ShortVersion (Get-FilePeVersion (Join-Path $tmpDemoDir 'nvngx_dlss.dll'))
        }
        Write-Info "NVIDIA/DLSS ${dlssTag}: DLSS $($dlssRepo.Dlss) (SR only)"
    } catch {
        Write-Warn2 "NVIDIA/DLSS source unavailable: $($_.Exception.Message) - continuing without it."
    }
}

# rhi-repo mirrors: exact re-hosts of official builds (verified bit-identical for dlss/dlssd/
# dlssg/streamline), newest-first per section. They are NOT raced against official feeds - they
# only serve as a rescue path when an official download fails, and only after the fetched bytes
# match a trusted pin (OTA SHA-256 sidecar or the previous release's checksums). Enumeration
# uses the git protocol (git ls-remote) - zero API quota; the REST API is only a fallback.
$mirrors = @{}
if (-not $SkipGitHubCheck) {
    try {
        $rhiTags = Get-RhiTagsViaGit
        if (-not $rhiTags) {
            $rhiRels = Get-GitHubJson 'repos/RankFTW/rhi-repo/releases?per_page=100'
            $rhiTags = @($rhiRels) | ForEach-Object { $_.tag_name }
        }
        foreach ($sec in 'dlss', 'dlssd', 'dlssg', 'streamline', 'dlssnr') {
            $mirrors[$sec] = @(Get-RhiMirrorBuilds @($rhiTags) $sec)
        }
        Write-Info "rhi-repo mirrors: dlss=$(@($mirrors['dlss']).Count) dlssd=$(@($mirrors['dlssd']).Count) dlssg=$(@($mirrors['dlssg']).Count) streamline=$(@($mirrors['streamline']).Count) dlssnr=$(@($mirrors['dlssnr']).Count)"
    } catch {
        Write-Warn2 "rhi-repo mirror index unavailable: $($_.Exception.Message) - rescue path disabled."
    }
}

# Mirrors are deliberately NOT part of the winner race: a mirror can never legitimately be newer
# than the official feed it re-hosts, and an unverifiable mirror must not ship. Winner selection
# uses official sources only; mirrors are consulted afterwards, per file, when an official fetch fails.
$candidates = @()
foreach ($ch in 'Staging', 'Production') {
    if ($ota.ContainsKey($ch)) {
        $candidates += @{ Source = "ota-$($ch.ToLowerInvariant())"; Dlss = $ota[$ch].Dlss; Sl = if ($ota[$ch].SlSdk) { $ota[$ch].SlSdk } else { $ota[$ch].Sl } }
    }
}
if ($sdkSource) { $candidates += @{ Source = 'sdk-streamline'; Dlss = $sdkSource.Dlss; Sl = $sdkSource.Sl } }
if ($dlssRepo)  { $candidates += @{ Source = 'github-dlss';    Dlss = $dlssRepo.Dlss;  Sl = $null } }
if (-not $candidates) { throw 'No usable source (OTA, Streamline SDK and NVIDIA/DLSS all unavailable).' }
$winners = Select-ComponentWinners $candidates
Write-Step "Winners: DLSS $($winners.DlssVersion) <- $($winners.DlssSource) | SL $($winners.SlVersion) <- $($winners.SlSource)"

# The SL winner's payload becomes the base set, so only that channel's bundle is downloaded.
$baseChannel = $null
if ($winners.SlSource -eq 'ota-staging') { $baseChannel = 'Staging' }
elseif ($winners.SlSource -eq 'ota-production') { $baseChannel = 'Production' }

function Get-Sha256Sidecar([string]$SidecarUrl) {
    # NVIDIA publishes a bare lowercase digest (64 bytes, no newline) next to each payload.
    try {
        $text = (Get-UrlText $SidecarUrl).Trim()
        $expected = ($text -split '\s+')[0].ToLowerInvariant()
        if ($expected -match '^[0-9a-f]{64}$') { return $expected }
    } catch { }
    return $null
}

# Mirror rescue for one mirrored component zip: fetch, then accept ONLY when the contained DLL
# hashes to the trusted pin ($TrustedSha) - a mirror without a matching pin is never used.
function Get-MirrorDll([object[]]$Candidates, [string]$DllName, [string]$TrustedSha, [string]$DestPath) {
    foreach ($cand in @($Candidates)) {
        if (-not $cand) { continue }
        $tmpZip = Join-Path (Get-TempRoot) "mirror-$($cand.Tag).zip"
        $tmpDir = Join-Path (Get-TempRoot) "mirror-$($cand.Tag)"
        try {
            Invoke-WebRequest -Uri $cand.DownloadUrl -OutFile $tmpZip -UseBasicParsing
            Expand-ZipSubset $tmpZip '' $tmpDir
            $dll = Join-Path $tmpDir $DllName
            if (-not (Test-Path $dll)) {
                Write-Warn2 "mirror $($cand.Tag): $DllName missing in archive."
                continue
            }
            $hash = Get-FileSha256 $dll
            if (-not (Test-Sha256Pin $hash $TrustedSha)) {
                Write-Warn2 "mirror $($cand.Tag): $DllName SHA-256 mismatch (expected $TrustedSha, got $hash) - refused."
                continue
            }
            Copy-Item $dll $DestPath -Force
            Write-Info "mirror $($cand.Tag): $DllName accepted (SHA-256 matches trusted pin)."
            return $true
        } catch {
            Write-Warn2 "mirror $($cand.Tag): $DllName fetch failed ($($_.Exception.Message))."
        } finally {
            if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force }
            if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
        }
    }
    return $false
}

# mirrored Streamline sets are NOT a rescue path: a set whose DLLs could be verified against
# known-good hashes is by definition a re-ship of an already-released version (which the publish
# gate blocks anyway), and an unverifiable newer set must never ship. An official bundle/SDK
# failure therefore fails the run and is retried on the next poll.

# ---------------------------------------------------------------- compose export
if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$sources = @(
    "dlss=$($winners.DlssVersion)=$($winners.DlssSource)",
    "sl=$($winners.SlVersion)=$($winners.SlSource)"
)
foreach ($ch in 'Staging', 'Production') {
    if ($ota.ContainsKey($ch)) { $sources += "$($ch.ToLowerInvariant())=$($ota[$ch].Dlss)/$($ota[$ch].SlSdk)" }
}
if ($sdkSource) { $sources += "sdk=$($sdkSource.Sl)" }
if ($dlssRepo)  { $sources += "dlss-repo=$($dlssRepo.Dlss)" }
Set-Content -Path (Join-Path $OutDir 'export-sources.txt') -Value $sources -Encoding Ascii

# base set = the SL winner's payload. For OTA winners that is the channel's sl_sdk_0 payload
# (~10 MB, NVIDIA CDN, .sha256 sidecar) - verified live to carry the byte-identical sl.* set the
# dlss_override bundle ships (9/9 hashes). The heavy bundle stays as a fallback for the rare case
# the sl_sdk payload is unreachable. The DLSS trio arrives via the DLSS winner overlay or the raw
# .bin refresh below (both sidecar-verified) and is never duplicated here.
if ($winners.SlSource -eq 'sdk-streamline') {
    Copy-Item (Join-Path $sdkSource.Dir '*.dll') $OutDir -Force
} elseif ($baseChannel) {
    $o = $ota[$baseChannel]
    $slPin = if ($o.SlSdk) { $o.SlSdk } else { $o.Sl }
    $packedSdk = ConvertTo-PackedVersion $slPin
    $slsdkUrl = "$(Get-ChannelBaseUrl $baseChannel)/sl_sdk_0/versions/$packedSdk/files/160_E658703.zip"
    Write-Step "Downloading $baseChannel sl_sdk_0 payload (pin $slPin)"
    $tmpSlsdkZip = Join-Path (Get-TempRoot) "nvngx_slsdk_$packedSdk.zip"
    $baseReady = $false
    try {
        Invoke-WebRequest -Uri $slsdkUrl -OutFile $tmpSlsdkZip -UseBasicParsing
        if (-not (Test-SidecarSha256 $tmpSlsdkZip "$slsdkUrl.sha256")) { throw 'sl_sdk_0 payload failed SHA-256 sidecar verification.' }
        # payload entries live under the 160_E658703/ subdirectory (like the SDK zip's bin/x64)
        Expand-ZipSubset $tmpSlsdkZip '160_E658703' $OutDir
        Write-Info "$baseChannel sl_sdk_0 payload extracted (SL $slPin, sidecar-verified)."
    } catch {
        Write-Warn2 "$baseChannel sl_sdk_0 payload unavailable: $($_.Exception.Message) - falling back to the dlss_override bundle."
    } finally {
        if (Test-Path $tmpSlsdkZip) { Remove-Item $tmpSlsdkZip -Force }
    }
    if (-not $baseReady) {
        $packed = ConvertTo-PackedVersion $o.Sl
        $tmpZip = Join-Path (Get-TempRoot) "nvngx_ota_bundle_$packed.zip"
        $url = "$(Get-ChannelBaseUrl $baseChannel)/dlss_override/versions/$packed/files/${GenericPayload}.zip"
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing
            if (-not (Test-SidecarSha256 $tmpZip "$url.sha256")) { throw "$baseChannel dlss_override bundle failed SHA-256 sidecar verification." }
            $dir = Join-Path (Get-TempRoot) "nvngx_ota_extract_$packed"
            if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
            [System.IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $dir)
            $payload = Get-ChildItem $dir -Directory | Select-Object -First 1
            Copy-Item (Join-Path $payload.FullName '*.dll') $OutDir -Force
            Remove-Item $dir -Recurse -Force
            Write-Info "$baseChannel dlss_override bundle extracted (SL pin $($o.Sl))."
        } catch {
            throw "SL winner $($winners.SlSource) $($winners.SlVersion): sl_sdk payload and dlss_override bundle both failed - $($_.Exception.Message)"
        } finally {
            if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force }
        }
    }
}
# DLSS fix-up: the DLSS winner's DLLs overlay the base set whenever they come from another source

# invariant: the base set must contain the SL winner's runtime - a silently empty base set
# (e.g. an extraction that matched no entries) would otherwise ship a half-valid export
if (-not (Test-Path (Join-Path $OutDir 'sl.common.dll'))) {
    throw 'Base set incomplete: sl.common.dll missing after SL payload composition.'
}
if ($winners.DlssSource -eq 'sdk-streamline' -and $winners.SlSource -ne 'sdk-streamline') {
    foreach ($dll in 'nvngx_dlss.dll', 'nvngx_dlssd.dll', 'nvngx_dlssg.dll') {
        Copy-Item (Join-Path $sdkSource.Dir $dll) (Join-Path $OutDir $dll) -Force
    }
    Write-Info 'DLSS DLLs taken from the Streamline SDK (newer than the OTA set).'
} elseif ($winners.DlssSource -eq 'github-dlss') {
    Copy-Item (Join-Path $dlssRepo.Dir 'nvngx_dlss.dll') (Join-Path $OutDir 'nvngx_dlss.dll') -Force
    Write-Info 'DLSS Super Resolution taken from the NVIDIA/DLSS GitHub demo release.'
}

# payload dirs are consumed by the composition above - clean them up only now
if ($sdkSource -and (Test-Path $sdkSource.Dir)) { Remove-Item $sdkSource.Dir -Recurse -Force }
if ($dlssRepo -and (Test-Path $dlssRepo.Dir)) { Remove-Item $dlssRepo.Dir -Recurse -Force }

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
            $needFetch = Compare-OtaNewer $pin (ConvertTo-ShortVersion (Get-FilePeVersion $dllPath))
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
                $tmpBin = Join-Path (Get-TempRoot) "$($c.Dll).ota.bin"
                try {
                    Invoke-WebRequest -Uri $binUrl -OutFile $tmpBin -UseBasicParsing
                    if (-not (Test-SidecarSha256 $tmpBin "$binUrl.sha256")) { throw 'payload failed SHA-256 sidecar verification.' }
                    Copy-Item $tmpBin $dllPath -Force
                } catch {
                    # Rescue: a mirrored build of the same version, accepted only when the fetched
                    # DLL hashes to NVIDIA's published sidecar digest for this exact payload.
                    Write-Warn2 "$ch/$($c.Section) raw payload unavailable ($($_.Exception.Message)) - trying rhi-repo mirror."
                    $trustedSha = Get-Sha256Sidecar "$binUrl.sha256"
                    if (-not $trustedSha) { throw "$ch/$($c.Section) payload failed and no sidecar digest is available to verify a mirror." }
                    if (-not (Get-MirrorDll $mirrors[$c.Section] $c.Dll $trustedSha $dllPath)) {
                        throw "$ch/$($c.Section) payload unavailable and no mirror build matched the sidecar digest."
                    }
                } finally {
                    if (Test-Path $tmpBin) { Remove-Item $tmpBin -Force }
                }
            }
        }
    }
}
# dlssnr (DLSS 5 Neural Rendering) ships as its own per-GPU asset, selected newest-wins across
# the user-pinned universal build and the rhi-repo mirror builds. NVIDIA publishes no official
# feed for this component any more (its OTA section is gone from both channels), so the PE gate
# plus the recorded SHA-256 is the integrity control: the pinned build additionally must match
# its immutable hash. Candidates are tried newest-first; a failing candidate is skipped and the
# next one is used, so the newest *valid* build wins.
$dlssnrNote = ''
if ($Channel -eq 'Newest' -and -not $SkipGitHubCheck) {
    Write-Step 'Resolving dlssnr (newest PE-valid build across the pinned universal asset and rhi-repo mirrors)'
    $unverifiedSpec = Get-UnverifiedDlssnrSpec
    $snrCandidates = @(@{ Tag = 'pinned-universal'; Version = $unverifiedSpec.Version; SortVersion = $unverifiedSpec.Version; Order = 0; Kind = 'pinned'; Spec = $unverifiedSpec })
    $order = 0
    foreach ($m in @($mirrors['dlssnr'])) {
        if (-not $m) { continue }
        $order++
        $snrCandidates += @{ Tag = $m.Tag; Version = $m.Version; SortVersion = $m.SortVersion; Order = $order; Kind = 'mirror'; Cand = $m }
    }
    $snrOrdered = @($snrCandidates | Sort-Object -Property @{ Expression = { [version]$_.SortVersion }; Descending = $true },
                                                @{ Expression = { $_.Order } })
    $snrAccepted = $null
    $snrRejected = @()
    foreach ($cand in $snrOrdered) {
        $ext = if ($cand.Kind -eq 'pinned') { '.7z' } else { '.zip' }
        $tmpZip = Join-Path (Get-TempRoot) ("dlssnr-" + ($cand.Tag -replace '[^A-Za-z0-9.-]', '_') + $ext)
        $tmpDir = Join-Path (Get-TempRoot) ("dlssnr-" + ($cand.Tag -replace '[^A-Za-z0-9.-]', '_'))
        try {
            $sourceUrl = if ($cand.Kind -eq 'pinned') { $cand.Spec.Url } else { $cand.Cand.DownloadUrl }
            Invoke-WebRequest -Uri $sourceUrl -OutFile $tmpZip -UseBasicParsing
            if ($cand.Kind -eq 'pinned') { Expand-7zArchive $tmpZip $tmpDir } else { Expand-ZipSubset $tmpZip '' $tmpDir }
            $snrDll = Join-Path $tmpDir 'nvngx_dlssnr.dll'
            if (-not (Test-Path $snrDll)) { throw 'nvngx_dlssnr.dll missing in archive' }
            $snrHash = Get-FileSha256 $snrDll
            if ($cand.Kind -eq 'pinned' -and -not (Test-Sha256Pin $snrHash $cand.Spec.Sha256)) {
                throw "pinned universal DLL SHA-256 mismatch: expected $($cand.Spec.Sha256), got $snrHash"
            }
            $verification = Get-DllVerification $snrDll
            if (-not $verification.Accepted) { throw 'not a valid PE image' }
            $candVersion = ConvertTo-ShortVersion (Get-FilePeVersion $snrDll)
            $stage = Join-Path (Get-TempRoot) ('dlssnr-stage-' + ($cand.Tag -replace '[^A-Za-z0-9.-]', '_'))
            if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            Copy-Item $snrDll (Join-Path $stage 'nvngx_dlssnr.dll') -Force
            $archiveName = if ($cand.Kind -eq 'pinned') { $cand.Spec.AssetName } else { "nvngx_dlssnr_$($cand.Version).7z" }
            New-7zArchive (Join-Path $OutDir $archiveName) (Join-Path $stage '*.dll') | Out-Null
            Remove-Item $stage -Recurse -Force
            if ($cand.Kind -eq 'pinned') {
                $dlssnrNote += "- ``$archiveName`` (user-pinned universal build, version $candVersion): **$($verification.Label)**; exact DLL SHA-256 ``$snrHash`` matches the immutable pin. Source: ``$($cand.Spec.Source)``.`n"
                Write-Info "dlssnr: pinned universal build selected (SHA-256 pin verified)."
            } else {
                $dlssnrNote += "- ``$archiveName`` (mirror tag ``$($cand.Tag)``): **$($verification.Label)**; DLL SHA-256 ``$snrHash``. Selected as the newest available build.`n"
                Write-Info "dlssnr: newest mirror build $($cand.Tag) selected (PE-valid)."
            }
            $snrAccepted = $cand
            break
        } catch {
            Write-Warn2 "dlssnr candidate $($cand.Tag) rejected: $($_.Exception.Message)"
            $snrRejected += "- ``$($cand.Tag)``: rejected ($($_.Exception.Message))."
        } finally {
            if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force }
            if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
        }
    }
    if (-not $snrAccepted) {
        Write-Warn2 'No usable dlssnr build found - shipping the main set without it.'
        $dlssnrNote += "- No usable dlssnr build (all candidates rejected).`n"
    } elseif ($snrAccepted.Kind -eq 'mirror' -and (Compare-OtaNewer $snrAccepted.SortVersion $unverifiedSpec.Version)) {
        $dlssnrNote += "- The pinned universal build ($($unverifiedSpec.Version)) is still available unchanged; this release ships the newer build above.`n"
    }
    foreach ($line in $snrRejected) { $dlssnrNote += "$line`n" }
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
        Version  = Get-FilePeVersion $_.FullName
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
