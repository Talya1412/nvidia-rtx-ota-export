# Shared, deterministic logic for the NVIDIA RTX OTA exporter + release publisher.
# Network and filesystem I/O stay in the entry scripts; everything here is pure and unit-
# tested (tests/run-tests.ps1); version comparisons are numeric via [version], never
# lexicographic. Exception: the shared tool helpers (pinned 7-Zip resolver, archive helpers,
# redirect/mirror probes) do download + filesystem I/O because both entry scripts use them.

# True when running on Windows (PS 5.1 has no $IsWindows; .NET 4.7.1+ / PS 7 both expose
# RuntimeInformation). Gates the Windows-only bits: Authenticode, registry, Program Files.
function Test-WindowsHost {
    try {
        $ri = [System.Runtime.InteropServices.RuntimeInformation]
        return $ri::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    } catch { return $true }   # ancient .NET without RuntimeInformation is a Windows PowerShell host
}

# Directory temp root, identical on every OS ($env:TEMP does not exist on Linux/macOS).
function Get-TempRoot {
    return [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
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

# PE FileVersion with any separators ("310,9,1,0" / "2.14.1.0") -> "310.9.1".
# Digits only; non-digits become separators (the old comma-DELETING variant merged "310,9,1,0"
# into "310910" and silently broke every version comparison).
function ConvertTo-ShortVersion([string]$FileVersion) {
    $p = @(($FileVersion -replace '[^0-9]', '.').Split('.') | Where-Object { $_ })
    if ($p.Count -eq 0) { return '' }
    $maj = $p[0]; $min = if ($p.Count -gt 1) { $p[1] } else { '0' }; $pat = if ($p.Count -gt 2) { $p[2] } else { '0' }
    return ('{0}.{1}.{2}' -f $maj, $min, $pat)
}

# Returns the driver's locally cached OTA payload for an exact (section, packed version, file)
# triple - models\<section>\versions\<packed>\files\<payload> - under any probe root, or $null.
# READ-ONLY: the cache belongs to NVIDIA's own updater (nvngx_update.exe).
function Find-OtaCachedPayload([string[]]$Roots, [string]$Section, [string]$Packed, [string]$PayloadFile) {
    foreach ($r in @($Roots)) {
        if (-not $r) { continue }
        # forward slashes: valid on Windows, required on Linux/macOS
        $p = "$r/models/$Section/versions/$Packed/files/$PayloadFile"
        if (Test-Path $p) { return $p }
    }
    return $null
}

# Lowercase hex SHA-256 via the .NET API - deliberately NOT the Get-FileHash cmdlet, which
# disappears on hosts where PowerShell module autoloading is broken (observed on real machines).
function Get-FileSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            return ([System.BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant()
        } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

# Cross-platform PE FileVersion. [IO.FileInfo]::VersionInfo is Windows-only (empty on
# Linux/macOS), so parse the PE resource directory: walk header -> section table -> .rsrc
# RVA/file mapping, then inside the mapped window locate UTF-16LE 'VS_VERSION_INFO' and the
# VS_FIXEDFILEINFO signature 0xFEEF04BD, decoding dwFileVersionMS/LS (char i == bytes 2i..2i+1).
# Returns 'maj.min.build', or '' for versionless images (e.g. NvLowLatencyVk.dll).
function Get-FilePeVersion([string]$Path) {
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 0x100 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { return '' }
    $peOff = [BitConverter]::ToInt32($b, 0x3C)
    if ($peOff -lt 0 -or ($peOff + 24) -gt $b.Length) { return '' }
    if ($b[$peOff] -ne 0x50 -or $b[$peOff + 1] -ne 0x45) { return '' }
    $numSections = [BitConverter]::ToUInt16($b, $peOff + 6)
    $optSize = [BitConverter]::ToUInt16($b, $peOff + 20)
    $optOff = $peOff + 24
    if (($optOff + 2) -gt $b.Length) { return '' }
    $magic = [BitConverter]::ToUInt16($b, $optOff)
    $dirOff = if ($magic -eq 0x20B) { $optOff + 112 } elseif ($magic -eq 0x10B) { $optOff + 96 } else { return '' }
    if (($dirOff + 8) -gt $b.Length) { return '' }
    $resRva = [BitConverter]::ToUInt32($b, $dirOff + 16)   # data directory[2] = Resource
    $resSize = [BitConverter]::ToUInt32($b, $dirOff + 20)
    if ($resRva -eq 0 -or $resSize -eq 0) { return '' }
    $secOff = $optOff + $optSize
    $fileOff = -1
    for ($s = 0; $s -lt $numSections; $s++) {
        $o = $secOff + ($s * 40)
        if (($o + 40) -gt $b.Length) { break }
        $va = [BitConverter]::ToUInt32($b, $o + 12)
        $raw = [BitConverter]::ToUInt32($b, $o + 16)
        $ptr = [BitConverter]::ToUInt32($b, $o + 20)
        if ($resRva -ge $va -and $resRva -lt ($va + [Math]::Max([int64]$raw, 1))) { $fileOff = $ptr + ($resRva - $va); break }
    }
    if ($fileOff -lt 0 -or $fileOff -ge $b.Length) { return '' }
    $len = [Math]::Min($resSize, $b.Length - $fileOff)
    if ($len -lt 2) { return '' }
    $chars = [System.Text.Encoding]::Unicode.GetString($b, $fileOff, $len)
    $idx = $chars.IndexOf('VS_VERSION_INFO', [StringComparison]::Ordinal)
    while ($idx -ge 0) {
        $limit = [Math]::Min($idx + 15 + 64, $chars.Length - 1)
        for ($c = $idx + 15; $c -lt $limit; $c++) {
            if ([int]$chars[$c] -eq 0x04BD -and [int]$chars[$c + 1] -eq 0xFEEF) {
                if (($c + 7) -ge $chars.Length) { return '' }   # truncated struct - nothing to decode
                $ms = (([int]$chars[$c + 5] -band 0xFFFF) -shl 16) -bor ([int]$chars[$c + 4] -band 0xFFFF)
                $ls = (([int]$chars[$c + 7] -band 0xFFFF) -shl 16) -bor ([int]$chars[$c + 6] -band 0xFFFF)
                if ($ms -eq 0 -and $ls -eq 0) { return '' }
                return ConvertTo-ShortVersion ('{0}.{1}.{2}.{3}' -f ($ms -shr 16), ($ms -band 0xFFFF), ($ls -shr 16), ($ls -band 0xFFFF))
            }
        }
        $idx = $chars.IndexOf('VS_VERSION_INFO', $idx + 1, [StringComparison]::Ordinal)
    }
    return ''
}

# true when $A is strictly newer than $B
function Compare-OtaNewer([string]$A, [string]$B) {
    try { return ([version]$A -gt [version]$B) } catch { return $false }
}

# dlssnr selection: candidates @{ Tag; Version; Pass }. Returns the newest build whose PE gate
# passed (numeric version compare); $null when none pass. List order breaks version ties (newest
# release first from the GitHub API).
function Select-DlssnrBuild([object[]]$Candidates) {
    $best = $null; $bestV = $null
    foreach ($c in @($Candidates)) {
        if (-not $c -or -not $c.Pass) { continue }
        try { $v = [version]$c.Version } catch { continue }
        if (-not $best -or $v -gt $bestV) { $best = $c.Tag; $bestV = $v }
    }
    return $best
}

# Per-component newest across sources. Candidates: @{ Source; Dlss; Sl } where $Sl may be $null
# (DLSS-only sources, e.g. the NVIDIA/DLSS GitHub demo) - they race for DLSS only, never SL.
# Each winner picked independently (numeric compare). Ties prefer official sources:
# Streamline SDK (GitHub) > OTA staging > OTA production > NVIDIA/DLSS (GitHub) > unknown.
function Select-ComponentWinners([object[]]$Candidates) {
    $priority = @{ 'sdk-streamline' = 0; 'ota-staging' = 1; 'ota-production' = 2; 'github-dlss' = 3 }
    $rank = { if ($priority.ContainsKey($_.Source)) { $priority[$_.Source] } else { 4 } }
    $okDlss = @($Candidates) | Where-Object { $_ -and $_.Source -and $_.Dlss }
    if (-not $okDlss) { throw 'Select-ComponentWinners: no candidates with a DLSS version.' }
    $byDlss = @($okDlss | Sort-Object -Property @{ Expression = { [version]$_.Dlss }; Descending = $true },
                                     @{ Expression = $rank })
    $result = [pscustomobject]@{
        DlssSource  = $byDlss[0].Source
        DlssVersion = $byDlss[0].Dlss
        SlSource    = $null
        SlVersion   = $null
    }
    $okSl = @($Candidates) | Where-Object { $_ -and $_.Source -and $_.Sl }
    if ($okSl) {
        $bySl = @($okSl | Sort-Object -Property @{ Expression = { [version]$_.Sl }; Descending = $true },
                                         @{ Expression = $rank })
        $result.SlSource = $bySl[0].Source
        $result.SlVersion = $bySl[0].Sl
    }
    return $result
}

# rhi-repo mirror builds for one section from a plain TAG LIST (no GitHub API - the tags come
# from `git ls-remote`, see Get-RhiTagsViaGit): newest-first candidates
# @{ Tag; Version; SortVersion; AssetName; DownloadUrl }. Download URLs are deterministic from
# the tag and asset name (github releases/download/<tag>/<asset>) - no API asset lookup needed.
# Only tags matching "<prefix>-<version>" count - community variants (renodx-*, DLSS-Enabler-*)
# are deliberately NOT sources. Version keeps its full tag remainder (suffixes like -RTX40 stay
# in the asset name); sorting uses the numeric prefix, and input order breaks ties. Tags whose
# numeric prefix does not parse (e.g. dlssnr-310.8.SF) are skipped.
function Get-RhiMirrorBuilds([string[]]$Tags, [string]$Section, [string]$RepoUrl = 'RankFTW/rhi-repo') {
    $map = @{
        'dlss'       = @{ TagPrefix = 'dlss-';       AssetPrefix = 'nvngx_dlss_' }
        'dlssd'      = @{ TagPrefix = 'dlssd-';      AssetPrefix = 'nvngx_dlssd_' }
        'dlssg'      = @{ TagPrefix = 'dlssg-';      AssetPrefix = 'nvngx_dlssg_' }
        'streamline' = @{ TagPrefix = 'streamline-'; AssetPrefix = 'streamline_' }
        'dlssnr'     = @{ TagPrefix = 'dlssnr-';     AssetPrefix = 'nvngx_dlssnr_' }
    }
    if (-not $map.ContainsKey($Section)) { return @() }
    $tagPrefix = $map[$Section].TagPrefix
    $assetPrefix = $map[$Section].AssetPrefix
    $cands = @()
    $order = 0
    foreach ($t in @($Tags)) {
        $order++
        if (-not $t -or -not $t.StartsWith($tagPrefix)) { continue }
        $version = $t.Substring($tagPrefix.Length)
        if (-not $version) { continue }
        $sortVersion = $version
        try { $null = [version]$sortVersion } catch {
            $sortVersion = $version -replace '-[A-Za-z0-9.]+$', ''
            try { $null = [version]$sortVersion } catch { continue }
        }
        $assetName = "$assetPrefix$version.zip"
        $cands += @{ Tag = $t; Version = $version; SortVersion = $sortVersion; AssetName = $assetName;
                     DownloadUrl = "https://github.com/$RepoUrl/releases/download/$t/$assetName"; Order = $order }
    }
    # callers wrap with @() (PowerShell convention): single-element lists unroll to a bare
    # hashtable across the pipeline, so [0]/.Count at a caller only work on the wrapped value
    return @($cands | Sort-Object -Property @{ Expression = { [version]$_.SortVersion }; Descending = $true },
                               @{ Expression = { $_.Order } })
}

# All tags of a GitHub repo via the GIT protocol - zero API quota, zero auth (public repos).
# Primary enumeration path for mirrors; callers fall back to the REST API when git is absent.
function Get-RhiTagsViaGit([string]$RepoUrl = 'https://github.com/RankFTW/rhi-repo.git') {
    $out = git ls-remote --tags $RepoUrl 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    # output lines: "<sha>\trefs/tags/<name>" (pooled tags carry the ^{} suffix - drop them)
    $tags = @($out | ForEach-Object {
        $n = ($_ -split "`t", 2)[1]
        if ($n -and $n -match '^refs/tags/(.+)$' -and $Matches[1] -notmatch '\^\{\}$') { $Matches[1] }
    })
    if ($tags.Count) { return $tags }
    return $null
}

# Newest release tag of a GitHub repo WITHOUT the REST API: the releases/latest URL 302-redirects
# to /releases/tag/<tag> - a plain HTTPS redirect, no auth, no rate limit. $null on any failure
# (network / repo without releases); callers fall back to the API path.
function Get-LatestReleaseTagViaRedirect([string]$Repo) {
    try {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('nvidia-rtx-ota-export')
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, "https://github.com/$Repo/releases/latest")
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        if (($resp.StatusCode -eq [System.Net.HttpStatusCode]::Found -or
             $resp.StatusCode -eq [System.Net.HttpStatusCode]::MovedPermanently -or
             $resp.StatusCode -eq [System.Net.HttpStatusCode]::TemporaryRedirect) -and $resp.Headers.Location) {
            $seg = $resp.Headers.Location.Segments | Where-Object { $_ -match '^v?[0-9A-Za-z][0-9A-Za-z.\-]*$' } | Select-Object -Last 1
            if ($seg) { return $seg.Trim('/') }
        }
    } catch { }
    return $null
}

# The NVIDIA/DLSS GitHub release asset carrying the runtime demo + DLLs (Windows build only).
function Get-DlssRepoAssetName([string[]]$AssetNames) {
    $win = @($AssetNames) | Where-Object { $_ -match '^ngx_dlss_demo_windows\.zip$' } | Select-Object -First 1
    if ($win) { return $win }
    return (@($AssetNames) | Where-Object { $_ -match 'demo_windows.*\.zip$' } | Select-Object -First 1)
}

# Cheap pre-gate: true when the live multi-feed probe differs from the stored probe state
# (probe-state.json attached to the newest release). $null/$empty pairs compare equal, and a
# missing stored state counts as a difference so the first run always bootstraps a full export.
function Test-ProbeStateDiffers($Live, $Stored) {
    if (-not $Stored) { return $true }
    foreach ($p in 'stagingDlss', 'stagingSl', 'productionDlss', 'productionSl', 'sdkTag', 'dlssRepoTag', 'dlssnrMirrorMax') {
        $l = [string]$Live.$p
        $s = [string]$Stored.$p
        if ($l -ne $s -and -not (([string]::IsNullOrEmpty($l)) -and ([string]::IsNullOrEmpty($s)))) { return $true }
    }
    return $false
}

# The x64 Streamline SDK zip asset: streamline-sdk-v<ver>.zip (excludes -aarch64/-arm64ec).
# Falls back to the first zip when NVIDIA renames assets.
function Get-SdkZipAssetName([string[]]$AssetNames) {
    $x64 = @($AssetNames) | Where-Object { $_ -match '^streamline-sdk-v[0-9.]+\.zip$' } | Select-Object -First 1
    if ($x64) { return $x64 }
    return (@($AssetNames) | Where-Object { $_ -match '\.zip$' } | Select-Object -First 1)
}

# 'v310.9.0-sl2.14.0' -> Dlss='310.9.0', Sl='2.14.0'; anything else -> $null
function Get-ReleaseTagVersion([string]$Tag) {
    if ($Tag -notmatch '^v(\d+(?:\.\d+)+)-sl(\d+(?:\.\d+)+)$') { return $null }
    return [pscustomobject]@{ Dlss = $Matches[1]; Sl = $Matches[2] }
}

# Among candidate release tags, the one with the highest (Dlss, Sl) tuple; $null when none parse.
function Get-NewestReleaseTag([string[]]$Tags) {
    $best = $null; $bestV = $null
    foreach ($t in @($Tags)) {
        if (-not $t) { continue }
        $v = Get-ReleaseTagVersion $t
        if (-not $v) { continue }
        if (-not $best -or (Compare-OtaNewer $v.Dlss $bestV.Dlss) -or ($v.Dlss -eq $bestV.Dlss -and (Compare-OtaNewer $v.Sl $bestV.Sl))) {
            $best = $t; $bestV = $v
        }
    }
    return $best
}

# Gate: true only when the candidate (Dlss, Sl) is strictly newer than an existing release tag.
# Equal version (already released, from any source) or older -> false, so a stale state can
# never be published and pull 'Latest release' backwards.
function Test-ReleaseTagNewer([string]$Dlss, [string]$Sl, [string]$ExistingTag) {
    $v = Get-ReleaseTagVersion $ExistingTag
    if (-not $v) { return $true }
    if (Compare-OtaNewer $Dlss $v.Dlss) { return $true }
    if ($Dlss -ne $v.Dlss) { return $false }
    return [bool](Compare-OtaNewer $Sl $v.Sl)
}

# Core DLL policy: sources are allowlisted upstream, so the file gate requires a PE/MZ image and
# reports Authenticode instead of rejecting HashMismatch/NotSigned builds. This keeps the risk
# visible in export-summary.txt while allowing working community variants.
function Get-DllAcceptancePolicy([bool]$IsPe, [string]$SignatureStatus, [string]$SignerSubject) {
    if (-not $IsPe) {
        return [pscustomobject]@{ Accepted = $false; Label = 'FAILED (not PE)' }
    }
    if (($SignatureStatus -eq 'Valid') -and ($SignerSubject -match 'NVIDIA Corporation')) {
        return [pscustomobject]@{ Accepted = $true; Label = 'Valid (NVIDIA)' }
    }
    $status = if ($SignatureStatus) { $SignatureStatus } else { 'Unknown' }
    return [pscustomobject]@{ Accepted = $true; Label = "UNVERIFIED ($status)" }
}

# Exact, case-insensitive SHA-256 pin for a deliberately selected unverified artifact.
function Test-Sha256Pin([string]$Actual, [string]$Expected) {
    if (-not $Actual -or -not $Expected) { return $false }
    return [bool]($Actual.Trim().ToLowerInvariant() -eq $Expected.Trim().ToLowerInvariant())
}

# ---------------------------------------------------------------- pinned 7-Zip tool (per platform)
# One pinned official artifact per OS/arch we support (verified against 7-zip.org live on
# 2026-09-13). Upstream does not Authenticode-sign these binaries, so the SHA-256 pin is the
# integrity control: every use (fresh download or cached copy) is verified against the pin
# before execution. Update procedure: download each artifact from https://www.7-zip.org/a/,
# confirm the source, then bump every entry's Version + Size + Sha256 together in one commit.
function Get-Pinned7zSpec {
    return @{
        Win        = @{ Url = 'https://www.7-zip.org/a/7zr.exe';               Sha256 = 'ad4c82fadcbdf93c03b4fc440f300509c7d60c5c2f4d183e35d9d70d6957037d'; Size = 602624;   Kind = 'exe';   Inner = '7zr.exe'; Version = '26.03' }
        Linux      = @{ Url = 'https://www.7-zip.org/a/7z2603-linux-x64.tar.xz';   Sha256 = 'dc99eff5008f1ab79bd7084c68513701547a808a89502bf4133683535ab3c695'; Size = 1575072; Kind = 'tarxz'; Inner = '7zzs'; Version = '26.03' }
        LinuxArm64 = @{ Url = 'https://www.7-zip.org/a/7z2603-linux-arm64.tar.xz'; Sha256 = '2389ba20e4d8295e8709c20b6263b69bd1ec4972fe38a04ad7a1badbf595b996'; Size = 1328620; Kind = 'tarxz'; Inner = '7zzs'; Version = '26.03' }
        Mac        = @{ Url = 'https://www.7-zip.org/a/7z2603-mac.tar.xz';         Sha256 = '5ca87677072c59f5602e5c49baa27d4694bacd2259b4e507f0094249d4281480'; Size = 1863192; Kind = 'tarxz'; Inner = '7zzs'; Version = '26.03' }
    }
}

# Works on Windows PowerShell 5.1 (.NET 4.7.1+) and PowerShell 7 on every OS.
function Get-CurrentPlatform {
    $ri = [System.Runtime.InteropServices.RuntimeInformation]
    if ($ri::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { return 'Win' }
    if ($ri::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) { return 'Mac' }
    if ($ri::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
        if ($ri::ProcessArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) { return 'LinuxArm64' }
        return 'Linux'
    }
    throw 'Unsupported OS platform.'
}

# Trusted local installs first; otherwise the hash-pinned official build for the current
# platform. Windows uses 7zr.exe directly; Linux/macOS download the official tarball, verify
# the pin, extract with the system tar and run the inner static 7zzs. A cached copy is
# re-verified on every call; any mismatch aborts instead of running unverified code.
function Resolve-7ZipTool {
    $platform = Get-CurrentPlatform
    if ($platform -eq 'Win') {
        $local = @()
        foreach ($cmd in '7z', '7zr') {
            $c = Get-Command $cmd -ErrorAction SilentlyContinue
            if ($c) { $local += $c.Source }
        }
        foreach ($p in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
                         "$env:ProgramFiles\NVIDIA Corporation\NVIDIA App\7z.exe")) {
            if (Test-Path $p) { $local += $p }
        }
        foreach ($p in $local) { if ($p) { return $p } }
    } else {
        foreach ($cmd in '7zzs', '7zz', '7zr', '7z') {
            $c = Get-Command $cmd -ErrorAction SilentlyContinue
            if ($c) { return $c.Source }
        }
    }

    $spec = (Get-Pinned7zSpec)[$platform]
    $tmpRoot = Join-Path (Get-TempRoot) "7z-pinned-$platform"
    $tool = Join-Path $tmpRoot $spec.Inner
    if ($spec.Kind -eq 'exe') {
        if (-not (Test-Path $tool) -or (Get-Item $tool).Length -ne $spec.Size) {
            New-Item -ItemType Directory $tmpRoot -Force | Out-Null
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $spec.Url -OutFile $tool -UseBasicParsing
        }
    } else {
        $tarball = Join-Path $tmpRoot ([System.IO.Path]::GetFileName($spec.Url))
        if (-not (Test-Path $tool) -or -not (Test-Path $tarball) -or (Get-Item $tarball).Length -ne $spec.Size) {
            New-Item -ItemType Directory $tmpRoot -Force | Out-Null
            Invoke-WebRequest -Uri $spec.Url -OutFile $tarball -UseBasicParsing
            if (-not (Test-Sha256Pin (Get-FileSha256 $tarball) $spec.Sha256)) {
                Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
                throw "Pinned 7-Zip tarball failed SHA-256 verification: expected $($spec.Sha256) - refusing to extract or execute."
            }
            tar -xf $tarball -C $tmpRoot
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tool)) { throw "Failed to extract the pinned 7-Zip tarball (system 'tar' missing or unreadable?): $tarball" }
        }
    }
    $actual = Get-FileSha256 $tool
    if (-not (Test-Sha256Pin $actual $spec.Sha256) -and $spec.Kind -ne 'tarxz') {
        Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw "Pinned 7-Zip tool failed SHA-256 verification: expected $($spec.Sha256), got $actual - refusing to execute."
    }
    return $tool
}

