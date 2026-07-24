# lib/common.ps1
# Shared runtime functions inlined into every generated MDM script by generate.ps1.
# Do NOT source this file directly — it is embedded at generation time.
#
# Functions:
#   Get-ConsoleUser                              — finds the logged-in user when running as SYSTEM
#   Set-UserEnvVar        <name> <value> <sid>   — writes persistent HKCU env var via user SID
#   Remove-UserEnvVar     <name> <sid>           — removes HKCU env var
#   Set-FileRestrictedAcl <path> <username>      — restricts file to owner only
#   Invoke-UpsertBlock    <path> <content> ...   — idempotent sentinel-block writer;
#                                                  delegates to Invoke-UpsertBlockPip when
#                                                  <content> has [global]
#   Invoke-UpsertBlockPip <path> <content> ...   — pip.ini writer; merges into an existing
#                                                  [global] (conflicting keys disabled with
#                                                  '#endor-bak#') when both content and file
#                                                  declare [global]
#   Invoke-RemoveBlock    <path> ...             — strips Endor sentinel block from a file
#   Invoke-UpsertXmlBlock <path> <content> ...   — XML-aware writer for Maven settings.xml
#   Remove-XmlBlock       <path> ...             — strips Endor XML block from settings.xml
#   Test-KeyConflict      <path> <pattern> <label> — warns when a key exists outside an Endor block
#   Test-XmlKeyConflict   <path> <pattern> <label> — same, but for XML-comment-delimited blocks

# ╔══════════════════════════════════════════════════════════════════════╗
# ║  SENTINEL CONTRACT — DO NOT CHANGE THESE STRINGS                    ║
# ║  Changing them orphans all existing deployments. Machines that       ║
# ║  received a prior script will have an undetected block that the new  ║
# ║  script cannot find or remove, causing duplicate config on re-run.   ║
# ║  These strings are shared with the macOS bash version.               ║
# ╚══════════════════════════════════════════════════════════════════════╝
$ENDOR_BLOCK_START = '# ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) ====='
$ENDOR_BLOCK_END   = '# ===== END ENDOR PACKAGE FIREWALL ====='

# XML sentinel markers — used for settings.xml (Maven), which cannot use '#' comments.
# These MUST match the BEGIN/END lines in shared/blocks/mavensettings.txt exactly,
# and the bash ENDOR_XML_BLOCK_* markers, or re-runs and removal cannot find the block.
$ENDOR_XML_BLOCK_START = '<!-- ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) ===== -->'
$ENDOR_XML_BLOCK_END   = '<!-- ===== END ENDOR PACKAGE FIREWALL ===== -->'

# Per-entry sentinel markers wrapping our <server> and <mirror>. They live in the
# shared fragment (shared/blocks/mavensettings.txt) and are what let each entry be
# merged into whichever <servers>/<mirrors> container already exists — Maven's
# schema forbids a second container. These MUST match that fragment and the bash
# ENDOR_XML_SERVER_*/MIRROR_* markers byte-for-byte. The legacy $ENDOR_XML_BLOCK_*
# pair above is still recognised on strip/remove so files written by older versions
# are cleaned up correctly.
$ENDOR_XML_SERVER_START = '<!-- ===== BEGIN ENDOR PACKAGE FIREWALL server (managed — do not edit) ===== -->'
$ENDOR_XML_SERVER_END   = '<!-- ===== END ENDOR PACKAGE FIREWALL server ===== -->'
$ENDOR_XML_MIRROR_START = '<!-- ===== BEGIN ENDOR PACKAGE FIREWALL mirror (managed — do not edit) ===== -->'
$ENDOR_XML_MIRROR_END   = '<!-- ===== END ENDOR PACKAGE FIREWALL mirror ===== -->'

# ── User attribution helpers ──────────────────────────────────────────────────
# Encode <console-user>@<machine> into the Basic-auth username. The firewall
# decodes the label, auths with the real API key, and logs it as "User".
# Unverified telemetry only — never an authz signal.

