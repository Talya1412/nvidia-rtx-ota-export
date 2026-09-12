# Dependency-free test runner for the shared OTA logic (Ota.Common.psm1).
# Runs under Windows PowerShell 5.1 and PowerShell 7+. Exit 1 on any failure.
#requires -Version 5.1

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

Assert-True 'numeric compare: 310.10.0 > 310.9.0 (not lexicographic)' (Compare-OtaNewer '310.10.0' '310.9.0')
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

Assert-True 'newest tag: picks max among mixed list' ((Get-NewestReleaseTag @('v310.7.128-sl2.12.128', 'v310.9.0-sl2.14.0', 'v0.1-docs')) -eq 'v310.9.0-sl2.14.0')
Assert-True 'newest tag: empty list -> null' ($null -eq (Get-NewestReleaseTag @()))
Assert-True 'newest tag: numeric 310.10 beats 310.9' ((Get-NewestReleaseTag @('v310.10.0-sl2.14.0', 'v310.9.0-sl2.15.0')) -eq 'v310.10.0-sl2.14.0')

Assert-True 'gate: production candidate older than staging release -> skip (regression: stale publish)' (-not (Test-ReleaseTagNewer '310.7.128' '2.12.128' 'v310.9.0-sl2.14.0'))
Assert-True 'gate: candidate newer than latest -> publish' (Test-ReleaseTagNewer '310.9.0' '2.14.0' 'v310.7.128-sl2.12.128')
Assert-True 'gate: same version already released -> skip' (-not (Test-ReleaseTagNewer '310.9.0' '2.14.0' 'v310.9.0-sl2.14.0'))
Assert-True 'gate: numeric 310.10.0 > 310.9.0 -> publish' (Test-ReleaseTagNewer '310.10.0' '2.14.0' 'v310.9.0-sl2.14.0')
Assert-True 'gate: dlss equal, sl newer -> publish' (Test-ReleaseTagNewer '310.9.0' '2.15.0' 'v310.9.0-sl2.14.0')
Assert-True 'gate: dlss equal, sl older -> skip' (-not (Test-ReleaseTagNewer '310.9.0' '2.13.0' 'v310.9.0-sl2.14.0'))
Assert-True 'gate: unparseable existing tag does not block' (Test-ReleaseTagNewer '310.9.0' '2.14.0' 'some-other-tag')

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


# ---------------------------------------------------------------- driver OTA cache lookup
$cacheRoot1 = Join-Path ([System.IO.Path]::GetTempPath()) ('ota-cache-' + [guid]::NewGuid().ToString('N'))
$cacheRel = Join-Path $cacheRoot1 'models\dlss\versions\20318464\files\160_E658700.bin'
New-Item -ItemType Directory -Path (Split-Path $cacheRel -Parent) -Force | Out-Null
Set-Content -Path $cacheRel -Value 'payload-bytes'
$cacheRoot2 = Join-Path ([System.IO.Path]::GetTempPath()) ('ota-cache-' + [guid]::NewGuid().ToString('N'))
$cacheRel2 = Join-Path $cacheRoot2 'models\dlssd\versions\20318464\files\160_E658700.bin'
New-Item -ItemType Directory -Path (Split-Path $cacheRel2 -Parent) -Force | Out-Null
Set-Content -Path $cacheRel2 -Value 'payload-bytes-2'
try {
    Assert-True 'cache: hit under first root' ((Find-OtaCachedPayload @($cacheRoot1) 'dlss' '20318464' '160_E658700.bin') -eq $cacheRel)
    Assert-True 'cache: hit under second root when first misses' ((Find-OtaCachedPayload @("$cacheRoot1-missing", $cacheRoot2) 'dlssd' '20318464' '160_E658700.bin') -eq $cacheRel2)
    Assert-True 'cache: wrong packed version -> miss' ($null -eq (Find-OtaCachedPayload @($cacheRoot1) 'dlss' '20318080' '160_E658700.bin'))
    Assert-True 'cache: wrong payload file -> miss' ($null -eq (Find-OtaCachedPayload @($cacheRoot1) 'dlss' '20318464' '160_E658701.bin'))
    Assert-True 'cache: no roots exist -> null' ($null -eq (Find-OtaCachedPayload @('L:\definitely-not-a-real-root') 'dlss' '20318464' '160_E658700.bin'))
} finally {
    Remove-Item $cacheRoot1, $cacheRoot2 -Recurse -Force -ErrorAction SilentlyContinue
}
$win4 = Select-ComponentWinners @(@{ Source = 'ota-production'; Dlss = '310.8.0'; Sl = '2.13.0' })
Assert-True 'winners: single source -> that source' ($win4.DlssSource -eq 'ota-production' -and $win4.SlVersion -eq '2.13.0')

Assert-True 'sdk asset: x64 zip preferred over arch variants' ((Get-SdkZipAssetName @('streamline-sdk-v2.14.1-aarch64.zip', 'streamline-sdk-v2.14.1.zip', 'streamline-sdk-v2.14.1-arm64ec.zip')) -eq 'streamline-sdk-v2.14.1.zip')
Assert-True 'sdk asset: fallback to any zip' ((Get-SdkZipAssetName @('streamline-2.14.1.zip')) -eq 'streamline-2.14.1.zip')

# ---------------------------------------------------------------- summary
if ($script:failed -gt 0) {
    Write-Host "`n$script:failed test(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "`nALL TESTS PASS" -ForegroundColor Green