# Pack files/dirs (7z glob wildcards allowed in $SourcePaths) into a .7z archive. Throws on failure.
function New-7zArchive([string]$ArchivePath, [string[]]$SourcePaths, [int]$Level = 7) {
    $tool = Resolve-7ZipTool
    $parent = Split-Path -Parent $ArchivePath
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path $ArchivePath) { Remove-Item $ArchivePath -Force }
    & $tool a -t7z "-mx=$Level" $ArchivePath @SourcePaths | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7z packing failed (exit $LASTEXITCODE): $ArchivePath" }
}

# Extract a .7z archive with the resolved 7-Zip tool. Throws on failure.
function Expand-7zArchive([string]$ArchivePath, [string]$DestDir) {
    $tool = Resolve-7ZipTool
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    & $tool x "-o$DestDir" -y $ArchivePath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7z extraction failed (exit $LASTEXITCODE): $ArchivePath" }
}

# Deliberately selected universal dlssnr artifact supplied by the user. Plain asset name; the
# UNVERIFIED Authenticode status is documented in release notes, not the filename. The URL is
# fetchable by CI; the DLL hash is immutable - an UNVERIFIED exception, never a blanket
# signature bypass.
function Get-UnverifiedDlssnrSpec {
    return [pscustomobject]@{
        AssetName = 'nvngx_dlssnr_310.8.0.7z'
        Url       = 'https://github.com/Talya1412/nvidia-rtx-ota-export/releases/download/v310.9.1-sl2.14.1/nvngx_dlssnr_310.8.0.7z'
        Sha256    = 'e67dee209320cdafe0e93e45675d7aa34323a53acc57a72b2e40a181581c989a'
        Version   = '310.8.0'
        Source    = 'Talya1412/nvidia-rtx-ota-export (user-pinned artifact)'
    }
}

 Export-ModuleMember -Function @(
    'Find-OtaCachedPayload',
    'Get-OtaSectionVersion',
    'ConvertTo-PackedVersion',
    'ConvertTo-ShortVersion',
    'Get-FileSha256',
    'Compare-OtaNewer',
    'Select-ComponentWinners',
    'Get-SdkZipAssetName',
    'Get-ReleaseTagVersion',
    'Get-NewestReleaseTag',
    'Select-DlssnrBuild',
    'Get-DllAcceptancePolicy',
    'Test-Sha256Pin',
    'Get-UnverifiedDlssnrSpec',
    'Get-Pinned7zSpec',
    'Get-CurrentPlatform',
    'Test-WindowsHost',
    'Get-TempRoot',
    'Get-FilePeVersion',
    'Resolve-7ZipTool',
    'New-7zArchive',
    'Expand-7zArchive',
    'Get-RhiMirrorBuilds',
    'Get-RhiTagsViaGit',
    'Get-LatestReleaseTagViaRedirect',
    'Get-DlssRepoAssetName',
    'Test-ProbeStateDiffers',
    'Test-ReleaseTagNewer'
)
