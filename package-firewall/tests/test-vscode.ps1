$ErrorActionPreference = 'Stop'

$TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path (Join-Path $TestDir '..\..')).Path
$Generator = Join-Path $RootDir 'package-firewall\powershell\generate.ps1'
$Fixture = Join-Path $TestDir 'fixtures\vscode-product.json'
$Namespace = 'ci-smoke'
$KeyId = 'ci-smoke-key-id'
$Secret = 'ci-smoke-secret'
$ExpectedUrl = 'https://factory.endorlabs.com/v1/namespaces/ci-smoke/firewall/vscode/_ak/Y2ktc21va2Uta2V5LWlkOmNpLXNtb2tlLXNlY3JldA'
$DefaultServiceUrl = 'https://marketplace.visualstudio.com/_apis/public/gallery'
$DefaultExtensionUrlTemplate = 'https://www.vscode-unpkg.net/_gallery/{publisher}/{name}/latest'
$TempDir = Join-Path ([IO.Path]::GetTempPath()) "endor-vscode-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $TempDir | Out-Null

$SavedEnvironment = @{
    ProgramData = $env:ProgramData
    ProgramFiles = $env:ProgramFiles
    ProgramW6432 = $env:ProgramW6432
    ProgramFilesX86 = ${env:ProgramFiles(x86)}
    SystemDrive = $env:SystemDrive
}

