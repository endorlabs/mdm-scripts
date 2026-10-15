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
$DefaultServiceUrl = 'https://marketplace.visualstudio.com/_apis/public/gallery'
$DefaultExtensionUrlTemplate = 'https://www.vscode-unpkg.net/_gallery/{publisher}/{name}/latest'
# Watch mode logs what it changes, and what goes wrong, next to the worker.
$LogPath = $null

function Write-Log {
    param([string]$Message)
    if (-not $LogPath) { return }
    try {
        $log = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
        if ($log -and $log.Length -gt 1MB) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
        }
        [System.IO.File]::AppendAllText($LogPath,
            ('{0:yyyy-MM-ddTHH:mm:ss.fffZ} {1}{2}' -f [DateTime]::UtcNow, $Message, [Environment]::NewLine))
    } catch {
    }
}

function Write-Change {
    param([string]$Message)
    Write-Host $Message
    Write-Log $Message
}

# Failures to patch or restore one file don't end the run, or the watcher loop: the caller sees
# the exit code instead.
function Write-Problem {
    param([string]$Message)
    Write-Log $Message
    Write-Error $Message -ErrorAction Continue
}

function Get-InstallRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $systemRoots = @()
    # 32-bit PowerShell, which Intune uses by default, sees the x86 folder as ProgramFiles.
    # ProgramW6432 is the 64-bit folder whichever PowerShell runs this.
    foreach ($programFiles in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($programFiles) {
            $systemRoots += Join-Path $programFiles 'Microsoft VS Code'
        }
    }
    foreach ($root in $systemRoots) {
        if ($root -and (Test-Path -LiteralPath $root) -and -not $roots.Contains($root)) {
            $roots.Add($root)
        }
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

# Shares delete access, so a read never stops VS Code's updater deleting an old version folder.
function Read-ProductJson {
    param([string]$FilePath)
    $stream = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false), $true)
        $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
    } finally {
        $stream.Dispose()
    }
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

function Test-ProductRestored {
    param([object]$Product)
    (Get-ServiceUrl $Product) -eq $DefaultServiceUrl -and
        [string]$Product.extensionsGallery.extensionUrlTemplate -eq $DefaultExtensionUrlTemplate
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

function ConvertTo-RestoredJson {
    param([object]$Product)
    if (-not $Product.extensionsGallery) {
        $Product | Add-Member -NotePropertyName extensionsGallery -NotePropertyValue ([PSCustomObject]@{})
    }
    if ($Product.extensionsGallery.PSObject.Properties['serviceUrl']) {
        $Product.extensionsGallery.serviceUrl = $DefaultServiceUrl
    } else {
        $Product.extensionsGallery | Add-Member -NotePropertyName serviceUrl -NotePropertyValue $DefaultServiceUrl
    }
    if ($Product.extensionsGallery.PSObject.Properties['extensionUrlTemplate']) {
        $Product.extensionsGallery.extensionUrlTemplate = $DefaultExtensionUrlTemplate
    } else {
        $Product.extensionsGallery |
            Add-Member -NotePropertyName extensionUrlTemplate -NotePropertyValue $DefaultExtensionUrlTemplate
    }
    ($Product | ConvertTo-Json -Depth 100) + [System.Environment]::NewLine
}

function Write-Utf8NoBom {
    param([string]$FilePath, [string]$Content)
    [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))
}

