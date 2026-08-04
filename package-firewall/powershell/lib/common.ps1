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
#
# VS Code (product.json) — see the "VS Code" section at the bottom of this file:
#   Get-EndorB64Url / Get-EndorB64Decode         — base64url encode / decode
#   *-Json*                                       — depth-1 JSON editors that preserve layout
#   Get-VSCodeInstallPath / Get-VSCodeManagedState / Invoke-VSCodePatch / Invoke-VSCodeUnpatch
#   Install-VSCodeWatcher / Uninstall-VSCodeWatcher

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

# ╔══════════════════════════════════════════════════════════════════════╗
# ║  SENTINEL CONTRACT (continued) — the JSON marker key                 ║
# ║  product.json cannot carry a '#' comment, so the managed marker is a  ║
# ║  top-level JSON key. It is also the ONLY record of the original       ║
# ║  extensionsGallery, so changing this string makes every deployed      ║
# ║  machine unrestorable. Shared with the bash ENDOR_JSON_MARKER_KEY.    ║
# ╚══════════════════════════════════════════════════════════════════════╝
$ENDOR_JSON_MARKER_KEY = '_endorPackageFirewall'

# Scheduled Task identity for the product.json re-apply watcher.
$ENDOR_VSCODE_TASK_PATH = '\Endor\'
$ENDOR_VSCODE_TASK_NAME = 'PackageFirewall-VSCode'

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

# Get-EndorB64Url <text> — base64url. Used for the VS Code gallery URL, where the
# credential is a path segment rather than userinfo, so '+' and '/' must be
# substituted rather than percent-encoded. Padding is stripped; the firewall
# applies strings.TrimRight(token, "=") anyway.
function Get-EndorB64Url {
    param([string]$Text)
    $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
    $b64.Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

# Get-EndorB64Decode <b64> — decode to a UTF-8 string.
function Get-EndorB64Decode {
    param([string]$B64)
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($B64))
}

# Get-EndorVSCodeToken <attrUser> <secret>
# Same attributed username as every other ecosystem; the firewall runs
# applyUserAttribution after resolving the _ak path token.
function Get-EndorVSCodeToken {
    param([string]$AttrUser, [string]$Secret)
    Get-EndorB64Url "${AttrUser}:${Secret}"
}

# Get-EndorRedactAk <text> — replace the _ak/<token> path segment.
# A deliberate deviation from the other ecosystems, which echo full credentialed
# URLs in -DryRun: this token is a bearer credential in a URL *path*, and MDM
# consoles retain script output for far more people than can read the target file.
function Get-EndorRedactAk {
    param([string]$Text)
    [System.Text.RegularExpressions.Regex]::Replace($Text, '/_ak/[A-Za-z0-9_-]*', '/_ak/<redacted>')
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

# Invoke-UpsertXmlBlock <filepath> <content> <username> [-DryRun]
#
# Idempotent writer for an XML settings file (Maven %USERPROFILE%\.m2\settings.xml).
# The generic Invoke-UpsertBlock appends to EOF, which for XML would land after
# </settings> and produce invalid XML — so Maven needs this XML-aware variant.
#   - File absent             -> create a minimal settings.xml wrapping the fragment
#   - File present, has block  -> replace only the delimited fragment
#   - File present, no block   -> insert fragment just before </settings>
#   - -DryRun                 -> prints what would happen, writes nothing
# The fragment carries its own XML-comment sentinels (from mavensettings.txt), so
# this helper detects/strips by the marker strings rather than adding them itself.
function Invoke-UpsertXmlBlock {
    param(
        [string]$FilePath,
        [string]$Content,
        [string]$Username,
        [switch]$DryRun
    )

    $dir        = Split-Path $FilePath -Parent
    $fileExists = Test-Path $FilePath
    $raw        = if ($fileExists) { Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } else { '' }
    $hasBlock   = $raw -match [regex]::Escape($ENDOR_XML_BLOCK_START)

    if ($DryRun) {
        if ($hasBlock) {
            Write-Host '[dry-run]   action : REPLACE Endor block in settings.xml'
        } elseif ($fileExists) {
            Write-Host '[dry-run]   action : INSERT Endor block before </settings>'
        } else {
            Write-Host '[dry-run]   action : CREATE settings.xml with Endor block'
        }
        Write-Host "[dry-run]   file   : $FilePath"
        $Content -split "`n" | ForEach-Object { Write-Host "[dry-run]     $_" }
        Write-Host ''
        return
    }

    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Case 1: file absent -> write a complete minimal settings.xml
    if (-not $fileExists) {
        $scaffold = @(
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"'
            '          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
            '          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.2.0 http://maven.apache.org/xsd/settings-1.2.0.xsd">'
            $Content
            '</settings>'
        )
        Write-EndorFile -FilePath $FilePath -Lines $scaffold
        Set-FileRestrictedAcl -FilePath $FilePath -Username $Username
        return
    }

    # Case 2: existing Endor block -> strip it (between and including the markers)
    $lines = @(Get-Content $FilePath -Encoding UTF8)
    if ($hasBlock) {
        $inBlock = $false
        $kept    = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $lines) {
            if ($line -match [regex]::Escape($ENDOR_XML_BLOCK_START)) { $inBlock = $true;  continue }
            if ($line -match [regex]::Escape($ENDOR_XML_BLOCK_END))   { $inBlock = $false; continue }
            if (-not $inBlock) { $kept.Add($line) }
        }
        $lines = $kept.ToArray()
    }

    # Case 3: insert the fresh fragment immediately before the first </settings>
    $out      = [System.Collections.Generic.List[string]]::new()
    $inserted = $false
    foreach ($line in $lines) {
        if (-not $inserted -and $line -match '</settings>') {
            $out.Add($Content)
            $inserted = $true
        }
        $out.Add($line)
    }
    if (-not $inserted) { $out.Add($Content) }  # no closing tag found — append so it isn't lost

    Write-EndorFile -FilePath $FilePath -Lines $out
    Set-FileRestrictedAcl -FilePath $FilePath -Username $Username
}