# Get-EndorAttrUsername <label> <apiKeyId>
# Returns base64(base64("userattr:"+label)+":"+keyId) — the format
# decodeAttributedUsername() expects in endorfactory's auth layer.
function Get-EndorAttrUsername {
    param([string]$Label, [string]$ApiKeyId)
    $inner = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("userattr:$Label"))
    [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${inner}:${ApiKeyId}"))
}

# Get-EndorUrlEncB64 <b64> — percent-encode base64 chars (+ / =) for URL userinfo.
function Get-EndorUrlEncB64 {
    param([string]$B64)
    $B64.Replace('+', '%2B').Replace('/', '%2F').Replace('=', '%3D')
}

# Get-EndorHostLabel — a stable, human-readable machine name for attribution.
function Get-EndorHostLabel {
    if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
}

# Write-EndorFile <path> <lines>
# UTF-8 WITHOUT BOM. Windows PowerShell 5.1's `-Encoding UTF8` writes a BOM,
# which pip's configparser rejects — pip.ini would be silently ignored.
function Write-EndorFile {
    param([string]$FilePath, [string[]]$Lines)
    $text = ($Lines -join [System.Environment]::NewLine) + [System.Environment]::NewLine
    [System.IO.File]::WriteAllText($FilePath, $text, [System.Text.UTF8Encoding]::new($false))
}

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
#
# Delegates to Invoke-UpsertBlockPip when <content> carries a [global] header (pip.ini).
function Invoke-UpsertBlock {
    param(
        [string]$FilePath,
        [string]$Content,
        [string]$Username,
        [switch]$DryRun
    )

    $Content = $Content.Replace("`r", '')
    if (($Content -split "`n") -contains '[global]') {
        Invoke-UpsertBlockPip @PSBoundParameters
        return
    }

    $contentLines = $Content -split "`n"
    $dir          = Split-Path $FilePath -Parent
    $fileExists   = Test-Path $FilePath
    $hasBlock     = $false
    if ($fileExists) {
        $raw = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        $hasBlock = $raw -match [regex]::Escape($ENDOR_BLOCK_START)
    }

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
        $contentLines | ForEach-Object { Write-Host "[dry-run]     $_" }
        Write-Host ''
        return
    }

    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $outside = [System.Collections.Generic.List[string]]::new()
    if ($fileExists) {
        $inBlock = $false
        foreach ($line in @(Get-Content $FilePath -Encoding UTF8)) {
            if ($line -eq $ENDOR_BLOCK_START) { $inBlock = $true;  continue }
            if ($line -eq $ENDOR_BLOCK_END)   { $inBlock = $false; continue }
            if (-not $inBlock) { $outside.Add($line) }
        }
    }

    $final = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $outside) { $final.Add($line) }
    $final.Add('')
    $final.Add($ENDOR_BLOCK_START)
    foreach ($line in $contentLines) { $final.Add($line) }
    $final.Add($ENDOR_BLOCK_END)
    Write-EndorFile -FilePath $FilePath -Lines $final

    Set-FileRestrictedAcl -FilePath $FilePath -Username $Username
}

