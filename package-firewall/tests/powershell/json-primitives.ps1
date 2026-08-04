#!/usr/bin/env pwsh
# The PowerShell JSON primitives, mirroring tests/bash/json-primitives.sh
# assertion for assertion.
#
# The mirroring is the point. The two generators write the same marker key and the
# same patched lines into the same file, and an admin may well run the bash script on
# a Mac and the PowerShell one on Windows against installs managed as one fleet. If
# the ports drift — a different indent, a different comma, a different marker shape —
# one platform's output stops being readable by the other's state machine, and that
# shows up as a mysterious re-patch loop rather than as an error.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Harness.ps1')
. $LIB

$T = Join-Path ([System.IO.Path]::GetTempPath()) ("psjson-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $T | Out-Null
try {

$PJ       = Join-Path $T 'product.json'
$PRISTINE = Join-Path $T 'pristine.json'
Copy-Item $FIXTURE $PJ
Copy-Item $FIXTURE $PRISTINE

$URL = 'https://factory.endorlabs.com/v1/namespaces/spiderman/firewall/vscode/_ak/dGVzdDp0b2tlbg'
$SET = @("`"serviceUrl`": `"$URL`"")
$DEL = @('extensionUrlTemplate')

Write-Host '== 1. document round-trip preserves layout =='
$doc = Get-JsonDoc $PJ
chk 'final newline absent, as in a shipped product.json' $doc.HadFinalNewline 'False'
chk 'newline flavour detected as LF' ($doc.NewLine -eq "`n") 'True'
chk 'line count' $doc.Lines.Count $FIXTURE_LINES
Set-JsonDoc -Doc $doc -FilePath $PJ
chk 'read plus write with no edits is byte-identical' `
  ((Get-FileHash $PJ).Hash -eq (Get-FileHash $PRISTINE).Hash) 'True'

Write-Host '== 2. extract a depth-1 object =='
$blk = Get-JsonTopObjectBlock -Lines $doc.Lines -Key 'extensionsGallery'
chk 'block line count' $blk.Count $FIXTURE_GALLERY_LINES
chk 'opening line' ($blk[0] -replace "`t", '@') '@"extensionsGallery": {'
chk 'closing line' ($blk[$blk.Count - 1] -replace "`t", '@') '@},'
chk 'a missing key returns null' ($null -eq (Get-JsonTopObjectBlock -Lines $doc.Lines -Key 'noSuchKey')) 'True'
chk 'top-level version, not the nested one in builtInExtensions' `
  (Get-JsonTopString -Lines $doc.Lines -Key 'version') $FIXTURE_VERSION
chk 'top-level commit' (Get-JsonTopString -Lines $doc.Lines -Key 'commit') $FIXTURE_COMMIT

Write-Host '== 3. the actual patch: set serviceUrl, delete extensionUrlTemplate =='
$doc = Get-JsonDoc $PJ
$new = Set-JsonObjectKeys -Lines $doc.Lines -Key 'extensionsGallery' -SetLines $SET -DeleteKeys $DEL
if ($null -eq $new) { bad 'merge returned null' } else {
    $doc.Lines = $new; Set-JsonDoc -Doc $doc -FilePath $PJ
    if (Test-JsonValid $PJ) { ok 'valid JSON' } else { bad 'INVALID JSON' }
    $g = (Get-Content $PJ -Raw | ConvertFrom-Json).extensionsGallery
    chk 'serviceUrl set' ($g.serviceUrl -eq $URL) 'True'
    chk 'extensionUrlTemplate gone (the 5xx unpkg bypass)' ($null -eq $g.extensionUrlTemplate) 'True'
    chk "controlUrl left alone (Microsoft's revocation list)" ($g.controlUrl.StartsWith('https://main.vscode-cdn.net')) 'True'
    chk 'resourceUrlTemplate left alone' ($g.resourceUrlTemplate.StartsWith('https://{publisher}')) 'True'
    chk 'accessSKUs untouched by a key-level merge' $g.accessSKUs.Count $FIXTURE_SKUS
    chk 'final-newline fidelity kept' ((Get-JsonDoc $PJ).HadFinalNewline) 'False'
    # One line replaced plus one line removed. This is what makes "one key set, one
    # key removed" a checked claim rather than an intention.
    chk 'diff touches only the 2 intended keys' (Get-DiffLineCount $PRISTINE $PJ) 3
}

Write-Host '== 4. delete the LAST entry, which is multi-line =='
# JSON has no trailing commas, so removing the final entry must fix up the one before.
$doc = Get-JsonDoc $PRISTINE
$doc.Lines = Set-JsonObjectKeys -Lines $doc.Lines -Key 'extensionsGallery' -SetLines @() -DeleteKeys @('accessSKUs')
$P2 = Join-Path $T 'droplast.json'; Set-JsonDoc -Doc $doc -FilePath $P2
if (Test-JsonValid $P2) { ok 'valid JSON after dropping the last multi-line entry' } else { bad 'INVALID' }
$blk2 = Get-JsonTopObjectBlock -Lines (Get-JsonDoc $P2).Lines -Key 'extensionsGallery'
chk 'the entry before it lost its comma' ($blk2[$blk2.Count - 2].Trim()) `
  '"mcpUrl": "https://main.vscode-cdn.net/mcp/servers.json"'

Write-Host '== 5. delete the FIRST entry, and append a new key =='
$doc = Get-JsonDoc $PRISTINE
$doc.Lines = Set-JsonObjectKeys -Lines $doc.Lines -Key 'extensionsGallery' -SetLines @() -DeleteKeys @('nlsBaseUrl')
$P3 = Join-Path $T 'dropfirst.json'; Set-JsonDoc -Doc $doc -FilePath $P3
if (Test-JsonValid $P3) { ok 'valid after dropping the first entry' } else { bad 'INVALID' }
$g3 = (Get-Content $P3 -Raw | ConvertFrom-Json).extensionsGallery
chk 'first entry gone, the rest intact' `
  (($null -eq $g3.nlsBaseUrl) -and ($g3.PSObject.Properties.Name.Count -eq ($FIXTURE_GALLERY_KEYS - 1))) 'True'

$doc = Get-JsonDoc $PRISTINE
$doc.Lines = Set-JsonObjectKeys -Lines $doc.Lines -Key 'extensionsGallery' -SetLines @('"endorProbe": "x"') -DeleteKeys @()
$P4 = Join-Path $T 'append.json'; Set-JsonDoc -Doc $doc -FilePath $P4
if (Test-JsonValid $P4) { ok 'valid after appending a new key' } else { bad 'INVALID' }
chk 'appended value readable' ((Get-Content $P4 -Raw | ConvertFrom-Json).extensionsGallery.endorProbe) 'x'
chk 'the preceding entry gained its comma' `
  ((Get-Content $P4 -Raw | ConvertFrom-Json).extensionsGallery.accessSKUs.Count) $FIXTURE_SKUS

Write-Host '== 6. idempotency =='
$h1 = (Get-FileHash $PJ).Hash
$doc = Get-JsonDoc $PJ
$doc.Lines = Set-JsonObjectKeys -Lines $doc.Lines -Key 'extensionsGallery' -SetLines $SET -DeleteKeys $DEL
Set-JsonDoc -Doc $doc -FilePath $PJ
chk 're-merge is byte-identical' ((Get-FileHash $PJ).Hash -eq $h1) 'True'

Write-Host '== 7. restore round-trip =='
$doc = Get-JsonDoc $PJ
$doc.Lines = Set-JsonTopObjectBlock -Lines $doc.Lines -Key 'extensionsGallery' -BlockLines $blk
Set-JsonDoc -Doc $doc -FilePath $PJ
chk 'restored byte-identical to pristine' ((Get-FileHash $PJ).Hash -eq (Get-FileHash $PRISTINE).Hash) 'True'

Write-Host '== 8. marker insert and removal =='
$MARK = "`t`"_endorPackageFirewall`": {`"schema`":1,`"namespace`":`"spiderman`"},"
$doc = Get-JsonDoc $PJ
$doc.Lines = Add-JsonTopLine -Lines $doc.Lines -Line $MARK
$P5 = Join-Path $T 'marked.json'; Set-JsonDoc -Doc $doc -FilePath $P5
if (Test-JsonValid $P5) { ok 'valid JSON with the marker' } else { bad 'INVALID with the marker' }
chk 'marker readable by a real parser' ((Get-Content $P5 -Raw | ConvertFrom-Json)._endorPackageFirewall.namespace) 'spiderman'
$doc = Get-JsonDoc $P5
$doc.Lines = Remove-JsonTopKey -Lines $doc.Lines -Key '_endorPackageFirewall'
$P6 = Join-Path $T 'unmarked.json'; Set-JsonDoc -Doc $doc -FilePath $P6
chk 'marker removal is byte-exact' ((Get-FileHash $P6).Hash -eq (Get-FileHash $PRISTINE).Hash) 'True'

Write-Host '== 9. shapes other than the shipped one =='
# 4-space indentation: the indent must be read from the file, never assumed.
$SP = Join-Path $T 'sp.json'
[System.IO.File]::WriteAllText($SP, "{`n    `"a`": 1,`n    `"extensionsGallery`": {`n        `"serviceUrl`": `"old`",`n        `"extensionUrlTemplate`": `"u`",`n        `"itemUrl`": `"i`"`n    },`n    `"z`": 2`n}`n")
$doc = Get-JsonDoc $SP
$doc.Lines = Set-JsonObjectKeys -Lines $doc.Lines -Key 'extensionsGallery' -SetLines $SET -DeleteKeys $DEL
Set-JsonDoc -Doc $doc -FilePath $SP
if (Test-JsonValid $SP) { ok '4-space-indented file valid' } else { bad 'space-indented INVALID' }
$o = Get-Content $SP -Raw | ConvertFrom-Json
chk 'space-indented: edit applied' ($o.extensionsGallery.serviceUrl -eq $URL) 'True'
chk 'space-indented: siblings intact' ($o.extensionsGallery.itemUrl + '/' + $o.z) 'i/2'
chk "the set line took the file's own 8-space indent, not a tab" `
  ((Get-LineIndent (Get-Content $SP | Where-Object { $_ -match 'factory' } | Select-Object -First 1)).Length) 8
chk 'space-indented file kept its final newline' ((Get-JsonDoc $SP).HadFinalNewline) 'True'

# Deleting the sole entry must leave a valid empty object, not a dangling comma.
$ONLY = Join-Path $T 'only.json'
[System.IO.File]::WriteAllText($ONLY, "{`n`t`"extensionsGallery`": {`n`t`t`"extensionUrlTemplate`": `"u`"`n`t}`n}`n")
$doc = Get-JsonDoc $ONLY
$doc.Lines = Set-JsonObjectKeys -Lines $doc.Lines -Key 'extensionsGallery' -SetLines @() -DeleteKeys $DEL
Set-JsonDoc -Doc $doc -FilePath $ONLY
if (Test-JsonValid $ONLY) { ok 'deleting the sole entry leaves a valid empty object' }
else { bad "sole-entry delete INVALID: $(Get-Content $ONLY -Raw)" }

# Minified: no depth-1 line range to edit, so the line writer must decline. That
# refusal is what hands off to the node writer.
$MIN = Join-Path $T 'min.json'
[System.IO.File]::WriteAllText($MIN, '{"extensionsGallery":{"serviceUrl":"old"},"z":1}')
chk 'minified: range lookup returns null (the fallback trigger)' `
  ($null -eq (Get-JsonTopObjectRange -Lines (Get-JsonDoc $MIN).Lines -Key 'extensionsGallery')) 'True'
chk 'minified: merge returns null' `
  ($null -eq (Set-JsonObjectKeys -Lines (Get-JsonDoc $MIN).Lines -Key 'extensionsGallery' -SetLines $SET -DeleteKeys $DEL)) 'True'

Write-Host '== 10. a CRLF file stays CRLF =='
# Windows tooling and some repackagers produce CRLF. Rewriting even one line to LF
# would show up as a whole-file diff and break byte-exact restore.
$CRLF = Join-Path $T 'crlf.json'
[System.IO.File]::WriteAllText($CRLF, "{`r`n`t`"extensionsGallery`": {`r`n`t`t`"serviceUrl`": `"old`"`r`n`t}`r`n}")
$doc = Get-JsonDoc $CRLF
chk 'CRLF detected' ($doc.NewLine -eq "`r`n") 'True'
$doc.Lines = Set-JsonObjectKeys -Lines $doc.Lines -Key 'extensionsGallery' -SetLines $SET -DeleteKeys $DEL
Set-JsonDoc -Doc $doc -FilePath $CRLF
if (Test-JsonValid $CRLF) { ok 'CRLF file still valid' } else { bad 'CRLF INVALID' }
chk 'CRLF preserved on write' ([System.IO.File]::ReadAllText($CRLF).Contains("`r`n")) 'True'
chk 'no bare LF introduced' `
  ([regex]::Matches([System.IO.File]::ReadAllText($CRLF), "(?<!`r)`n").Count) 0

Write-Host '== 11. validation refuses what it must =='
$BAD = Join-Path $T 'bad.json'; [System.IO.File]::WriteAllText($BAD, 'not json at all')
chk 'rejects non-JSON' (Test-JsonValid $BAD) 'False'
# ConvertFrom-Json accepts trailing commas in both 5.1 and 7.x, so validity alone is
# not enough — and a trailing comma is exactly what a bad comma rewrite produces.
$TC = Join-Path $T 'tc.json'; [System.IO.File]::WriteAllText($TC, "{`n`t`"a`": 1,`n}")
chk 'rejects a trailing comma, which ConvertFrom-Json would accept' (Test-JsonValid $TC) 'False'
$GOOD = Join-Path $T 'good.json'; [System.IO.File]::WriteAllText($GOOD, "{`n`t`"a`": 1`n}")
chk 'accepts good JSON' (Test-JsonValid $GOOD) 'True'

} finally {
    Remove-Item -Recurse -Force $T -ErrorAction SilentlyContinue
}
Summarize