# Remove-XmlBlock <filepath> [-DryRun]
#
# Strips the Endor XML fragment from settings.xml. If the file is left with only
# the empty <settings> scaffold (i.e. it was Endor-only), the whole file is deleted.
function Remove-XmlBlock {
    param([string]$FilePath, [switch]$DryRun)

    if (-not (Test-Path $FilePath)) {
        Write-Host "[endor-remove] skip (not found)    : $FilePath"
        return
    }
    $raw = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not ($raw -match [regex]::Escape($ENDOR_XML_BLOCK_START))) {
        Write-Host "[endor-remove] skip (no Endor block): $FilePath"
        return
    }

    if ($DryRun) {
        Write-Host '[dry-run]   action : REMOVE Endor block from settings.xml'
        Write-Host "[dry-run]   file   : $FilePath"
        Write-Host ''
        return
    }

    $lines   = @(Get-Content $FilePath -Encoding UTF8)
    $inBlock = $false
    $kept    = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line -match [regex]::Escape($ENDOR_XML_BLOCK_START)) { $inBlock = $true;  continue }
        if ($line -match [regex]::Escape($ENDOR_XML_BLOCK_END))   { $inBlock = $false; continue }
        if (-not $inBlock) { $kept.Add($line) }
    }

    # If only the empty XML scaffold remains (no real Maven elements), delete the file
    $hasContent = ($kept -join "`n") -match '<(server|mirror|profile|proxy|pluginGroup|repository)'
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


# ══════════════════════════════════════════════════════════════════════════════
# VS Code
#
# VS Code reads its extension gallery endpoints from product.json in the install
# directory. Unlike every other ecosystem here the target file is owned and
# rewritten by a third party (VS Code's own updater), and it is JSON, so it can
# carry neither an Endor sentinel comment nor an %ENDOR_*% reference.
#
# Hence: a key-level merge into the depth-1 "extensionsGallery" object, a
# top-level JSON marker key holding the byte-exact original for restore, and a
# Scheduled Task to re-apply after updates.
#
# The editors below are line-oriented rather than using ConvertTo-Json on
# purpose. ConvertTo-Json would reformat all 2962 lines, reorder nothing but
# re-indent everything, needs -Depth raised on 5.1 (default 2 silently truncates),
# and escapes forward slashes — turning a two-line change into a whole-file
# rewrite that no reviewer can diff. Shipped product.json is pretty-printed one
# entry per line, so a depth-1 line range is unambiguous. Anything else falls
# through to Invoke-VSCodePatchViaNode.
# ══════════════════════════════════════════════════════════════════════════════

# Get-JsonDoc <path>
# Reads a JSON file preserving the two things line editing would otherwise lose:
# the newline flavour and whether a final newline was present. Shipped
# product.json has NO trailing newline, so without this every patch would dirty
# the last line and a restore could never be byte-exact.
function Get-JsonDoc {
    param([string]$FilePath)
    $raw = [System.IO.File]::ReadAllText($FilePath)
    if ($raw.Contains("`r`n")) { $nl = "`r`n" } else { $nl = "`n" }
    $hadFinal = $raw.EndsWith("`n")
    $lines = [System.Text.RegularExpressions.Regex]::Split($raw, "`r`n|`n")
    if ($hadFinal -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines = $lines[0..($lines.Count - 2)]
    }
    [PSCustomObject]@{ Lines = @($lines); NewLine = $nl; HadFinalNewline = $hadFinal }
}

# Set-JsonDoc <doc> <path>
# Writes in place — FileMode.Create truncates the existing file rather than
# replacing it, so the ACL and file identity survive. UTF-8 without BOM, for the
# same reason Write-EndorFile does it.
function Set-JsonDoc {
    param([PSObject]$Doc, [string]$FilePath)
    $text = ($Doc.Lines -join $Doc.NewLine)
    if ($Doc.HadFinalNewline) { $text += $Doc.NewLine }
    [System.IO.File]::WriteAllText($FilePath, $text, [System.Text.UTF8Encoding]::new($false))
}

function Get-LineIndent {
    param([string]$Line)
    [System.Text.RegularExpressions.Regex]::Match($Line, '^[ \t]*').Value
}

function Get-LineEntryKey {
    param([string]$Line)
    $m = [System.Text.RegularExpressions.Regex]::Match($Line, '^[ \t]*"([^"]+)"[ \t]*:')
    if ($m.Success) { $m.Groups[1].Value } else { '' }
}