# Invoke-UpsertBlockPip <filepath> <content> <username> [-DryRun]
#
# pip.ini-aware sentinel-block writer. Identical to Invoke-UpsertBlock except when both
# <content> and the pre-existing file (outside any Endor block) declare [global]:
# pip rejects duplicate [global] sections, so the Endor keys are inserted inside the
# existing section and conflicting keys are disabled reversibly with '#endor-bak#'.
function Invoke-UpsertBlockPip {
    param(
        [string]$FilePath,
        [string]$Content,
        [string]$Username,
        [switch]$DryRun
    )

    $Content      = $Content.Replace("`r", '')
    $contentLines = $Content -split "`n"
    $dir          = Split-Path $FilePath -Parent
    $fileExists   = Test-Path $FilePath
    $raw          = if ($fileExists) { Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } else { '' }
    $hasBlock     = $raw -match [regex]::Escape($ENDOR_BLOCK_START)

    # Existing lines outside the Endor block (block content excluded up front)
    $outside = [System.Collections.Generic.List[string]]::new()
    if ($fileExists) {
        $inBlock = $false
        foreach ($line in @(Get-Content $FilePath -Encoding UTF8)) {
            if ($line -eq $ENDOR_BLOCK_START) { $inBlock = $true;  continue }
            if ($line -eq $ENDOR_BLOCK_END)   { $inBlock = $false; continue }
            if (-not $inBlock) { $outside.Add($line) }
        }
    }

    # Merge only when both the content and the pre-existing file declare [global]
    $merge = ($contentLines -contains '[global]') -and ($outside -contains '[global]')

    if ($DryRun) {
        if ($hasBlock) {
            Write-Host '[dry-run]   action : REPLACE existing Endor block'
        } elseif ($merge) {
            Write-Host '[dry-run]   action : MERGE into existing [global] (conflicting keys disabled via #endor-bak#)'
        } elseif ($fileExists) {
            Write-Host '[dry-run]   action : APPEND Endor block to existing file'
        } else {
            Write-Host '[dry-run]   action : CREATE file with Endor block'
        }
        if ($merge) {
            Write-Host "[dry-run]   note   : pre-existing index keys will be disabled via '#endor-bak#'"
            Write-Host '[dry-run]            and the Endor keys merged into the existing [global]'
        }
        Write-Host "[dry-run]   file   : $FilePath"
        Write-Host '[dry-run]   content:'
        $contentLines | ForEach-Object { Write-Host "[dry-run]     $_" }
        Write-Host ''
        return
    }

    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ($merge) {
        # Disable-keys derived from the content; pip treats '-'/'_' and '='/':' alike.
        $keys = $contentLines | ForEach-Object {
            if ($_ -match '^([A-Za-z0-9_-]+)\s*[=:]') { $Matches[1] }
        }
        $keyPattern = ($keys | ForEach-Object { $_ -replace '[-_]', '[-_]' }) -join '|'

        # 1. Reversibly disable pre-existing copies of those keys and their
        #    indented continuation lines.
        $body     = [System.Collections.Generic.List[string]]::new()
        $cont     = $false
        $disabled = $false
        foreach ($line in $outside) {
            if ($keyPattern -and $line -match "^\s*($keyPattern)\s*[=:]") {
                $body.Add("#endor-bak#$line"); $cont = $true; $disabled = $true; continue
            }
            if ($cont -and $line -match '^\s+\S') {
                $body.Add("#endor-bak#$line"); continue
            }
            $cont = $false
            $body.Add($line)
        }
        if ($disabled) {
            Write-Host "[endor] NOTE: existing pip index keys in $FilePath disabled with '#endor-bak#' (restored on removal)"
        }

        # 2. Insert the sentinel-wrapped keys (minus the [global] header) after
        #    the first [global].
        $keysBlock = @($ENDOR_BLOCK_START) + @($contentLines | Where-Object { $_ -ne '[global]' }) + @($ENDOR_BLOCK_END)
        $final = [System.Collections.Generic.List[string]]::new()
        $done  = $false
        foreach ($line in $body) {
            $final.Add($line)
            if (-not $done -and $line -eq '[global]') {
                foreach ($k in $keysBlock) { $final.Add($k) }
                $done = $true
            }
        }
        Write-EndorFile -FilePath $FilePath -Lines $final
    } else {
        $final = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $outside) { $final.Add($line) }
        $final.Add('')
        $final.Add($ENDOR_BLOCK_START)
        foreach ($line in $contentLines) { $final.Add($line) }
        $final.Add($ENDOR_BLOCK_END)
        Write-EndorFile -FilePath $FilePath -Lines $final
    }

    Set-FileRestrictedAcl -FilePath $FilePath -Username $Username
}

