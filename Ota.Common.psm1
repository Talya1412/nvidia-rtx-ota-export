# Shared, deterministic logic for the NVIDIA RTX OTA exporter + release publisher.
# Network and filesystem I/O stay in the entry scripts; everything here is pure and unit-tested
# (tests/run-tests.ps1). Version comparisons are numeric via [version], never lexicographic.

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

# true when $A is strictly newer than $B
function Compare-OtaNewer([string]$A, [string]$B) {
    try { return ([version]$A -gt [version]$B) } catch { return $false }
}

# Per-component newest across sources. Candidates: @{ Source; Dlss; Sl }. Picks the DLSS winner
# and the SL winner independently (numeric compare). Ties prefer the official Streamline SDK
# (GitHub) over OTA staging over OTA production.
function Select-ComponentWinners([object[]]$Candidates) {
    $priority = @{ 'sdk-streamline' = 0; 'ota-staging' = 1; 'ota-production' = 2 }
    $ok = @($Candidates) | Where-Object { $_ -and $_.Source -and $_.Dlss -and $_.Sl }
    if (-not $ok) { throw 'Select-ComponentWinners: no complete candidates.' }
    $rank = { if ($priority.ContainsKey($_.Source)) { $priority[$_.Source] } else { 3 } }
    $byDlss = @($ok | Sort-Object -Property @{ Expression = { [version]$_.Dlss }; Descending = $true },
                                     @{ Expression = $rank })
    $bySl   = @($ok | Sort-Object -Property @{ Expression = { [version]$_.Sl }; Descending = $true },
                                     @{ Expression = $rank })
    return [pscustomobject]@{
        DlssSource  = $byDlss[0].Source
        DlssVersion = $byDlss[0].Dlss
        SlSource    = $bySl[0].Source
        SlVersion   = $bySl[0].Sl
    }
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

Export-ModuleMember -Function @(
    'Get-OtaSectionVersion',
    'ConvertTo-PackedVersion',
    'ConvertTo-ShortVersion',
    'Get-FileSha256',
    'Compare-OtaNewer',
    'Select-ComponentWinners',
    'Get-SdkZipAssetName',
    'Get-ReleaseTagVersion',
    'Get-NewestReleaseTag',
    'Test-ReleaseTagNewer'
)