# After an update, VS Code's updater deletes the old version folder, sometimes during a pass. A
# file that has gone is skipped, not reported.
function Invoke-PatchOne {
    param([string]$FilePath)
    try {
        $product = Read-ProductJson $FilePath
    } catch {
        if (-not (Test-Path -LiteralPath $FilePath)) { return $true }
        Write-Problem "[endor-vscode] refusing to modify invalid JSON: $FilePath : $_"
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
        if (-not (Test-Path -LiteralPath $FilePath)) { return $true }
        Write-Problem "[endor-vscode] failed to patch $FilePath : $_"
        return $false
    }

    Write-Change "[endor-vscode] configured: $FilePath"
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

function Invoke-RestoreOne {
    param([string]$FilePath)
    try {
        $product = Read-ProductJson $FilePath
    } catch {
        if (-not (Test-Path -LiteralPath $FilePath)) { return $true }
        Write-Problem "[endor-vscode] refusing to modify invalid JSON: $FilePath : $_"
        return $false
    }

    if (-not (Test-ProductManaged $product)) {
        Write-Host "[endor-vscode] skip restore (gallery is not Endor-managed): $FilePath"
        return $true
    }
    if ($DryRun) {
        Write-Host '[dry-run]   action : RESTORE default VS Code gallery settings'
        Write-Host "[dry-run]   file   : $FilePath"
        return $true
    }

    $tempPath = "$FilePath.endor-restore.$([Guid]::NewGuid().ToString('N')).tmp"
    $replaceBackup = "$FilePath.endor-restore-replace.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        Write-Utf8NoBom -FilePath $tempPath -Content (ConvertTo-RestoredJson $product)
        $validated = Read-ProductJson $tempPath
        if (-not (Test-ProductRestored $validated)) {
            throw 'restored JSON did not contain the default gallery settings'
        }
        $acl = if (Get-Command Get-Acl -ErrorAction SilentlyContinue) {
            Get-Acl -LiteralPath $FilePath
        } else { $null }
        [System.IO.File]::Replace($tempPath, $FilePath, $replaceBackup, $true)
        if ($acl) { Set-Acl -LiteralPath $FilePath -AclObject $acl }
        Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        Write-Change "[endor-vscode] restored default gallery settings: $FilePath"
        return $true
    } catch {
        Remove-Item -LiteralPath $tempPath, $replaceBackup -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $FilePath)) { return $true }
        Write-Problem "[endor-vscode] failed to restore $FilePath : $_"
        return $false
    }
}

function Invoke-RestoreAll {
    $files = @(Get-ProductFiles)
    if ($files.Count -eq 0) {
        Write-Host '[endor-vscode] Microsoft VS Code Stable not found; nothing to restore.'
        return $true
    }
    $ok = $true
    foreach ($file in $files) {
        if (-not (Invoke-RestoreOne $file)) { $ok = $false }
    }
    $ok
}

# Folders in which a new install's 'Microsoft VS Code' folder appears.
function Get-InstallParents {
    $parents = [System.Collections.Generic.List[string]]::new()
    foreach ($programFiles in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($programFiles -and (Test-Path -LiteralPath $programFiles) -and -not $parents.Contains($programFiles)) {
            $parents.Add($programFiles)
        }
    }
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if (Test-Path -LiteralPath $usersRoot) {
        foreach ($profile in @(Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue)) {
            $programs = Join-Path $profile.FullName 'AppData\Local\Programs'
            if (Test-Path -LiteralPath $programs) { $parents.Add($programs) }
        }
    }
    $parents
}