# Invoke-RemoveBlock <filepath> [-DryRun]
#
# Strips the Endor sentinel block and restores '#endor-bak#'-disabled keys.
#   - File absent           -> skips silently
#   - No Endor block found  -> skips with a notice
#   - Block found           -> removes block; preserves everything else
#   - File empty after removal -> deletes it (a bare [global] counts as empty)
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
        if (-not $inBlock) { $newLines.Add(($line -replace '^(\s*)#endor-bak#', '$1')) }
    }

    # Effectively empty = whitespace only, or a bare [global] left from a pip merge
    $remaining = ($newLines -join '') -replace '\s', ''
    $isEmpty   = (-not $remaining) -or ($remaining -eq '[global]')

    if ($DryRun) {
        if ($isEmpty) {
            Write-Host '[dry-run]   action : REMOVE block -> file would be empty -> DELETE file'
        } else {
            Write-Host '[dry-run]   action : REMOVE block, preserve remaining content'
        }
        if ($raw -match '#endor-bak#') {
            Write-Host "[dry-run]   restore: keys disabled with '#endor-bak#'"
        }
        Write-Host "[dry-run]   file   : $FilePath"
        Write-Host ''
        return
    }

    if ($isEmpty) {
        Remove-Item $FilePath -Force
        Write-Host "[endor-remove] deleted (was empty) : $FilePath"
    } else {
        Write-EndorFile -FilePath $FilePath -Lines $newLines
        Write-Host "[endor-remove] block removed       : $FilePath"
    }
}

# ── Maven XML helpers (parity with the bash upsert_xml_block machinery) ────────
# Maven's schema allows at most ONE <servers> and ONE <mirrors> container, so we
# never emit our own wrapper when one already exists — we merge our sentinel-
# delimited <server>/<mirror> entry into it. These helpers operate on line arrays.

# Get-EndorXmlSubBlock <lines[]> <start> <end> -> inclusive marker block (string[])
function Get-EndorXmlSubBlock {
    param([string[]]$Lines, [string]$Start, [string]$End)
    $out  = [System.Collections.Generic.List[string]]::new()
    $grab = $false
    foreach ($line in $Lines) {
        if ($line.Contains($Start)) { $grab = $true }
        if ($grab)                  { $out.Add($line) }
        if ($line.Contains($End))   { $grab = $false }
    }
    return ,$out.ToArray()
}

# Remove-EndorXmlManaged <lines[]> -> lines with every managed region removed
# (new per-entry server/mirror sub-blocks AND the legacy combined block).
function Remove-EndorXmlManaged {
    param([string[]]$Lines)
    $out  = [System.Collections.Generic.List[string]]::new()
    $skip = $false
    foreach ($line in $Lines) {
        if ($line.Contains($ENDOR_XML_SERVER_START) -or $line.Contains($ENDOR_XML_MIRROR_START) -or $line.Contains($ENDOR_XML_BLOCK_START)) { $skip = $true }
        if (-not $skip) { $out.Add($line) }
        if ($line.Contains($ENDOR_XML_SERVER_END)   -or $line.Contains($ENDOR_XML_MIRROR_END)   -or $line.Contains($ENDOR_XML_BLOCK_END))   { $skip = $false }
    }
    return ,$out.ToArray()
}

