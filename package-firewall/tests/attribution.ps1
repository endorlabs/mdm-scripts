# tests/attribution.ps1: dot-sourced by the VS Code suites after they set $RootDir, $TempDir,
# $Namespace, $KeyId and $Secret.
# Set-FakeConsoleUser replaces Find-ConsoleUser in a generated endor-vscode.ps1, so no one is logged
# in unless Set-ConsoleUser names someone, and the user running the tests stays out of the URLs they
# check. The fake answers from a file, so a worker that is already running sees a user log in.

# The machine name in labels, as lib/attribution.ps1's Get-EndorHostLabel gets it.
$HostLabel = & { . (Join-Path $RootDir 'package-firewall\powershell\lib\attribution.ps1'); Get-EndorHostLabel }

# Get-AttributedUrl <label> [secret]: the gallery URL attributed to label, built as the firewall
# decodes it: base64url(base64(base64("userattr:" + label) + ":" + key ID) + ":" + secret).
function Get-AttributedUrl {
    param([string]$Label, [string]$ApiSecret = $Secret)
    $utf8 = [Text.Encoding]::UTF8
    $inner = [Convert]::ToBase64String($utf8.GetBytes("userattr:$Label"))
    $user = [Convert]::ToBase64String($utf8.GetBytes("${inner}:$KeyId"))
    $token = [Convert]::ToBase64String($utf8.GetBytes("${user}:$ApiSecret")).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    "https://factory.endorlabs.com/v1/namespaces/$Namespace/firewall/vscode/_ak/$token"
}

$ConsoleUserFile = Join-Path $TempDir 'console-user'
$env:ENDOR_TEST_CONSOLE_FILE = $ConsoleUserFile

# Set-ConsoleUser [user]: logs user in, or no one.
function Set-ConsoleUser {
    param([string]$User)
    if ($User) {
        [IO.File]::WriteAllText($ConsoleUserFile, $User, [Text.UTF8Encoding]::new($false))
    } else {
        Remove-Item -LiteralPath $ConsoleUserFile -Force -ErrorAction SilentlyContinue
    }
}

# Add-ToInlinedCommon <code> [script]: puts code at the end of each lib/attribution.ps1 that the
# script (the endor-vscode.ps1 that $Generator writes, by default) carries, its own and its
# worker's, where it replaces what that file defines.
function Add-ToInlinedCommon {
    param([string]$Code, [string]$Path = (Join-Path (Split-Path $Generator) "out\$Namespace\endor-vscode.ps1"))
    $text = [IO.File]::ReadAllText($Path)
    $commons = [regex]::Matches($text, '(?ms)^# -- (Common functions \(inlined from lib/attribution\.ps1 and lib/common\.ps1\)|User attribution \(inlined from lib/attribution\.ps1\)) --\r?$.*?^# --\r?$')
    if ($commons.Count -ne 2) { throw "$Path carries lib/attribution.ps1 $($commons.Count) times, not 2" }
    for ($i = $commons.Count - 1; $i -ge 0; $i--) {
        $text = $text.Insert($commons[$i].Index + $commons[$i].Value.LastIndexOf('# --'), "$Code`n")
    }
    # With a BOM, as the generator writes it, so Windows PowerShell 5.1 reads it as UTF-8.
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($true))
}

function Set-FakeConsoleUser {
    Add-ToInlinedCommon @'
function Find-ConsoleUser {
    $file = $env:ENDOR_TEST_CONSOLE_FILE
    if ($file -and [IO.File]::Exists($file)) {
        $user = [IO.File]::ReadAllText($file)
        if ($user) { [PSCustomObject]@{ Username = $user } }
    }
}
'@
}