# Events go to PowerShell's event queue. A script block added as a .NET event handler would run on
# a thread pool thread with no runspace, which ends the process.
function New-Watcher {
    param([string]$Path, [bool]$Recursive, [string]$Filter, [int]$Index)
    $watcher = [System.IO.FileSystemWatcher]::new($Path)
    $watcher.IncludeSubdirectories = $Recursive
    if ($Filter) { $watcher.Filter = $Filter }
    $watcher.InternalBufferSize = 65536
    $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite'
    foreach ($name in 'Changed', 'Created', 'Deleted', 'Renamed', 'Error') {
        $null = Register-ObjectEvent -InputObject $watcher -EventName $name `
            -SourceIdentifier "EndorVSCode.$Index.$name"
    }
    $watcher.EnableRaisingEvents = $true
    $watcher
}

function Stop-Watchers {
    param([object[]]$Watchers)
    Get-EventSubscriber | Where-Object SourceIdentifier -like 'EndorVSCode.*' |
        ForEach-Object { Unregister-Event -SubscriptionId $_.SubscriptionId }
    foreach ($watcher in $Watchers) { $watcher.Dispose() }
    Get-Event | Where-Object SourceIdentifier -like 'EndorVSCode.*' | Remove-Event
}

# Takes the queued watcher events. Returns how many there were, and whether any was an Error
# (a buffer overflow, or a watched folder that went away).
function Receive-WatcherEvents {
    $queued = @(Get-Event | Where-Object SourceIdentifier -like 'EndorVSCode.*')
    foreach ($id in @($queued | ForEach-Object SourceIdentifier | Select-Object -Unique)) {
        Remove-Event -SourceIdentifier $id -ErrorAction SilentlyContinue
    }
    [PSCustomObject]@{
        Count = $queued.Count
        Error = @($queued | Where-Object SourceIdentifier -like '*.Error').Count -gt 0
    }
}

# Watches each install recursively, and the folders new installs appear in. A system install
# updates in the foreground: Setup writes a new <commit>\resources\app\product.json, then starts
# VS Code a few seconds later. So a change is patched once 250 ms pass with no further events, and
# never later than 1 s after the first one, however long Setup keeps writing. Events that arrive
# during a pass stay queued and start the next one. Every RescanSeconds it patches regardless.
function Watch-Products {
    $rescanSeconds = 60
    if ($env:ENDOR_VSCODE_RESCAN_SECONDS -match '^[1-9][0-9]{0,4}$') {
        $rescanSeconds = [int]$env:ENDOR_VSCODE_RESCAN_SECONDS
    }
    $watchers = @()
    $layout = $null
    $rebuild = $true
    $retries = 0
    Write-Log '[endor-vscode] watcher started'
    while ($true) {
        $roots = @(Get-InstallRoots)
        $parents = @(Get-InstallParents)
        $current = ($roots -join ';') + '|' + ($parents -join ';')
        if ($rebuild -or $current -ne $layout) {
            Stop-Watchers $watchers
            $watchers = @()
            $index = 0
            foreach ($root in $roots) {
                try {
                    $watchers += New-Watcher -Path $root -Recursive $true -Index $index
                } catch {
                    Write-Log "[endor-vscode] could not watch $root : $_"
                }
                $index++
            }
            foreach ($parent in $parents) {
                try {
                    $watchers += New-Watcher -Path $parent -Recursive $false -Filter 'Microsoft VS Code' -Index $index
                } catch {
                    Write-Log "[endor-vscode] could not watch $parent : $_"
                }
                $index++
            }
            if ($current -ne $layout) {
                Write-Log "[endor-vscode] watching $($roots.Count) install(s) and $($parents.Count) folder(s) for new installs"
            }
            $layout = $current
            $rebuild = $false
        }

        # Retry a failed pass (a file Setup still has open, say) after 2 s, for up to a minute.
        $timeout = $rescanSeconds
        if (Invoke-PatchAll) {
            $retries = 0
        } elseif ($retries -lt 30) {
            $retries++
            $timeout = 2
        }

        if (-not (Wait-Event -Timeout $timeout)) { continue }
        $started = [DateTime]::UtcNow
        $lastSeen = $started
        while ($true) {
            $received = Receive-WatcherEvents
            if ($received.Count) { $lastSeen = [DateTime]::UtcNow }
            if ($received.Error) {
                Write-Log '[endor-vscode] a watcher reported an error; watching again'
                $rebuild = $true
            }
            $now = [DateTime]::UtcNow
            if (($now - $lastSeen).TotalMilliseconds -ge 250 -or ($now - $started).TotalMilliseconds -ge 1000) {
                break
            }
            Start-Sleep -Milliseconds 50
        }
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
        $LogPath = Join-Path $PSScriptRoot 'worker.log'
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
        $global:LASTEXITCODE = 0
        & $_vscodeTempWorker -Mode Once -DryRun
        if ($LASTEXITCODE) { $EndorWarned = $true }
    } catch {
        Write-Warning "[endor] VS Code firewall dry run failed: $_"
        $EndorWarned = $true
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

    # A worker failure is reported, not thrown, so the update remediation task is still installed.
    try {
        $global:LASTEXITCODE = 0
        & $_vscodeWorkerPath -Mode Once
        if ($LASTEXITCODE) { $EndorWarned = $true }
    } catch {
        Write-Warning "[endor] VS Code firewall worker failed: $_"
        $EndorWarned = $true
    }

    if ($env:ENDOR_VSCODE_SKIP_WATCHER -ne '1') {
        try {
            $taskName = 'Endor VS Code Extension Firewall'
            $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $taskAction = New-ScheduledTaskAction -Execute $powerShellExe `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$_vscodeWorkerPath`" -Mode Watch"
            $taskTrigger = New-ScheduledTaskTrigger -AtStartup
            $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            # Task Scheduler's default priority, 7, is below normal. While Setup and antivirus keep
            # the CPUs busy, the worker would then wait about 4 s for Windows' anti-starvation boost,
            # and could lose the race with Setup starting VS Code. 4 is normal priority.
            $taskSettings = New-ScheduledTaskSettingsSet -Priority 4 -RestartCount 999 `
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
