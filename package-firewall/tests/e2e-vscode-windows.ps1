# Windows only. End-to-end test of the VS Code firewall watcher with Microsoft's real system
# installer:
#   1. install OLD, then deploy endor-vscode.ps1 with both methods from 32-bit Windows PowerShell,
#      as Intune does by default, and check the SYSTEM task is running, OLD is patched, and the
#      policy is in HKLM where VS Code's own VSCode.admx says VS Code reads it;
#   2. install NEW over it the way a system install updates (VS Code closed, Setup writes a new
#      <commit>\resources\app\product.json, then starts VS Code), and check the running watcher
#      patches the new file within 5 seconds of it appearing;
#   3. run endor-remove.ps1 and check Microsoft's gallery settings are back, and the task and the
#      policy are gone.
#
# It changes the machine it runs on: it installs VS Code for all users, registers a SYSTEM
# scheduled task and runs endor-remove.ps1. So it runs only on a GitHub-hosted runner, or with
# ENDOR_E2E_ALLOW_HOST_CHANGES=1 on a disposable machine. It needs an elevated PowerShell 7 and
# access to update.code.visualstudio.com.
#
#   ENDOR_E2E_OLD_VERSION, ENDOR_E2E_NEW_VERSION  the VS Code releases to use. By default NEW is
#                            the latest stable release and OLD the newest one of the minor before.
#   ENDOR_E2E_ARTIFACTS      where to keep logs: Setup, worker, scheduled task
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'skip: the VS Code Windows end-to-end test runs on Windows only'
    exit 0
}
if ($env:RUNNER_ENVIRONMENT -ne 'github-hosted' -and $env:ENDOR_E2E_ALLOW_HOST_CHANGES -ne '1') {
    Write-Error ('refusing to run: this test installs VS Code and a SYSTEM scheduled task on this machine. ' +
        'Run it on a GitHub-hosted runner, or set ENDOR_E2E_ALLOW_HOST_CHANGES=1 on a disposable machine.') `
        -ErrorAction Continue
    exit 2
}
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'this test needs an elevated PowerShell' -ErrorAction Continue
    exit 2
}

$TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path (Join-Path $TestDir '..\..')).Path
$Namespace = 'ci-e2e'
$Out = Join-Path $RootDir "package-firewall\powershell\out\$Namespace"
$FirewallPrefix = "https://factory.endorlabs.com/v1/namespaces/$Namespace/firewall/vscode/_ak/"
$DefaultServiceUrl = 'https://marketplace.visualstudio.com/_apis/public/gallery'
$DefaultExtensionUrlTemplate = 'https://www.vscode-unpkg.net/_gallery/{publisher}/{name}/latest'
$App = Join-Path $env:ProgramW6432 'Microsoft VS Code'
$TaskName = 'Endor VS Code Extension Firewall'
$StateDir = Join-Path $env:ProgramData 'Endor Labs\vscode-firewall'
$WorkerLog = Join-Path $StateDir 'worker.log'
$PolicyKey = 'SOFTWARE\Policies\Microsoft\VSCode'
$PolicyStateDir = Join-Path $env:ProgramData 'Endor Labs\vscode-policy'
$WindowsPowerShell32 = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
$Artifacts = if ($env:ENDOR_E2E_ARTIFACTS) { $env:ENDOR_E2E_ARTIFACTS } else {
    Join-Path ([IO.Path]::GetTempPath()) 'vscode-e2e-artifacts'
}
$Work = Join-Path ([IO.Path]::GetTempPath()) "endor-vscode-e2e-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $Artifacts, $Work -Force | Out-Null

function Write-Pass { param([string]$Message) Write-Host "PASS: $Message" }
function Stop-Test { param([string]$Message) throw "FAIL: $Message" }

function Get-Product {
    param([string]$Path)
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-CommitProduct {
    param([string]$Commit)
    Join-Path $App "$($Commit.Substring(0, 10))\resources\app\product.json"
}

function Test-Patched {
    param([string]$Path)
    try {
        ([string](Get-Product $Path).extensionsGallery.serviceUrl).StartsWith($FirewallPrefix)
    } catch {
        $false
    }
}

function Get-Setup {
    param([string]$Version)
    $setup = Join-Path $Work "VSCodeSetup-x64-$Version.exe"
    Invoke-WebRequest -Uri "https://update.code.visualstudio.com/$Version/win32-x64/stable" `
        -OutFile $setup -MaximumRetryCount 3 -RetryIntervalSec 5
    $setup
}

