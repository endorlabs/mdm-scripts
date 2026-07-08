# templates/envvars.ps1
# Computes the attributed credentials at install time, then writes them as
# persistent user-level environment variables to HKCU:\Environment.
#
# The attributed username (<console-user>@<machine>) only exists on the
# developer's machine, so it is derived here at install time from $ConsoleUser
# (detected in the script header) and the machine name.
#
# On Windows, HKCU:\Environment is automatically inherited by every new process
# the user starts — including non-interactive contexts such as Makefiles, git
# hooks, and IDE terminal windows.
#
# $ENDOR_PYPI_URL / $ENDOR_GO_PROXY_URL are NOT written to HKCU (no runtime
# reader) — they only feed the literal fills in python.ps1 / go.ps1 below.

Write-Host '[endor] -- environment variables ----------------------------------------'

# -- User attribution: compute the attributed username + derived credentials --
$_secret              = '{{API_SECRET}}'
$ENDOR_ATTR_LABEL     = "$ConsoleUser@$(Get-EndorHostLabel)"
$ENDOR_ATTR_USER      = Get-EndorAttrUsername -Label $ENDOR_ATTR_LABEL -ApiKeyId '{{API_KEY_ID}}'
$ENDOR_AUTH_B64       = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${ENDOR_ATTR_USER}:${_secret}"))
$ENDOR_API_SECRET_B64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($_secret))

# pip / uv / go URLs: percent-encode both userinfo halves ('/' would break the URL).
$_attrUserEnc         = Get-EndorUrlEncB64 $ENDOR_ATTR_USER
$_secretEnc           = Get-EndorUrlEncB64 $_secret
$ENDOR_PYPI_URL       = "https://${_attrUserEnc}:${_secretEnc}@{{FQDN_HOST}}/v1/namespaces/{{NAMESPACE}}/firewall/pypi/simple/"
$ENDOR_GO_PROXY_URL   = "https://${_attrUserEnc}:${_secretEnc}@{{FQDN_HOST}}/v1/namespaces/{{NAMESPACE}}/firewall/go/,direct"

Write-Host "[endor] user attribution -> $ENDOR_ATTR_LABEL"

$_envVars = [ordered]@{
    'ENDOR_API_KEY_ID'                          = '{{API_KEY_ID}}'
    'ENDOR_API_SECRET'                          = $_secret
    'ENDOR_ATTR_USER'                           = $ENDOR_ATTR_USER
    'ENDOR_AUTH_B64'                            = $ENDOR_AUTH_B64
    'ENDOR_API_SECRET_B64'                      = $ENDOR_API_SECRET_B64
    'ENDOR_NPM_REGISTRY_URL'                    = '{{NPM_REGISTRY_URL}}'
    'POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME' = $ENDOR_ATTR_USER
    'POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD' = $_secret
}

foreach ($_name in $_envVars.Keys) {
    if ($DryRun) {
        Write-Host "[dry-run]   Set-UserEnvVar : $_name"
    } else {
        Set-UserEnvVar -Name $_name -Value $_envVars[$_name] -UserSID $UserSID
        Write-Host "[endor]   set : $_name"
    }
}
Remove-Variable _envVars, _secret, _attrUserEnc, _secretEnc
Write-Host '[endor] [done] env vars -- take effect in new terminal sessions'
Write-Host ''