# Get-JsonTopObjectRange <lines> <key>
# Locates a depth-1 object value. Returns $null when the key is absent or the
# file is not line-oriented — the signal to fall back to the node writer.
function Get-JsonTopObjectRange {
    param([string[]]$Lines, [string]$Key)
    $open = '^[ \t]*"' + [System.Text.RegularExpressions.Regex]::Escape($Key) + '"[ \t]*:[ \t]*\{[ \t]*$'
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $open) {
            $indent = Get-LineIndent $Lines[$i]
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                if ($Lines[$j] -eq ($indent + '}') -or $Lines[$j] -eq ($indent + '},')) {
                    return [PSCustomObject]@{ Start = $i; End = $j; Indent = $indent }
                }
            }
            return $null
        }
    }
    return $null
}

# Get-JsonTopObjectBlock <lines> <key> — the raw lines of the object, inclusive.
function Get-JsonTopObjectBlock {
    param([string[]]$Lines, [string]$Key)
    $r = Get-JsonTopObjectRange -Lines $Lines -Key $Key
    if (-not $r) { return $null }
    @($Lines[$r.Start..$r.End])
}

# Set-JsonObjectKeys <lines> <key> <setLines> <deleteKeys>
# Key-level merge into a depth-1 object:
#   - each entry in <setLines> ('"key": value') replaces the matching entry in
#     place, keeping its position, or is appended when the key is absent
#   - each key in <deleteKeys> has its entry removed, however many lines it spans
#   - entry-terminating commas are recomputed from scratch, so removing or
#     appending the last entry cannot leave a trailing comma
# Every other line passes through untouched. Returns $null if <key> was not found.
#
# Entries are segmented by indent: a line whose indent equals the first inner
# line's indent and which starts with "name": opens a new entry, and anything more
# deeply indented belongs to the entry above. That is what makes the comma rewrite
# safe across nested arrays such as accessSKUs.
function Set-JsonObjectKeys {
    param([string[]]$Lines, [string]$Key, [string[]]$SetLines, [string[]]$DeleteKeys)

    $r = Get-JsonTopObjectRange -Lines $Lines -Key $Key
    if (-not $r) { return $null }

    $del = @{}
    foreach ($k in $DeleteKeys) { if ($k) { $del[$k.Trim()] = $true } }

    $entries    = New-Object System.Collections.ArrayList
    $entryIndex = @{}
    $innerIndent = $null

    for ($i = $r.Start + 1; $i -lt $r.End; $i++) {
        $line = $Lines[$i]
        if ($null -eq $innerIndent) { $innerIndent = Get-LineIndent $line }
        $key = ''
        if ((Get-LineIndent $line) -eq $innerIndent) { $key = Get-LineEntryKey $line }
        if ($key -ne '') {
            $e = [PSCustomObject]@{ Key = $key; Lines = (New-Object System.Collections.ArrayList); Dropped = $del.ContainsKey($key) }
            [void]$entries.Add($e)
            $entryIndex[$key] = $entries.Count - 1
        }
        if ($entries.Count -eq 0) {
            $e = [PSCustomObject]@{ Key = ''; Lines = (New-Object System.Collections.ArrayList); Dropped = $false }
            [void]$entries.Add($e)
        }
        [void]$entries[$entries.Count - 1].Lines.Add($line)
    }
    if ($null -eq $innerIndent) { $innerIndent = $r.Indent + "`t" }

    foreach ($sl in $SetLines) {
        if (-not $sl) { continue }
        $clean = $sl.Trim()
        if ($clean -match ',$') { $clean = $clean.Substring(0, $clean.Length - 1) }
        $k = Get-LineEntryKey $clean
        if ($entryIndex.ContainsKey($k)) {
            $e = $entries[$entryIndex[$k]]
            $e.Lines.Clear(); [void]$e.Lines.Add($innerIndent + $clean); $e.Dropped = $false
        } else {
            $e = [PSCustomObject]@{ Key = $k; Lines = (New-Object System.Collections.ArrayList); Dropped = $false }
            [void]$e.Lines.Add($innerIndent + $clean)
            [void]$entries.Add($e)
            $entryIndex[$k] = $entries.Count - 1
        }
    }

    $kept = @($entries | Where-Object { -not $_.Dropped })
    $out  = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $r.Start; $i++) { [void]$out.Add($Lines[$i]) }
    [void]$out.Add($Lines[$r.Start])
    for ($n = 0; $n -lt $kept.Count; $n++) {
        $eLines = @($kept[$n].Lines)
        for ($m = 0; $m -lt $eLines.Count; $m++) {
            $line = $eLines[$m]
            if ($m -eq $eLines.Count - 1) {
                $line = [System.Text.RegularExpressions.Regex]::Replace($line, ',[ \t]*$', '')
                if ($n -lt $kept.Count - 1) { $line = $line + ',' }
            }
            [void]$out.Add($line)
        }
    }
    for ($i = $r.End; $i -lt $Lines.Count; $i++) { [void]$out.Add($Lines[$i]) }
    @($out.ToArray())
}

