# templates/remove.ps1
# Removes Endor Package Firewall sentinel blocks from all config files and
# deletes all Endor env vars from HKCU:\Environment.
#
# Files targeted (mirrors exactly what the install scripts write to):
#
#   JavaScript:
#     %USERPROFILE%\.npmrc
#     %USERPROFILE%\.yarnrc.yml
#
#   Python:
#     %APPDATA%\pip\pip.ini
#     %APPDATA%\uv\uv.toml
#
# Registry env vars removed:
#   ENDOR_API_KEY_ID, ENDOR_API_SECRET, ENDOR_AUTH_B64
#   ENDOR_NPM_REGISTRY_URL, ENDOR_PYPI_URL
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
    'ENDOR_AUTH_B64'
    'ENDOR_NPM_REGISTRY_URL'
    'ENDOR_PYPI_URL'
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
Invoke-RemoveBlock -FilePath (Join-Path $UserHome '.yarnrc.yml') -DryRun:$DryRun
Write-Host ''

# -- Python config files --
Write-Host '[endor-remove] -- Python -------------------------------------------------'

Invoke-RemoveBlock -FilePath (Join-Path $AppData 'pip\pip.ini') -DryRun:$DryRun
Invoke-RemoveBlock -FilePath (Join-Path $AppData 'uv\uv.toml')  -DryRun:$DryRun
Write-Host ''

if ($DryRun) {
    Write-Host '[endor-remove] [done] Dry run complete -- no files modified, no registry keys removed.'
} else {
    Write-Host '[endor-remove] [done] Removal complete.'
    Write-Host '[endor-remove]   Package managers will fall back to their default registries.'
    Write-Host '[endor-remove]   Open a new terminal for env var changes to take effect.'
}
