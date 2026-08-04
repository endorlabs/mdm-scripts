#!/usr/bin/env pwsh
# End-to-end against the script generate.ps1 actually produces.
#
# The generated installer cannot be run wholesale off-Windows: its header calls
# Get-ConsoleUser, which uses [WindowsIdentity]::GetCurrent(). So the header is
# stubbed and everything after it is extracted verbatim from the generated file and
# executed for real — block splitting, token construction, the patch loop, the state
# writes, the watcher call, and the repatch counter.
#
# What that leaves uncovered, on every platform, is the header itself: console-user
# detection and the HKCU environment writes. Those need a Windows box. The stub is
# deliberately narrow so it is obvious what is and is not being exercised.
#
# Discovery is redirected at the one call site that resolves install roots, so this
# can never reach a real VS Code installation.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Harness.ps1')
. $LIB

$T = Join-Path ([System.IO.Path]::GetTempPath()) ("pse2e-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $T | Out-Null
$env:ENDOR_VSCODE_STATE_DIR = (Join-Path $T 'state')
try {

Write-Host '== 0. generate from the working tree, in a sandbox =='
# The generator writes to <generator dir>/out/<namespace> with no override, so it runs
# against a copy. That keeps the checkout clean and lets the rotation case regenerate
# with different credentials for free.
$SBPF = Join-Path $T 'pf'
Copy-PackageFirewall $SBPF
$GENPS = Join-Path $SBPF 'powershell'
function Invoke-Generate([string]$Secret) {
    $env:ENDOR_NAMESPACE = 'spiderman'
    $env:ENDOR_API_KEY_ID = 'TESTKEYID'
    $env:ENDOR_API_SECRET = $Secret
    & pwsh -NoProfile -File (Join-Path $GENPS 'generate.ps1') *>&1 | Out-String
}
$genlog = Invoke-Generate 'TESTSECRET'
$OUTDIR = Join-Path $GENPS 'out/spiderman'
if (Test-Path (Join-Path $OUTDIR 'endor-vscode.ps1')) { ok 'generate.ps1 produced endor-vscode.ps1' }
else { bad "generate.ps1 failed: $genlog"; Summarize }
if (Test-Path (Join-Path $OUTDIR 'endor-vscode-repatch.ps1')) { ok 'generate.ps1 produced the repatch script' }
else { bad 'repatch script missing' }
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $OUTDIR 'endor-vscode.ps1'), [ref]$null, [ref]$errs)
if ($errs.Count -eq 0) { ok 'endor-vscode.ps1 parses' } else { bad "parse errors: $($errs[0].Message)" }

Write-Host '== 1. fixture installs =='
New-FixtureInstall (Join-Path $T 'Microsoft VS Code')          'Visual Studio Code'            $null
New-FixtureInstall (Join-Path $T 'Microsoft VS Code Insiders') 'Visual Studio Code - Insiders' $null
$PJ  = Join-Path $T 'Microsoft VS Code/resources/app/product.json'
$PJI = Join-Path $T 'Microsoft VS Code Insiders/resources/app/product.json'
$PRISTINE  = Join-Path $T 'pristine.json';  Copy-Item $PJ  $PRISTINE
$PRISTINEI = Join-Path $T 'pristinei.json'; Copy-Item $PJI $PRISTINEI
$ROOTS = @((Join-Path $T 'Microsoft VS Code'), (Join-Path $T 'Microsoft VS Code Insiders'))
ok 'built stable and Insiders fixture installs'

# Get-ShippedBody — everything from the gallery-block assignment to the exit-code
# footer, taken verbatim. Only the discovery call is rewritten, and the rewrite is
# verified: without it this suite would patch the real VS Code on this machine.
function Get-ShippedBody([string]$File, [string]$Anchor = '$VSCODE_GALLERY_BLOCK') {
    $raw = [System.IO.File]::ReadAllText($File)
    $i = $raw.IndexOf($Anchor)
    if ($i -lt 0) { throw "anchor '$Anchor' not found in $File — the generator's layout changed" }
    $j = $raw.IndexOf('# -- Exit non-zero if any warnings')
    if ($j -lt 0) { $j = $raw.Length }
    $body = $raw.Substring($i, $j - $i)
    $needle = 'Get-VSCodeInstallPath -UserHome $UserHome'
    if (-not $body.Contains($needle)) { throw "discovery call site not found in $File — refusing to run" }
    $body.Replace($needle, 'Get-VSCodeInstallPath -Roots $ROOTS')
}

$INSTALL_BODY = Get-ShippedBody (Join-Path $OUTDIR 'endor-vscode.ps1')
$REPATCH_BODY = Get-ShippedBody (Join-Path $OUTDIR 'endor-vscode-repatch.ps1') '$DryRun = $false'
ok 'extracted both shipped bodies with discovery redirected'

