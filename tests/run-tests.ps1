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

# ---------------------------------------------------------------- newest-channel resolution
Assert-True 'resolve: production newer -> Production' ((Resolve-NewestChannel $staging3109 $production31010) -eq 'Production')
Assert-True 'resolve: staging newer -> Staging' ((Resolve-NewestChannel $staging3109 $production3107) -eq 'Staging')
Assert-True 'resolve: equal -> Staging (default)' ((Resolve-NewestChannel $staging3109 ($staging3109 -replace 'x', 'x')) -eq 'Staging')
Assert-True 'resolve: production manifest missing -> Staging' ((Resolve-NewestChannel $staging3109 $null) -eq 'Staging')
Assert-True 'resolve: staging manifest missing -> Production' ((Resolve-NewestChannel $null $production3107) -eq 'Production')

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

# ---------------------------------------------------------------- summary
if ($script:failed -gt 0) {
    Write-Host "`n$script:failed test(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "`nALL TESTS PASS" -ForegroundColor Green
