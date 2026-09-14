# Dependency-free test runner for the shared OTA logic (Ota.Common.psm1).
# Runs under Windows PowerShell 5.1 and PowerShell 7+. Exit 1 on any failure.
#requires -Version 5.1

param(
    [switch]$Integration
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'Ota.Common.psm1') -Force

$script:failed = 0
function Assert-True([string]$Name, [bool]$Condition) {
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:failed++ }
}

# ---------------------------------------------------------------- script syntax
foreach ($f in 'Export-RtxOtaPreRelease.ps1', 'New-OtaRelease.ps1') {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $f), [ref]$null, [ref]$errs)
    Assert-True "syntax clean: $f" ($errs.Count -eq 0)
}

# ---------------------------------------------------------------- sl_sdk_0 base set + host re-invocation (behavioral)
function New-TestZip([string]$Path, [string[]]$EntryNames) {
    $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($name in $EntryNames) {
            $entry = $zip.CreateEntry($name)
            $stream = $entry.Open()
            try {
                $bytes = [byte[]]@(1, 2, 3)
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $stream.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
    }
}

$slSdkTestRoot = Join-Path (Get-TempRoot) ('ota-sl-sdk-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $slSdkTestRoot -Force | Out-Null

    $zipA = Join-Path $slSdkTestRoot 'case-a.zip'
    $destA = Join-Path $slSdkTestRoot 'case-a'
    New-TestZip $zipA @('160_E658703/sl.common.dll', '160_E658703/sl.dlss.dll', '160_E658703/readme.txt')
    $resultA = Expand-SlSdkPayload $zipA $destA
    Assert-True 'sl_sdk_0: top-level DLLs extracted mark base set ready' ($resultA -eq $true)
    Assert-True 'sl_sdk_0: sl.common.dll extracted' (Test-Path (Join-Path $destA 'sl.common.dll'))
    Assert-True 'sl_sdk_0: sl.dlss.dll extracted' (Test-Path (Join-Path $destA 'sl.dlss.dll'))
    Assert-True 'sl_sdk_0: non-DLL payload entry is not extracted' (-not (Test-Path (Join-Path $destA 'readme.txt')))

    $zipB = Join-Path $slSdkTestRoot 'case-b.zip'
    $destB = Join-Path $slSdkTestRoot 'case-b'
    New-TestZip $zipB @('160_E658703/bin/sl.common.dll')
    $resultB = Expand-SlSdkPayload $zipB $destB
    Assert-True 'sl_sdk_0: nested-only payload leaves base set NOT ready (bundle fallback stays reachable)' ($resultB -eq $false)
    Assert-True 'sl_sdk_0: nested-only payload extracts no DLLs' (@(Get-ChildItem $destB -Filter '*.dll' -File).Count -eq 0)

    $zipD = Join-Path $slSdkTestRoot 'case-d.zip'
    $destD = Join-Path $slSdkTestRoot 'case-d'
    New-Item -ItemType Directory -Path $destD -Force | Out-Null
    Set-Content -Path (Join-Path $destD 'sl.common.dll') -Value 'pre-existing' -NoNewline
    New-TestZip $zipD @('160_E658703/bin/sl.common.dll')
    $resultD = Expand-SlSdkPayload $zipD $destD
    Assert-True 'sl_sdk_0: pre-existing sl.common.dll in destination does not count as ready' ($resultD -eq $false)

    $zipC = Join-Path $slSdkTestRoot 'case-c.zip'
    $destC = Join-Path $slSdkTestRoot 'case-c'
    New-TestZip $zipC @('other/sl.common.dll')
    $resultC = Expand-SlSdkPayload $zipC $destC
    Assert-True 'sl_sdk_0: wrong-prefix payload leaves base set NOT ready' ($resultC -eq $false)

    $zipE = Join-Path $slSdkTestRoot 'case-e.zip'
    $destE = Join-Path $slSdkTestRoot 'case-e'
    New-TestZip $zipE @('160_E658703/..\evil.dll', '160_E658703/../evil2.dll')
    $resultE = Expand-SlSdkPayload $zipE $destE
    $destParent = Split-Path -Parent $destE
    Assert-True 'zip-slip: traversal entries are skipped and nothing lands outside dest' ($resultE -eq $false -and -not (Test-Path (Join-Path $destE 'evil.dll')) -and -not (Test-Path (Join-Path $destParent 'evil.dll')))

    $hostPath = Get-PowerShellHostPath
    Assert-True 'host: resolved path is non-empty' (-not [string]::IsNullOrWhiteSpace($hostPath))
    Assert-True 'host: resolved path launches and reports the same PSEdition' ((& $hostPath -NoProfile -NonInteractive -Command '$PSVersionTable.PSEdition').Trim() -eq $PSVersionTable.PSEdition)
    Assert-True 'host: Core edition never resolves to Windows PowerShell' ($PSVersionTable.PSEdition -ne 'Core' -or ((Split-Path -Leaf $hostPath) -notmatch '^powershell(\.exe)?$'))
    Assert-True 'host: resolved executable is pwsh or powershell' ((Split-Path -Leaf $hostPath) -match '^(pwsh|powershell)(\.exe)?$')
} finally {
    Remove-Item $slSdkTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- fixtures
$staging3109 = @'
[dlss]
app_E658700 = 310.9.0

[dlssd]
app_E658700 = 310.9.0

[dlssg]
app_E658700 = 310.9.0

[dlss_override]
app_E658700 = 310.9.0
'@

$production31010 = @'
[dlss]
app_E658700 = 310.10.0

[dlssd]
app_E658700 = 310.10.0

[dlssg]
app_E658700 = 310.10.0

[dlss_override]
app_E658700 = 310.10.0
'@

$production3107 = $staging3109 -replace '310\.9\.0', '310.7.128'

# ---------------------------------------------------------------- manifest parsing
Assert-True 'section version: dlss pin read' ((Get-OtaSectionVersion $staging3109 'dlss') -eq '310.9.0')
Assert-True 'section version: dlss_override pin read' ((Get-OtaSectionVersion $staging3109 'dlss_override') -eq '310.9.0')
Assert-True 'section version: missing section -> null' ($null -eq (Get-OtaSectionVersion $staging3109 'dlssnr'))

# ---------------------------------------------------------------- version math
Assert-True 'packed version: 310.9.0 -> 20318464 (README-documented)' ((ConvertTo-PackedVersion '310.9.0') -eq 20318464)
Assert-True 'packed version: 310.7.128 -> 20318080' ((ConvertTo-PackedVersion '310.7.128') -eq 20318080)

Assert-True 'packed version: 310.9.0 -> 20318464 (README-documented)' ((ConvertTo-PackedVersion '310.9.0') -eq 20318464)
Assert-True 'packed version: 2.14.0 -> 134656 (sl_sdk_0 payload path)' ((ConvertTo-PackedVersion '2.14.0') -eq 134656)
Assert-True 'numeric compare: 310.9.0 < 310.10.0' (-not (Compare-OtaNewer '310.9.0' '310.10.0'))
Assert-True 'numeric compare: equal -> not newer' (-not (Compare-OtaNewer '310.7.128' '310.7.128'))

# ---------------------------------------------------------------- file hashing (env-resilient)
$tmp1 = Join-Path ([System.IO.Path]::GetTempPath()) ('ota-test-' + [guid]::NewGuid().ToString('N'))
Set-Content -Path $tmp1 -Value '' -NoNewline
$tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) ('ota-test-' + [guid]::NewGuid().ToString('N'))
Set-Content -Path $tmp2 -Value 'abc' -NoNewline
try {
    $h1 = try { Get-FileSha256 $tmp1 } catch { '' }
    $h2 = try { Get-FileSha256 $tmp2 } catch { '' }
} finally {
    Remove-Item $tmp1, $tmp2 -Force -ErrorAction SilentlyContinue
}
Assert-True 'sha256: empty file -> known vector' ($h1 -eq 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
Assert-True 'sha256: abc -> known vector' ($h2 -eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')


# ---------------------------------------------------------------- tag identity + release gate
$tag = Get-ReleaseTagVersion 'v310.9.0-sl2.14.0'
Assert-True 'tag parse: dlss part' ($tag.Dlss -eq '310.9.0')
Assert-True 'tag parse: sl part' ($tag.Sl -eq '2.14.0')
Assert-True 'tag parse: non-release tag -> null' ($null -eq (Get-ReleaseTagVersion 'v0.1-docs'))

# ---------------------------------------------------------------- cross-platform PE FileVersion (synthetic)
# Minimal PE: MZ, e_lfanew=0x40, 'PE\0\0', COFF (1 section, optSize 0xF0), PE32+ optional header,
# data directory[2] -> resource RVA, one section mapping that RVA into the file, then the
# VS_VERSION_INFO key + VS_FIXEDFILEINFO struct in the mapped window.
function New-FakeVersionPe([int]$Major, [int]$Minor, [int]$Build, [int]$Rev) {
    $b = [System.Collections.Generic.List[byte]]::new()
    $b.AddRange([byte[]]@(0x4D, 0x5A)); $b.AddRange((New-Object byte[] 0x3A)); $b.AddRange([BitConverter]::GetBytes([int32]0x40))
    $b.AddRange([byte[]]@(0x50, 0x45, 0x00, 0x00))                                   # PE\0\0
    $b.AddRange([byte[]]@(0x8B, 0x01)); $b.AddRange([BitConverter]::GetBytes([int16]1)) # machine, 1 section
    $b.AddRange((New-Object byte[] 12)); $b.AddRange([BitConverter]::GetBytes([int16]0xF0)); $b.AddRange([byte[]]@(0x22, 0x00)) # sizeOpt=0xF0, chars
    $b.AddRange([byte[]]@(0x0B, 0x02))                                               # PE32+ magic
    while ($b.Count -lt 0x40 + 24 + 112 + 16) { $b.Add(0) }                          # to data dir[2]
    $resRva = 0x200; $resSize = 0x80
    $b.AddRange([BitConverter]::GetBytes([int32]$resRva)); $b.AddRange([BitConverter]::GetBytes([int32]$resSize))
    while ($b.Count -lt 0x148) { $b.Add(0) }                                          # section table
    $b.AddRange([byte[]]@(0x2E, 0x72, 0x73, 0x72, 0x63, 0x00, 0x00, 0x00))            # '.rsrc'
    $b.AddRange((New-Object byte[] 4)); $b.AddRange([BitConverter]::GetBytes([int32]$resRva)); $b.AddRange([BitConverter]::GetBytes([int32]$resSize)); $b.AddRange([BitConverter]::GetBytes([int32]$resRva))
    while ($b.Count -lt 0x200) { $b.Add(0) }                                          # resource data starts at resRva=0x200
    $key = [System.Text.Encoding]::Unicode.GetBytes('VS_VERSION_INFO')
    $ms = ([int]$Major -shl 16) -bor [int]$Minor
    $ls = ([int]$Build -shl 16) -bor [int]$Rev
    $b.AddRange([byte[]]@(0x00, 0x00)); $b.AddRange($key); $b.AddRange([byte[]]@(0x00, 0x00))
    $b.AddRange([byte[]]@(0xBD, 0x04, 0xEF, 0xFE)); $b.AddRange([BitConverter]::GetBytes([int32]1)); $b.AddRange([BitConverter]::GetBytes([int32]$ms)); $b.AddRange([BitConverter]::GetBytes([int32]$ls))
    return $b.ToArray()
}
$fakePath = Join-Path ([System.IO.Path]::GetTempPath()) ('pever-fake-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
[System.IO.File]::WriteAllBytes($fakePath, (New-FakeVersionPe 310 9 1 0))
Assert-True 'pe version: 310.9.1 decoded from synthetic VS_FIXEDFILEINFO' ((Get-FilePeVersion $fakePath) -eq '310.9.1')
[System.IO.File]::WriteAllBytes($fakePath, (New-FakeVersionPe 2 14 1 0))
Assert-True 'pe version: 2.14.1 decoded' ((Get-FilePeVersion $fakePath) -eq '2.14.1')
$vNone = [byte[]](@([byte]0x4D, [byte]0x5A) + @([byte]0x00) * 0x120)
[System.IO.File]::WriteAllBytes($fakePath, $vNone)
Assert-True 'pe version: no version resource -> empty string' ((Get-FilePeVersion $fakePath) -eq '')
Remove-Item $fakePath -Force -ErrorAction SilentlyContinue
Assert-True 'newest tag: empty list -> null' ($null -eq (Get-NewestReleaseTag @()))
Assert-True 'newest tag: numeric 310.10 beats 310.9' ((Get-NewestReleaseTag @('v310.10.0-sl2.14.0', 'v310.9.0-sl2.15.0')) -eq 'v310.10.0-sl2.14.0')
Assert-True 'newest tag: picks max among mixed list' ((Get-NewestReleaseTag @('v310.7.128-sl2.12.128', 'v310.9.0-sl2.14.0', 'v0.1-docs')) -eq 'v310.9.0-sl2.14.0')

Assert-True 'gate: production candidate older than staging release -> skip (regression: stale publish)' (-not (Test-ReleaseTagNewer '310.7.128' '2.12.128' 'v310.9.0-sl2.14.0'))
Assert-True 'gate: candidate newer than latest -> publish' (Test-ReleaseTagNewer '310.9.0' '2.14.0' 'v310.7.128-sl2.12.128')
Assert-True 'gate: same version already released -> skip' (-not (Test-ReleaseTagNewer '310.9.0' '2.14.0' 'v310.9.0-sl2.14.0'))
Assert-True 'gate: numeric 310.10.0 > 310.9.0 -> publish' (Test-ReleaseTagNewer '310.10.0' '2.14.0' 'v310.9.0-sl2.14.0')
Assert-True 'gate: dlss equal, sl newer -> publish' (Test-ReleaseTagNewer '310.9.0' '2.15.0' 'v310.9.0-sl2.14.0')
Assert-True 'gate: dlss equal, sl older -> skip' (-not (Test-ReleaseTagNewer '310.9.0' '2.13.0' 'v310.9.0-sl2.14.0'))
Assert-True 'gate: unparseable existing tag does not block' (Test-ReleaseTagNewer '310.9.0' '2.14.0' 'some-other-tag')
Assert-True 'tag parse: optional dlssnr part' ((Get-ReleaseTagVersion 'v310.9.1-sl2.14.1-nr310.8.0').Dlssnr -eq '310.8.0')
Assert-True 'gate: dlssnr newer publishes same main version' (Test-ReleaseTagNewer '310.9.1' '2.14.1' 'v310.9.1-sl2.14.1-nr310.8.0' '310.9.0')
Assert-True 'gate: same dlssnr does not republish' (-not (Test-ReleaseTagNewer '310.9.1' '2.14.1' 'v310.9.1-sl2.14.1-nr310.8.0' '310.8.0'))

# ---------------------------------------------------------------- multi-source winners
$win = Select-ComponentWinners @(
    @{ Source = 'ota-staging';    Dlss = '310.9.0';   Sl = '2.14.0' },
    @{ Source = 'ota-production'; Dlss = '310.7.128'; Sl = '2.12.128' },
    @{ Source = 'sdk-streamline'; Dlss = '310.9.1';   Sl = '2.14.1' }
)
Assert-True 'short version: comma-separated FileVersion' ((ConvertTo-ShortVersion '310,9,1,0') -eq '310.9.1')
Assert-True 'short version: dot-separated FileVersion' ((ConvertTo-ShortVersion '2.14.1.0') -eq '2.14.1')
Assert-True 'short version: regression - must not merge digits (old bug: 310910..)' ((ConvertTo-ShortVersion '310,9,0,0') -eq '310.9.0')
$hEmpty = try { ConvertTo-ShortVersion '' } catch { '<threw>' }
Assert-True 'short version: empty FileVersion -> empty string (versionless DLLs)' ($hEmpty -eq '')
Assert-True 'winners: SDK newest on both components' ($win.DlssSource -eq 'sdk-streamline' -and $win.DlssVersion -eq '310.9.1' -and $win.SlSource -eq 'sdk-streamline' -and $win.SlVersion -eq '2.14.1')

$win2 = Select-ComponentWinners @(
    @{ Source = 'ota-staging';    Dlss = '310.10.0'; Sl = '2.14.0' },
    @{ Source = 'sdk-streamline'; Dlss = '310.9.1';  Sl = '2.14.1' }
)
Assert-True 'winners: mixed - DLSS from OTA (numeric 310.10 > 310.9), SL from SDK' ($win2.DlssSource -eq 'ota-staging' -and $win2.DlssVersion -eq '310.10.0' -and $win2.SlSource -eq 'sdk-streamline')

$win3 = Select-ComponentWinners @(
    @{ Source = 'ota-staging';    Dlss = '310.9.1'; Sl = '2.14.1' },
    @{ Source = 'sdk-streamline'; Dlss = '310.9.1'; Sl = '2.14.1' }
)
Assert-True 'winners: tie -> SDK preferred (official SDK repo first)' ($win3.DlssSource -eq 'sdk-streamline' -and $win3.SlSource -eq 'sdk-streamline')
$win4 = Select-ComponentWinners @(@{ Source = 'ota-production'; Dlss = '310.8.0'; Sl = '2.13.0' })
Assert-True 'winners: single source -> that source' ($win4.DlssSource -eq 'ota-production' -and $win4.SlVersion -eq '2.13.0')

Assert-True 'sdk asset: x64 zip preferred over arch variants' ((Get-SdkZipAssetName @('streamline-sdk-v2.14.1-aarch64.zip', 'streamline-sdk-v2.14.1.zip', 'streamline-sdk-v2.14.1-arm64ec.zip')) -eq 'streamline-sdk-v2.14.1.zip')
Assert-True 'sdk asset: fallback to any zip' ((Get-SdkZipAssetName @('streamline-2.14.1.zip')) -eq 'streamline-2.14.1.zip')
Assert-True 'dlssnr: newer PE accepted regardless of signature status' ((Select-DlssnrBuild @(@{ Tag = 'dlssnr-310.9.0-SF'; Version = '310.9.0'; Pass = $true }, @{ Tag = 'dlssnr-310.8.0'; Version = '310.8.0'; Pass = $true })) -eq 'dlssnr-310.9.0-SF')


# ---------------------------------------------------------------- driver OTA cache lookup
$cacheRoot1 = Join-Path ([System.IO.Path]::GetTempPath()) ('ota-cache-' + [guid]::NewGuid().ToString('N'))
$cacheRel = "$cacheRoot1/models/dlss/versions/20318464/files/160_E658700.bin"
New-Item -ItemType Directory -Force -Path (Split-Path $cacheRel -Parent) | Out-Null
Set-Content -Path $cacheRel -Value 'payload-bytes'
$cacheRoot2 = Join-Path ([System.IO.Path]::GetTempPath()) ('ota-cache-' + [guid]::NewGuid().ToString('N'))
$cacheRel2 = "$cacheRoot2/models/dlssd/versions/20318464/files/160_E658700.bin"
New-Item -ItemType Directory -Force -Path (Split-Path $cacheRel2 -Parent) | Out-Null
Set-Content -Path $cacheRel2 -Value 'payload-bytes-2'
try {
    Assert-True 'cache: hit under first root' ((Find-OtaCachedPayload @($cacheRoot1) 'dlss' '20318464' '160_E658700.bin') -eq $cacheRel)
    Assert-True 'cache: hit under second root when first misses' ((Find-OtaCachedPayload @("$cacheRoot1-missing", $cacheRoot2) 'dlssd' '20318464' '160_E658700.bin') -eq $cacheRel2)
    Assert-True 'cache: wrong packed version -> miss' ($null -eq (Find-OtaCachedPayload @($cacheRoot1) 'dlss' '20318080' '160_E658700.bin'))
    Assert-True 'cache: wrong payload file -> miss' ($null -eq (Find-OtaCachedPayload @($cacheRoot1) 'dlss' '20318464' '160_E658701.bin'))
    $missingRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'ota-cache-missing-root-does-not-exist'
    Assert-True 'cache: no roots exist -> null' ($null -eq (Find-OtaCachedPayload @($missingRoot) 'dlss' '20318464' '160_E658700.bin'))
} finally {
    Remove-Item $cacheRoot1, $cacheRoot2 -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- relaxed PE-only export policy
$hashMismatch = Get-DllAcceptancePolicy $true 'HashMismatch' 'CN=NVIDIA Corporation'
Assert-True 'gate: PE with NVIDIA HashMismatch is accepted but labeled UNVERIFIED' ($hashMismatch.Accepted -and $hashMismatch.Label -match 'UNVERIFIED')
$unsigned = Get-DllAcceptancePolicy $true 'NotSigned' ''
Assert-True 'gate: PE without Authenticode is accepted but labeled UNVERIFIED' ($unsigned.Accepted -and $unsigned.Label -match 'UNVERIFIED')
$valid = Get-DllAcceptancePolicy $true 'Valid' 'CN=NVIDIA Corporation'
Assert-True 'gate: valid NVIDIA signature is accepted and labeled verified' ($valid.Accepted -and $valid.Label -eq 'Valid (NVIDIA)')
$otherSigner = Get-DllAcceptancePolicy $true 'Valid' 'CN=Some Other Publisher'
Assert-True 'gate: PE with non-NVIDIA valid signature is still accepted as UNVERIFIED' ($otherSigner.Accepted -and $otherSigner.Label -match 'UNVERIFIED')
$badPe = Get-DllAcceptancePolicy $false 'Valid' 'CN=NVIDIA Corporation'
Assert-True 'gate: non-PE is still rejected' (-not $badPe.Accepted)

Assert-True 'pin: exact SHA-256 matches case-insensitively' (Test-Sha256Pin 'ABCDEF0123456789' 'abcdef0123456789')
Assert-True 'pin: dlssnr asset is a plain 7z name (UNVERIFIED status lives in release notes, not the filename)' ((Get-UnverifiedDlssnrSpec).AssetName -eq 'nvngx_dlssnr_310.8.0.7z')
Assert-True 'pin: dlssnr asset hash is exact and immutable' ((Get-UnverifiedDlssnrSpec).Sha256 -eq 'e67dee209320cdafe0e93e45675d7aa34323a53acc57a72b2e40a181581c989a')
Assert-True 'pin: dlssnr asset has fetchable release URL' ((Get-UnverifiedDlssnrSpec).Url -match '^https://github\.com/Talya1412/nvidia-rtx-ota-export/releases/download/v310\.9\.1-sl2\.14\.1/nvngx_dlssnr_310\.8\.0\.7z$')
Assert-True 'pinned 7z: Windows artifact is the official standalone console build' ((Get-Pinned7zSpec)['Win'].Url -eq 'https://www.7-zip.org/a/7zr.exe')
Assert-True 'pinned 7z: Windows SHA-256 pin is the exact recorded digest' ((Get-Pinned7zSpec)['Win'].Sha256 -eq 'ad4c82fadcbdf93c03b4fc440f300509c7d60c5c2f4d183e35d9d70d6957037d')
Assert-True 'pinned 7z: Linux/Mac artifacts pinned per platform' (((Get-Pinned7zSpec)['Linux'].Kind -eq 'tarxz') -and ((Get-Pinned7zSpec)['Mac'].Kind -eq 'tarxz') -and ((Get-Pinned7zSpec)['LinuxArm64'].Inner -eq '7zzs'))
Assert-True 'pinned 7z: resolver is exported' ($null -ne (Get-Command Resolve-7ZipTool -ErrorAction SilentlyContinue))

# ---------------------------------------------------------------- multi-feed expansion (new sources)
$mockRhiTags = @(
    'renodx-dlss5-5.2.1', 'dlss-310.9.1', 'dlss-310.9.0', 'dlssd-310.9.1', 'dlssg-310.9.1',
    'streamline-2.14.1.0', 'streamline-2.14.0.0', 'dlssnr-310.9.0', 'dlssnr-310.8.0-RTX40',
    'dlssnr-310.8.SF', 'DLSS-Enabler-4.10.0'
)
$mDlss = @(Get-RhiMirrorBuilds $mockRhiTags 'dlss')
Assert-True 'mirror: dlss newest first, unrelated prefixes filtered' ($mDlss.Count -eq 2 -and $mDlss[0].Version -eq '310.9.1' -and $mDlss[0].Tag -eq 'dlss-310.9.1')
Assert-True 'mirror: dlss asset name mapping' ($mDlss[0].AssetName -eq 'nvngx_dlss_310.9.1.zip')
Assert-True 'mirror: download url deterministic from tag (no API asset lookup)' ($mDlss[0].DownloadUrl -eq 'https://github.com/RankFTW/rhi-repo/releases/download/dlss-310.9.1/nvngx_dlss_310.9.1.zip')
Assert-True 'mirror: dlssd section isolated' ((@(Get-RhiMirrorBuilds $mockRhiTags 'dlssd'))[0].AssetName -eq 'nvngx_dlssd_310.9.1.zip')
Assert-True 'mirror: streamline 4-part version' ((@(Get-RhiMirrorBuilds $mockRhiTags 'streamline'))[0].Version -eq '2.14.1.0')
$snrM = @(Get-RhiMirrorBuilds $mockRhiTags 'dlssnr')
Assert-True 'mirror: dlssnr suffix-tolerant, newest first (non-numeric suffix tag skipped)' ($snrM.Count -eq 2 -and $snrM[0].Version -eq '310.9.0' -and $snrM[1].Version -eq '310.8.0-RTX40')
Assert-True 'mirror: dlssnr asset keeps full version incl. suffix' ($snrM[1].AssetName -eq 'nvngx_dlssnr_310.8.0-RTX40.zip')
Assert-True 'mirror: unknown section -> empty' (@(Get-RhiMirrorBuilds $mockRhiTags 'nosuch').Count -eq 0)

Assert-True 'dlss repo asset: demo windows picked' ((Get-DlssRepoAssetName @('ngx_dlss_demo_linux.zip', 'ngx_dlss_demo_windows.zip')) -eq 'ngx_dlss_demo_windows.zip')
Assert-True 'dlss repo asset: no windows asset -> null' ($null -eq (Get-DlssRepoAssetName @('ngx_dlss_demo_linux.zip')))

$probeLive = [pscustomobject]@{ stagingDlss = '310.9.0'; stagingSl = '2.14.0'; productionDlss = '310.7.128'; productionSl = '2.12.128'; sdkTag = 'v2.14.1'; dlssRepoTag = 'v310.9.1'; dlssnrMirrorMax = '310.8.0' }
Assert-True 'probe: identical state -> no diff' (-not (Test-ProbeStateDiffers $probeLive $probeLive))
$probeOld = [pscustomobject]@{ stagingDlss = '310.9.0'; stagingSl = '2.14.0'; productionDlss = '310.7.128'; productionSl = '2.12.128'; sdkTag = 'v2.14.1'; dlssRepoTag = 'v310.9.0'; dlssnrMirrorMax = '310.8.0' }
Assert-True 'probe: one field differs -> diff' (Test-ProbeStateDiffers $probeLive $probeOld)
Assert-True 'probe: missing stored state -> diff (bootstrap)' (Test-ProbeStateDiffers $probeLive $null)
Assert-True 'probe: null vs empty string are equal' (-not (Test-ProbeStateDiffers ([pscustomobject]@{ stagingDlss = $null }) ([pscustomobject]@{ stagingDlss = '' })))

$dlssOnlyWin = Select-ComponentWinners @(@{ Source = 'github-dlss'; Dlss = '310.9.1'; Sl = $null }, @{ Source = 'ota-staging'; Dlss = '310.9.0'; Sl = '2.14.0' })
Assert-True 'winners: DLSS-only official source wins DLSS, never SL' ($dlssOnlyWin.DlssSource -eq 'github-dlss' -and $dlssOnlyWin.DlssVersion -eq '310.9.1' -and $dlssOnlyWin.SlSource -eq 'ota-staging' -and $dlssOnlyWin.SlVersion -eq '2.14.0')
Assert-True 'winners: older DLSS-only source loses to official with same SL' ((Select-ComponentWinners @(@{ Source = 'github-dlss'; Dlss = '310.9.1'; Sl = $null }, @{ Source = 'sdk-streamline'; Dlss = '310.9.1'; Sl = '2.14.1' })).SlSource -eq 'sdk-streamline')
Assert-True 'dlssnr: mirror newer than pinned universal wins (newest-wins)' ((Select-DlssnrBuild @(@{ Tag = 'pinned-universal'; Version = '310.8.0'; Pass = $true }, @{ Tag = 'dlssnr-310.9.0'; Version = '310.9.0'; Pass = $true })) -eq 'dlssnr-310.9.0')
Assert-True 'dlssnr: version tie prefers pinned universal (listed first)' ((Select-DlssnrBuild @(@{ Tag = 'pinned-universal'; Version = '310.8.0'; Pass = $true }, @{ Tag = 'dlssnr-310.8.0'; Version = '310.8.0'; Pass = $true })) -eq 'pinned-universal')


# ---------------------------------------------------------------- proton NGX cache roots (Linux/macOS)
$protonHome = Join-Path (Get-TempRoot) ('ota-proton-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $protonHome -Force | Out-Null
    $steamNgx = "$protonHome/.steam/steam/steamapps/compatdata/1091500/pfx/drive_c/users/steamuser/AppData/Local/NVIDIA/NGX"
    $flatNgx  = "$protonHome/.var/app/com.valvesoftware.Steam/.steam/steam/steamapps/compatdata/1091500/pfx/drive_c/users/steamuser/AppData/Local/NVIDIA/NGX"
    $wineNgx  = "$protonHome/.wine/drive_c/users/hoang/AppData/Local/NVIDIA/NGX"
    foreach ($d in @($steamNgx, $flatNgx, $wineNgx)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    New-Item -ItemType Directory -Path "$protonHome/.steam/steam/steamapps/compatdata/999/pfx/drive_c/users/steamuser" -Force | Out-Null

    $roots = @(Get-ProtonOtaCacheRoots -HomeDir $protonHome)
    Assert-True 'proton roots: steam compatdata prefix found' ($roots -contains ($steamNgx -replace '\\', '/'))
    Assert-True 'proton roots: flatpak steam prefix found' ($roots -contains ($flatNgx -replace '\\', '/'))
    Assert-True 'proton roots: plain wine prefix found' ($roots -contains ($wineNgx -replace '\\', '/'))
    Assert-True 'proton roots: prefix without NGX dir excluded' (@($roots | Where-Object { $_ -like '*compatdata/999*' }).Count -eq 0)
    Assert-True 'proton roots: all returned paths exist' (@($roots | Where-Object { -not (Test-Path $_) }).Count -eq 0)
    Assert-True 'proton roots: forward slashes everywhere' (@($roots | Where-Object { $_.Contains([char]92) }).Count -eq 0)

    $empty = @(Get-ProtonOtaCacheRoots -HomeDir (Join-Path $protonHome 'empty'))
    Assert-True 'proton roots: empty home -> empty list' ($empty.Count -eq 0)
} finally {
    Remove-Item $protonHome -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- osslsigncode output parsing (non-Windows signatures)
$osslOkOut = @'
Message digest algorithm  : SHA256
Current message digest    : 0A9F10FB285BA0064B5537023F8BC9E06E173801
Calculated message digest : 0A9F10FB285BA0064B5537023F8BC9E06E173801
Signature verification: ok

Number of signers: 1
Signer #0:
    Subject: /C=US/ST=California/L=Santa Clara/O=NVIDIA Corporation/CN=NVIDIA Corporation
    Issuer : /C=US/O=DigiCert Inc/CN=DigiCert EV Code Signing CA
'@
$parsedOk = ConvertFrom-OsslSigncodeOutput $osslOkOut
Assert-True 'ossl parse: ok verdict -> Valid' ($parsedOk.Status -eq 'Valid')
Assert-True 'ossl parse: NVIDIA signer captured' ($parsedOk.Signer -match 'NVIDIA Corporation')
Assert-True 'ossl parse: failed verdict -> HashMismatch' ((ConvertFrom-OsslSigncodeOutput "Signature verification: failed`nSerial: 01").Status -eq 'HashMismatch')
Assert-True 'ossl parse: no verdict -> Invalid' ((ConvertFrom-OsslSigncodeOutput 'garbage output only').Status -eq 'Invalid')
$parsedEmpty = ConvertFrom-OsslSigncodeOutput ''
Assert-True 'ossl parse: empty -> Invalid without signer' ($parsedEmpty.Status -eq 'Invalid' -and -not $parsedEmpty.Signer)

# ---------------------------------------------------------------- signature tool resolution
$sigTool = Resolve-SignatureTool
if (Test-WindowsHost) {
    Assert-True 'sig tool: Windows never resolves osslsigncode' ($null -eq $sigTool)
} else {
    Assert-True 'sig tool: non-Windows resolves to null or a real osslsigncode' ($null -eq $sigTool -or (Test-Path $sigTool))
    if ($env:CI -eq 'true') {
        Assert-True 'sig tool: CI non-Windows installation is present' ($null -ne $sigTool -and (Test-Path $sigTool))
        $cliPePath = Join-Path (Get-TempRoot) ('osslsigncode-cli-' + [guid]::NewGuid().ToString('N') + '.dll')
        try {
            [System.IO.File]::WriteAllBytes($cliPePath, (New-FakeVersionPe 310 9 1 0))
            $cliOutput = (& $sigTool verify -in $cliPePath 2>&1 | Out-String)
            Assert-True 'sig tool: real CLI accepts -in input form' ($cliOutput -and $cliOutput -notmatch '(?i)usage:')
            $cliVerification = Get-DllVerification $cliPePath
            Assert-True 'sig tool: exporter reaches real CLI result' ($cliVerification.Status -ne 'Unavailable (osslsigncode error)')
        } finally {
            Remove-Item $cliPePath -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------- GPU family mapping (dlssnr per-GPU picker)
Assert-True 'gpu family: RTX 4070 -> RTX40' ((ConvertTo-GpuFamily 'NVIDIA GeForce RTX 4070') -eq 'RTX40')
Assert-True 'gpu family: RTX 2080 Ti -> RTX20' ((ConvertTo-GpuFamily 'NVIDIA GeForce RTX 2080 Ti') -eq 'RTX20')
Assert-True 'gpu family: RTX 5090 -> RTX50' ((ConvertTo-GpuFamily 'RTX 5090') -eq 'RTX50')
Assert-True 'gpu family: RTX 3070 Laptop GPU -> RTX30' ((ConvertTo-GpuFamily 'RTX 3070 Laptop GPU') -eq 'RTX30')
Assert-True 'gpu family: GTX 1650 -> null' ($null -eq (ConvertTo-GpuFamily 'NVIDIA GeForce GTX 1650'))
Assert-True 'gpu family: empty -> null' ($null -eq (ConvertTo-GpuFamily ''))
Assert-True 'gpu family: non-NVIDIA -> null' ($null -eq (ConvertTo-GpuFamily 'AMD Radeon RX 7900 XTX'))

Assert-True 'dlssnr suffix: matching family compatible' (Test-MirrorSuffixCompatible 'dlssnr-310.8.0-RTX40' 'RTX40')
Assert-True 'dlssnr suffix: wrong family incompatible' (-not (Test-MirrorSuffixCompatible 'dlssnr-310.8.0-RTX50' 'RTX40'))
Assert-True 'dlssnr suffix: 4-digit model suffix maps to series' (Test-MirrorSuffixCompatible 'dlssnr-310.8.0-RTX4090' 'RTX40')
Assert-True 'dlssnr suffix: no suffix compatible' (Test-MirrorSuffixCompatible 'dlssnr-310.8.0' 'RTX40')
Assert-True 'dlssnr suffix: unknown family compatible' (Test-MirrorSuffixCompatible 'dlssnr-310.8.0-RTX50' '')
Assert-True 'dlssnr suffix: pinned universal compatible' (Test-MirrorSuffixCompatible 'pinned-universal' 'RTX40')
Assert-True 'dlssnr suffix: case-insensitive' (Test-MirrorSuffixCompatible 'dlssnr-310.8.0-rtx40' 'RTX40')
Assert-True 'dlssnr suffix: non-GPU suffix compatible' (Test-MirrorSuffixCompatible 'dlssnr-310.8.0-SF' 'RTX40')
$gpuOrdered = @(Sort-DlssnrCandidates @(
    @{ Tag = 'dlssnr-310.9.0-RTX50'; SortVersion = '310.9.0'; Order = 0 }
    @{ Tag = 'dlssnr-310.8.0-RTX40'; SortVersion = '310.8.0'; Order = 1 }
    @{ Tag = 'dlssnr-310.7.0'; SortVersion = '310.7.0'; Order = 2 }
) 'RTX40')
Assert-True 'dlssnr ordering: compatible family beats newer wrong-family build' ($gpuOrdered[0].Tag -eq 'dlssnr-310.8.0-RTX40')
Assert-True 'dlssnr ordering: unsuffixed candidate remains compatible' ($gpuOrdered[1].Tag -eq 'dlssnr-310.7.0')


# ---------------------------------------------------------------- versions.json manifest builder
$sumLines = @(
    "nvngx_dlss.dll`t310.9.1`t$('a' * 64)",
    "sl.common.dll`t2.14.1`t$('b' * 64)"
)
$archList = @(
    [pscustomobject]@{ name = 'streamline-ota-310.9.1-sl2.14.1.7z'; sha256 = $('c' * 64) },
    [pscustomobject]@{ name = 'nvngx_dlssnr_310.8.0.7z'; sha256 = $('d' * 64) }
)
$compMap = @{
    dlss   = @{ version = '310.9.1'; source = 'sdk-streamline' }
    sl     = @{ version = '2.14.1';  source = 'sdk-streamline' }
    dlssnr = @{ version = '310.8.0'; source = 'pinned-universal' }
}
$feedMap = @{ staging = '310.9.0/2.14.0'; production = '310.7.128/2.12.128'; sdk = '2.14.1' }
$versionsJson = ConvertTo-OtaVersionsJson -Tag 'v310.9.1-sl2.14.1' -Components $compMap -ChecksumLines $sumLines -Archives $archList -FeedState $feedMap
$vdoc = $versionsJson | ConvertFrom-Json
Assert-True 'versions.json: parses back' ($null -ne $vdoc)
Assert-True 'versions.json: schema 1' ($vdoc.schema -eq 1)
Assert-True 'versions.json: release tag recorded' ($vdoc.release -eq 'v310.9.1-sl2.14.1')
Assert-True 'versions.json: generatedAt present' (-not [string]::IsNullOrEmpty($vdoc.generatedAt))
Assert-True 'versions.json: dlss component version+source' ($vdoc.components.dlss.version -eq '310.9.1' -and $vdoc.components.dlss.source -eq 'sdk-streamline')
Assert-True 'versions.json: dlssnr component recorded' ($vdoc.components.dlssnr.version -eq '310.8.0' -and $vdoc.components.dlssnr.source -eq 'pinned-universal')
Assert-True 'versions.json: files parsed from checksum lines' ($vdoc.files.'nvngx_dlss.dll'.sha256 -eq ('a' * 64) -and $vdoc.files.'nvngx_dlss.dll'.version -eq '310.9.1')
Assert-True 'versions.json: archives listed with hashes' ($vdoc.archives.Count -eq 2 -and $vdoc.archives[1].name -eq 'nvngx_dlssnr_310.8.0.7z')
Assert-True 'versions.json: feeds included' ($vdoc.feeds.staging -eq '310.9.0/2.14.0')

$compNoSnr = @{ dlss = @{ version = '310.9.1'; source = 'sdk-streamline' }; sl = @{ version = '2.14.1'; source = 'sdk-streamline' } }
$vdoc2 = ConvertTo-OtaVersionsJson -Tag 'v310.9.1-sl2.14.1' -Components $compNoSnr -ChecksumLines $sumLines -Archives $archList[0..0] -FeedState $feedMap | ConvertFrom-Json
Assert-True 'versions.json: dlssnr optional' ($null -eq $vdoc2.components.dlssnr)
Assert-True 'versions.json: single archive list' ($vdoc2.archives.Count -eq 1)

# ---------------------------------------------------------------- integration suite (frozen release fixtures)
# Runs with -Integration (also wired into .github/workflows/ota-release.yml). Downloads the real
# release artifacts listed in tests/fixtures/manifest.json (re-frozen each release), verifies every
# archive SHA-256, extracts, and validates: exact DLL set, per-group FileVersion consistency,
# versionless DLLs, per-DLL SHA-256 pins, release-tag identity, and agreement of the frozen dlssnr
# artifact with the module's pin spec (Get-UnverifiedDlssnrSpec).
if ($Integration) {
    Write-Host "`n=== Integration suite: frozen release fixtures ===" -ForegroundColor Cyan
    $manifestPath = Join-Path $repoRoot 'tests\fixtures\manifest.json'
    Assert-True 'fixtures: frozen manifest exists' (Test-Path $manifestPath)
    $fixturesData = Get-Content $manifestPath -Raw | ConvertFrom-Json

    function Test-PeHeader([string]$Path) {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $m = New-Object byte[] 2
            [void]$fs.Read($m, 0, 2)
            return ($m[0] -eq 0x4D -and $m[1] -eq 0x5A)
        } finally { $fs.Dispose() }
    }

    # stable cache dir: re-verified against the manifest pin on every run, so a re-download
    # only happens when the cached copy is missing or corrupt
    $cache = Join-Path ([System.IO.Path]::GetTempPath()) 'ota-fixture-cache'
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('ota-fixture-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $groupVersions = @{}
    try {
        New-Item -ItemType Directory $work, $cache -Force | Out-Null
        foreach ($art in $fixturesData.artifacts) {
            $archive = Join-Path $cache $art.name
            $pin = $art.sha256.ToLowerInvariant()
            if ((Test-Path $archive) -and ((Get-FileSha256 $archive).ToLowerInvariant() -ne $pin)) { Remove-Item $archive -Force }
            if (-not (Test-Path $archive)) {
                Write-Host "  download $($art.name)" -ForegroundColor DarkGray
                Invoke-WebRequest -Uri $art.url -OutFile $archive -UseBasicParsing
            }
            Assert-True "archive sha256 matches frozen pin: $($art.name)" ((Get-FileSha256 $archive).ToLowerInvariant() -eq $pin)

            $dest = Join-Path $work ($art.name + '.x')
            Expand-7zArchive $archive $dest
            $dlls = @(Get-ChildItem $dest -Filter '*.dll')
            Assert-True "DLL count matches frozen manifest: $($art.name) (expected $($art.expect.dllCount))" ($dlls.Count -eq $art.expect.dllCount)
            $actualNames = @($dlls | Sort-Object Name | ForEach-Object { $_.Name })
            $expectedNames = @($art.expect.dllNames | Sort-Object)
            Assert-True "DLL set matches frozen manifest exactly: $($art.name)" ((Compare-Object $actualNames $expectedNames).Count -eq 0)
            foreach ($dll in $dlls) { Assert-True "PE gate: $($dll.Name) ($($art.name))" (Test-PeHeader $dll.FullName) }

            foreach ($grp in $art.expect.groups) {
                $ver = $null; $ok = $true
                foreach ($dll in ($dlls | Where-Object { $_.Name -match $grp.pattern })) {
                    $short = Get-FilePeVersion $dll.FullName
                    if ($short -ne $grp.version) { $ok = $false }
                    if (-not $ver) { $ver = $short } elseif ($short -ne $ver) { $ok = $false }
                }
                if ($grp.id) { $groupVersions[$grp.id] = $ver }
                Assert-True "dependency consistency: $($grp.name) all share FileVersion $($grp.version) ($($art.name))" $ok
            }
            foreach ($name in @($art.expect.versionless)) {
                $dll = $dlls | Where-Object { $_.Name -eq $name }
                Assert-True "versionless DLL present with empty FileVersion: $name ($($art.name))" ($null -ne $dll -and -not (Get-FilePeVersion $dll.FullName))
            }
            if ($art.expect.PSObject.Properties['dllSha256']) {
                foreach ($p in $art.expect.dllSha256.PSObject.Properties) {
                    $dll = $dlls | Where-Object { $_.Name -eq $p.Name }
                    Assert-True "DLL sha256 pin: $($p.Name) ($($art.name))" ($null -ne $dll -and (Get-FileSha256 $dll.FullName).ToLowerInvariant() -eq $p.Value.ToLowerInvariant())
                }
            }
        }

        Assert-True "tag identity: dlss FileVersion $($fixturesData.tagIdentity.dlss) matches release tag" ($groupVersions['nvngx'] -eq $fixturesData.tagIdentity.dlss)
        Assert-True "tag identity: sl FileVersion $($fixturesData.tagIdentity.sl) matches release tag" ($groupVersions['sl'] -eq $fixturesData.tagIdentity.sl)

        $spec = Get-UnverifiedDlssnrSpec
        $snrFixture = $fixturesData.artifacts | Where-Object { $_.name -eq $spec.AssetName }
        Assert-True 'frozen dlssnr artifact URL agrees with module pin spec' ($null -ne $snrFixture -and $snrFixture.url -eq $spec.Url)
        Assert-True 'frozen dlssnr DLL pin agrees with module pin spec' ($null -ne $snrFixture -and $snrFixture.expect.dllSha256.'nvngx_dlssnr.dll' -eq $spec.Sha256)
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- summary
if ($script:failed -gt 0) {
    Write-Host "`n$script:failed test(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "`nALL TESTS PASS" -ForegroundColor Green
