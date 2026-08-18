# templates/remove.ps1
# Removes Endor Package Firewall sentinel blocks from all config files and
# deletes all Endor env vars from HKCU:\Environment.
#
# Files targeted (mirrors exactly what the install scripts write to):
#
#   JavaScript:
#     %USERPROFILE%\.npmrc
#     %USERPROFILE%\.yarnrc
#     %USERPROFILE%\.yarnrc.yml
#
#   Python:
#     %APPDATA%\pip\pip.ini
#     %APPDATA%\uv\uv.toml
#
#   Go:
#     %APPDATA%\go\env
#
#   Java / Maven:
#     %USERPROFILE%\.m2\settings.xml
#
#   VS Code:
#     Restores product.json backup and removes update remediation
#
# Registry env vars removed:
#   ENDOR_API_KEY_ID, ENDOR_API_SECRET, ENDOR_AUTH_B64
#   ENDOR_NPM_REGISTRY_URL, ENDOR_PYPI_URL, ENDOR_GO_PROXY_URL
#   POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME/PASSWORD
#
# Behaviour:
#   - Files with no Endor block are skipped (nothing modified)
#   - Files where Endor block is the only content are deleted
#   - Files with other content have only the block stripped
#   - Registry env vars that don't exist are skipped silently
#   - -DryRun: prints what would happen, writes nothing
#   - Safe to run multiple times (idempotent)

Write-Host ''
Write-Host '[endor-remove] -- Endor Package Firewall removal ------------------------'
Write-Host '[endor-remove]    namespace={{NAMESPACE}}'
if ($DryRun) { Write-Host '[endor-remove]    mode=DRY RUN -- no changes will be made' }
Write-Host ''

# -- Registry environment variables --
Write-Host '[endor-remove] -- environment variables ---------------------------------'

$_removeVars = @(
    'ENDOR_API_KEY_ID'
    'ENDOR_API_SECRET'
    'ENDOR_ATTR_USER'
    'ENDOR_AUTH_B64'
    'ENDOR_API_SECRET_B64'
    'ENDOR_NPM_REGISTRY_URL'
    'ENDOR_PYPI_URL'      # no longer written; still removed to clean older deployments
    'ENDOR_GO_PROXY_URL'  # no longer written; still removed to clean older deployments
    'POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME'
    'POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD'
)

foreach ($_name in $_removeVars) {
    if ($DryRun) {
        Write-Host "[dry-run]   Remove-UserEnvVar : $_name"
    } else {
        Remove-UserEnvVar -Name $_name -UserSID $UserSID
        Write-Host "[endor-remove]   removed : $_name"
    }
}
Remove-Variable _removeVars
Write-Host ''

# -- JavaScript config files --
Write-Host '[endor-remove] -- JavaScript ---------------------------------------------'

Invoke-RemoveBlock -FilePath (Join-Path $UserHome '.npmrc')      -DryRun:$DryRun
Invoke-RemoveBlock -FilePath (Join-Path $UserHome '.yarnrc')     -DryRun:$DryRun
Invoke-RemoveBlock -FilePath (Join-Path $UserHome '.yarnrc.yml') -DryRun:$DryRun

# yarn 1.x rewrites .yarnrc on its own and can copy the Endor registry outside
# the managed block. Delete only lines exactly matching our URL — they can't be
# anyone else's config.
$_yarnrc    = Join-Path $UserHome '.yarnrc'
$_endorLine = 'registry "{{NPM_REGISTRY_URL}}"'
$_outside   = @()
if (Test-Path $_yarnrc) {
    $_inBlock = $false
    foreach ($_l in @(Get-Content $_yarnrc -Encoding UTF8)) {
        if ($_l -eq $ENDOR_BLOCK_START) { $_inBlock = $true;  continue }
        if ($_l -eq $ENDOR_BLOCK_END)   { $_inBlock = $false; continue }
        if (-not $_inBlock) { $_outside += $_l }
    }
}
if ($_outside -contains $_endorLine) {
    if ($DryRun) {
        Write-Host "[dry-run]   action : DELETE yarn-copied Endor registry line from $_yarnrc"
    } else {
        $_kept = @(Get-Content $_yarnrc -Encoding UTF8) |
                 Where-Object { $_ -ne $_endorLine -and $_ -ne 'always-auth true' }
        if (-not (($_kept -join '') -replace '\s', '')) {
            Remove-Item $_yarnrc -Force
            Write-Host "[endor-remove] deleted (was empty) : $_yarnrc"
        } else {
            Write-EndorFile -FilePath $_yarnrc -Lines $_kept
            Write-Host "[endor-remove] yarn-copied line removed: $_yarnrc"
        }
    }
}
Remove-Variable _yarnrc, _endorLine, _outside -ErrorAction SilentlyContinue
Write-Host ''