# Set-JsonTopObjectBlock <lines> <key> <blockLines>
# Restore path: puts the captured original back verbatim. The trailing comma is
# taken from whatever is being replaced, so the enclosing object stays valid.
function Set-JsonTopObjectBlock {
    param([string[]]$Lines, [string]$Key, [string[]]$BlockLines)
    $r = Get-JsonTopObjectRange -Lines $Lines -Key $Key
    if (-not $r) { return $null }
    $comma = $Lines[$r.End] -match ',[ \t]*$'
    $blk = @($BlockLines)
    $last = $blk[$blk.Count - 1]
    $last = [System.Text.RegularExpressions.Regex]::Replace($last, ',[ \t]*$', '')
    if ($comma) { $last = $last + ',' }
    $blk[$blk.Count - 1] = $last

    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $r.Start; $i++) { [void]$out.Add($Lines[$i]) }
    foreach ($l in $blk) { [void]$out.Add($l) }
    for ($i = $r.End + 1; $i -lt $Lines.Count; $i++) { [void]$out.Add($Lines[$i]) }
    @($out.ToArray())
}

# Add-JsonTopLine <lines> <line>
# Inserts immediately after the opening brace on line 1, so we emit our own
# trailing comma and never have to append one to an existing line.
function Add-JsonTopLine {
    param([string[]]$Lines, [string]$Line)
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add($Lines[0])
    [void]$out.Add($Line)
    for ($i = 1; $i -lt $Lines.Count; $i++) { [void]$out.Add($Lines[$i]) }
    @($out.ToArray())
}

# Remove-JsonTopKey <lines> <key> — removes a depth-1 single-line key.
function Remove-JsonTopKey {
    param([string[]]$Lines, [string]$Key)
    $pat = '^[ \t]*"' + [System.Text.RegularExpressions.Regex]::Escape($Key) + '"[ \t]*:'
    @($Lines | Where-Object { $_ -notmatch $pat })
}

# Get-JsonTopString <lines> <key>
# Depth-1 string value, anchored to the indent of the first top-level key.
# product.json contains nested "version" keys hundreds of lines before the
# top-level one, so an indent-agnostic match returns the wrong value.
function Get-JsonTopString {
    param([string[]]$Lines, [string]$Key)
    if ($Lines.Count -lt 2) { return '' }
    $tind = Get-LineIndent $Lines[1]
    $pat = '^' + $tind + '"' + [System.Text.RegularExpressions.Regex]::Escape($Key) + '"[ \t]*:[ \t]*"([^"]*)"'
    foreach ($l in $Lines) {
        if ((Get-LineIndent $l) -ne $tind) { continue }
        $m = [System.Text.RegularExpressions.Regex]::Match($l, $pat)
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

# Test-JsonValid <path>
# ConvertFrom-Json is native and free, so it always runs — but it is NOT strict:
# both the 5.1 (Newtonsoft) and 7.x (System.Text.Json) implementations happily
# accept a trailing comma before } or ]. That is exactly the malformation the
# comma rewrite in Set-JsonObjectKeys could introduce, so it has to be checked
# explicitly, or a corrupt product.json would pass validation on Windows while
# failing in VS Code's own strict JSON.parse.
#
# The check is structural rather than a regex over the whole text: a line whose
# last character is a comma, followed by a line starting with } or ]. A string
# value can never end in a bare comma (it ends in a quote), so this cannot
# false-positive on content — which matters, because a false positive here means
# refusing to apply an otherwise-good patch.
function Test-JsonValid {
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) { return $false }
    try {
        $raw = [System.IO.File]::ReadAllText($FilePath)
        if (-not $raw.TrimStart().StartsWith('{')) { return $false }
        if (-not $raw.TrimEnd().EndsWith('}')) { return $false }
        $null = $raw | ConvertFrom-Json

        $lines = [System.Text.RegularExpressions.Regex]::Split($raw, "`r`n|`n")
        $prev = ''
        foreach ($l in $lines) {
            $t = $l.Trim()
            if ($t -eq '') { continue }
            if ($prev.EndsWith(',') -and ($t.StartsWith('}') -or $t.StartsWith(']'))) { return $false }
            $prev = $t
        }
        return $true
    } catch { return $false }
}

# ── Install discovery ─────────────────────────────────────────────────────────

# Get-VSCodeInstallPath [-UserHome <path>] [-Roots <string[]>]
# One product.json path per VS Code install found, stable and Insiders.
#
# NOTE the per-user candidates use $UserHome, NOT $env:LOCALAPPDATA: Intune runs
# scripts as SYSTEM, whose LOCALAPPDATA is under C:\Windows, so relying on the
# env var would silently miss every per-user install on the fleet.
function Get-VSCodeInstallPath {
    param([string]$UserHome, [string[]]$Roots)

    if (-not $Roots) {
        $bases = @()
        foreach ($pf in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($pf) { $bases += $pf }
        }
        if ($UserHome) { $bases += (Join-Path $UserHome 'AppData\Local\Programs') }
        $Roots = @()
        foreach ($b in ($bases | Select-Object -Unique)) {
            $Roots += (Join-Path $b 'Microsoft VS Code')
            $Roots += (Join-Path $b 'Microsoft VS Code Insiders')
        }
    }

    $found = @()
    foreach ($r in $Roots) {
        $pj = Join-Path $r 'resources\app\product.json'
        if (Test-Path -LiteralPath $pj -PathType Leaf) { $found += $pj }
    }
    @($found | Select-Object -Unique)
}

# Get-VSCodeEditionLabel <product.json> — human label for logs.
function Get-VSCodeEditionLabel {
    param([string]$FilePath)
    try {
        $name = Get-JsonTopString -Lines (Get-JsonDoc $FilePath).Lines -Key 'nameLong'
        if ($name) { return $name }
    } catch { }
    'VS Code'
}

# Get-VSCodeInstallRoot <product.json> — the directory containing resources\.
function Get-VSCodeInstallRoot {
    param([string]$FilePath)
    Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $FilePath))
}

