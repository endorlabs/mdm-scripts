# lib/attribution.ps1
# User attribution: the label every generated script attributes to, and what VS Code needs to put
# it into its gallery URL. generate.ps1 inlines this file into every script, before lib/common.ps1,
# and into the worker endor-vscode.ps1 installs, which carries this file alone, so the worker labels
# users as every script does. Do NOT source this file directly — it is embedded at generation time.
# The worker is a single-quoted here-string, so no line here can start with '@.
#
# The firewall decodes the label from the Basic-auth username, auths with the real API key, and logs
# it as "User". Unverified telemetry only — never an authz signal.
#
# Functions:
#   Get-EndorAttrLabel    <user>             — the label: <user>@<machine>
#   Get-EndorAttrUsername <label> <apiKeyId> — the attributed Basic-auth username
#   Find-ConsoleUser                         — finds the logged-in user when running as SYSTEM;
#                                              $null when no one is logged in
#   Get-EndorVscodeLabel  <kept-file> [-KeptOnly]
#                                            — VS Code's label: the logged-in user's, or the kept one
#   Save-EndorVscodeLabel <kept-file> <label> — keeps VS Code's label beside a method's state
#   Get-EndorVscodeUrl    <url> <label>      — VS Code's gallery URL with the label in its token
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
# The label every ecosystem attributes to, VS Code included: <user>@<machine>. Nothing with no
# user, when no one is logged in. To label users another way (by email, or by looking the machine
# up), change only this function before generating. Anything it calls must be in this file too,
# because the worker endor-vscode.ps1 installs carries only this file.
function Get-EndorAttrLabel {
    param([string]$User)
    if ($User) { "$User@$(Get-EndorHostLabel)" }
}

# ── VS Code's user attribution (endor-vscode.ps1, and its worker) ──────────────
# VS Code's gallery URL is machine-wide, so it carries the label of the user logged in now and,
# while no one is, the label kept beside each method's state.

# Get-EndorVscodeLabel <kept-file> [-KeptOnly]: the label of the user logged in now. With no one
# logged in, or with -KeptOnly, the first line of <kept-file>, unless Get-EndorAttrLabel gives one
# without a user. Nothing with none, or with one that has control characters, and when someone is
# logged in whose label fails. With no <kept-file>, only the user logged in now.
function Get-EndorVscodeLabel {
    param([string]$Path, [switch]$KeptOnly)
    $label = $null
    if (-not $KeptOnly) {
        $user = $null
        try { $user = [string](Find-ConsoleUser -NameOnly).Username } catch { }
        try { $label = Get-EndorAttrLabel $user } catch { }
        if ($label -isnot [string] -or $label -cmatch '[\x00-\x1f\x7f]') { $label = $null }
        # Someone is logged in whose label failed: the kept one may be another user's.
        if ($user -and -not $label) { return }
    }
    if (-not $label -and $Path) {
        try {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $label = ([IO.File]::ReadAllText($Path) -split '\r?\n', 2)[0]
            }
        } catch {
        }
    }
    if ($label -is [string] -and $label -cnotmatch '^$|[\x00-\x1f\x7f]') { $label }
}

# Save-EndorVscodeLabel <kept-file> <label>: keeps the label when it changed, if the file's folder, a
# method's state, exists. It never creates the folder, which endor-vscode.ps1 restricts to SYSTEM
# and Administrators.
function Save-EndorVscodeLabel {
    param([string]$Path, [string]$Label)
    $temp = "$Path.$PID.tmp"
    try {
        if ((Test-Path -LiteralPath $Path -PathType Leaf) -and [IO.File]::ReadAllText($Path) -ceq $Label) { return }
        [IO.File]::WriteAllText($temp, $Label, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

# Get-EndorVscodeUrl <url> <label>: VS Code's gallery URL with the label in its token, or nothing.
# The token is base64url(<key ID>:<secret>); the key ID becomes the attributed username, as in the
# other ecosystems' credentials, and the firewall decodes it.
function Get-EndorVscodeUrl {
    param([string]$Url, [string]$Label)
    $at = $Url.LastIndexOf('/_ak/')
    if ($at -lt 0) { return }
    $token = $Url.Substring($at + 5)
    if (-not $token -or $token.Contains('/')) { return }
    $token = $token.Replace('-', '+').Replace('_', '/')
    $token += '=' * ((4 - $token.Length % 4) % 4)
    try { $pair = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($token)) } catch { return }
    $colon = $pair.IndexOf(':')
    if ($colon -lt 1 -or $colon -eq $pair.Length - 1) { return }
    $user = Get-EndorAttrUsername -Label $Label -ApiKeyId $pair.Substring(0, $colon)
    $Url.Substring(0, $at + 5) + [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes("${user}:$($pair.Substring($colon + 1))")
    ).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# Find-ConsoleUser [-Problem <ref>] [-NameOnly]
# Intune scripts run as SYSTEM by default. Detects the logged-in interactive user
# via explorer.exe and resolves their profile path + SID for registry writes.
# Falls back gracefully when running directly as the logged-in user. Returns $null
# when no one is logged in, and puts the reason in -Problem.
# With -NameOnly, only Username and Domain, without the SID and profile lookups.
function Find-ConsoleUser {
    param([ref]$Problem, [switch]$NameOnly)
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
    # Enough for a label; the SID and profile lookups below can be slow, or fail during a first sign-in.
    if ($NameOnly) { return [PSCustomObject]@{ Username = $username; Domain = $domain } }

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