# Add-EndorIntoContainer <lines[]> <open> <close> <selfclose> <subblock[]>
# Inserts <subblock> as the FIRST child of an existing container (so the Endor
# catch-all mirror wins Maven precedence). Returns the new lines[] on success, or
# $null when the container is absent (caller must create it). Handles the multi-
# line <servers> … </servers> form and the self-closed <servers/> form.
function Add-EndorIntoContainer {
    param([string[]]$Lines, [string]$Open, [string]$Close, [string]$SelfClose, [string[]]$SubBlock)

    $hasOpen = $false; $hasSelf = $false
    foreach ($l in $Lines) {
        if ($l.Contains($Open))      { $hasOpen = $true }
        if ($l.Contains($SelfClose)) { $hasSelf = $true }
    }

    $out  = [System.Collections.Generic.List[string]]::new()
    $done = $false

    if ($hasOpen) {
        foreach ($l in $Lines) {
            if (-not $done) {
                $p = $l.IndexOf($Open)
                if ($p -ge 0) {
                    $out.Add($l.Substring(0, $p + $Open.Length))
                    foreach ($b in $SubBlock) { $out.Add($b) }
                    $rest = $l.Substring($p + $Open.Length)
                    if ($rest -ne '') { $out.Add($rest) }
                    $done = $true
                    continue
                }
            }
            $out.Add($l)
        }
        return ,$out.ToArray()
    }
    elseif ($hasSelf) {
        foreach ($l in $Lines) {
            if (-not $done) {
                $p = $l.IndexOf($SelfClose)
                if ($p -ge 0) {
                    $out.Add($l.Substring(0, $p) + $Open)
                    foreach ($b in $SubBlock) { $out.Add($b) }
                    $out.Add($Close + $l.Substring($p + $SelfClose.Length))
                    $done = $true
                    continue
                }
            }
            $out.Add($l)
        }
        return ,$out.ToArray()
    }
    return $null
}

# Add-EndorOrdered <lines[]> <block[]> <laterTags[]>
# Inserts a newly-created container <block> before the first line containing any
# of <laterTags> (Maven schema order servers→mirrors→profiles→activeProfiles→
# pluginGroups), else before </settings>, keeping the file schema-valid.
function Add-EndorOrdered {
    param([string[]]$Lines, [string[]]$Block, [string[]]$LaterTags)
    $out  = [System.Collections.Generic.List[string]]::new()
    $done = $false
    foreach ($l in $Lines) {
        if (-not $done) {
            foreach ($t in $LaterTags) {
                if ($l.Contains($t)) { foreach ($b in $Block) { $out.Add($b) }; $done = $true; break }
            }
        }
        if (-not $done -and $l.Contains('</settings>')) { foreach ($b in $Block) { $out.Add($b) }; $done = $true }
        $out.Add($l)
    }
    if (-not $done) { foreach ($b in $Block) { $out.Add($b) } }
    return ,$out.ToArray()
}

