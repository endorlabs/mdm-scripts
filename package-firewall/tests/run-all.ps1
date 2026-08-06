#!/usr/bin/env pwsh
# Runs the PowerShell suites and aggregates the tallies.
#
#   ./run-all.ps1              all PowerShell suites
#   ./run-all.ps1 lib          only suites whose name matches
#
# This exists so a Windows admin can validate before pushing to a fleet without
# needing bash or WSL. The bash suites cover the same ground for macOS and Linux and
# are run by ./run-all.sh — which will also run these when pwsh is on PATH.
#
# Nothing here needs Administrator, and nothing touches an installed VS Code: the
# suites work on copies of tests/fixtures/product.json inside a temp directory.
param([string[]]$Filter = @())

Set-Location $PSScriptRoot

$suites = @(
    @{ Name = 'powershell/json-primitives'; Path = 'powershell/json-primitives.ps1' },
    @{ Name = 'powershell/lib';             Path = 'powershell/lib.ps1' },
    @{ Name = 'powershell/e2e';             Path = 'powershell/e2e.ps1' }
)

$totPass = 0; $totFail = 0; $totSkip = 0; $failedSuites = @()

foreach ($s in $suites) {
    if ($Filter.Count -gt 0 -and -not ($Filter | Where-Object { $s.Name -like "*$_*" })) { continue }
    Write-Host ''
    Write-Host "--- $($s.Name) ---"
    $out = & pwsh -NoProfile -File $s.Path 2>&1 | Out-String
    $rc = $LASTEXITCODE
    Write-Host $out.TrimEnd()

    $m = [regex]::Match($out, 'passed (\d+), failed (\d+)(?:, skipped (\d+))?')
    if ($m.Success) {
        $totPass += [int]$m.Groups[1].Value
        $totFail += [int]$m.Groups[2].Value
        if ($m.Groups[3].Success) { $totSkip += [int]$m.Groups[3].Value }
    } else {
        # No tally means the suite died before finishing, which must not read as a pass.
        $totFail += 1
    }
    if ($rc -ne 0) { $failedSuites += $s.Name }
}

Write-Host ''
Write-Host '--- total ---'
if ($totSkip -gt 0) { Write-Host "passed $totPass, failed $totFail, skipped $totSkip" }
else { Write-Host "passed $totPass, failed $totFail" }
if ($failedSuites.Count -gt 0) {
    Write-Host "failing suites: $($failedSuites -join ', ')"
    exit 1
}
if ($totFail -gt 0) { exit 1 }
