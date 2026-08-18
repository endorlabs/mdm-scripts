# templates/vscode.ps1
# Patches Microsoft VS Code Stable's product.json and installs update remediation.

Write-Host ''
Write-Host '[endor] -- VS Code extension firewall -----------------------------------'

$_vscodeWorkerContent = @'
param(
    [ValidateSet('Once', 'Watch', 'Restore')]
    [string]$Mode = 'Once',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$FirewallUrl = '{{VSCODE_SERVICE_URL}}'
$DefaultStateRoot = Join-Path $env:ProgramData 'Endor Labs\vscode-firewall'
$StateRoot = if ($env:ENDOR_VSCODE_STATE_DIR) { $env:ENDOR_VSCODE_STATE_DIR } else { $DefaultStateRoot }

function Get-StringSha256 {
    param([string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value)) |
            ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
}

function Get-InstallRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $systemRoots = @()
    if ($env:ProgramFiles) {
        $systemRoots += Join-Path $env:ProgramFiles 'Microsoft VS Code'
    }
    if (${env:ProgramFiles(x86)}) {
        $systemRoots += Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code'
    }
    foreach ($root in $systemRoots) {
        if ($root -and (Test-Path -LiteralPath $root)) { $roots.Add($root) }
    }

    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if (Test-Path -LiteralPath $usersRoot) {
        foreach ($profile in @(Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue)) {
            $root = Join-Path $profile.FullName 'AppData\Local\Programs\Microsoft VS Code'
            if (Test-Path -LiteralPath $root) { $roots.Add($root) }
        }
    }
    $roots | Select-Object -Unique
}

function Get-ProductFiles {
    if ($env:ENDOR_VSCODE_PRODUCT_JSON) {
        if (Test-Path -LiteralPath $env:ENDOR_VSCODE_PRODUCT_JSON) {
            return ,$env:ENDOR_VSCODE_PRODUCT_JSON
        }
        return @()
    }

    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($root in @(Get-InstallRoots)) {
        $legacy = Join-Path $root 'resources\app\product.json'
        if (Test-Path -LiteralPath $legacy) { $files.Add($legacy) }
        foreach ($versionDir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object Name -Match '^[0-9a-fA-F]{10}$')) {
            $versioned = Join-Path $versionDir.FullName 'resources\app\product.json'
            if (Test-Path -LiteralPath $versioned) { $files.Add($versioned) }
        }
    }
    $files | Select-Object -Unique
}

function Read-ProductJson {
    param([string]$FilePath)
    Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
}

function Get-ServiceUrl {
    param([object]$Product)
    if ($Product.extensionsGallery -and
        $Product.extensionsGallery.PSObject.Properties['serviceUrl']) {
        return [string]$Product.extensionsGallery.serviceUrl
    }
    ''
}

function Test-ProductDesired {
    param([object]$Product)
    (Get-ServiceUrl $Product) -eq $FirewallUrl -and
        -not $Product.extensionsGallery.PSObject.Properties['extensionUrlTemplate']
}

function Test-ProductManaged {
    param([object]$Product)
    (Get-ServiceUrl $Product) -like '*/firewall/vscode/_ak/*'
}

function ConvertTo-PatchedJson {
    param([object]$Product)
    if (-not $Product.extensionsGallery) {
        $Product | Add-Member -NotePropertyName extensionsGallery -NotePropertyValue ([PSCustomObject]@{})
    }
    if ($Product.extensionsGallery.PSObject.Properties['serviceUrl']) {
        $Product.extensionsGallery.serviceUrl = $FirewallUrl
    } else {
        $Product.extensionsGallery | Add-Member -NotePropertyName serviceUrl -NotePropertyValue $FirewallUrl
    }
    if ($Product.extensionsGallery.PSObject.Properties['extensionUrlTemplate']) {
        $Product.extensionsGallery.PSObject.Properties.Remove('extensionUrlTemplate')
    }
    ($Product | ConvertTo-Json -Depth 100) + [System.Environment]::NewLine
}