# Invoke-UpsertXmlBlock <filepath> <content> <username> [-DryRun]
#
# Idempotent, MERGE-AWARE writer for Maven %USERPROFILE%\.m2\settings.xml. The
# fragment carries two sentinel-delimited entries — a <server> and a <mirror>.
# Maven's schema forbids a second <servers>/<mirrors>, so each entry is merged into
# whichever singleton container already exists; a container is created only when it
# is absent.
#   - File absent              -> create a minimal settings.xml with both containers
#   - <servers> present        -> insert our <server> as its first child
#   - <servers> absent         -> create <servers> (in schema order) wrapping our entry
#   - <mirrors> present/absent -> same treatment for our <mirror>
#   - Re-run                   -> prior managed entries (new or legacy) stripped first
#   - -DryRun                  -> prints what would happen, writes nothing
function Invoke-UpsertXmlBlock {
    param(
        [string]$FilePath,
        [string]$Content,
        [string]$Username,
        [switch]$DryRun
    )

    # Split the fragment into its two independently-sentineled managed entries.
    $fragLines = $Content -split "`r?`n"
    $serverBlk = Get-EndorXmlSubBlock -Lines $fragLines -Start $ENDOR_XML_SERVER_START -End $ENDOR_XML_SERVER_END
    $mirrorBlk = Get-EndorXmlSubBlock -Lines $fragLines -Start $ENDOR_XML_MIRROR_START -End $ENDOR_XML_MIRROR_END

    $dir        = Split-Path $FilePath -Parent
    $fileExists = Test-Path $FilePath

    if ($DryRun) {
        if (-not $fileExists) {
            Write-Host '[dry-run]   action : CREATE settings.xml with <servers> + <mirrors>'
        } else {
            $raw = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($raw -match '<servers>') { Write-Host '[dry-run]   action : MERGE <server> into existing <servers>' }
            else                         { Write-Host '[dry-run]   action : CREATE <servers> with Endor <server>' }
            if ($raw -match '<mirrors>') { Write-Host '[dry-run]   action : MERGE <mirror> into existing <mirrors> (inserted first)' }
            else                         { Write-Host '[dry-run]   action : CREATE <mirrors> with Endor <mirror>' }
        }
        Write-Host "[dry-run]   file   : $FilePath"
        $Content -split "`n" | ForEach-Object { Write-Host "[dry-run]     $_" }
        Write-Host ''
        return
    }

    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Case 1: file absent -> minimal settings.xml with both containers, in order.
    if (-not $fileExists) {
        $scaffold = [System.Collections.Generic.List[string]]::new()
        $scaffold.Add('<?xml version="1.0" encoding="UTF-8"?>')
        $scaffold.Add('<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"')
        $scaffold.Add('          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"')
        $scaffold.Add('          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.2.0 http://maven.apache.org/xsd/settings-1.2.0.xsd">')
        $scaffold.Add('  <servers>'); foreach ($b in $serverBlk) { $scaffold.Add($b) }; $scaffold.Add('  </servers>')
        $scaffold.Add('  <mirrors>'); foreach ($b in $mirrorBlk) { $scaffold.Add($b) }; $scaffold.Add('  </mirrors>')
        $scaffold.Add('</settings>')
        Write-EndorFile -FilePath $FilePath -Lines $scaffold.ToArray()
        Set-FileRestrictedAcl -FilePath $FilePath -Username $Username
        return
    }

    # Case 2: strip any prior managed entries so re-runs stay idempotent.
    $lines = @(Get-Content $FilePath -Encoding UTF8)
    $lines = Remove-EndorXmlManaged -Lines $lines

    # Case 3a: merge the <server> entry (create <servers> only if absent).
    $merged = Add-EndorIntoContainer -Lines $lines -Open '<servers>' -Close '</servers>' -SelfClose '<servers/>' -SubBlock $serverBlk
    if ($null -ne $merged) {
        $lines = $merged
    } else {
        $container = [System.Collections.Generic.List[string]]::new()
        $container.Add('  <servers>'); foreach ($b in $serverBlk) { $container.Add($b) }; $container.Add('  </servers>')
        $lines = Add-EndorOrdered -Lines $lines -Block $container.ToArray() -LaterTags @('<mirrors', '<profiles', '<activeProfiles', '<pluginGroups')
    }

    # Case 3b: merge the <mirror> entry (create <mirrors> only if absent).
    $merged = Add-EndorIntoContainer -Lines $lines -Open '<mirrors>' -Close '</mirrors>' -SelfClose '<mirrors/>' -SubBlock $mirrorBlk
    if ($null -ne $merged) {
        $lines = $merged
    } else {
        $container = [System.Collections.Generic.List[string]]::new()
        $container.Add('  <mirrors>'); foreach ($b in $mirrorBlk) { $container.Add($b) }; $container.Add('  </mirrors>')
        $lines = Add-EndorOrdered -Lines $lines -Block $container.ToArray() -LaterTags @('<profiles', '<activeProfiles', '<pluginGroups')
    }

    Write-EndorFile -FilePath $FilePath -Lines $lines
    Set-FileRestrictedAcl -FilePath $FilePath -Username $Username
}