# Get-VSCodeNodeBin <product.json>
# Code.exe doubles as node under ELECTRON_RUN_AS_NODE=1 — the same trick VS Code's
# own CLI shim uses, so the fallback writer needs no extra dependency.
function Get-VSCodeNodeBin {
    param([string]$FilePath)
    $root = Get-VSCodeInstallRoot $FilePath
    foreach ($exe in @('Code.exe', 'Code - Insiders.exe')) {
        $p = Join-Path $root $exe
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

# Test-VSCodeCanWrite <product.json>
# Opens for write and closes immediately: no content change, no mtime change, but
# it fails exactly where a real write would (ACLs, or a file locked by a running
# VS Code). Checked up front so a permission problem is reported as such rather
# than surfacing as a half-applied patch.
function Test-VSCodeCanWrite {
    param([string]$FilePath)
    try {
        $fs = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $fs.Close()
        return $true
    } catch { return $false }
}

# ── Sidecar state ─────────────────────────────────────────────────────────────
# Holds the rendered gallery URL for the watcher plus re-apply telemetry. Never
# inside the install directory. Overridable so it can be exercised off-Windows.

function Get-VSCodeStateDir {
    if ($env:ENDOR_VSCODE_STATE_DIR) { return $env:ENDOR_VSCODE_STATE_DIR }
    if ($env:ProgramData) { return (Join-Path $env:ProgramData 'Endor\PackageFirewall\vscode') }
    'C:\ProgramData\Endor\PackageFirewall\vscode'
}

function Set-VSCodeState {
    param([string]$Key, [string]$Value)
    $dir = Get-VSCodeStateDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $f = Join-Path $dir 'state'
    $lines = @()
    if (Test-Path -LiteralPath $f) {
        $lines = @(Get-Content -LiteralPath $f | Where-Object { $_ -notmatch "^$([regex]::Escape($Key))=" })
    }
    $lines += "$Key=$Value"
    Write-EndorFile -FilePath $f -Lines $lines

    # The state file carries the rendered gallery URL, i.e. a live credential, so
    # lock it to the account the watcher runs as. Resolved from the well-known SID
    # rather than the literal string 'SYSTEM', because that account name is
    # localised on non-English Windows and would fail to resolve.
    if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
        try {
            $sysName = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
                       ).Translate([System.Security.Principal.NTAccount]).Value
            Set-FileRestrictedAcl -FilePath $f -Username $sysName
        } catch {
            Write-Warning "[endor-vscode] could not restrict $f -- it holds a credential; check its ACL."
        }
    }
}

function Get-VSCodeState {
    param([string]$Key)
    $f = Join-Path (Get-VSCodeStateDir) 'state'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    $hit = @(Get-Content -LiteralPath $f | Where-Object { $_ -match "^$([regex]::Escape($Key))=" })
    if ($hit.Count -eq 0) { return '' }
    ($hit[-1] -replace "^$([regex]::Escape($Key))=", '')
}

# Write-VSCodeStateReport — surface watcher activity into MDM logs, so an admin can
# see that VS Code updates really are clobbering product.json on this fleet.
function Write-VSCodeStateReport {
    $n = Get-VSCodeState 'repatch_count'
    if ($n -and $n -ne '0') {
        $last = Get-VSCodeState 'last_repatch'
        if (-not $last) { $last = 'unknown' }
        Write-Host "[endor-vscode]       watcher has re-applied the patch ${n}x (last: $last)"
    }
}

# ── Marker + state machine ────────────────────────────────────────────────────

# Get-VSCodeMarkerField <product.json> <field>
# The awk/PowerShell writer emits the marker on one line; the node fallback runs it
# through JSON.stringify and pretty-prints it. Reading only the single-line shape
# would silently break restore for node-written files, so fall back to extracting
# the marker as a block.
function Get-VSCodeMarkerField {
    param([string]$FilePath, [string]$Field)
    $pat = '"' + [regex]::Escape($Field) + '"[ \t]*:[ \t]*"([^"]*)"'
    $lines = (Get-JsonDoc $FilePath).Lines
    foreach ($l in $lines) {
        if ($l -match [regex]::Escape($ENDOR_JSON_MARKER_KEY)) {
            $m = [regex]::Match($l, $pat)
            if ($m.Success) { return $m.Groups[1].Value }
        }
    }
    $blk = Get-JsonTopObjectBlock -Lines $lines -Key $ENDOR_JSON_MARKER_KEY
    if ($blk) {
        foreach ($l in $blk) {
            $m = [regex]::Match($l, $pat)
            if ($m.Success) { return $m.Groups[1].Value }
        }
    }
    return ''
}