function Install-VSCode {
    param([string]$Setup, [string]$Label)
    # The arguments VS Code passes for a foreground update, without starting VS Code afterwards.
    $process = Start-Process -FilePath $Setup -Wait -PassThru -ArgumentList '/VERYSILENT', '/NORESTART',
        '/SUPPRESSMSGBOXES', '/MERGETASKS=!runcode,!desktopicon,!quicklaunchicon',
        "/LOG=`"$(Join-Path $Artifacts "setup-$Label.log")`""
    if ($process.ExitCode) { Stop-Test "Setup ($Label) exited with $($process.ExitCode)" }
}

function Get-InstalledCommit {
    $product = Get-ChildItem -LiteralPath $App -Directory |
        Where-Object Name -Match '^[0-9a-f]{10}$' |
        ForEach-Object { Join-Path $_.FullName 'resources\app\product.json' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Sort-Object { (Get-Item -LiteralPath $_).CreationTimeUtc } |
        Select-Object -Last 1
    if (-not $product) { Stop-Test "no <commit>\resources\app\product.json under $App" }
    [string](Get-Product $product).commit
}

function Save-Logs {
    param([string]$Label)
    if (Test-Path -LiteralPath $WorkerLog) {
        Copy-Item -LiteralPath $WorkerLog -Destination (Join-Path $Artifacts "worker-$Label.log") -Force
    }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Export-ScheduledTask -TaskName $TaskName | Set-Content (Join-Path $Artifacts "task-$Label.xml")
        $task | Get-ScheduledTaskInfo | Format-List | Out-String |
            Set-Content (Join-Path $Artifacts "task-info-$Label.txt")
    }
    # Which Windows PowerShell processes run, since when, and with what arguments: shows whether the
    # watcher started, and when.
    Get-CimInstance Win32_Process -Filter "name='powershell.exe'" -ErrorAction SilentlyContinue |
        Select-Object ProcessId, ParentProcessId, CreationDate, CommandLine | Format-List | Out-String -Width 4096 |
        Set-Content (Join-Path $Artifacts "processes-$Label.txt")
}

try {
    # Invoke-RestMethod returns a JSON array as one object; the cast makes it a list of versions.
    $releases = [string[]](Invoke-RestMethod -Uri 'https://update.code.visualstudio.com/api/releases/stable' `
        -MaximumRetryCount 3 -RetryIntervalSec 5) | Where-Object { $_ -match '^\d+\.\d+\.\d+$' }
    $new = if ($env:ENDOR_E2E_NEW_VERSION) { $env:ENDOR_E2E_NEW_VERSION } else { $releases[0] }
    $old = if ($env:ENDOR_E2E_OLD_VERSION) { $env:ENDOR_E2E_OLD_VERSION } else {
        $minor = ($new -split '\.')[0..1] -join '.'
        $releases | Where-Object { (($_ -split '\.')[0..1] -join '.') -ne $minor -and [version]$_ -lt [version]$new } |
            Select-Object -First 1
    }
    if (-not $new -or -not $old) { Stop-Test "could not choose VS Code versions (new '$new', old '$old')" }
    Write-Host "VS Code $old -> $new"
    $oldSetup = Get-Setup $old
    $newSetup = Get-Setup $new

    Write-Host '== 1. install OLD and deploy from 32-bit Windows PowerShell'
    Install-VSCode $oldSetup 'old'
    $oldCommit = Get-InstalledCommit
    $oldProduct = Get-CommitProduct $oldCommit
    if (Test-Patched $oldProduct) { Stop-Test 'a fresh install is already patched' }

    $env:ENDOR_NAMESPACE = $Namespace
    $env:ENDOR_API_KEY_ID = 'ci-e2e-key-id'
    $env:ENDOR_API_SECRET = 'ci-e2e-secret'
    $env:ENDOR_VSCODE_ENABLE_PATCH = '1'
    $env:ENDOR_VSCODE_ENABLE_POLICY = '1'
    # VS Code reads the URL policy from 1.99, and the sign-in provider from 1.137. Check what OLD reads.
    $oldVersion = [version]($old -replace '[^0-9.].*$', '')
    $policyNames = @()
    if ($oldVersion -ge [version]'1.99') { $policyNames += 'ExtensionGalleryServiceUrl' }
    if ($oldVersion -ge [version]'1.137') { $policyNames += 'ExtensionGalleryAuthProvider' }
    $env:ENDOR_VSCODE_POLICY_AUTH = if ($policyNames -contains 'ExtensionGalleryAuthProvider') { 'microsoft' } else { '' }
    $global:LASTEXITCODE = 0
    & (Join-Path $RootDir 'package-firewall\powershell\generate.ps1') | Out-Null
    if ($LASTEXITCODE) { Stop-Test 'generate.ps1 failed' }
    & $WindowsPowerShell32 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Out 'endor-vscode.ps1') *>&1 |
        Tee-Object -FilePath (Join-Path $Artifacts 'install.log')
    if ($LASTEXITCODE) { Stop-Test "endor-vscode.ps1 exited with $LASTEXITCODE" }
    if (-not (Test-Patched $oldProduct)) { Stop-Test 'the installer did not patch the 64-bit install' }
    Write-Pass 'the installer, run from 32-bit PowerShell, patched the 64-bit install'
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task -or $task.State -ne 'Running') { Stop-Test "the task is $($task.State), not running" }
    if ($task.Principal.UserId -notin 'SYSTEM', 'NT AUTHORITY\SYSTEM') {
        Stop-Test "the task runs as $($task.Principal.UserId)"
    }
    if ($task.Settings.Priority -ne 4) { Stop-Test "the task runs at priority $($task.Settings.Priority), not 4 (normal)" }
    Write-Pass 'the SYSTEM watcher task is running at normal priority'
    # Let the watcher finish its first pass and start watching. The installer has already patched,
    # so a slow start on a busy runner doesn't matter here; the time it took is printed.
    $watchStarted = Get-Date
    $deadline = $watchStarted.AddSeconds(120)
    while (-not ((Test-Path -LiteralPath $WorkerLog) -and
            (Get-Content -LiteralPath $WorkerLog -Raw) -match 'watching [1-9][0-9]* install')) {
        if ((Get-Date) -gt $deadline) {
            Save-Logs 'watch-start'
            Stop-Test 'the watcher did not start watching within 120s'
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Host ("the watcher was watching {0:N1}s after the installer finished" -f ((Get-Date) - $watchStarted).TotalSeconds)
    # VS Code's own policy definitions say where it reads each policy.
    $admx = @(@(Get-Item -LiteralPath $App) + @(Get-ChildItem -LiteralPath $App -Directory) |
        ForEach-Object { Join-Path $_.FullName 'policies\VSCode.admx' } |
        Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
    if ($policyNames -and -not $admx) { Stop-Test "the install has no policies\VSCode.admx" }
    if ($admx) { [xml]$definitions = Get-Content -LiteralPath $admx -Raw }
    foreach ($name in $policyNames) {
        $definition = $definitions.SelectSingleNode(
            "//*[local-name()='policy'][@valueName='$name' or .//*[@valueName='$name']]")
        if (-not $definition) { Stop-Test "VSCode.admx does not define $name" }
        if ($definition.GetAttribute('key') -ne $PolicyKey) {
            Stop-Test "VSCode.admx reads $name from $($definition.GetAttribute('key')), not $PolicyKey"
        }
    }
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    $key = $hklm.OpenSubKey($PolicyKey)
    if (-not $key) { Stop-Test "the installer did not create HKLM\$PolicyKey" }
    if (-not ([string]$key.GetValue('ExtensionGalleryServiceUrl')).StartsWith($FirewallPrefix)) {
        Stop-Test 'HKLM does not set the Endor ExtensionGalleryServiceUrl'
    }
    if ($env:ENDOR_VSCODE_POLICY_AUTH -and $key.GetValue('ExtensionGalleryAuthProvider') -ne 'microsoft') {
        Stop-Test 'HKLM does not set ExtensionGalleryAuthProvider'
    }
    $key.Dispose()
    Write-Pass "the policy is in HKLM\$PolicyKey, where VSCode.admx says VS Code reads it"

    Write-Host '== 2. update to NEW the way a system install does, while the watcher runs'
    # Poll the new commit's product.json from another process, to time it from appearing to patched.
    $poller = Start-Job -ArgumentList $App, $oldCommit.Substring(0, 10), $FirewallPrefix -ScriptBlock {
        param($App, $OldFolder, $Prefix)
        $seen = $null
        $deadline = [DateTime]::UtcNow.AddMinutes(10)
        while ([DateTime]::UtcNow -lt $deadline) {
            foreach ($dir in @(Get-ChildItem -LiteralPath $App -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^[0-9a-f]{10}$' -and $_.Name -ne $OldFolder })) {
                $product = Join-Path $dir.FullName 'resources\app\product.json'
                if (-not (Test-Path -LiteralPath $product)) { continue }
                if (-not $seen) { $seen = [DateTime]::UtcNow }
                # Setup and the worker hold the file open while they write it. -ErrorAction Stop makes
                # that sharing violation catchable, so this poll retries instead of failing the job.
                try {
                    $url = [string](Get-Content -LiteralPath $product -Raw -ErrorAction Stop | ConvertFrom-Json).extensionsGallery.serviceUrl
                    if ($url.StartsWith($Prefix)) {
                        return [PSCustomObject]@{ Seen = $seen; Patched = [DateTime]::UtcNow; Path = $product }
                    }
                } catch {
                }
            }
            Start-Sleep -Milliseconds 50
        }
        [PSCustomObject]@{ Seen = $seen; Patched = $null; Path = $null }
    }
    Install-VSCode $newSetup 'new'
    $setupDone = [DateTime]::UtcNow
    $timing = $poller | Wait-Job -Timeout 60 | Receive-Job
    $poller | Remove-Job -Force
    $newCommit = Get-InstalledCommit
    if ($newCommit -eq $oldCommit) { Stop-Test 'the update did not install a new commit folder' }
    if (-not $timing -or -not $timing.Patched) { Stop-Test "the watcher did not patch $(Get-CommitProduct $newCommit)" }
    $latency = ($timing.Patched - $timing.Seen).TotalSeconds
    $margin = ($setupDone - $timing.Patched).TotalSeconds
    Write-Host ("product.json patched {0:N1}s after it appeared, {1:N1}s before Setup finished" -f $latency, $margin)
    if ($latency -gt 5) { Stop-Test "the watcher took ${latency}s to patch the new product.json" }
    Write-Pass 'the watcher patched the new version within 5s of Setup writing it'
    $product = Get-Product (Get-CommitProduct $newCommit)
    if ($product.target -ne 'system' -or $product.win32VersionedUpdate -ne $true -or $newCommit.Length -ne 40) {
        Stop-Test 'the patch lost target, win32VersionedUpdate or commit, which VS Code uses to choose how to update'
    }
    $workerLog = Get-Content -LiteralPath $WorkerLog -Raw
    if ($workerLog -notmatch [regex]::Escape($newCommit.Substring(0, 10))) {
        Stop-Test 'the worker log does not record the patch'
    }
    # The updater deletes the old version folder at the end, often during a pass.
    if ($workerLog -match 'refusing|failed to') { Stop-Test 'the worker logged a problem during the update (see worker log)' }
    if ((Get-ScheduledTask -TaskName $TaskName).State -ne 'Running') { Stop-Test 'the watcher task stopped' }
    Write-Pass 'the patch kept target and commit, and the watcher is still running'
    Save-Logs 'before-removal'

    Write-Host '== 3. remove'
    $explorer = Get-CimInstance Win32_Process -Filter "name='explorer.exe'" -ErrorAction SilentlyContinue
    if ($explorer) {
        & $WindowsPowerShell32 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Out 'endor-remove.ps1') *>&1 |
            Tee-Object -FilePath (Join-Path $Artifacts 'remove.log')
        if ($LASTEXITCODE) { Stop-Test "endor-remove.ps1 exited with $LASTEXITCODE" }
    } else {
        # endor-remove.ps1 needs a signed-in user for the other ecosystems. Its VS Code section
        # doesn't, so run only that.
        Write-Host '::notice::no signed-in user on this runner; running only the VS Code section of endor-remove.ps1'
        $text = Get-Content -Raw (Join-Path $Out 'endor-remove.ps1')
        $section = [regex]::Match($text, '(?ms)^# >>> endor-vscode-remove\r?$.*?^# <<< endor-vscode-remove\r?$').Value
        if (-not $section) { Stop-Test 'endor-remove.ps1 has no VS Code section' }
        $sectionPath = Join-Path $Work 'remove-vscode.ps1'
        [IO.File]::WriteAllText($sectionPath,
            "param([switch]`$DryRun)`n`$ErrorActionPreference = 'Stop'`n`$EndorWarned = `$false`n$section`nif (`$EndorWarned) { exit 1 }`n",
            [Text.UTF8Encoding]::new($true))
        & $WindowsPowerShell32 -NoProfile -ExecutionPolicy Bypass -File $sectionPath *>&1 |
            Tee-Object -FilePath (Join-Path $Artifacts 'remove.log')
        if ($LASTEXITCODE) { Stop-Test "the VS Code section of endor-remove.ps1 exited with $LASTEXITCODE" }
    }
    $product = Get-Product (Get-CommitProduct $newCommit)
    if ($product.extensionsGallery.serviceUrl -ne $DefaultServiceUrl -or
            $product.extensionsGallery.extensionUrlTemplate -ne $DefaultExtensionUrlTemplate) {
        Stop-Test 'removal did not restore the default gallery settings'
    }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Stop-Test 'the task is still registered' }
    if (Test-Path -LiteralPath $StateDir) { Stop-Test 'the state folder is still there' }
    $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64').OpenSubKey($PolicyKey)
    if ($key) { Stop-Test "removal left HKLM\$PolicyKey, which the installer created" }
    if (Test-Path -LiteralPath $PolicyStateDir) { Stop-Test 'removal left the policy record' }
    Write-Pass 'removal restored the gallery settings and removed the task, its state and the policy'
    Write-Host 'VS Code Windows end-to-end test passed'
} finally {
    Save-Logs 'end'
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
