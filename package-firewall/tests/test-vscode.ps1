$ErrorActionPreference = 'Stop'

$TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path (Join-Path $TestDir '..\..')).Path
$Generator = Join-Path $RootDir 'package-firewall\powershell\generate.ps1'
$Fixture = Join-Path $TestDir 'fixtures\vscode-product.json'
$Namespace = 'ci-smoke'
$KeyId = 'ci-smoke-key-id'
$Secret = 'ci-smoke-secret'
$ExpectedUrl = 'https://factory.endorlabs.com/v1/namespaces/ci-smoke/firewall/vscode/_ak/Y2ktc21va2Uta2V5LWlkOmNpLXNtb2tlLXNlY3JldA'
$TempDir = Join-Path ([IO.Path]::GetTempPath()) "endor-vscode-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $TempDir | Out-Null

$SavedEnvironment = @{
    ProgramData = $env:ProgramData
    ProgramFiles = $env:ProgramFiles
    ProgramFilesX86 = ${env:ProgramFiles(x86)}
    SystemDrive = $env:SystemDrive
}

function Invoke-Generate {
    param([string]$ApiSecret = $Secret)
    $env:ENDOR_NAMESPACE = $Namespace
    $env:ENDOR_API_KEY_ID = $KeyId
    $env:ENDOR_API_SECRET = $ApiSecret
    & $Generator *> $null
    if ($LASTEXITCODE) { throw "generator failed with exit code $LASTEXITCODE" }
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

function Assert-FilesEqual {
    param([string]$Actual, [string]$Expected)
    $actualHash = (Get-FileHash -LiteralPath $Actual -Algorithm SHA256).Hash
    $expectedHash = (Get-FileHash -LiteralPath $Expected -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) { throw "files differ: $Actual and $Expected" }
}

try {
    $env:ProgramData = $TempDir
    Invoke-Generate

    Write-Host 'test: patches product.json, preserves fields, and is idempotent'
    $product = Join-Path $TempDir 'basic-product.json'
    $original = Join-Path $TempDir 'basic-original.json'
    $state = Join-Path $TempDir 'basic-state'
    Copy-Item $Fixture $product
    Copy-Item $Fixture $original
    Invoke-Installer $product $state
    Assert-Patched $product
    $before = (Get-FileHash $product -Algorithm SHA256).Hash
    Invoke-Installer $product $state
    $after = (Get-FileHash $product -Algorithm SHA256).Hash
    if ($before -ne $after) { throw 'idempotent run changed product.json' }
    & (Join-Path $state 'worker.ps1') -Mode Restore
    if ($LASTEXITCODE) { throw 'restore failed' }
    Assert-FilesEqual $product $original

    Write-Host 'test: dry-run reports drift without writing'
    $product = Join-Path $TempDir 'dry-product.json'
    $state = Join-Path $TempDir 'dry-state'
    Copy-Item $Fixture $product
    $before = (Get-FileHash $product -Algorithm SHA256).Hash
    Invoke-Installer $product $state -DryRun
    $after = (Get-FileHash $product -Algorithm SHA256).Hash
    if ($before -ne $after) { throw 'dry-run changed product.json' }
    if (Test-Path $state) { throw 'dry-run created managed state' }

    Write-Host 'test: credential rotation keeps the clean backup'
    $product = Join-Path $TempDir 'rotation-product.json'
    $original = Join-Path $TempDir 'rotation-original.json'
    $state = Join-Path $TempDir 'rotation-state'
    Copy-Item $Fixture $product
    Copy-Item $Fixture $original
    Invoke-Generate
    Invoke-Installer $product $state
    Invoke-Generate 'ci-smoke-rotated-secret'
    Invoke-Installer $product $state
    & (Join-Path $state 'worker.ps1') -Mode Restore
    if ($LASTEXITCODE) { throw 'rotation restore failed' }
    Assert-FilesEqual $product $original

    Write-Host 'test: an updater overwrite refreshes the restorable backup'
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
    Assert-FilesEqual $product $updated

    Write-Host 'test: current versioned Windows resource paths are discovered'
    $versionRoot = Join-Path $TempDir 'fake-program-files'
    $versionedProduct = Join-Path $versionRoot 'Microsoft VS Code\abcdef1234\resources\app\product.json'
    New-Item -ItemType Directory -Path (Split-Path $versionedProduct -Parent) -Force | Out-Null
    Copy-Item $Fixture $versionedProduct
    $env:ProgramFiles = $versionRoot
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
    Assert-FilesEqual $newVersionedProduct $Fixture

    Write-Host 'test: malformed JSON fails without mutation'
    $product = Join-Path $TempDir 'malformed-product.json'
    $original = Join-Path $TempDir 'malformed-original.json'
    $state = Join-Path $TempDir 'malformed-state'
    [IO.File]::WriteAllText($product, '{"extensionsGallery":', [Text.UTF8Encoding]::new($false))
    Copy-Item $product $original
    $failed = $false
    try {
        Invoke-Installer $product $state
    } catch {
        $failed = $true
    }
    if (-not $failed) { throw 'expected malformed product.json to fail' }
    Assert-FilesEqual $product $original

    Write-Host 'VS Code PowerShell tests passed'
} finally {
    $env:ProgramData = $SavedEnvironment.ProgramData
    $env:ProgramFiles = $SavedEnvironment.ProgramFiles
    ${env:ProgramFiles(x86)} = $SavedEnvironment.ProgramFilesX86
    $env:SystemDrive = $SavedEnvironment.SystemDrive
    Remove-Item Env:\ENDOR_VSCODE_PRODUCT_JSON -ErrorAction SilentlyContinue
    Remove-Item Env:\ENDOR_VSCODE_STATE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\ENDOR_VSCODE_SKIP_WATCHER -ErrorAction SilentlyContinue
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
