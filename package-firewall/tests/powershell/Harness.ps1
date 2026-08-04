# Shared harness for the PowerShell suites. Dot-sourced, never run directly.

# ─── Paths ────────────────────────────────────────────────────────────────────
# Derived from this file's location, so the suites run from any cwd and from a
# checkout at any path.
$script:TESTS_DIR = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:PF_DIR    = (Resolve-Path (Join-Path $TESTS_DIR '..')).Path
$script:PS_DIR    = Join-Path $PF_DIR 'powershell'
$script:LIB       = Join-Path $PS_DIR 'lib/common.ps1'
$script:FIXTURE   = Join-Path $TESTS_DIR 'fixtures/product.json'

# Facts about the fixture that several suites assert against. The bash harness
# carries the same set; they must agree, because both ports are tested against the
# same file and the sentinel contract requires their output to be interchangeable.
$script:FIXTURE_LINES         = 74   # real lines; the last one has no newline
$script:FIXTURE_GALLERY_LINES = 28   # extensionsGallery incl. opening and closing
$script:FIXTURE_GALLERY_KEYS  = 9
$script:FIXTURE_SKUS          = 16
$script:FIXTURE_VERSION       = '1.999.0'
$script:FIXTURE_COMMIT        = '0123456789abcdef0123456789abcdef01234567'

# ─── Counters ─────────────────────────────────────────────────────────────────
$script:pass = 0; $script:fail = 0; $script:skipped = 0
function ok($m)   { Write-Host "  ok   $m"; $script:pass++ }
function bad($m)  { Write-Host "  FAIL $m"; $script:fail++ }
function skip($m) { Write-Host "  skip $m"; $script:skipped++ }
function chk($m, $got, $want) {
    if ("$got" -eq "$want") { ok $m } else { bad "$m (got [$got] want [$want])" }
}

# Summarize — print the tally and exit. Last line of every suite.
function Summarize {
    Write-Host ''
    if ($script:skipped -gt 0) {
        Write-Host "passed $script:pass, failed $script:fail, skipped $script:skipped"
    } else {
        Write-Host "passed $script:pass, failed $script:fail"
    }
    if ($script:fail -gt 0) { exit 1 }
}

# ─── Helpers ──────────────────────────────────────────────────────────────────
# Get-DiffLineCount — the equivalent of `diff a b | grep -c '^[<>]'`, without
# needing git or diff on the box. Used to assert that a patch touches only the
# lines it claims to.
function Get-DiffLineCount([string]$A, [string]$B) {
    $x = [System.IO.File]::ReadAllText($A) -split "`r`n|`n"
    $y = [System.IO.File]::ReadAllText($B) -split "`r`n|`n"
    (Compare-Object -ReferenceObject $x -DifferenceObject $y).Count
}

# Set-NameLong — copy the fixture with nameLong replaced, which is how the two
# editions are told apart. ReadAllText/WriteAllText round-trip byte-for-byte, so the
# fixture's absent final newline survives — every byte-exactness assertion
# downstream depends on that.
function Set-NameLong([string]$Src, [string]$Dst, [string]$Long) {
    $t = [System.IO.File]::ReadAllText($Src)
    $t = [regex]::Replace($t, '"nameLong"\s*:\s*"[^"]*"', ('"nameLong": "' + $Long + '"'))
    [System.IO.File]::WriteAllText($Dst, $t, [System.Text.UTF8Encoding]::new($false))
}

# New-FixtureInstall — a Windows-shaped install root: <root>\resources\app\product.json.
# The Code.exe shim stands in for the bundled Electron the fallback writer uses;
# ELECTRON_RUN_AS_NODE is simply ignored by real node.
function New-FixtureInstall([string]$Root, [string]$Long, [string]$NodeBin) {
    New-Item -ItemType Directory -Path (Join-Path $Root 'resources/app') -Force | Out-Null
    Set-NameLong $script:FIXTURE (Join-Path $Root 'resources/app/product.json') $Long
    if ($NodeBin) {
        $shim = Join-Path $Root 'Code.exe'
        [System.IO.File]::WriteAllText($shim, "#!/bin/sh`nexec $NodeBin `"`$@`"`n")
        if ($IsMacOS -or $IsLinux) { & chmod +x $shim }
    }
}

# Copy-PackageFirewall — the generators write to <generator dir>/out/<namespace> with
# no override, so the e2e suite copies the working tree and generates there. That
# keeps the checkout clean and keeps this branch additive: no product code changes to
# accommodate the tests.
function Copy-PackageFirewall([string]$Dest) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    Copy-Item -Path (Join-Path $script:PF_DIR '*') -Destination $Dest -Recurse -Force
    Get-ChildItem -LiteralPath $Dest -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'out' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