# Invoke-Body — the header stub: exactly the variables script-header.ps1 establishes,
# and nothing more.
function Invoke-Body([string]$Body, [switch]$DryRunSw, [switch]$NoWatcher, [switch]$Repatch) {
    if ($Repatch) {
        # The repatch prelude ships inside the body and establishes its own state.
        $sb = @"
`$ErrorActionPreference = 'Stop'
. '$LIB'
`$ROOTS = @('$($ROOTS[0])', '$($ROOTS[1])')
$Body
"@
    } else {
        $sb = @"
`$ErrorActionPreference = 'Stop'
. '$LIB'
`$DryRun = `$$([bool]$DryRunSw)
`$NoVSCodeWatcher = `$$([bool]$NoWatcher)
`$EndorWarned = `$false
`$ConsoleUser = 'jane'
`$UserHome = '$T/home'
`$ROOTS = @('$($ROOTS[0])', '$($ROOTS[1])')
$Body
"@
    }
    $f = Join-Path $T ("body-" + [guid]::NewGuid().ToString('N') + '.ps1')
    [System.IO.File]::WriteAllText($f, $sb)
    $out = & pwsh -NoProfile -File $f 2>&1 | Out-String
    Remove-Item $f -Force
    $out
}

Write-Host '== 2. install patches both editions =='
$out = Invoke-Body $INSTALL_BODY
if (Test-JsonValid $PJ) { ok 'stable valid JSON' } else { bad "stable INVALID: $out" }
if (Test-JsonValid $PJI) { ok 'Insiders valid JSON' } else { bad 'Insiders INVALID' }
if ((Get-Content $PJ -Raw) -match '/firewall/vscode/_ak/') { ok 'stable points at the firewall' } else { bad "stable not patched: $out" }
if ((Get-Content $PJI -Raw) -match '/firewall/vscode/_ak/') { ok 'Insiders points at the firewall' } else { bad 'Insiders not patched' }
$g = (Get-Content $PJ -Raw | ConvertFrom-Json).extensionsGallery
chk 'unpkg fallback removed' ($null -eq $g.extensionUrlTemplate) 'True'
chk "controlUrl (Microsoft's revocation list) preserved" ($g.controlUrl.StartsWith('https://main.vscode-cdn.net')) 'True'
chk 'accessSKUs preserved' $g.accessSKUs.Count $FIXTURE_SKUS
if ($out -match 'Visual Studio Code - Insiders') { ok 'Insiders reported by name' } else { bad 'Insiders not named' }
if ($out -match 'user attribution -> jane@') { ok 'attribution label built from the console user' } else { bad "no attribution line: $out" }

Write-Host '== 3. the token matches an independent computation =='
# base64url(base64(base64("userattr:"+label) + ":" + keyId) + ":" + secret), padding
# stripped — the same scheme every other ecosystem uses, recomputed here from scratch
# rather than read back out of the lib.
$inner = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('userattr:jane@' + (Get-EndorHostLabel)))
$attr  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($inner + ':TESTKEYID'))
$want  = ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($attr + ':TESTSECRET'))).Replace('+','-').Replace('/','_').TrimEnd('=')
$got   = ([regex]::Match((Get-Content $PJ -Raw), '/_ak/([A-Za-z0-9_-]+)')).Groups[1].Value
chk 'attributed base64url token is correct' $got $want

Write-Host '== 4. sidecar state and the repatch payload =='
chk 'gallery_url recorded for the watcher to reuse' ((Get-VSCodeState 'gallery_url') -match '/_ak/') 'True'
chk 'user_home recorded' (Get-VSCodeState 'user_home') "$T/home"
$rp = Join-Path $env:ENDOR_VSCODE_STATE_DIR 'endor-vscode-repatch.ps1'
if (Test-Path $rp) { ok 'repatch payload decoded to a stable path' } else { bad 'repatch payload missing' }
# Not a copy of $PSCommandPath: MDM tools routinely run scripts from a temp file that
# is already gone by the time the task fires.
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($rp, [ref]$null, [ref]$errs)
if ($errs.Count -eq 0) { ok 'decoded payload parses' } else { bad "decoded payload has parse errors: $($errs[0].Message)" }
if ((Get-Content $rp -Raw) -eq (Get-Content (Join-Path $OUTDIR 'endor-vscode-repatch.ps1') -Raw)) {
    ok 'decoded payload is byte-identical to the generated copy'
} else { bad 'payload differs from the generated script' }
if ($IsWindows) {
    skip 'watcher registration (would leave a real Scheduled Task on this host)'
} elseif ($out -match 'Scheduled Task cmdlets unavailable') {
    ok 'watcher degraded loudly off-Windows rather than silently'
} else { bad 'no watcher warning off-Windows' }

Write-Host '== 5. idempotency =='
$h = (Get-FileHash $PJ).Hash
$out = Invoke-Body $INSTALL_BODY
chk 'no bytes changed on a re-run' ((Get-FileHash $PJ).Hash -eq $h) 'True'
if ($out -match 'already current') { ok 'reported already-current' } else { bad 'did not report a no-op' }

