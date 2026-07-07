# templates/go.ps1
# Go ecosystem
#
# Config file written to the console user's go env file.
# The path is resolved via `go env GOENV` (Windows default: %APPDATA%\go\env).
#
# Block content is defined in shared/blocks/goenv.txt.
# Go env files can't expand env vars, so the {{GO_PROXY_URL}} token is filled
# here at install time with the attributed literal (from envvars.ps1).
#
# The go env file takes lower precedence than the GOPROXY process env var, so
# project-level overrides (go env -w GOPROXY=... in a workspace) remain possible.
# Sentinel comment lines (# ...) are silently ignored by `go env` parsing.

Write-Host '[endor-go] -- Go package manager ----------------------------------------'

# Fill the attributed GOPROXY into the block content (go env can't expand env vars).
$GO_BLOCK = $GO_BLOCK.Replace('{{GO_PROXY_URL}}', $ENDOR_GO_PROXY_URL)

# -- Resolve go env file path --
# Run `go env GOENV` with APPDATA pointed at the user's AppData so Go's
# os.UserConfigDir() returns the correct user-specific path.
# Falls back to %APPDATA%\go\env if go is not installed.
$_goEnvFile = $null

$_goExe = Get-Command 'go' -ErrorAction SilentlyContinue
if ($_goExe) {
    try {
        $env:APPDATA = $AppData
        $env:USERPROFILE = $UserHome
        $env:GOENV = ''
        $_goEnvFile = (& go env GOENV 2>$null) | Select-Object -First 1
    } catch {
        $_goEnvFile = $null
    } finally {
        Remove-Item Env:\GOENV -ErrorAction SilentlyContinue
    }
}

if (-not $_goEnvFile) {
    $_goEnvFile = Join-Path $AppData 'go\env'
    Write-Host '[endor-go]   go binary not found -- using OS default path'
}

$_goEnvFile = $_goEnvFile.Trim()

# -- Write GOPROXY to go env file --
Test-KeyConflict `
    -FilePath $_goEnvFile `
    -Pattern  '^GOPROXY=' `
    -Label    'GOPROXY'

Invoke-UpsertBlock `
    -FilePath  $_goEnvFile `
    -Content   $GO_BLOCK `
    -Username  $ConsoleUser `
    -DryRun:$DryRun

Write-Host "[endor-go] go env file   -> $_goEnvFile"
Write-Host '[endor-go]   covers: go modules (all versions)'
Write-Host '[endor-go]   GOPROXY: {{FQDN}}/v1/namespaces/{{NAMESPACE}}/firewall/go/ (with ,direct fallback)'
Write-Host '[endor-go] [done] Go done'
Remove-Variable _goEnvFile, _goExe
