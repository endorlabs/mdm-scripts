#!/usr/bin/env pwsh
# MDM-deployable: {{DESCRIPTION}}
# Generated for namespace={{NAMESPACE}} fqdn={{FQDN}}.
# Do not edit — regenerate with generate.ps1.
# Usage: .\{{SCRIPTNAME}} [-DryRun]
#
# Requirements : PowerShell 5.1+ or PowerShell Core 7+
# MDM context  : Run as SYSTEM (Intune default) or as the logged-in user
# Execution policy: set to Bypass or RemoteSigned in your MDM policy

[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

# -- Common functions (inlined from lib/common.ps1) --
{{COMMON_CONTENT}}
# --

if ($DryRun) {
    Write-Host '[endor] DRY RUN -- no files will be modified and no registry keys will be written.'
}

# -- Detect console user --
# When running as SYSTEM (Intune default), Get-ConsoleUser detects the logged-in
# user via explorer.exe and resolves their profile path + registry SID.
# When running as the logged-in user, returns the current user's identity.
$_ctx        = Get-ConsoleUser
$UserSID     = $_ctx.SID
$UserHome    = $_ctx.ProfilePath
$AppData     = $_ctx.AppDataPath
$ConsoleUser = $_ctx.Username
Remove-Variable _ctx

Write-Host "[endor] console user: $ConsoleUser"
Write-Host "[endor] profile     : $UserHome"
Write-Host ''
