# templates/envvars.ps1
# Writes persistent user-level environment variables to HKCU:\Environment.
# Values are baked in at generation time by generate.ps1.
#
# On Windows, HKCU:\Environment is automatically inherited by every new process
# the user starts — including non-interactive contexts such as Makefiles, git
# hooks, and IDE terminal windows. This natively closes the non-interactive
# shell gap that exists on macOS (where env vars require sourcing ~/.zshrc).
#
# {{PLACEHOLDER}} values are substituted at generation time.
# The written registry entries are plain REG_SZ strings.

Write-Host '[endor] -- environment variables ----------------------------------------'

$_envVars = [ordered]@{
    'ENDOR_API_KEY_ID'                          = '{{API_KEY_ID}}'
    'ENDOR_API_SECRET'                          = '{{API_SECRET}}'
    'ENDOR_AUTH_B64'                            = '{{NPM_AUTH_B64}}'
    'ENDOR_API_SECRET_B64'                      = '{{API_SECRET_B64}}'
    'ENDOR_NPM_REGISTRY_URL'                    = '{{NPM_REGISTRY_URL}}'
    'ENDOR_PYPI_URL'                            = '{{PIP_INDEX_URL}}'
    'POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME' = '{{API_KEY_ID}}'
    'POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD' = '{{API_SECRET}}'
}

foreach ($_name in $_envVars.Keys) {
    if ($DryRun) {
        Write-Host "[dry-run]   Set-UserEnvVar : $_name"
    } else {
        Set-UserEnvVar -Name $_name -Value $_envVars[$_name] -UserSID $UserSID
        Write-Host "[endor]   set : $_name"
    }
}
Remove-Variable _envVars
Write-Host '[endor] [done] env vars -- take effect in new terminal sessions'
Write-Host ''
