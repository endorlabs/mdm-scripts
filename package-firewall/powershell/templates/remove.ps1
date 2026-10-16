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
#   .NET / NuGet:
#     %APPDATA%\NuGet\NuGet.Config  (sections kept; nuget.org restored if no source is left)
#
#   Ruby / Bundler:
#     %USERPROFILE%\.bundle\config  (Endor mirror keys removed, incl. stale copies left by `bundle config`;
#                                    user keys kept; the credential is the HKCU env var)
#
#   Ruby / gem:
#     %USERPROFILE%\.gemrc          (pre-install original restored from .gemrc.endor-bak, or deleted if Endor created it)
#
#   VS Code:
#     Restores default gallery properties, removes update remediation, and removes
#     Endor's ExtensionGalleryServiceUrl policy from HKLM\SOFTWARE\Policies\Microsoft\VSCode
#
# Registry env vars removed:
#   ENDOR_API_KEY_ID, ENDOR_API_SECRET, ENDOR_AUTH_B64
#   ENDOR_NPM_REGISTRY_URL, ENDOR_PYPI_URL, ENDOR_GO_PROXY_URL
#   POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME/PASSWORD
#   BUNDLE_<FIREWALL_HOST>
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
    'BUNDLE_{{BUNDLE_HOST_KEY}}'
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

# Same broadcast as the installer: apps launched from now on no longer see the
# removed values. Open windows keep their copy until restarted.
if ($DryRun) {
    Write-Host '[dry-run]   broadcast WM_SETTINGCHANGE (Environment)'
} else {
    switch (Send-EnvironmentChangeBroadcast) {
        'sent'   { Write-Host '[endor-remove]   environment change broadcast; open a new terminal' }
        'system' { Write-Host '[endor-remove]   running as SYSTEM: removal applies at the user''s next sign-in' }
        default  { Write-Host "[endor-remove]   removal applies at next sign-in (environment broadcast $_)" }
    }
}
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

# -- NuGet config file --
Write-Host '[endor-remove] -- NuGet / .NET -------------------------------------------'

Remove-NuGetBlocks -FilePath (Join-Path $AppData 'NuGet\NuGet.Config') -DryRun:$DryRun
Write-Host ''

# -- Bundler config file --
Write-Host '[endor-remove] -- Ruby / Bundler -------------------------------------------'

Remove-BundleConfig -FilePath (Join-Path $UserHome '.bundle\config') -MirrorUrl '{{GEM_MIRROR_URL}}' -DryRun:$DryRun
Write-Host ''

# -- gem config file --
Write-Host '[endor-remove] -- Ruby / gem -----------------------------------------------'

Remove-Gemrc -FilePath (Join-Path $UserHome '.gemrc') -MirrorUrl '{{GEM_MIRROR_URL}}' -DryRun:$DryRun
Write-Host ''

# >>> endor-vscode-remove
# -- VS Code extension firewall --
# Removes both methods: the product.json patch and the ExtensionGalleryServiceUrl policy. This
# section stands on its own, and doesn't use the signed-in user.
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
    # Workers installed by earlier versions throw on a file they can't restore; count that as
    # a failure too, so the state is kept for another try.
    $_vscodeRestoreFailed = $false
    try {
        $global:LASTEXITCODE = 0
        if ($DryRun) {
            & $_vscodeWorkerPath -Mode Restore -DryRun
        } else {
            & $_vscodeWorkerPath -Mode Restore
        }
        if ($LASTEXITCODE) { $_vscodeRestoreFailed = $true }
    } catch {
        Write-Warning "[endor-remove] VS Code worker failed: $_"
        $_vscodeRestoreFailed = $true
    }
    if ($_vscodeRestoreFailed) {
        $EndorWarned = $true
        Write-Warning '[endor-remove] VS Code restoration was incomplete; managed state was retained.'
    } elseif (-not $DryRun) {
        Remove-Item -LiteralPath $_vscodeStateRoot -Recurse -Force
    }
} else {
    Write-Host '[endor-remove] skip (no VS Code managed state)'
}

