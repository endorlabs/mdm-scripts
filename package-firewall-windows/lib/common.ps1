# lib/common.ps1
# Shared runtime functions inlined into every generated MDM script by generate.ps1.
# Do NOT source this file directly — it is embedded at generation time.
#
# Functions:
#   Get-ConsoleUser                              — finds the logged-in user when running as SYSTEM
#   Set-UserEnvVar        <name> <value> <sid>   — writes persistent HKCU env var via user SID
#   Remove-UserEnvVar     <name> <sid>           — removes HKCU env var
#   Set-FileRestrictedAcl <path> <username>      — restricts file to owner only
#   Invoke-UpsertBlock    <path> <content> ...   — idempotent sentinel-block writer
#   Invoke-RemoveBlock    <path> ...             — strips Endor sentinel block from a file
#   Test-KeyConflict      <path> <pattern> <label> — warns when a key exists outside an Endor block

# ╔══════════════════════════════════════════════════════════════════════╗
# ║  SENTINEL CONTRACT — DO NOT CHANGE THESE STRINGS                    ║
# ║  Changing them orphans all existing deployments. Machines that       ║
# ║  received a prior script will have an undetected block that the new  ║
# ║  script cannot find or remove, causing duplicate config on re-run.   ║
# ║  These strings are shared with the macOS bash version.               ║
# ╚══════════════════════════════════════════════════════════════════════╝
$ENDOR_BLOCK_START = '# ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) ====='
$ENDOR_BLOCK_END   = '# ===== END ENDOR PACKAGE FIREWALL ====='

# Get-ConsoleUser
# Intune scripts run as SYSTEM by default. Detects the logged-in interactive user
# via explorer.exe and resolves their profile path + SID for registry writes.
# Falls back gracefully when running directly as the logged-in user.
function Get-ConsoleUser {
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

    # Running as SYSTEM — detect via explorer.exe owned by the interactive user
    $proc = Get-CimInstance Win32_Process -Filter "name='explorer.exe'" -ErrorAction SilentlyContinue |
            Select-Object -First 1

    if (-not $proc) {
        Write-Error '[endor] ERROR: could not detect console user (no explorer.exe). Ensure a user is logged in.'
        exit 1
    }

    $owner = Invoke-CimMethod -InputObject $proc -MethodName 'GetOwner'
    if (-not $owner.User) {
        Write-Error '[endor] ERROR: could not determine owner of explorer.exe.'
        exit 1
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
        Write-Error "[endor] ERROR: could not resolve SID for user '$domain\$username'."
        exit 1
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

# Set-UserEnvVar <name> <value> <usersid>
# Writes a persistent user-level environment variable into HKCU:\Environment
# via the SID-keyed registry path, which works whether running as SYSTEM or the user.
function Set-UserEnvVar {
    param([string]$Name, [string]$Value, [string]$UserSID)
    $regPath = "Registry::HKEY_USERS\$UserSID\Environment"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name $Name -Value $Value -Type String
}

# Remove-UserEnvVar <name> <usersid>
function Remove-UserEnvVar {
    param([string]$Name, [string]$UserSID)
    $regPath = "Registry::HKEY_USERS\$UserSID\Environment"
    if (Test-Path $regPath) {
        Remove-ItemProperty -Path $regPath -Name $Name -ErrorAction SilentlyContinue
    }
}

# Set-FileRestrictedAcl <path> <username>
# Disables ACL inheritance and grants Full Control to the owner only.
function Set-FileRestrictedAcl {
    param([string]$FilePath, [string]$Username)
    try {
        $acl = Get-Acl $FilePath
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $Username, 'FullControl', 'Allow'
        )
        $acl.SetAccessRule($rule)
        Set-Acl -Path $FilePath -AclObject $acl
    } catch {
        Write-Warning "[endor] Could not set restrictive permissions on $FilePath : $_"
    }
}

# Invoke-UpsertBlock <filepath> <content> <username> [-DryRun]
#
# Non-destructive, idempotent config writer using sentinel blocks.
#   - File absent            -> creates it with the Endor block
#   - File present, no block -> appends the block; existing content untouched
#   - File present, block found -> replaces only the block; rest untouched
#   - -DryRun                -> prints what would happen, writes nothing
function Invoke-UpsertBlock {
    param(
        [string]$FilePath,
        [string]$Content,
        [string]$Username,
        [switch]$DryRun
    )

    $dir        = Split-Path $FilePath -Parent
    $fileExists = Test-Path $FilePath
    $raw        = if ($fileExists) { Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } else { '' }
    $hasBlock   = $raw -match [regex]::Escape($ENDOR_BLOCK_START)

    if ($DryRun) {
        if ($hasBlock) {
            Write-Host '[dry-run]   action : REPLACE existing Endor block'
        } elseif ($fileExists) {
            Write-Host '[dry-run]   action : APPEND Endor block to existing file'
        } else {
            Write-Host '[dry-run]   action : CREATE file with Endor block'
        }
        Write-Host "[dry-run]   file   : $FilePath"
        Write-Host '[dry-run]   content:'
        $Content -split "`n" | ForEach-Object { Write-Host "[dry-run]     $_" }
        Write-Host ''
        return
    }

    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Strip existing Endor block, preserve everything else
    if ($hasBlock) {
        $lines    = Get-Content $FilePath -Encoding UTF8
        $inBlock  = $false
        $newLines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $lines) {
            if ($line -eq $ENDOR_BLOCK_START) { $inBlock = $true;  continue }
            if ($line -eq $ENDOR_BLOCK_END)   { $inBlock = $false; continue }
            if (-not $inBlock) { $newLines.Add($line) }
        }
        Set-Content -Path $FilePath -Value $newLines -Encoding UTF8
    }

    # Append block (leading newline keeps it visually separated from prior content)
    $block = "`n$ENDOR_BLOCK_START`n$Content`n$ENDOR_BLOCK_END"
    Add-Content -Path $FilePath -Value $block -Encoding UTF8 -NoNewline

    Set-FileRestrictedAcl -FilePath $FilePath -Username $Username
}

