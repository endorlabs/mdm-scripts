# The ExtensionGalleryServiceUrl policy in the registry, set by endor-vscode.ps1 and removed by
# endor-remove.ps1. ENDOR_VSCODE_POLICY_KEY moves the key under HKCU, so this needs no machine-wide
# change. Windows only.
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'skip: the VS Code policy tests use the registry, so they run on Windows only'
    exit 0
}

$TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path (Join-Path $TestDir '..\..')).Path
$Generator = Join-Path $RootDir 'package-firewall\powershell\generate.ps1'
$Fixture = Join-Path $TestDir 'fixtures\vscode-product.json'
$Namespace = 'ci-smoke'
$KeyId = 'ci-smoke-key-id'
$Secret = 'ci-smoke-secret'
$Out = Join-Path $RootDir "package-firewall\powershell\out\$Namespace"
$TempDir = Join-Path ([IO.Path]::GetTempPath()) "endor-vscode-policy-tests-$([Guid]::NewGuid().ToString('N'))"
$KeyRoot = "Software\Endor Labs Tests\vscode-policy-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $TempDir | Out-Null

function Get-ServiceUrl {
    param([string]$ApiSecret)
    $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${KeyId}:$ApiSecret")).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    "https://factory.endorlabs.com/v1/namespaces/$Namespace/firewall/vscode/_ak/$token"
}
$ExpectedUrl = Get-ServiceUrl $Secret

function Invoke-Generate {
    param([string]$ApiSecret = $Secret, [string]$Patch = '0', [string]$Policy = '1', [string]$Auth = '')
    $env:ENDOR_NAMESPACE = $Namespace
    $env:ENDOR_API_KEY_ID = $KeyId
    $env:ENDOR_API_SECRET = $ApiSecret
    $env:ENDOR_VSCODE_ENABLE_PATCH = $Patch
    $env:ENDOR_VSCODE_ENABLE_POLICY = $Policy
    $env:ENDOR_VSCODE_POLICY_AUTH = $Auth
    $global:LASTEXITCODE = 0
    & $Generator *> $null
    if ($LASTEXITCODE) { throw "generator failed with exit code $LASTEXITCODE" }
}

# Each case gets a VS Code install, product.json state, policy key and record of its own.
function New-Case {
    param([string]$Name, [string]$Version = '1.141.2')
    $dir = Join-Path $TempDir $Name
    New-Item -ItemType Directory -Path (Join-Path $dir 'app') -Force | Out-Null
    Copy-Item $Fixture (Join-Path $dir 'app\product.json')
    [IO.File]::WriteAllText((Join-Path $dir 'app\package.json'), "{`"name`": `"code`", `"version`": `"$Version`"}")
    $script:Case = [PSCustomObject]@{
        Product = Join-Path $dir 'app\product.json'
        State = Join-Path $dir 'state'
        Key = "$KeyRoot\$Name"
        Record = Join-Path $dir 'policy-state'
    }
    $env:ENDOR_VSCODE_PRODUCT_JSON = $Case.Product
    $env:ENDOR_VSCODE_STATE_DIR = $Case.State
    $env:ENDOR_VSCODE_POLICY_KEY = $Case.Key
    $env:ENDOR_VSCODE_POLICY_STATE_DIR = $Case.Record
    $env:ENDOR_VSCODE_SKIP_WATCHER = '1'
}

# Runs a script and returns its output; the exit code is in $script:Rc.
function Invoke-Script {
    param([string]$Path, [switch]$DryRun)
    $global:LASTEXITCODE = 0
    $output = if ($DryRun) { & $Path -DryRun *>&1 | Out-String -Width 4096 } else { & $Path *>&1 | Out-String -Width 4096 }
    $script:Rc = $LASTEXITCODE
    $output
}

function Invoke-Install {
    param([switch]$DryRun)
    Invoke-Script (Join-Path $Out 'endor-vscode.ps1') -DryRun:$DryRun
}

# Runs only the VS Code section of endor-remove.ps1, which needs no signed-in user and leaves this
# machine's own files and environment alone.
function Invoke-Remove {
    param([switch]$DryRun)
    $text = Get-Content -Raw (Join-Path $Out 'endor-remove.ps1')
    $section = [regex]::Match($text, '(?ms)^# >>> endor-vscode-remove\r?$.*?^# <<< endor-vscode-remove\r?$').Value
    if (-not $section) { throw 'endor-remove.ps1 has no VS Code section' }
    $path = Join-Path $TempDir 'remove-section.ps1'
    $body = "param([switch]`$DryRun)`n`$ErrorActionPreference = 'Stop'`n`$EndorWarned = `$false`n$section`nif (`$EndorWarned) { exit 1 }`n"
    [IO.File]::WriteAllText($path, $body, [Text.UTF8Encoding]::new($true))
    Invoke-Script $path -DryRun:$DryRun
}

function Get-PolicyValue {
    param([string]$Name)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Case.Key)
    if (-not $key) { return '<no key>' }
    try {
        $value = $key.GetValue($Name)
        if ($null -eq $value) { '<none>' } else { [string]$value }
    } finally {
        $key.Dispose()
    }
}

function Set-PolicyValue {
    param([string]$Name, [string]$Value)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Case.Key)
    try { $key.SetValue($Name, $Value, 'String') } finally { $key.Dispose() }
}

function Assert-Rc {
    param([int]$Expected, [string]$Output)
    if ($Rc -ne $Expected) { throw "expected exit $Expected, got $Rc`n$Output" }
}