function Write-Utf8NoBom {
    param([string]$FilePath, [string]$Content)
    [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-StateEntry {
    param([string]$FilePath)
    Join-Path $StateRoot (Get-StringSha256 $FilePath.ToLowerInvariant())
}

function Invoke-PatchOne {
    param([string]$FilePath)
    try {
        $product = Read-ProductJson $FilePath
    } catch {
        Write-Error "[endor-vscode] refusing to modify invalid JSON: $FilePath : $_"
        return $false
    }

    if (Test-ProductDesired $product) {
        Write-Host "[endor-vscode] already configured: $FilePath"
        return $true
    }
    if ($DryRun) {
        Write-Host '[dry-run]   action : PATCH extensionsGallery.serviceUrl and REMOVE extensionUrlTemplate'
        Write-Host "[dry-run]   file   : $FilePath"
        Write-Host "[dry-run]   URL    : $FirewallUrl"
        return $true
    }

    $entry = Get-StateEntry $FilePath
    New-Item -ItemType Directory -Path $entry -Force | Out-Null
    Write-Utf8NoBom -FilePath (Join-Path $entry 'path.txt') -Content ($FilePath + [Environment]::NewLine)

    $currentHash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $managedHashPath = Join-Path $entry 'managed.sha256'
    $previousHash = if (Test-Path -LiteralPath $managedHashPath) {
        (Get-Content -LiteralPath $managedHashPath -Raw).Trim()
    } else { '' }
    $backupPath = Join-Path $entry 'upstream-product.json'

    if ($currentHash -ne $previousHash) {
        if ((Test-ProductManaged $product) -and -not (Test-Path -LiteralPath $backupPath)) {
            Write-Warning "[endor-vscode] existing managed product.json has no clean backup; removal cannot restore this version"
        } else {
            Copy-Item -LiteralPath $FilePath -Destination $backupPath -Force
            Write-Host "[endor-vscode] saved upstream backup: $backupPath"
        }
    }

    $tempPath = "$FilePath.endor.$([Guid]::NewGuid().ToString('N')).tmp"
    $replaceBackup = "$FilePath.endor-replace.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $patched = ConvertTo-PatchedJson $product
        Write-Utf8NoBom -FilePath $tempPath -Content $patched
        $validated = Read-ProductJson $tempPath
        if (-not (Test-ProductDesired $validated)) {
            throw 'patched JSON did not contain the required gallery settings'
        }
        $acl = if (Get-Command Get-Acl -ErrorAction SilentlyContinue) {
            Get-Acl -LiteralPath $FilePath
        } else { $null }
        [System.IO.File]::Replace($tempPath, $FilePath, $replaceBackup, $true)
        if ($acl) { Set-Acl -LiteralPath $FilePath -AclObject $acl }
        Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
    } catch {
        Remove-Item -LiteralPath $tempPath, $replaceBackup -Force -ErrorAction SilentlyContinue
        Write-Error "[endor-vscode] failed to patch $FilePath : $_"
        return $false
    }

    $newHash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8NoBom -FilePath $managedHashPath -Content ($newHash + [Environment]::NewLine)
    Write-Host "[endor-vscode] configured: $FilePath"
    $true
}

function Invoke-PatchAll {
    $files = @(Get-ProductFiles)
    if ($files.Count -eq 0) {
        Write-Host '[endor-vscode] Microsoft VS Code Stable not found; remediation remains ready for a later install.'
        return $true
    }
    $ok = $true
    foreach ($file in $files) {
        if (-not (Invoke-PatchOne $file)) { $ok = $false }
    }
    $ok
}

function Invoke-RestoreAll {
    if (-not (Test-Path -LiteralPath $StateRoot)) {
        Write-Host '[endor-vscode] no managed VS Code backups found'
        return $true
    }
    $ok = $true
    $found = $false
    foreach ($pathRecord in @(Get-ChildItem -LiteralPath $StateRoot -Filter path.txt -File -Recurse -ErrorAction SilentlyContinue)) {
        $found = $true
        $entry = $pathRecord.DirectoryName
        $file = (Get-Content -LiteralPath $pathRecord.FullName -Raw).Trim()
        $backupPath = Join-Path $entry 'upstream-product.json'
        $managedHashPath = Join-Path $entry 'managed.sha256'
        if (-not (Test-Path -LiteralPath $file)) {
            if ($DryRun) {
                Write-Host "[dry-run]   action : REMOVE stale state for missing install: $file"
            } else {
                Remove-Item -LiteralPath $entry -Recurse -Force
                Write-Host "[endor-vscode] removed stale state for missing install: $file"
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $backupPath) -or
            -not (Test-Path -LiteralPath $managedHashPath)) {
            Write-Host "[endor-vscode] skip restore (incomplete state): $file"
            $ok = $false
            continue
        }
        $expected = (Get-Content -LiteralPath $managedHashPath -Raw).Trim()
        $current = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($current -ne $expected) {
            Write-Host "[endor-vscode] skip restore (product.json changed outside Endor): $file"
            $ok = $false
            continue
        }
        if ($DryRun) {
            Write-Host '[dry-run]   action : RESTORE upstream product.json'
            Write-Host "[dry-run]   file   : $file"
            continue
        }
        try {
            $null = Read-ProductJson $backupPath
            $tempPath = "$file.endor-restore.$([Guid]::NewGuid().ToString('N')).tmp"
            $replaceBackup = "$file.endor-restore-replace.$([Guid]::NewGuid().ToString('N')).tmp"
            Copy-Item -LiteralPath $backupPath -Destination $tempPath -Force
            $acl = if (Get-Command Get-Acl -ErrorAction SilentlyContinue) {
                Get-Acl -LiteralPath $file
            } else { $null }
            [System.IO.File]::Replace($tempPath, $file, $replaceBackup, $true)
            if ($acl) { Set-Acl -LiteralPath $file -AclObject $acl }
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $entry -Recurse -Force
            Write-Host "[endor-vscode] restored upstream product.json: $file"
        } catch {
            Remove-Item -LiteralPath $tempPath, $replaceBackup -Force -ErrorAction SilentlyContinue
            Write-Error "[endor-vscode] failed to restore $file : $_"
            $ok = $false
        }
    }
    if (-not $found) { Write-Host '[endor-vscode] no managed VS Code backups found' }
    $ok
}

function Watch-Products {
    while ($true) {
        $signal = [System.Threading.AutoResetEvent]::new($false)
        $watchers = [System.Collections.Generic.List[System.IO.FileSystemWatcher]]::new()
        foreach ($root in @(Get-InstallRoots)) {
            try {
                $watcher = [System.IO.FileSystemWatcher]::new($root)
                $watcher.IncludeSubdirectories = $true
                $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite'
                $watcher.add_Changed({ param($sender, $eventArgs) [void]$signal.Set() })
                $watcher.add_Created({ param($sender, $eventArgs) [void]$signal.Set() })
                $watcher.add_Deleted({ param($sender, $eventArgs) [void]$signal.Set() })
                $watcher.add_Renamed({ param($sender, $eventArgs) [void]$signal.Set() })
                $watcher.EnableRaisingEvents = $true
                $watchers.Add($watcher)
            } catch {
                Write-Warning "[endor-vscode] could not watch $root : $_"
            }
        }
        [void]$signal.WaitOne([TimeSpan]::FromMinutes(1))
        Start-Sleep -Seconds 2
        foreach ($watcher in $watchers) { $watcher.Dispose() }
        $signal.Dispose()
        $null = Invoke-PatchAll
    }
}

switch ($Mode) {
    'Once' {
        if (-not (Invoke-PatchAll)) { exit 1 }
    }
    'Restore' {
        if (-not (Invoke-RestoreAll)) { exit 1 }
    }
    'Watch' {
        $null = Invoke-PatchAll
        Watch-Products
    }
}
'@

$_vscodeStateRoot = if ($env:ENDOR_VSCODE_STATE_DIR) {
    $env:ENDOR_VSCODE_STATE_DIR
} else {
    Join-Path $env:ProgramData 'Endor Labs\vscode-firewall'
}
$_vscodeWorkerPath = Join-Path $_vscodeStateRoot 'worker.ps1'

if ($DryRun) {
    $_vscodeTempWorker = Join-Path ([IO.Path]::GetTempPath()) "endor-vscode-$([Guid]::NewGuid().ToString('N')).ps1"
    [IO.File]::WriteAllText($_vscodeTempWorker, $_vscodeWorkerContent, [Text.UTF8Encoding]::new($false))
    try {
        & $_vscodeTempWorker -Mode Once -DryRun
        if ($LASTEXITCODE) { $EndorWarned = $true }
    } finally {
        Remove-Item -LiteralPath $_vscodeTempWorker -Force -ErrorAction SilentlyContinue
    }
    Write-Host '[dry-run]   action : INSTALL VS Code update remediation scheduled task'
} else {
    New-Item -ItemType Directory -Path $_vscodeStateRoot -Force | Out-Null
    [IO.File]::WriteAllText($_vscodeWorkerPath, $_vscodeWorkerContent, [Text.UTF8Encoding]::new($false))
    if ($env:OS -eq 'Windows_NT') {
        & icacls.exe $_vscodeStateRoot /inheritance:r /grant:r `
            '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    }

    & $_vscodeWorkerPath -Mode Once
    if ($LASTEXITCODE) { $EndorWarned = $true }

    if ($env:ENDOR_VSCODE_SKIP_WATCHER -ne '1') {
        try {
            $taskName = 'Endor VS Code Extension Firewall'
            $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $taskAction = New-ScheduledTaskAction -Execute $powerShellExe `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$_vscodeWorkerPath`" -Mode Watch"
            $taskTrigger = New-ScheduledTaskTrigger -AtStartup
            $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $taskSettings = New-ScheduledTaskSettingsSet -RestartCount 999 `
                -RestartInterval (New-TimeSpan -Minutes 1) `
                -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -MultipleInstances IgnoreNew
            Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger `
                -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
        } catch {
            Write-Warning "[endor] could not install VS Code update remediation task: $_"
            $EndorWarned = $true
        }
    }
}

Write-Host '[endor] [done] VS Code extension firewall'
Remove-Variable _vscodeWorkerContent, _vscodeStateRoot, _vscodeWorkerPath,
    _vscodeTempWorker -ErrorAction SilentlyContinue