# Invoke-RemoveBlock <filepath> [-DryRun]
#
# Strips the Endor sentinel block from a config file.
#   - File absent           -> skips silently
#   - No Endor block found  -> skips with a notice
#   - Block found           -> removes block; preserves everything else
#   - File empty after removal -> deletes the file entirely
function Invoke-RemoveBlock {
    param([string]$FilePath, [switch]$DryRun)

    if (-not (Test-Path $FilePath)) {
        Write-Host "[endor-remove] skip (not found)    : $FilePath"
        return
    }

    $raw = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not ($raw -match [regex]::Escape($ENDOR_BLOCK_START))) {
        Write-Host "[endor-remove] skip (no Endor block): $FilePath"
        return
    }

    $lines    = Get-Content $FilePath -Encoding UTF8
    $inBlock  = $false
    $newLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line -eq $ENDOR_BLOCK_START) { $inBlock = $true;  continue }
        if ($line -eq $ENDOR_BLOCK_END)   { $inBlock = $false; continue }
        if (-not $inBlock) { $newLines.Add($line) }
    }

    $remaining = ($newLines -join '') -replace '\s', ''

    if ($DryRun) {
        if (-not $remaining) {
            Write-Host '[dry-run]   action : REMOVE block -> file would be empty -> DELETE file'
        } else {
            Write-Host '[dry-run]   action : REMOVE block, preserve remaining content'
        }
        Write-Host "[dry-run]   file   : $FilePath"
        Write-Host ''
        return
    }

    if (-not $remaining) {
        Remove-Item $FilePath -Force
        Write-Host "[endor-remove] deleted (was empty) : $FilePath"
    } else {
        Set-Content -Path $FilePath -Value $newLines -Encoding UTF8
        Write-Host "[endor-remove] block removed       : $FilePath"
    }
}

# Test-KeyConflict <filepath> <regex-pattern> <label>
# Warns when <pattern> matches a line in <file> outside an Endor-managed block.
# Helps IT admins catch precedence conflicts before they cause a broken environment.
function Test-KeyConflict {
    param([string]$FilePath, [string]$Pattern, [string]$Label)

    if (-not (Test-Path $FilePath)) { return }
    $raw = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($raw -match [regex]::Escape($ENDOR_BLOCK_START)) { return }  # already managed

    if (Get-Content $FilePath -Encoding UTF8 | Where-Object { $_ -match $Pattern }) {
        Write-Warning "[endor] WARNING: existing '$Label' found in $FilePath."
        Write-Warning "[endor]          Endor block will be appended -- verify key precedence with your tool."
    }
}
