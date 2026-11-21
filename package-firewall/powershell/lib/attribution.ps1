# lib/attribution.ps1
# User attribution: the label every generated script attributes to. generate.ps1 inlines this file
# into every script, before lib/common.ps1. Do NOT source this file directly — it is embedded at
# generation time.
#
# The firewall decodes the label from the Basic-auth username, auths with the real API key, and logs
# it as "User". Unverified telemetry only — never an authz signal.
#
# Functions:
#   Get-EndorAttrLabel    <user>             — the label: <user>@<machine>
#   Get-EndorAttrUsername <label> <apiKeyId> — the attributed Basic-auth username
#   Find-ConsoleUser                         — finds the logged-in user when running as SYSTEM;
#                                              $null when no one is logged in
#   Get-EndorHostLabel                       — what those need

# Get-EndorAttrUsername <label> <apiKeyId>
# Returns base64(base64("userattr:"+label)+":"+keyId) — the format
# decodeAttributedUsername() expects in endorfactory's auth layer.
function Get-EndorAttrUsername {
    param([string]$Label, [string]$ApiKeyId)
    $inner = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("userattr:$Label"))
    [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${inner}:${ApiKeyId}"))
}

# Get-EndorHostLabel — a stable, human-readable machine name for attribution.
function Get-EndorHostLabel {
    if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
}

# Get-EndorAttrLabel <user>
# The label every ecosystem attributes to: <user>@<machine>. Nothing with no user, when no one is
# logged in. To label users another way (by email, or by looking the machine up), change only this
# function before generating. Anything it calls belongs in this file too.
function Get-EndorAttrLabel {
    param([string]$User)
    if ($User) { "$User@$(Get-EndorHostLabel)" }
}

# Find-ConsoleUser [-Problem <ref>]
# Intune scripts run as SYSTEM by default. Detects the logged-in interactive user
# via explorer.exe and resolves their profile path + SID for registry writes.
# Falls back gracefully when running directly as the logged-in user. Returns $null
# when no one is logged in, and puts the reason in -Problem.
function Find-ConsoleUser {
    param([ref]$Problem)
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()

    if (-not $currentIdentity.IsSystem) {
        # Running as the user directly (e.g. testing locally)
        $parts   = $currentIdentity.Name -split '\\'
        $domain  = if ($parts.Count -gt 1) { $parts[0] } else { $env:COMPUTERNAME }
        $username = $parts[-1]
        return [PSCustomObject]@{
            Username    = $username
            Domain      = $domain
            SID         = $currentIdentity.User.Value
            ProfilePath = $env:USERPROFILE
            AppDataPath = $env:APPDATA
        }
    }

    # Running as SYSTEM — detect via explorer.exe owned by the interactive user. Windows setup
    # (OOBE, Autopilot) runs Explorer as defaultuser0, which isn't one.
    $procs = @(Get-CimInstance Win32_Process -Filter "name='explorer.exe'" -ErrorAction SilentlyContinue)
    if (-not $procs) {
        if ($Problem) { $Problem.Value = 'could not detect console user (no explorer.exe). Ensure a user is logged in.' }
        return $null
    }

    $owner = $null
    foreach ($proc in $procs) {
        $candidate = Invoke-CimMethod -InputObject $proc -MethodName 'GetOwner'
        if ($candidate.User -and $candidate.User -notmatch '^defaultuser\d+$') {
            $owner = $candidate
            break
        }
    }
    if (-not $owner) {
        if ($Problem) { $Problem.Value = 'could not determine a user who owns explorer.exe (only Windows setup is signed in, or none). Ensure a user is logged in.' }
        return $null
    }

    $username = $owner.User
    $domain   = $owner.Domain

    # Resolve SID — try domain\user first, fall back to plain username
    $sid = $null
    foreach ($candidate in @("$domain\$username", $username)) {
        try {
            $ntAccount = New-Object System.Security.Principal.NTAccount($candidate)
            $sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
            break
        } catch { }
    }
    if (-not $sid) {
        if ($Problem) { $Problem.Value = "could not resolve SID for user '$domain\$username'." }
        return $null
    }

    $regKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
    $profilePath = (Get-ItemProperty $regKey -ErrorAction Stop).ProfileImagePath
    $appDataPath = Join-Path $profilePath 'AppData\Roaming'

    [PSCustomObject]@{
        Username    = $username
        Domain      = $domain
        SID         = $sid
        ProfilePath = $profilePath
        AppDataPath = $appDataPath
    }
}