# Get-VSCodeManagedState <product.json> <url> <deleteKeys>
# unmanaged | current | stale. A 'stale' file must be restored before being
# re-patched — never patch on top of a patch, or the captured original is lost.
function Get-VSCodeManagedState {
    param([string]$FilePath, [string]$Url, [string[]]$DeleteKeys)
    $raw = [System.IO.File]::ReadAllText($FilePath)
    if (-not $raw.Contains('"' + $ENDOR_JSON_MARKER_KEY + '"')) { return 'unmanaged' }
    if (-not $raw.Contains('"serviceUrl": "' + $Url + '"')) { return 'stale' }
    foreach ($k in $DeleteKeys) {
        if ($k -and $raw.Contains('"' + $k.Trim() + '"')) { return 'stale' }
    }
    'current'
}

# ── Patch / unpatch ───────────────────────────────────────────────────────────

function Get-VSCodeMarkerBase {
    param([string]$Namespace, [string]$Fqdn, [string[]]$Lines)
    $ver = Get-JsonTopString -Lines $Lines -Key 'version'
    $cmt = Get-JsonTopString -Lines $Lines -Key 'commit'
    if (-not $ver) { $ver = 'unknown' }
    if (-not $cmt) { $cmt = 'unknown' }
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    '{"schema":1,"namespace":"' + $Namespace + '","fqdn":"' + $Fqdn +
      '","appVersion":"' + $ver + '","appCommit":"' + $cmt + '","patchedAt":"' + $ts + '"'
}