# Remove-XmlBlock <filepath> [-DryRun]
#
# Strips the Endor managed entries (new per-entry server/mirror sub-blocks AND the
# legacy combined block) from settings.xml. Any pre-existing <server>/<mirror> the
# user had is preserved. If nothing but empty scaffolding remains, the file is
# deleted. An emptied <servers></servers>/<mirrors></mirrors> we may have created
# is harmless (valid, no-op) and is left in place when other content survives.
function Remove-XmlBlock {
    param([string]$FilePath, [switch]$DryRun)

    if (-not (Test-Path $FilePath)) {
        Write-Host "[endor-remove] skip (not found)    : $FilePath"
        return
    }
    $raw = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not ($raw -match [regex]::Escape($ENDOR_XML_SERVER_START) `
          -or $raw -match [regex]::Escape($ENDOR_XML_MIRROR_START) `
          -or $raw -match [regex]::Escape($ENDOR_XML_BLOCK_START))) {
        Write-Host "[endor-remove] skip (no Endor block): $FilePath"
        return
    }

    if ($DryRun) {
        Write-Host '[dry-run]   action : REMOVE Endor <server>/<mirror> from settings.xml'
        Write-Host "[dry-run]   file   : $FilePath"
        Write-Host ''
        return
    }

    $lines = @(Get-Content $FilePath -Encoding UTF8)
    $kept  = Remove-EndorXmlManaged -Lines $lines

    # Delete only if no real child entry survives. The regex matches the SINGULAR
    # child tags (a following '>' or space) but not the plural containers, so an
    # emptied <servers></servers> does not count as content.
    $hasContent = ($kept -join "`n") -match '<(server|mirror|profile|proxy|pluginGroup|repository|activeProfile|localRepository)[ >]'
    if (-not $hasContent) {
        Remove-Item $FilePath -Force
        Write-Host "[endor-remove] deleted (was empty) : $FilePath"
    } else {
        Write-EndorFile -FilePath $FilePath -Lines $kept
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
        $script:EndorWarned = $true
    }
}

# Test-XmlKeyConflict <filepath> <regex-pattern> <label>
# Warns when <pattern> matches a line in <file> outside an Endor-managed XML block.
# Unlike Test-KeyConflict, scans only lines outside ENDOR_XML_BLOCK_START/END
# so re-runs on an already-managed settings.xml do not false-positive.
function Test-XmlKeyConflict {
    param([string]$FilePath, [string]$Pattern, [string]$Label)

    if (-not (Test-Path $FilePath)) { return }

    $inBlock = $false
    $found   = $false
    foreach ($line in @(Get-Content $FilePath -Encoding UTF8)) {
        if ($line -match [regex]::Escape($ENDOR_XML_BLOCK_START)) { $inBlock = $true;  continue }
        if ($line -match [regex]::Escape($ENDOR_XML_BLOCK_END))   { $inBlock = $false; continue }
        if (-not $inBlock -and $line -match $Pattern) { $found = $true; break }
    }

    if ($found) {
        Write-Warning "[endor] WARNING: existing '$Label' found in $FilePath."
        Write-Warning "[endor]          Endor block will be inserted -- verify key precedence with your tool."
        $script:EndorWarned = $true
    }
}

# Test-XmlForeignMirror <filepath> -> $true when a <mirror> exists OUTSIDE any
# Endor-managed region (new server/mirror sub-blocks or the legacy block). A user's
# catch-all mirror ahead of ours would bypass the firewall, so this is a genuine
# precedence conflict worth warning about. Endor's own mirror is NOT foreign, so
# re-runs on an already-managed settings.xml do not false-positive (parity with
# bash xml_has_foreign_mirror).
function Test-XmlForeignMirror {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) { return $false }

    $skip  = $false
    $found = $false
    foreach ($line in @(Get-Content $FilePath -Encoding UTF8)) {
        if ($line.Contains($ENDOR_XML_SERVER_START) -or $line.Contains($ENDOR_XML_MIRROR_START) -or $line.Contains($ENDOR_XML_BLOCK_START)) { $skip = $true }
        if (-not $skip -and $line -match '<mirror[ >]') { $found = $true }
        if ($line.Contains($ENDOR_XML_SERVER_END)   -or $line.Contains($ENDOR_XML_MIRROR_END)   -or $line.Contains($ENDOR_XML_BLOCK_END))   { $skip = $false }
    }
    return $found
}
