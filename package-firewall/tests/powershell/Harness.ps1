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