# Invoke-VSCodePatchViaNode — fallback for a product.json that is not
# line-oriented (repackaged or minified). Reformats the whole file, which is
# acceptable precisely because the layout was already non-standard. Records
# via:"node" so unpatch restores the same way.
function Invoke-VSCodePatchViaNode {
    param([string]$FilePath, [string]$NodeBin, [string]$Url, [string[]]$DeleteKeys,
          [string]$MarkerBase, [string]$OutFile)
    $js = @'
const fs = require("fs");
const d = JSON.parse(fs.readFileSync(process.env.ENDOR_PJ, "utf8"));
const orig = JSON.stringify(d.extensionsGallery || {});
const g = Object.assign({}, d.extensionsGallery || {});
g.serviceUrl = process.env.ENDOR_URL;
(process.env.ENDOR_DEL || "").split(/\s+/).filter(Boolean).forEach(k => { delete g[k]; });
const marker = Object.assign(JSON.parse(process.env.ENDOR_MARKER), {
  via: "node",
  originalExtensionsGalleryB64: Buffer.from(orig).toString("base64"),
});
const out = {};
out[process.env.ENDOR_MARKER_KEY] = marker;
for (const k of Object.keys(d)) out[k] = (k === "extensionsGallery") ? g : d[k];
fs.writeFileSync(process.env.ENDOR_OUT, JSON.stringify(out, null, "\t"));
'@
    try {
        $env:ENDOR_PJ = $FilePath; $env:ENDOR_URL = $Url
        $env:ENDOR_DEL = ($DeleteKeys -join ' '); $env:ENDOR_OUT = $OutFile
        $env:ENDOR_MARKER_KEY = $ENDOR_JSON_MARKER_KEY
        $env:ENDOR_MARKER = ($MarkerBase + '}')
        $env:ELECTRON_RUN_AS_NODE = '1'
        & $NodeBin -e $js 2>$null | Out-Null
        return (Test-Path -LiteralPath $OutFile)
    } catch { return $false } finally {
        foreach ($v in 'ENDOR_PJ','ENDOR_URL','ENDOR_DEL','ENDOR_OUT','ENDOR_MARKER_KEY','ENDOR_MARKER','ELECTRON_RUN_AS_NODE') {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-VSCodeUnpatchViaNode {
    param([string]$FilePath, [string]$NodeBin, [string]$OutFile)
    $js = @'
const fs = require("fs");
const d = JSON.parse(fs.readFileSync(process.env.ENDOR_PJ, "utf8"));
const m = d[process.env.ENDOR_MARKER_KEY] || {};
if (m.originalExtensionsGalleryB64) {
  d.extensionsGallery = JSON.parse(Buffer.from(m.originalExtensionsGalleryB64, "base64").toString("utf8"));
}
delete d[process.env.ENDOR_MARKER_KEY];
fs.writeFileSync(process.env.ENDOR_OUT, JSON.stringify(d, null, "\t"));
'@
    try {
        $env:ENDOR_PJ = $FilePath; $env:ENDOR_OUT = $OutFile
        $env:ENDOR_MARKER_KEY = $ENDOR_JSON_MARKER_KEY
        $env:ELECTRON_RUN_AS_NODE = '1'
        & $NodeBin -e $js 2>$null | Out-Null
        return (Test-Path -LiteralPath $OutFile)
    } catch { return $false } finally {
        foreach ($v in 'ENDOR_PJ','ENDOR_OUT','ENDOR_MARKER_KEY','ELECTRON_RUN_AS_NODE') {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }
}

# Invoke-VSCodePatch
# Returns 0 patched · 2 already current (nothing written) · 1 failed.
function Invoke-VSCodePatch {
    param([string]$FilePath, [string]$Url, [string[]]$SetLines, [string[]]$DeleteKeys,
          [string]$Namespace, [string]$Fqdn, [switch]$DryRun)

    $label = Get-VSCodeEditionLabel $FilePath
    $state = Get-VSCodeManagedState -FilePath $FilePath -Url $Url -DeleteKeys $DeleteKeys

    if ($state -eq 'current') {
        Write-Host "[endor-vscode] ok    ${label}: already current -- no change"
        return 2
    }

    if ($DryRun) {
        Write-Host "[dry-run]   action : $state -> PATCH product.json"
        if ($state -eq 'stale') {
            Write-Host '[dry-run]   note   : stale -- original restored first, then re-patched'
        }
        Write-Host "[dry-run]   file   : $FilePath"
        Write-Host ("[dry-run]   set    : " + (Get-EndorRedactAk ($SetLines -join '; ')))
        Write-Host ("[dry-run]   remove : " + (($DeleteKeys -join ' ')))
        Write-Host "[dry-run]   marker : $ENDOR_JSON_MARKER_KEY (carries the original for restore)"
        Write-Host ''
        return 0
    }

    if (-not (Test-VSCodeCanWrite $FilePath)) {
        Write-Warning "[endor-vscode] ${label}: cannot write $FilePath"
        Write-Warning '[endor-vscode]       Run as SYSTEM/Administrator. If VS Code is running, close it and re-run.'
        return 1
    }

    if ($state -eq 'stale') {
        Write-Host "[endor-vscode]       ${label}: managed but out of date -- restoring original first"
        if ((Invoke-VSCodeUnpatch -FilePath $FilePath) -ne 0) { return 1 }
    }

    $nodeBin = Get-VSCodeNodeBin $FilePath
    $doc = Get-JsonDoc $FilePath
    $markerBase = Get-VSCodeMarkerBase -Namespace $Namespace -Fqdn $Fqdn -Lines $doc.Lines
    $tmp = [System.IO.Path]::GetTempFileName()
    $applied = $false

    $blk = Get-JsonTopObjectBlock -Lines $doc.Lines -Key 'extensionsGallery'
    if ($blk) {
        $merged = Set-JsonObjectKeys -Lines $doc.Lines -Key 'extensionsGallery' `
                    -SetLines $SetLines -DeleteKeys $DeleteKeys
        if ($merged) {
            $origB64 = [System.Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes(($blk -join $doc.NewLine) + $doc.NewLine))
            $tind = Get-LineIndent $doc.Lines[1]
            $markerLine = $tind + '"' + $ENDOR_JSON_MARKER_KEY + '": ' + $markerBase +
                          ',"via":"ps","originalExtensionsGalleryB64":"' + $origB64 + '"},'
            $doc.Lines = Add-JsonTopLine -Lines $merged -Line $markerLine
            Set-JsonDoc -Doc $doc -FilePath $tmp
            $applied = $true
        }
    }

    if (-not $applied) {
        if ($nodeBin -and (Invoke-VSCodePatchViaNode -FilePath $FilePath -NodeBin $nodeBin `
                             -Url $Url -DeleteKeys $DeleteKeys -MarkerBase $markerBase -OutFile $tmp)) {
            Write-Host "[endor-vscode]       ${label}: product.json is not line-oriented -- used the bundled node writer"
            $applied = $true
        } else {
            Write-Warning "[endor-vscode] ${label}: unrecognised product.json layout and no usable node binary"
            Write-Warning "[endor-vscode]       $FilePath was left untouched."
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return 1
        }
    }

    if (-not (Test-JsonValid $tmp)) {
        Write-Warning "[endor-vscode] ${label}: patched product.json failed validation -- not installing it"
        Write-Warning "[endor-vscode]       $FilePath was left untouched."
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return 1
    }

    # Write through the existing file so its ACL and identity survive.
    $newDoc = Get-JsonDoc $tmp
    $newDoc.HadFinalNewline = (Get-JsonDoc $FilePath).HadFinalNewline
    Set-JsonDoc -Doc $newDoc -FilePath $FilePath
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

    Write-Host "[endor-vscode] ok    ${label}: gallery routed through the Endor firewall"
    return 0
}

# Invoke-VSCodeUnpatch — restores the captured original and drops the marker.
# Returns 0 on success (including "nothing to do"), 1 on failure.
function Invoke-VSCodeUnpatch {
    param([string]$FilePath, [switch]$DryRun)

    $label = Get-VSCodeEditionLabel $FilePath
    $raw = [System.IO.File]::ReadAllText($FilePath)
    if (-not $raw.Contains('"' + $ENDOR_JSON_MARKER_KEY + '"')) {
        Write-Host "[endor-remove] skip  ${label}: not managed by Endor -- $FilePath"
        return 0
    }

    if ($DryRun) {
        Write-Host '[dry-run]   action : RESTORE original extensionsGallery, drop marker'
        Write-Host "[dry-run]   file   : $FilePath"
        return 0
    }

    if (-not (Test-VSCodeCanWrite $FilePath)) {
        Write-Warning "[endor-vscode] ${label}: cannot write $FilePath (privileges, or VS Code is running)"
        return 1
    }

    $via     = Get-VSCodeMarkerField -FilePath $FilePath -Field 'via'
    $origB64 = Get-VSCodeMarkerField -FilePath $FilePath -Field 'originalExtensionsGalleryB64'
    if (-not $origB64) {
        Write-Warning "[endor-vscode] ${label}: marker carries no original -- refusing to guess"
        Write-Warning "[endor-vscode]       Reinstall ${label} to restore a pristine product.json."
        return 1
    }

    $tmp = [System.IO.Path]::GetTempFileName()
    $okDone = $false

    if ($via -eq 'node') {
        $nodeBin = Get-VSCodeNodeBin $FilePath
        if ($nodeBin -and (Invoke-VSCodeUnpatchViaNode -FilePath $FilePath -NodeBin $nodeBin -OutFile $tmp)) {
            $okDone = $true
        }
    } else {
        $doc = Get-JsonDoc $FilePath
        $blockText = Get-EndorB64Decode $origB64
        $blockLines = @([System.Text.RegularExpressions.Regex]::Split($blockText.TrimEnd("`r", "`n"), "`r`n|`n"))
        $restored = Set-JsonTopObjectBlock -Lines $doc.Lines -Key 'extensionsGallery' -BlockLines $blockLines
        if ($restored) {
            $doc.Lines = Remove-JsonTopKey -Lines $restored -Key $ENDOR_JSON_MARKER_KEY
            Set-JsonDoc -Doc $doc -FilePath $tmp
            $okDone = $true
        }
    }

    if ((-not $okDone) -or (-not (Test-JsonValid $tmp))) {
        Write-Warning "[endor-vscode] ${label}: restore failed validation -- $FilePath left as-is"
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return 1
    }

    $newDoc = Get-JsonDoc $tmp
    $newDoc.HadFinalNewline = (Get-JsonDoc $FilePath).HadFinalNewline
    Set-JsonDoc -Doc $newDoc -FilePath $FilePath
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

    Write-Host "[endor-remove] ok    ${label}: original gallery restored"
    return 0
}

# ── product.json re-apply watcher (Scheduled Task) ────────────────────────────
# VS Code replaces product.json on every update -- monthly for stable, nightly for
# Insiders -- on a schedule unrelated to MDM check-in. Task Scheduler has no
# file-watch trigger, so -AtLogOn stands in for "the user updated, then relaunched"
# and the hourly repetition is the real backstop.

function Install-VSCodeWatcher {
    param([string]$ScriptPath, [switch]$DryRun)

    if ($DryRun) {
        Write-Host "[dry-run]   watcher: Scheduled Task ${ENDOR_VSCODE_TASK_PATH}${ENDOR_VSCODE_TASK_NAME} (startup + logon + hourly)"
        Write-Host "[dry-run]   repatch: $ScriptPath"
        return $true
    }

    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        Write-Warning '[endor-vscode] Scheduled Task cmdlets unavailable -- cannot install the update watcher.'
        Write-Warning '[endor-vscode]          The patch will be lost on the next VS Code update.'
        return $false
    }

    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
        $triggers = @(
            (New-ScheduledTaskTrigger -AtStartup),
            (New-ScheduledTaskTrigger -AtLogOn)
        )
        try {
            $triggers += (New-ScheduledTaskTrigger -Once -At (Get-Date) `
                            -RepetitionInterval (New-TimeSpan -Hours 1) `
                            -RepetitionDuration ([TimeSpan]::MaxValue))
        } catch {
            # Older Task Scheduler rejects TimeSpan.MaxValue; an indefinite
            # repetition with no duration is the documented equivalent.
            $triggers += (New-ScheduledTaskTrigger -Once -At (Get-Date) `
                            -RepetitionInterval (New-TimeSpan -Hours 1))
        }
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' `
                        -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $ENDOR_VSCODE_TASK_NAME -TaskPath $ENDOR_VSCODE_TASK_PATH `
            -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "[endor-vscode]       update watcher installed -> ${ENDOR_VSCODE_TASK_PATH}${ENDOR_VSCODE_TASK_NAME}"
        return $true
    } catch {
        Write-Warning "[endor-vscode] could not register the update watcher: $($_.Exception.Message)"
        Write-Warning '[endor-vscode]          The patch will be lost on the next VS Code update.'
        return $false
    }
}

function Uninstall-VSCodeWatcher {
    param([switch]$DryRun)

    if ($DryRun) {
        Write-Host '[dry-run]   action : REMOVE update watcher (Scheduled Task) and sidecar state'
        return
    }

    if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
        $existing = Get-ScheduledTask -TaskName $ENDOR_VSCODE_TASK_NAME `
                      -TaskPath $ENDOR_VSCODE_TASK_PATH -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $ENDOR_VSCODE_TASK_NAME `
                -TaskPath $ENDOR_VSCODE_TASK_PATH -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "[endor-remove] watcher removed     : ${ENDOR_VSCODE_TASK_PATH}${ENDOR_VSCODE_TASK_NAME}"
        } else {
            Write-Host "[endor-remove] skip (no watcher)   : ${ENDOR_VSCODE_TASK_PATH}${ENDOR_VSCODE_TASK_NAME}"
        }
    }

    $dir = Get-VSCodeStateDir
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[endor-remove] sidecar removed     : $dir"
    }
}
