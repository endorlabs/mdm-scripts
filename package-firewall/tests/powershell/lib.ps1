#!/usr/bin/env pwsh
# The PowerShell VS Code lifecycle: discovery, the three-state machine, patch,
# restore, both writer paths, and the failure modes that must be loud.
#
# Two surfaces genuinely cannot run off-Windows — Scheduled Task registration and
# %ProgramFiles% / AppData discovery. They are skipped explicitly rather than quietly
# passed, because a suite that reports green on a Mac while never touching the Windows
# code path is worse than no suite at all. They still need a Windows box before this
# ships to a Windows fleet.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Harness.ps1')
. $LIB

$NODE = (Get-Command node -ErrorAction SilentlyContinue).Source
$T = Join-Path ([System.IO.Path]::GetTempPath()) ("psvsc-" + [guid]::NewGuid().ToString('N'))
$env:ENDOR_VSCODE_STATE_DIR = (Join-Path $T 'state')
try {

# Windows-shaped install roots: <root>\resources\app\product.json.
New-FixtureInstall (Join-Path $T 'Microsoft VS Code')          'Visual Studio Code'            $NODE
New-FixtureInstall (Join-Path $T 'Microsoft VS Code Insiders') 'Visual Studio Code - Insiders' $NODE
$PJ  = Join-Path $T 'Microsoft VS Code/resources/app/product.json'
$PJI = Join-Path $T 'Microsoft VS Code Insiders/resources/app/product.json'
$PRISTINE = Join-Path $T 'pristine.json'
Copy-Item $PJ $PRISTINE

$URL = 'https://factory.endorlabs.com/v1/namespaces/spiderman/firewall/vscode/_ak/dGVzdHVzZXI6c2VjcmV0'
$SET = @("`"serviceUrl`": `"$URL`"")
$DEL = @('extensionUrlTemplate')
$FQDN = 'https://factory.endorlabs.com'

Write-Host '== 1. discovery =='
$found = Get-VSCodeInstallPath -Roots @((Join-Path $T 'Microsoft VS Code'), (Join-Path $T 'Microsoft VS Code Insiders'))
chk 'finds both editions' $found.Count 2
chk 'edition label read from nameLong' (Get-VSCodeEditionLabel $PJI) 'Visual Studio Code - Insiders'
chk 'install root resolved' ((Get-VSCodeInstallRoot $PJ) -eq (Join-Path $T 'Microsoft VS Code')) 'True'
if ($NODE) {
    # Never hardcode the executable name: it differs between stable and Insiders.
    chk 'node bin resolved as Code.exe' (Split-Path -Leaf (Get-VSCodeNodeBin $PJ)) 'Code.exe'
} else { skip 'node bin (no node on PATH)' }
chk 'can write a writable file' (Test-VSCodeCanWrite $PJ) 'True'
chk 'the writability probe left the content alone' ((Get-FileHash $PJ).Hash -eq (Get-FileHash $PRISTINE).Hash) 'True'

Write-Host '== 2. patch =='
chk 'unmanaged before patching' (Get-VSCodeManagedState -FilePath $PJ -Url $URL -DeleteKeys $DEL) 'unmanaged'
$rc = Invoke-VSCodePatch -FilePath $PJ -Url $URL -SetLines $SET -DeleteKeys $DEL -Namespace 'spiderman' -Fqdn $FQDN
chk 'patch returns 0' $rc 0
if (Test-JsonValid $PJ) { ok 'valid JSON' } else { bad 'INVALID JSON' }
chk 'state is now current' (Get-VSCodeManagedState -FilePath $PJ -Url $URL -DeleteKeys $DEL) 'current'
chk 'marker records via=ps' (Get-VSCodeMarkerField -FilePath $PJ -Field 'via') 'ps'
chk 'marker records appVersion' (Get-VSCodeMarkerField -FilePath $PJ -Field 'appVersion') $FIXTURE_VERSION
chk 'final newline still absent, as the source had none' ((Get-JsonDoc $PJ).HadFinalNewline) 'False'
$g = (Get-Content $PJ -Raw | ConvertFrom-Json).extensionsGallery
chk 'serviceUrl set' ($g.serviceUrl -eq $URL) 'True'
chk 'extensionUrlTemplate gone (the 5xx unpkg bypass)' ($null -eq $g.extensionUrlTemplate) 'True'
chk 'controlUrl preserved' ($g.controlUrl.StartsWith('https://main.vscode-cdn.net')) 'True'
chk 'resourceUrlTemplate preserved' ($g.resourceUrlTemplate.StartsWith('https://{publisher}')) 'True'
chk 'accessSKUs preserved' $g.accessSKUs.Count $FIXTURE_SKUS

Write-Host '== 3. idempotency =='
$h = (Get-FileHash $PJ).Hash
$rc = Invoke-VSCodePatch -FilePath $PJ -Url $URL -SetLines $SET -DeleteKeys $DEL -Namespace 'spiderman' -Fqdn $FQDN
chk 're-patch returns 2 (already current)' $rc 2
chk 'no bytes changed' ((Get-FileHash $PJ).Hash -eq $h) 'True'

Write-Host '== 4. credential rotation: stale -> restore, then patch =='
# Never patch on top of a patch. Restoring first is what lets credentials rotate
# indefinitely without the captured original drifting.
$URL2 = $URL + 'rotated'
chk 'rotation detected as stale' (Get-VSCodeManagedState -FilePath $PJ -Url $URL2 -DeleteKeys $DEL) 'stale'
$rc = Invoke-VSCodePatch -FilePath $PJ -Url $URL2 -SetLines @("`"serviceUrl`": `"$URL2`"") -DeleteKeys $DEL -Namespace 'spiderman' -Fqdn $FQDN
chk 'patch after rotation returns 0' $rc 0
chk 'current at the new URL' (Get-VSCodeManagedState -FilePath $PJ -Url $URL2 -DeleteKeys $DEL) 'current'
chk 'exactly one marker, no accumulation' (([regex]::Matches([System.IO.File]::ReadAllText($PJ), '_endorPackageFirewall')).Count) 1
if (Test-JsonValid $PJ) { ok 'valid JSON after rotation' } else { bad 'INVALID after rotation' }

Write-Host '== 5. unpatch restores pristine bytes =='
$rc = Invoke-VSCodeUnpatch -FilePath $PJ
chk 'unpatch returns 0' $rc 0
chk 'byte-identical to pristine, after two patch cycles' ((Get-FileHash $PJ).Hash -eq (Get-FileHash $PRISTINE).Hash) 'True'
$rc = Invoke-VSCodeUnpatch -FilePath $PJ
chk 'unpatch on an unmanaged file is a no-op success' $rc 0

Write-Host '== 6. the node writer, on a minified product.json =='
if ($NODE) {
    $MIN = Join-Path $T 'Microsoft VS Code/resources/app/min.json'
    [System.IO.File]::WriteAllText($MIN, ((Get-Content $PRISTINE -Raw | ConvertFrom-Json) | ConvertTo-Json -Depth 100 -Compress))
    chk 'range lookup returns null (the fallback trigger)' `
      ($null -eq (Get-JsonTopObjectRange -Lines (Get-JsonDoc $MIN).Lines -Key 'extensionsGallery')) 'True'
    $rc = Invoke-VSCodePatch -FilePath $MIN -Url $URL -SetLines $SET -DeleteKeys $DEL -Namespace 'spiderman' -Fqdn $FQDN
    chk 'patch via the node writer returns 0' $rc 0
    if (Test-JsonValid $MIN) { ok 'node-written file valid' } else { bad 'node-written INVALID' }
    # The node writer pretty-prints, so the marker spans several lines. This catches a
    # marker reader that only handles the single-line form.
    chk 'marker records via=node' (Get-VSCodeMarkerField -FilePath $MIN -Field 'via') 'node'
    $gm = (Get-Content $MIN -Raw | ConvertFrom-Json).extensionsGallery
    chk 'the node path applied the same two edits' (($gm.serviceUrl -eq $URL) -and ($null -eq $gm.extensionUrlTemplate)) 'True'
    $rc = Invoke-VSCodeUnpatch -FilePath $MIN
    chk 'node unpatch returns 0' $rc 0
    $dm = Get-Content $MIN -Raw | ConvertFrom-Json
    chk 'node restore dropped the marker' ($null -eq $dm._endorPackageFirewall) 'True'
    chk 'node restore reinstated extensionUrlTemplate' ($dm.extensionsGallery.extensionUrlTemplate.StartsWith('https://www.vscode-unpkg.net')) 'True'
} else { skip 'node writer fallback (no node on PATH)' }

Write-Host '== 7. validation refuses a corrupt candidate =='
$BAD = Join-Path $T 'bad.json'; [System.IO.File]::WriteAllText($BAD, 'not json')
chk 'rejects non-JSON' (Test-JsonValid $BAD) 'False'
$B2 = Join-Path $T 'b2.json'; [System.IO.File]::WriteAllText($B2, "{`n`t`"a`": 1,`n}")
chk 'rejects a trailing-comma object' (Test-JsonValid $B2) 'False'

Write-Host '== 8. an unwritable file is reported, not half-applied =='
$RO = Join-Path $T 'ro.json'; Copy-Item $PRISTINE $RO
if ($IsWindows) {
    skip 'unwritable-file path (chmod is not the mechanism on Windows)'
} elseif ((& id -u) -eq '0') {
    skip 'unwritable-file path (running as root, chmod cannot simulate it)'
} else {
    & chmod 444 $RO
    $rc = Invoke-VSCodePatch -FilePath $RO -Url $URL -SetLines $SET -DeleteKeys $DEL -Namespace 'ns' -Fqdn 'https://f' -WarningAction SilentlyContinue
    chk 'patch fails on an unwritable file' $rc 1
    chk 'file left untouched' ((Get-FileHash $RO).Hash -eq (Get-FileHash $PRISTINE).Hash) 'True'
}

Write-Host '== 9. dry-run writes nothing and does not print the credential =='
$DRY = Join-Path $T 'dry.json'; Copy-Item $PRISTINE $DRY
$out = Invoke-VSCodePatch -FilePath $DRY -Url $URL -SetLines $SET -DeleteKeys $DEL -Namespace 'spiderman' -Fqdn 'https://f' -DryRun 6>&1 | Out-String
chk 'no bytes written' ((Get-FileHash $DRY).Hash -eq (Get-FileHash $PRISTINE).Hash) 'True'
# The token is a bearer credential in a URL path, and MDM logs are read by more people
# than product.json is.
if ($out -match 'dGVzdHVzZXI6c2VjcmV0') { bad 'dry-run leaked the token' }
elseif ($out -match '_ak/<redacted>') { ok 'token redacted in dry-run output' }
else { bad "unexpected dry-run output: $out" }

Write-Host '== 10. sidecar telemetry =='
# The update race cannot be closed; counting re-applies is what makes it visible in
# an MDM log rather than invisible.
Set-VSCodeState -Key 'repatch_count' -Value '4'
Set-VSCodeState -Key 'last_repatch' -Value '2026-08-04T12:00:00Z'
chk 'state round-trips' (Get-VSCodeState 'repatch_count') '4'
Set-VSCodeState -Key 'repatch_count' -Value '5'
chk 'a key is replaced, not appended' (Get-VSCodeState 'repatch_count') '5'
chk 'exactly one repatch_count line after the update' `
  (([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $env:ENDOR_VSCODE_STATE_DIR 'state')), '(?m)^repatch_count=')).Count) 1
$rep = Write-VSCodeStateReport 6>&1 | Out-String
if ($rep -match '5x' -or ((Write-VSCodeStateReport | Out-String) -match '5x')) { ok 'report surfaces the count' }
else { bad "report empty: $rep" }

Write-Host '== 11. Windows-only surfaces =='
if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
    # On a real Windows host these are reachable, but registering a system task from a
    # test would leave state behind on the box, so only the dry-run is exercised.
    skip 'Scheduled Task registration (would leave a real task on this host)'
    skip '%ProgramFiles% / AppData discovery (needs a real install to be meaningful)'
} else {
    $r = Install-VSCodeWatcher -ScriptPath 'C:\x.ps1' -WarningAction SilentlyContinue
    chk 'watcher install degrades to a warning without the cmdlets' $r 'False'
    skip 'Scheduled Task registration (needs Windows)'
    skip '%ProgramFiles% / AppData discovery (needs Windows)'
}
$dr = Install-VSCodeWatcher -ScriptPath 'C:\x.ps1' -DryRun
chk 'watcher dry-run reports without touching anything' $dr 'True'

Write-Host '== 12. cross-check against the real installed product.json, if there is one =='
# The fixture mirrors a shipped product.json but is not one. Nothing version-specific
# is asserted here, so this keeps working across VS Code updates.
$REAL = @(
    '/Applications/Visual Studio Code.app/Contents/Resources/app/product.json',
    "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/product.json",
    "$env:ProgramFiles\Microsoft VS Code\resources\app\product.json",
    "$env:LOCALAPPDATA\Programs\Microsoft VS Code\resources\app\product.json",
    '/usr/share/code/resources/app/product.json'
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $REAL) {
    skip 'real-install round-trip (no VS Code installation found)'
} else {
    Write-Host "  (using $REAL)"
    $RJ = Join-Path $T 'real.json'; $RP = Join-Path $T 'real-pristine.json'
    Copy-Item $REAL $RJ; Copy-Item $REAL $RP
    $rc = Invoke-VSCodePatch -FilePath $RJ -Url $URL -SetLines $SET -DeleteKeys $DEL -Namespace 'spiderman' -Fqdn $FQDN
    chk 'patch of the real file returns 0' $rc 0
    if (Test-JsonValid $RJ) { ok 'real file still valid JSON' } else { bad 'real file INVALID' }
    $rg = (Get-Content $RJ -Raw | ConvertFrom-Json).extensionsGallery
    chk 'real file: serviceUrl set and the unpkg fallback removed' `
      (($rg.serviceUrl -eq $URL) -and ($null -eq $rg.extensionUrlTemplate)) 'True'
    # 3 lines for the two key edits, plus 1 for the inserted marker.
    chk 'real file: diff is the 2 key edits plus the marker, nothing else' (Get-DiffLineCount $RP $RJ) 4
    $rc = Invoke-VSCodeUnpatch -FilePath $RJ
    chk 'unpatch of the real file returns 0' $rc 0
    chk 'real file restored byte-for-byte' ((Get-FileHash $RJ).Hash -eq (Get-FileHash $RP).Hash) 'True'
}

} finally {
    if ($IsMacOS -or $IsLinux) { & chmod -R u+w $T 2>$null }
    Remove-Item -Recurse -Force $T -ErrorAction SilentlyContinue
}
Summarize