Write-Host '== 6. simulate a VS Code update, then run the repatch body =='
Copy-Item $PRISTINE $PJ -Force; Copy-Item $PRISTINEI $PJI -Force
if ((Get-Content $PJ -Raw) -match '_ak/') { bad 'sanity: should be pristine' } else { ok 'product.json clobbered (update simulated)' }
$out = Invoke-Body $REPATCH_BODY -Repatch
if ((Get-Content $PJ -Raw) -match '/firewall/vscode/_ak/') { ok 'stable re-patched' } else { bad "repatch failed: $out" }
if ((Get-Content $PJI -Raw) -match '/firewall/vscode/_ak/') { ok 'Insiders re-patched' } else { bad 'Insiders not re-patched' }
chk 'repatch_count incremented to 2, one per edition' (Get-VSCodeState 'repatch_count') '2'
chk 'last_repatch stamped' ((Get-VSCodeState 'last_repatch') -match '^\d{4}-') 'True'
# The watcher can fire at startup with nobody logged in, so recomputing attribution
# there would mint a token attributed to no user at all.
if ($out -notmatch 'user attribution') { ok 'repatch did not recompute attribution' } else { bad 'repatch recomputed attribution' }
$gotAfter = ([regex]::Match((Get-Content $PJ -Raw), '/_ak/([A-Za-z0-9_-]+)')).Groups[1].Value
chk 'repatch reused the SAME attributed token, not one for an empty user' $gotAfter $want

Write-Host '== 7. the next install run surfaces the count =='
$out = Invoke-Body $INSTALL_BODY
if ($out -match 're-applied the patch 2x') { ok 'the update race is visible in the output' }
else { bad "count not surfaced: $out" }

Write-Host '== 8. -NoVSCodeWatcher is loud but not a failure =='
Copy-Item $PRISTINE $PJ -Force; Copy-Item $PRISTINEI $PJI -Force
$out = Invoke-Body $INSTALL_BODY -NoWatcher
if ($out -match 'watcher skipped') { ok 'stated the opt-out' } else { bad 'no opt-out message' }
# Failing every check-in over a deliberate setting is alert fatigue, and alert fatigue
# is how real warnings end up ignored.
if ($out -match 'WARNING') { bad 'the opt-out emitted a warning' } else { ok 'no warning raised for a chosen setting' }
chk 'state still recorded, so the watcher can be enabled later' ((Get-VSCodeState 'gallery_url') -match '/_ak/') 'True'

Write-Host '== 9. dry-run writes nothing and does not print the credential =='
Copy-Item $PRISTINE $PJ -Force
$out = Invoke-Body $INSTALL_BODY -DryRunSw
chk 'no bytes written' ((Get-FileHash $PJ).Hash -eq (Get-FileHash $PRISTINE).Hash) 'True'
if ($out -match [regex]::Escape($want)) { bad 'dry-run leaked the token' }
elseif ($out -match '_ak/<redacted>') { ok 'token redacted' }
else { bad "unexpected dry-run output: $out" }

Write-Host '== 10. credential rotation is detected and re-applied =='
$out = Invoke-Body $INSTALL_BODY
$null = Invoke-Generate 'ROTATEDSECRET'
$ROTATED_BODY = Get-ShippedBody (Join-Path $OUTDIR 'endor-vscode.ps1')
$out = Invoke-Body $ROTATED_BODY
chk 'exactly one marker, no accumulation' `
  (([regex]::Matches([System.IO.File]::ReadAllText($PJ), '_endorPackageFirewall')).Count) 1
if (Test-JsonValid $PJ) { ok 'valid JSON after rotation' } else { bad 'invalid after rotation' }
if ($out -match 'out of date') { ok 'reported stale and restored before re-patching' } else { bad "did not report stale: $out" }
$rotToken = ([regex]::Match((Get-Content $PJ -Raw), '/_ak/([A-Za-z0-9_-]+)')).Groups[1].Value
if ($rotToken -ne $want) { ok 'the new credential is in place' } else { bad 'still using the old token' }

Write-Host '== 11. removal restores pristine bytes =='
foreach ($p in @($PJ, $PJI)) { $null = Invoke-VSCodeUnpatch -FilePath $p }
chk 'stable byte-identical to pristine' ((Get-FileHash $PJ).Hash -eq (Get-FileHash $PRISTINE).Hash) 'True'
chk 'Insiders byte-identical to pristine' ((Get-FileHash $PJI).Hash -eq (Get-FileHash $PRISTINEI).Hash) 'True'
$null = Uninstall-VSCodeWatcher
chk 'sidecar removed' (Test-Path -LiteralPath $env:ENDOR_VSCODE_STATE_DIR) 'False'

} finally {
    Remove-Item -Recurse -Force $T -ErrorAction SilentlyContinue
}
Summarize