function Assert-Output {
    param([string]$Output, [string]$Text)
    if (-not $Output.Contains($Text)) { throw "expected the output to contain: $Text`n$Output" }
}

try {
    Write-Host 'test: the policy goes into a new key, once'
    Invoke-Generate
    New-Case 'create'
    $output = Invoke-Install
    Assert-Rc 0 $output
    if ((Get-PolicyValue 'ExtensionGalleryServiceUrl') -cne $ExpectedUrl) { throw 'the URL is not set' }
    if ((Get-PolicyValue 'ExtensionGalleryAuthProvider') -ne '<none>') { throw 'the auth provider was set without AUTH' }
    Assert-Output $output 'Copilot Business or Enterprise'
    if ((Get-Content -Raw (Join-Path $Case.Record 'record.json')) -match '_ak/') { throw 'the record contains the URL' }
    if ((Get-FileHash $Case.Product).Hash -ne (Get-FileHash $Fixture).Hash) { throw 'the policy alone changed product.json' }
    if (Test-Path -LiteralPath $Case.State) { throw 'the policy alone installed the patch' }
    $output = Invoke-Install
    Assert-Rc 0 $output
    Assert-Output $output 'policy already set'

    Write-Host 'test: other values stay, and a rotated credential replaces the URL'
    New-Case 'merge'
    Set-PolicyValue 'UpdateMode' 'none'
    Set-PolicyValue 'ExtensionGalleryServiceUrl' ''
    $output = Invoke-Install
    Assert-Rc 0 $output
    if ((Get-PolicyValue 'UpdateMode') -ne 'none') { throw 'another value was lost' }
    if ((Get-PolicyValue 'ExtensionGalleryServiceUrl') -cne $ExpectedUrl) { throw 'an empty URL was not replaced' }
    Invoke-Generate -ApiSecret 'ci-smoke-rotated-secret'
    $output = Invoke-Install
    Assert-Rc 0 $output
    if ((Get-PolicyValue 'ExtensionGalleryServiceUrl') -cne (Get-ServiceUrl 'ci-smoke-rotated-secret')) { throw 'the rotated URL was not written' }
    Invoke-Generate

    Write-Host "test: a gallery that isn't Endor's is left alone"
    New-Case 'foreign'
    Set-PolicyValue 'ExtensionGalleryServiceUrl' 'https://gallery.example.invalid/_apis/public/gallery'
    $output = Invoke-Install
    Assert-Rc 1 $output
    Assert-Output $output 'sets ExtensionGalleryServiceUrl to another gallery'
    if ((Get-PolicyValue 'ExtensionGalleryServiceUrl') -ne 'https://gallery.example.invalid/_apis/public/gallery') { throw 'a foreign gallery was changed' }

    Write-Host "test: the sign-in provider is set, changed and cleared, and someone else's is kept"
    New-Case 'auth'
    Invoke-Generate -Auth 'microsoft'
    $output = Invoke-Install
    Assert-Rc 0 $output
    if ((Get-PolicyValue 'ExtensionGalleryAuthProvider') -ne 'microsoft') { throw 'AUTH=microsoft was not set' }
    Assert-Output $output 'Microsoft Entra ID work or school account'
    Invoke-Generate -Auth 'github'
    $output = Invoke-Install
    Assert-Rc 0 $output
    if ((Get-PolicyValue 'ExtensionGalleryAuthProvider') -ne 'github') { throw 'AUTH was not changed to github' }
    Invoke-Generate
    $output = Invoke-Install
    Assert-Rc 0 $output
    if ((Get-PolicyValue 'ExtensionGalleryAuthProvider') -ne '<none>') { throw 'an unset AUTH did not clear the value it wrote' }
    New-Case 'auth-foreign'
    Set-PolicyValue 'ExtensionGalleryAuthProvider' 'github'
    Invoke-Generate -Auth 'microsoft'
    $output = Invoke-Install
    Assert-Rc 1 $output
    Assert-Output $output "sets ExtensionGalleryAuthProvider to 'github'"
    if ((Get-PolicyValue 'ExtensionGalleryAuthProvider') -ne 'github') { throw "someone else's provider was changed" }
    if ((Get-PolicyValue 'ExtensionGalleryServiceUrl') -cne $ExpectedUrl) { throw 'the URL was not set' }
    Invoke-Generate
    $output = Invoke-Install
    Assert-Rc 0 $output
    if ((Get-PolicyValue 'ExtensionGalleryAuthProvider') -ne 'github') { throw "someone else's provider was removed" }

    Write-Host 'test: a dry run changes nothing'
    New-Case 'dry-run'
    $output = Invoke-Install -DryRun
    Assert-Rc 0 $output
    Assert-Output $output '[dry-run]   action : SET ExtensionGalleryServiceUrl'
    if ((Get-PolicyValue 'ExtensionGalleryServiceUrl') -ne '<no key>') { throw 'a dry run created the key' }
    if (Test-Path -LiteralPath $Case.Record) { throw 'a dry run wrote the record' }

    Write-Host 'test: a VS Code too old for the policy is reported'
    New-Case 'old-vscode' '1.98.2'
    $output = Invoke-Install
    Assert-Rc 1 $output
    Assert-Output $output "VS Code 1.98.2 ($($Case.Product)) doesn't read the ExtensionGalleryServiceUrl policy; 1.99 and later do."
    Invoke-Generate -Patch '1'
    New-Case 'old-vscode-patched' '1.98.2'
    $output = Invoke-Install
    Assert-Rc 0 $output
    Assert-Output $output "The patch covers it until it's updated."
    Invoke-Generate -Auth 'microsoft'
    New-Case 'old-vscode-auth' '1.120.0'
    $output = Invoke-Install
    Assert-Rc 1 $output
    Assert-Output $output 'ignores ExtensionGalleryAuthProvider'
    Invoke-Generate

    Write-Host "test: endor-remove.ps1 removes only Endor's policy"
    New-Case 'remove-created'
    Invoke-Generate -Auth 'microsoft'
    $output = Invoke-Install
    Assert-Rc 0 $output
    $output = Invoke-Remove
    Assert-Rc 0 $output
    if ((Get-PolicyValue 'ExtensionGalleryServiceUrl') -ne '<no key>') { throw 'removal left the key it created' }
    if (Test-Path -LiteralPath $Case.Record) { throw 'removal left the record' }
    Invoke-Generate
    New-Case 'remove-shared'
    Set-PolicyValue 'UpdateMode' 'none'
    Set-PolicyValue 'ExtensionGalleryAuthProvider' 'github'
    $output = Invoke-Install
    Assert-Rc 0 $output
    $output = Invoke-Remove
    Assert-Rc 0 $output
    if ((Get-PolicyValue 'ExtensionGalleryServiceUrl') -ne '<none>') { throw 'removal left the URL' }
    if ((Get-PolicyValue 'UpdateMode') -ne 'none') { throw 'removal took another value' }
    if ((Get-PolicyValue 'ExtensionGalleryAuthProvider') -ne 'github') { throw "removal took someone else's provider" }
    New-Case 'remove-unrecorded'
    Set-PolicyValue 'ExtensionGalleryServiceUrl' $ExpectedUrl
    $output = Invoke-Remove -DryRun
    Assert-Rc 0 $output
    Assert-Output $output '[dry-run]   action : REMOVE ExtensionGalleryServiceUrl'
    if ((Get-PolicyValue 'ExtensionGalleryServiceUrl') -cne $ExpectedUrl) { throw 'a dry run removed the policy' }
    $output = Invoke-Remove
    Assert-Rc 1 $output
    Assert-Output $output 'Intune Settings Catalog'
    if ((Get-PolicyValue 'ExtensionGalleryServiceUrl') -ne '<none>') { throw 'removal left an unrecorded Endor URL' }
    New-Case 'remove-nothing'
    $output = Invoke-Remove
    Assert-Rc 0 $output
    Assert-Output $output 'skip (no Endor VS Code policy'

    Write-Host 'test: a policy left by an earlier deployment is reported, and left in place'
    New-Case 'leftover'
    $output = Invoke-Install
    Assert-Rc 0 $output
    Invoke-Generate -Patch '1' -Policy '0'
    $output = Invoke-Install
    Assert-Rc 1 $output
    Assert-Output $output 'policy from an earlier deployment is still set'
    if ((Get-PolicyValue 'ExtensionGalleryServiceUrl') -cne $ExpectedUrl) { throw 'the policy was removed' }
    Invoke-Generate

    $global:LASTEXITCODE = 0
    Write-Host 'VS Code policy PowerShell tests passed'
} finally {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\Endor Labs Tests', $false)
    foreach ($name in 'ENDOR_VSCODE_PRODUCT_JSON', 'ENDOR_VSCODE_STATE_DIR', 'ENDOR_VSCODE_POLICY_KEY',
            'ENDOR_VSCODE_POLICY_STATE_DIR', 'ENDOR_VSCODE_SKIP_WATCHER', 'ENDOR_VSCODE_ENABLE_PATCH',
            'ENDOR_VSCODE_ENABLE_POLICY', 'ENDOR_VSCODE_POLICY_AUTH') {
        Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