# The policy, in HKLM\SOFTWARE\Policies\Microsoft\VSCode: only Endor's values go, and the key too
# if this machine's record says the installer created it and nothing else is left in it.
# ENDOR_VSCODE_POLICY_KEY and ENDOR_VSCODE_POLICY_STATE_DIR are for tests, as in the installer.
if ($env:OS -eq 'Windows_NT') {
    $_vscodePolicyHive = 'LocalMachine'
    $_vscodePolicyKey = 'SOFTWARE\Policies\Microsoft\VSCode'
    if ($env:ENDOR_VSCODE_POLICY_KEY) {
        $_vscodePolicyHive = 'CurrentUser'
        $_vscodePolicyKey = $env:ENDOR_VSCODE_POLICY_KEY
    }
    $_vscodePolicyName = $(if ($_vscodePolicyHive -eq 'LocalMachine') { 'HKLM\' } else { 'HKCU\' }) + $_vscodePolicyKey
    $_vscodePolicyState = if ($env:ENDOR_VSCODE_POLICY_STATE_DIR) {
        $env:ENDOR_VSCODE_POLICY_STATE_DIR
    } else {
        Join-Path $env:ProgramData 'Endor Labs\vscode-policy'
    }
    try {
        $_vscodeRecord = $null
        $_vscodeRecordPath = Join-Path $_vscodePolicyState 'record.json'
        if (Test-Path -LiteralPath $_vscodeRecordPath) {
            try { $_vscodeRecord = Get-Content -LiteralPath $_vscodeRecordPath -Raw | ConvertFrom-Json } catch { }
        }
        $_vscodeBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey($_vscodePolicyHive, 'Registry64')
        $_vscodeKey = $_vscodeBase.OpenSubKey($_vscodePolicyKey, -not $DryRun)
        $_vscodeRemove = @()
        if ($_vscodeKey) {
            if ([string]$_vscodeKey.GetValue('ExtensionGalleryServiceUrl') -like '*/firewall/vscode/_ak/*') {
                $_vscodeRemove += 'ExtensionGalleryServiceUrl'
            }
            if ($_vscodeRecord.auth -and [string]$_vscodeKey.GetValue('ExtensionGalleryAuthProvider') -ceq [string]$_vscodeRecord.auth) {
                $_vscodeRemove += 'ExtensionGalleryAuthProvider'
            }
        }
        if ($_vscodeRemove.Count -eq 0) {
            Write-Host "[endor-remove] skip (no Endor VS Code policy in $_vscodePolicyName)"
        } elseif ($DryRun) {
            Write-Host "[dry-run]   action : REMOVE $($_vscodeRemove -join ' and ') from $_vscodePolicyName"
        } else {
            foreach ($_vscodeName in $_vscodeRemove) { $_vscodeKey.DeleteValue($_vscodeName, $false) }
            Write-Host "[endor-remove] removed the Endor VS Code policy from $_vscodePolicyName"
            if (-not $_vscodeRecord -and $_vscodeRemove -contains 'ExtensionGalleryServiceUrl') {
                Write-Warning "[endor-remove] this machine has no record of setting ExtensionGalleryServiceUrl in $_vscodePolicyName."
                Write-Warning '[endor-remove]   If Group Policy, an ADMX-based profile or the Intune Settings Catalog set it, it will be set again; remove it there.'
                $EndorWarned = $true
            }
            if ($_vscodeRecord.createdKey -and $_vscodeKey.ValueCount -eq 0 -and $_vscodeKey.SubKeyCount -eq 0) {
                $_vscodeKey.Dispose()
                $_vscodeKey = $null
                $_vscodeBase.DeleteSubKey($_vscodePolicyKey, $false)
            }
        }
        if ($_vscodeKey) { $_vscodeKey.Dispose() }
        $_vscodeBase.Dispose()
        if (-not $DryRun -and (Test-Path -LiteralPath $_vscodePolicyState)) {
            Remove-Item -LiteralPath $_vscodePolicyState -Recurse -Force
        }
    } catch {
        Write-Warning "[endor-remove] VS Code's policy was not removed from $_vscodePolicyName ($_)"
        $EndorWarned = $true
    }
}
Remove-Variable _vscodeStateRoot, _vscodeWorkerPath
Remove-Variable _vscodeRestoreFailed, _vscodePolicyHive, _vscodePolicyKey, _vscodePolicyName, _vscodePolicyState,
    _vscodeRecord, _vscodeRecordPath, _vscodeBase, _vscodeKey, _vscodeRemove, _vscodeName -ErrorAction SilentlyContinue
# <<< endor-vscode-remove
Write-Host ''

if ($DryRun) {
    Write-Host '[endor-remove] [done] Dry run complete -- no files modified, no registry keys removed.'
} else {
    Write-Host '[endor-remove] [done] Removal complete.'
    Write-Host '[endor-remove]   Package managers will fall back to their default registries.'
    Write-Host '[endor-remove]   Open a new terminal for env var changes to take effect.'
}

if ($EndorWarned) { exit 1 }