# -- Python config files --
Write-Host '[endor-remove] -- Python -------------------------------------------------'

Invoke-RemoveBlock -FilePath (Join-Path $AppData 'pip\pip.ini') -DryRun:$DryRun
Invoke-RemoveBlock -FilePath (Join-Path $AppData 'uv\uv.toml')  -DryRun:$DryRun
Write-Host ''

# -- Go config file --
Write-Host '[endor-remove] -- Go -----------------------------------------------------'

# Resolve go env file path the same way the install script does.
$_goEnvFile = $null
$_goExe = Get-Command 'go' -ErrorAction SilentlyContinue
if ($_goExe) {
    try {
        $env:APPDATA = $AppData; $env:USERPROFILE = $UserHome; $env:GOENV = ''
        $_goEnvFile = (& go env GOENV 2>$null) | Select-Object -First 1
    } catch { $_goEnvFile = $null } finally { Remove-Item Env:\GOENV -ErrorAction SilentlyContinue }
}
if (-not $_goEnvFile) { $_goEnvFile = Join-Path $AppData 'go\env' }
$_goEnvFile = $_goEnvFile.Trim()

Invoke-RemoveBlock -FilePath $_goEnvFile -DryRun:$DryRun
Remove-Variable _goEnvFile, _goExe
Write-Host ''

# -- Maven config file --
Write-Host '[endor-remove] -- Maven --------------------------------------------------'

Remove-XmlBlock -FilePath (Join-Path $UserHome '.m2\settings.xml') -DryRun:$DryRun
Write-Host ''

# -- VS Code extension firewall --
Write-Host '[endor-remove] -- VS Code extensions ------------------------------------'
$_vscodeStateRoot = if ($env:ENDOR_VSCODE_STATE_DIR) {
    $env:ENDOR_VSCODE_STATE_DIR
} else {
    Join-Path $env:ProgramData 'Endor Labs\vscode-firewall'
}
$_vscodeWorkerPath = Join-Path $_vscodeStateRoot 'worker.ps1'

if ($DryRun) {
    Write-Host '[dry-run]   action : STOP and DELETE Endor VS Code Extension Firewall task'
} elseif ($env:ENDOR_VSCODE_SKIP_WATCHER -ne '1') {
    Stop-ScheduledTask -TaskName 'Endor VS Code Extension Firewall' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'Endor VS Code Extension Firewall' -Confirm:$false -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $_vscodeWorkerPath) {
    if ($DryRun) {
        & $_vscodeWorkerPath -Mode Restore -DryRun
    } else {
        & $_vscodeWorkerPath -Mode Restore
    }
    if ($LASTEXITCODE) {
        $EndorWarned = $true
        Write-Warning '[endor-remove] VS Code restoration was incomplete; managed state was retained.'
    } elseif (-not $DryRun) {
        Remove-Item -LiteralPath $_vscodeStateRoot -Recurse -Force
    }
} else {
    Write-Host '[endor-remove] skip (no VS Code managed state)'
}
Remove-Variable _vscodeStateRoot, _vscodeWorkerPath
Write-Host ''

if ($DryRun) {
    Write-Host '[endor-remove] [done] Dry run complete -- no files modified, no registry keys removed.'
} else {
    Write-Host '[endor-remove] [done] Removal complete.'
    Write-Host '[endor-remove]   Package managers will fall back to their default registries.'
    Write-Host '[endor-remove]   Open a new terminal for env var changes to take effect.'
}

if ($EndorWarned) { exit 1 }
