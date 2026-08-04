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
# Suites are discovered by glob (powershell/*.ps1, minus the dot-sourced harness), so
# adding one needs no edit here.
#
# Nothing here needs Administrator, and nothing touches an installed VS Code: the
# suites work on copies of tests/fixtures/product.json inside a temp directory.
param([string[]]$Filter = @())

Set-Location $PSScriptRoot

$suites = Get-ChildItem -LiteralPath 'powershell' -Filter '*.ps1' |
    Where-Object { $_.Name -ne 'Harness.ps1' } |
    Sort-Object Name

$totPass = 0; $totFail = 0; $totSkip = 0; $failedSuites = @(); $ran = 0

foreach ($s in $suites) {
    $name = 'powershell/' + $s.BaseName
    if ($Filter.Count -gt 0 -and -not ($Filter | Where-Object { $name -like "*$_*" })) { continue }
    Write-Host ''
    Write-Host "--- $name ---"
    $out = & pwsh -NoProfile -File $s.FullName 2>&1 | Out-String
    $rc = $LASTEXITCODE
    Write-Host $out.TrimEnd()
    $ran++

    $m = [regex]::Match($out, 'passed (\d+), failed (\d+)(?:, skipped (\d+))?')
    if ($m.Success) {
        $totPass += [int]$m.Groups[1].Value
        $totFail += [int]$m.Groups[2].Value
        if ($m.Groups[3].Success) { $totSkip += [int]$m.Groups[3].Value }
    } else {
        # No tally means the suite died before finishing, which must not read as a pass.
        $totFail += 1
    }
    if ($rc -ne 0) { $failedSuites += $name }
}

Write-Host ''
Write-Host '--- total ---'
if ($ran -eq 0) { Write-Host 'no suites matched'; exit 1 }
if ($totSkip -gt 0) { Write-Host "passed $totPass, failed $totFail, skipped $totSkip" }
else { Write-Host "passed $totPass, failed $totFail" }
if ($failedSuites.Count -gt 0) {
    Write-Host "failing suites: $($failedSuites -join ', ')"
    exit 1
}
if ($totFail -gt 0) { exit 1 }