function Invoke-Generate {
    param([string]$ApiSecret = $Secret, [string]$Patch = '1', [string]$Policy = '0', [string]$Auth = '')
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

# True when the generator refuses these flags.
function Test-GenerateRejected {
    param([string]$Patch = '1', [string]$Policy = '0', [string]$Auth = '')
    try {
        Invoke-Generate -Patch $Patch -Policy $Policy -Auth $Auth
        return $false
    } catch {
        return $true
    }
}

# Runs the generated installer and returns its output; the exit code is in $LASTEXITCODE.
function Invoke-InstallerOutput {
    param([string]$Product, [string]$State, [string]$Script)
    $env:ENDOR_VSCODE_PRODUCT_JSON = $Product
    $env:ENDOR_VSCODE_STATE_DIR = $State
    $env:ENDOR_VSCODE_SKIP_WATCHER = '1'
    if (-not $Script) { $Script = Join-Path $RootDir "package-firewall\powershell\out\$Namespace\endor-vscode.ps1" }
    $global:LASTEXITCODE = 0
    & $Script *>&1 | Out-String -Width 4096
}

function Invoke-Installer {
    param([string]$Product, [string]$State, [switch]$DryRun)
    $env:ENDOR_VSCODE_PRODUCT_JSON = $Product
    $env:ENDOR_VSCODE_STATE_DIR = $State
    $env:ENDOR_VSCODE_SKIP_WATCHER = '1'
    $script = Join-Path $RootDir "package-firewall\powershell\out\$Namespace\endor-vscode.ps1"
    $global:LASTEXITCODE = 0
    if ($DryRun) { & $script -DryRun } else { & $script }
    if ($LASTEXITCODE) { throw "installer failed with exit code $LASTEXITCODE" }
}

function Assert-Patched {
    param([string]$ProductPath, [string]$ServiceUrl = $ExpectedUrl)
    $product = Get-Content -LiteralPath $ProductPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($product.extensionsGallery.serviceUrl -ne $ServiceUrl) { throw 'serviceUrl was not patched exactly' }
    if ($product.extensionsGallery.PSObject.Properties['extensionUrlTemplate']) {
        throw 'extensionUrlTemplate was not removed'
    }
    if ($product.extensionsGallery.controlUrl -ne 'https://main.vscode-cdn.net/extensions/marketplace.json') {
        throw 'unrelated gallery data was not preserved'
    }
    if (-not $product.unknownFixtureData.preserve) { throw 'unknown product data was not preserved' }
}

function Assert-Restored {
    param([string]$ProductPath)
    $product = Get-Content -LiteralPath $ProductPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($product.extensionsGallery.serviceUrl -ne $DefaultServiceUrl) {
        throw 'default serviceUrl was not restored'
    }
    if ($product.extensionsGallery.extensionUrlTemplate -ne $DefaultExtensionUrlTemplate) {
        throw 'default extensionUrlTemplate was not restored'
    }
    if (-not $product.unknownFixtureData.preserve) { throw 'unknown product data was not preserved' }
}

# Everything but the two gallery settings is unchanged. The raw-text checks catch what a round
# trip through ConvertFrom-Json could hide: an empty array or object, or a one-element array.
function Assert-Preserved {
    param([string]$ProductPath)
    $raw = Get-Content -LiteralPath $ProductPath -Raw -Encoding UTF8
    foreach ($pattern in '"target":\s*"system"', '"win32VersionedUpdate":\s*true',
            '"emptyObject":\s*\{\s*\}', '"emptyArray":\s*\[\s*\]', '"oneItem":\s*\[\s*"only"\s*\]') {
        if ($raw -notmatch $pattern) { throw "product.json no longer matches $pattern" }
    }
    $expected = Get-Content -LiteralPath $Fixture -Raw -Encoding UTF8 | ConvertFrom-Json
    $actual = $raw | ConvertFrom-Json
    foreach ($product in $expected, $actual) {
        $product.extensionsGallery.PSObject.Properties.Remove('serviceUrl')
        $product.extensionsGallery.PSObject.Properties.Remove('extensionUrlTemplate')
    }
    if (($expected | ConvertTo-Json -Depth 100 -Compress) -ne ($actual | ConvertTo-Json -Depth 100 -Compress)) {
        throw 'product.json changed beyond the gallery settings'
    }
}

function Test-Patched {
    param([string]$ProductPath)
    try {
        $product = Get-Content -LiteralPath $ProductPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $product.extensionsGallery.serviceUrl -eq $ExpectedUrl
    } catch {
        $false
    }
}

function Wait-Until {
    param([scriptblock]$Condition, [double]$Seconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 100
    }
    [bool](& $Condition)
}

function Assert-FilesEqual {
    param([string]$Actual, [string]$Expected)
    $actualHash = (Get-FileHash -LiteralPath $Actual -Algorithm SHA256).Hash
    $expectedHash = (Get-FileHash -LiteralPath $Expected -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) { throw "files differ: $Actual and $Expected" }
}

$watcherProcess = $null
try {
    $env:ProgramData = $TempDir
    Invoke-Generate

    Write-Host 'test: patches product.json, preserves fields, and is idempotent'
    $product = Join-Path $TempDir 'basic-product.json'
    $state = Join-Path $TempDir 'basic-state'
    Copy-Item $Fixture $product
    Invoke-Installer $product $state
    Assert-Patched $product
    Assert-Preserved $product
    $before = (Get-FileHash $product -Algorithm SHA256).Hash
    Invoke-Installer $product $state
    $after = (Get-FileHash $product -Algorithm SHA256).Hash
    if ($before -ne $after) { throw 'idempotent run changed product.json' }
    & (Join-Path $state 'worker.ps1') -Mode Restore
    if ($LASTEXITCODE) { throw 'restore failed' }
    Assert-Restored $product
    Assert-Preserved $product

    Write-Host 'test: dry-run reports drift without writing'
    $product = Join-Path $TempDir 'dry-product.json'
    $state = Join-Path $TempDir 'dry-state'
    Copy-Item $Fixture $product
    $before = (Get-FileHash $product -Algorithm SHA256).Hash
    Invoke-Installer $product $state -DryRun
    $after = (Get-FileHash $product -Algorithm SHA256).Hash
    if ($before -ne $after) { throw 'dry-run changed product.json' }
    if (Test-Path $state) { throw 'dry-run created managed state' }

    Write-Host 'test: credential rotation preserves valid product.json modifications'
    $product = Join-Path $TempDir 'rotation-product.json'
    $state = Join-Path $TempDir 'rotation-state'
    Copy-Item $Fixture $product
    Invoke-Generate
    Invoke-Installer $product $state
    $modifiedProduct = Get-Content $product -Raw | ConvertFrom-Json
    $modifiedProduct.unknownFixtureData |
        Add-Member -NotePropertyName adminModification -NotePropertyValue 'keep-me'
    [IO.File]::WriteAllText(
        $product,
        (($modifiedProduct | ConvertTo-Json -Depth 100) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Invoke-Generate 'ci-smoke-rotated-secret'
    Invoke-Installer $product $state
    $modifiedProduct = Get-Content $product -Raw | ConvertFrom-Json
    if ($modifiedProduct.unknownFixtureData.adminModification -ne 'keep-me') {
        throw 'credential rotation lost an admin product.json modification'
    }
    & (Join-Path $state 'worker.ps1') -Mode Restore
    if ($LASTEXITCODE) { throw 'rotation restore failed' }
    Assert-Restored $product
    $modifiedProduct = Get-Content $product -Raw | ConvertFrom-Json
    if ($modifiedProduct.unknownFixtureData.adminModification -ne 'keep-me') {
        throw 'restoration lost an admin product.json modification'
    }

    Write-Host 'test: an updater overwrite is patched without losing new product data'
    $product = Join-Path $TempDir 'update-product.json'
    $updated = Join-Path $TempDir 'update-upstream.json'
    $state = Join-Path $TempDir 'update-state'
    Invoke-Generate
    Copy-Item $Fixture $product
    Invoke-Installer $product $state
    $newProduct = Get-Content $Fixture -Raw | ConvertFrom-Json
    $newProduct.commit = 'fixture-v2'
    $newProduct.extensionsGallery.serviceUrl = 'https://new-upstream.example/gallery'
    $newProduct.extensionsGallery.controlUrl = 'https://new-upstream.example/control'
    [IO.File]::WriteAllText(
        $updated,
        (($newProduct | ConvertTo-Json -Depth 100) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Copy-Item $updated $product -Force
    Invoke-Installer $product $state
    & (Join-Path $state 'worker.ps1') -Mode Restore
    if ($LASTEXITCODE) { throw 'update restore failed' }
    Assert-Restored $product
    $restoredUpdate = Get-Content $product -Raw | ConvertFrom-Json
    if ($restoredUpdate.commit -ne 'fixture-v2' -or
        $restoredUpdate.extensionsGallery.controlUrl -ne 'https://new-upstream.example/control') {
        throw 'restoration lost updated product.json data'
    }

    # ProgramFiles points elsewhere, as it does in 32-bit PowerShell (Intune's default), so the
    # install is found only through ProgramW6432.
    Write-Host 'test: current versioned Windows resource paths are discovered from 32-bit PowerShell'
    $versionRoot = Join-Path $TempDir 'fake-program-files'
    $x86Root = Join-Path $TempDir 'fake-program-files-x86'
    New-Item -ItemType Directory -Path $x86Root -Force | Out-Null
    $versionedProduct = Join-Path $versionRoot 'Microsoft VS Code\abcdef1234\resources\app\product.json'
    New-Item -ItemType Directory -Path (Split-Path $versionedProduct -Parent) -Force | Out-Null
    Copy-Item $Fixture $versionedProduct
    $env:ProgramFiles = $x86Root
    $env:ProgramW6432 = $versionRoot
    ${env:ProgramFiles(x86)} = ''
    $env:SystemDrive = $TempDir
    Remove-Item Env:\ENDOR_VSCODE_PRODUCT_JSON -ErrorAction SilentlyContinue
    $env:ENDOR_VSCODE_STATE_DIR = Join-Path $TempDir 'versioned-state'
    $env:ENDOR_VSCODE_SKIP_WATCHER = '1'
    $script = Join-Path $RootDir "package-firewall\powershell\out\$Namespace\endor-vscode.ps1"
    & $script
    if ($LASTEXITCODE) { throw 'versioned path install failed' }
    Assert-Patched $versionedProduct
    $newVersionedProduct = Join-Path $versionRoot 'Microsoft VS Code\1234567890\resources\app\product.json'
    Remove-Item (Join-Path $versionRoot 'Microsoft VS Code\abcdef1234') -Recurse -Force
    New-Item -ItemType Directory -Path (Split-Path $newVersionedProduct -Parent) -Force | Out-Null
    Copy-Item $Fixture $newVersionedProduct
    & $script
    if ($LASTEXITCODE) { throw 'updated versioned path install failed' }
    Assert-Patched $newVersionedProduct
    & (Join-Path $env:ENDOR_VSCODE_STATE_DIR 'worker.ps1') -Mode Restore
    if ($LASTEXITCODE) { throw 'versioned path restore failed' }
    Assert-Restored $newVersionedProduct

    Write-Host 'test: the watcher patches VS Code updates and new installs as they land'
    $watchRoot = Join-Path $TempDir 'watch'
    $watchProgramFiles = Join-Path $watchRoot 'Program Files'
    $watchProgramFilesX86 = Join-Path $watchRoot 'Program Files (x86)'
    $watchDrive = Join-Path $watchRoot 'drive'
    $watchPrograms = Join-Path $watchDrive 'Users\alice\AppData\Local\Programs'
    $watchApp = Join-Path $watchProgramFiles 'Microsoft VS Code'
    foreach ($dir in $watchProgramFilesX86, $watchPrograms, $watchApp) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $env:ProgramW6432 = $watchProgramFiles
    $env:ProgramFiles = $watchProgramFilesX86
    ${env:ProgramFiles(x86)} = ''
    $env:SystemDrive = $watchDrive
    Remove-Item Env:\ENDOR_VSCODE_PRODUCT_JSON -ErrorAction SilentlyContinue
    # Long enough that only the watcher's events can explain a patch within these timeouts.
    $env:ENDOR_VSCODE_RESCAN_SECONDS = '600'
    $watchState = Join-Path $TempDir 'watch-state'
    $env:ENDOR_VSCODE_STATE_DIR = $watchState
    $env:ENDOR_VSCODE_SKIP_WATCHER = '1'
    $global:LASTEXITCODE = 0
    & (Join-Path $RootDir "package-firewall\powershell\out\$Namespace\endor-vscode.ps1") *> $null
    if ($LASTEXITCODE) { throw 'install for the watcher test failed' }
    $watchLog = Join-Path $watchState 'worker.log'
    $installed = Join-Path $watchApp '1111111111\resources\app\product.json'
    New-Item -ItemType Directory -Path (Split-Path $installed -Parent) -Force | Out-Null
    Copy-Item $Fixture $installed
    # The same PowerShell as this test, so the 32-bit run watches from 32-bit PowerShell too.
    $watcherProcess = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -NoNewWindow `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            ('"{0}"' -f (Join-Path $watchState 'worker.ps1')), '-Mode', 'Watch' `
        -RedirectStandardOutput (Join-Path $TempDir 'watch.out') `
        -RedirectStandardError (Join-Path $TempDir 'watch.err')
    # The watcher's first pass patches the install that is already there.
    if (-not (Wait-Until { Test-Patched $installed } 30)) { throw 'the watcher did not start' }
    Start-Sleep -Milliseconds 500

    # Background update: a new commit folder.
    $product = Join-Path $watchApp '2222222222\resources\app\product.json'
    New-Item -ItemType Directory -Path (Split-Path $product -Parent) -Force | Out-Null
    Copy-Item $Fixture $product
    if (-not (Wait-Until { Test-Patched $product } 3)) { throw 'a new commit folder was not patched within 3s' }

    # Foreground update: Setup keeps writing files after product.json, then starts VS Code.
    $product = Join-Path $watchApp '3333333333\resources\app\product.json'
    New-Item -ItemType Directory -Path (Split-Path $product -Parent) -Force | Out-Null
    Copy-Item $Fixture $product
    $written = [DateTime]::UtcNow
    $patchedAfter = $null
    $streamed = 0
    while (([DateTime]::UtcNow - $written).TotalSeconds -lt 4) {
        [IO.File]::WriteAllText((Join-Path $watchApp "3333333333\stream$streamed.txt"), 'x')
        $streamed++
        if (-not $patchedAfter -and (Test-Patched $product)) {
            $patchedAfter = ([DateTime]::UtcNow - $written).TotalSeconds
        }
        Start-Sleep -Milliseconds 20
    }
    if (-not $patchedAfter -or $patchedAfter -gt 2.5) {
        throw "while files kept arriving, product.json was patched after ${patchedAfter}s, not within 2.5s"
    }

    # A new user install: Setup creates the folder, then copies files into it.
    $userApp = Join-Path $watchPrograms 'Microsoft VS Code'
    New-Item -ItemType Directory -Path $userApp | Out-Null
    Start-Sleep -Milliseconds 1500
    $product = Join-Path $userApp '4444444444\resources\app\product.json'
    New-Item -ItemType Directory -Path (Split-Path $product -Parent) -Force | Out-Null
    Copy-Item $Fixture $product
    if (-not (Wait-Until { Test-Patched $product } 3)) { throw 'a new user install was not patched within 3s' }

    # An overwrite of a file already patched.
    $product = Join-Path $watchApp '2222222222\resources\app\product.json'
    Copy-Item $Fixture $product -Force
    if (-not (Wait-Until { Test-Patched $product } 3)) { throw 'an overwritten product.json was not patched within 3s' }
    Assert-Preserved $product

    if ($watcherProcess.HasExited) {
        throw "the watcher exited: $(Get-Content -Raw (Join-Path $TempDir 'watch.err'))"
    }
    $logText = Get-Content -LiteralPath $watchLog -Raw
    if ($logText -notmatch 'watching 2 install' -or $logText -notmatch 'configured: .*2222222222') {
        throw 'the watcher log does not record what it patched'
    }
    Stop-Process -Id $watcherProcess.Id -Force
    $watcherProcess.WaitForExit()
    Remove-Item Env:\ENDOR_VSCODE_RESCAN_SECONDS

    Write-Host 'test: malformed JSON fails without mutation'
    $product = Join-Path $TempDir 'malformed-product.json'
    $original = Join-Path $TempDir 'malformed-original.json'
    $state = Join-Path $TempDir 'malformed-state'
    [IO.File]::WriteAllText($product, '{"extensionsGallery":', [Text.UTF8Encoding]::new($false))
    Copy-Item $product $original
    # The worker reports the failure and the installer exits 1; it must not throw, or the rest of
    # the installer (the update remediation task) would never run.
    $env:ENDOR_VSCODE_PRODUCT_JSON = $product
    $env:ENDOR_VSCODE_STATE_DIR = $state
    $env:ENDOR_VSCODE_SKIP_WATCHER = '1'
    $script = Join-Path $RootDir "package-firewall\powershell\out\$Namespace\endor-vscode.ps1"
    $global:LASTEXITCODE = 0
    $output = & $script *>&1 | Out-String
    if ($LASTEXITCODE -ne 1) { throw "expected malformed product.json to exit 1, got $LASTEXITCODE" }
    if ($output -notmatch '\[done\] VS Code extension firewall') { throw 'the installer stopped before finishing' }
    Assert-FilesEqual $product $original
    # That exit 1 was expected; don't let run-all.ps1 read it as this suite failing.
    $global:LASTEXITCODE = 0

    Write-Host 'test: the VS Code flags take true, false, 1 and 0 in any case, and nothing else'
    $generated = Join-Path $RootDir "package-firewall\powershell\out\$Namespace\endor-vscode.ps1"
    foreach ($value in 'true', 'TRUE', 'True', '1') {
        Invoke-Generate -Patch $value
        if ((Get-Content -Raw $generated) -notmatch "(?m)^\`$_vscodeEnablePatch = '1'\r?$") { throw "ENDOR_VSCODE_ENABLE_PATCH=$value did not enable the patch" }
    }
    foreach ($value in 'false', 'FALSE', '0', '') {
        Invoke-Generate -Patch $value -Policy 'true'
        $text = Get-Content -Raw $generated
        if ($text -notmatch "(?m)^\`$_vscodeEnablePatch = '0'\r?$") { throw "ENDOR_VSCODE_ENABLE_PATCH='$value' did not disable the patch" }
        if ($text -notmatch "(?m)^\`$_vscodeEnablePolicy = '1'\r?$") { throw 'ENDOR_VSCODE_ENABLE_POLICY=true did not enable the policy' }
    }
    foreach ($value in 'yes', 'on', '2', ' true') {
        if (-not (Test-GenerateRejected -Patch $value)) { throw "expected ENDOR_VSCODE_ENABLE_PATCH='$value' to be rejected" }
        if (-not (Test-GenerateRejected -Policy $value)) { throw "expected ENDOR_VSCODE_ENABLE_POLICY='$value' to be rejected" }
    }

    Write-Host 'test: ENDOR_VSCODE_POLICY_AUTH is optional, github or microsoft, and only with the policy'
    Invoke-Generate -Policy '1' -Auth 'Microsoft'
    if ((Get-Content -Raw $generated) -notmatch "(?m)^\`$_vscodePolicyAuth = 'microsoft'\r?$") { throw 'AUTH=Microsoft was not normalised' }
    Invoke-Generate -Policy '1'
    if ((Get-Content -Raw $generated) -notmatch "(?m)^\`$_vscodePolicyAuth = ''\r?$") { throw 'an unset AUTH was given a value' }
    $summary = & $Generator *>&1 | Out-String -Width 4096
    if (-not $summary.Contains("policy on (sign-in: VS Code's default).")) {
        throw "expected the summary to say an unset ENDOR_VSCODE_POLICY_AUTH leaves VS Code's default`n$summary"
    }
    if (-not (Test-GenerateRejected -Policy '1' -Auth 'okta')) { throw 'expected ENDOR_VSCODE_POLICY_AUTH=okta to be rejected' }
    if (-not (Test-GenerateRejected -Auth 'github')) { throw 'expected ENDOR_VSCODE_POLICY_AUTH without the policy to be rejected' }

    Write-Host 'test: with neither method enabled, VS Code is left alone'
    Invoke-Generate -Patch '0'
    $allScript = Join-Path $RootDir "package-firewall\powershell\out\$Namespace\endor-all.ps1"
    if ((Get-Content -Raw $allScript) -notmatch 'VS Code: not enabled') { throw 'endor-all.ps1 claims to configure VS Code' }
    $product = Join-Path $TempDir 'neither-product.json'
    $state = Join-Path $TempDir 'neither-state'
    Copy-Item $Fixture $product
    $output = Invoke-InstallerOutput $product $state
    if ($LASTEXITCODE) { throw "expected exit 0 with neither method, got $LASTEXITCODE`n$output" }
    if ($output -notmatch 'no VS Code method is enabled') { throw 'the installer did not say no method is enabled' }
    if ($output -match '\[done\] VS Code') { throw 'the installer said VS Code was done' }
    Assert-FilesEqual $product $Fixture
    if (Test-Path -LiteralPath $state) { throw 'the installer created state with neither method' }

    Write-Host 'test: a patch left by an earlier deployment is reported, and left in place'
    Invoke-Generate
    $product = Join-Path $TempDir 'leftover-product.json'
    $state = Join-Path $TempDir 'leftover-state'
    Copy-Item $Fixture $product
    Invoke-Installer $product $state
    Invoke-Generate -Patch '0'
    $output = Invoke-InstallerOutput $product $state
    if ($LASTEXITCODE -ne 1) { throw "expected a leftover patch to exit 1, got $LASTEXITCODE" }
    if ($output -notmatch 'patch from an earlier deployment is still installed') { throw "the leftover patch was not reported`n$output" }
    Assert-Patched $product
    # The patched product.json alone is enough to report it.
    Remove-Item -LiteralPath $state -Recurse -Force
    $output = Invoke-InstallerOutput $product $state
    if ($LASTEXITCODE -ne 1 -or $output -notmatch [regex]::Escape("still installed ($product)")) {
        throw "a patched product.json was not reported`n$output"
    }

    # The docs-site generator fetches these templates and fills in only the placeholders it knows.
    # A script with the method placeholders left in place must behave as scripts did before them.
    Write-Host 'test: a script from a generator that predates the method flags behaves as before'
    Invoke-Generate -Patch '1' -Policy '1'
    $legacy = Join-Path $TempDir 'legacy-vscode.ps1'
    $text = Get-Content -Raw $generated
    $text = $text -creplace "(?m)^\`$_vscodeEnablePatch = '1'", "`$`$_vscodeEnablePatch = '{{VSCODE_ENABLE_PATCH}}'"
    $text = $text -creplace "(?m)^\`$_vscodeEnablePolicy = '1'", "`$`$_vscodeEnablePolicy = '{{VSCODE_ENABLE_POLICY}}'"
    $text = $text -creplace "(?m)^\`$_vscodePolicyAuth = ''", "`$`$_vscodePolicyAuth = '{{VSCODE_POLICY_AUTH}}'"
    if (([regex]::Matches($text, '\{\{VSCODE_')).Count -ne 3) { throw 'the legacy script does not have the three placeholders' }
    [IO.File]::WriteAllText($legacy, $text, [Text.UTF8Encoding]::new($true))
    $product = Join-Path $TempDir 'legacy-product.json'
    $state = Join-Path $TempDir 'legacy-state'
    Copy-Item $Fixture $product
    $output = Invoke-InstallerOutput $product $state $legacy
    if ($LASTEXITCODE) { throw "the legacy script exited $LASTEXITCODE`n$output" }
    if ($output -match 'policy') { throw "a script from an older generator mentioned the policy`n$output" }
    Assert-Patched $product

    if ($env:OS -ne 'Windows_NT') {
        Write-Host 'test: the policy is reported as Windows-only elsewhere'
        Invoke-Generate -Patch '0' -Policy '1'
        $product = Join-Path $TempDir 'policy-elsewhere-product.json'
        Copy-Item $Fixture $product
        $output = Invoke-InstallerOutput $product (Join-Path $TempDir 'policy-elsewhere-state')
        if ($LASTEXITCODE -ne 1 -or $output -notmatch 'Windows registry setting') { throw "expected a Windows-only warning`n$output" }
    }
    Invoke-Generate
    $global:LASTEXITCODE = 0

    Write-Host 'VS Code PowerShell tests passed'
} finally {
    if ($watcherProcess -and -not $watcherProcess.HasExited) {
        Stop-Process -Id $watcherProcess.Id -Force -ErrorAction SilentlyContinue
        $watcherProcess.WaitForExit()
    }
    Remove-Item Env:\ENDOR_VSCODE_RESCAN_SECONDS -ErrorAction SilentlyContinue
    $env:ProgramData = $SavedEnvironment.ProgramData
    $env:ProgramFiles = $SavedEnvironment.ProgramFiles
    $env:ProgramW6432 = $SavedEnvironment.ProgramW6432
    ${env:ProgramFiles(x86)} = $SavedEnvironment.ProgramFilesX86
    $env:SystemDrive = $SavedEnvironment.SystemDrive
    Remove-Item Env:\ENDOR_VSCODE_PRODUCT_JSON -ErrorAction SilentlyContinue
    Remove-Item Env:\ENDOR_VSCODE_STATE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\ENDOR_VSCODE_SKIP_WATCHER -ErrorAction SilentlyContinue
    Remove-Item Env:\ENDOR_VSCODE_ENABLE_PATCH, Env:\ENDOR_VSCODE_ENABLE_POLICY, Env:\ENDOR_VSCODE_POLICY_AUTH -ErrorAction SilentlyContinue
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
