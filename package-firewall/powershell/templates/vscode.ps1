# templates/vscode.ps1
# VS Code ecosystem — extension gallery
#
# Config target is product.json inside each VS Code install directory:
#   %ProgramFiles%\Microsoft VS Code{, Insiders}\resources\app\product.json   (system)
#   <UserHome>\AppData\Local\Programs\Microsoft VS Code{, Insiders}\...       (per-user)
#
# Block content is defined in shared/blocks/vscodegallery.txt.
#
# Three things make this ecosystem different from npm/pip/go/maven:
#
#   1. The file is JSON, so it can carry neither an Endor sentinel comment nor an
#      env-var reference. The managed marker is a top-level JSON key that also
#      stores the byte-exact original for restore.
#   2. product.json lives inside the application and is replaced wholesale by
#      every VS Code update, so a Scheduled Task re-applies the patch. Stable
#      updates monthly; Insiders nightly.
#   3. The credential is a URL path segment, so it lands in a file every user can
#      read. That is unavoidable — VS Code offers no indirection in product.json —
#      and is why VS Code should use its own separately revocable API key.
#
# The {{VSCODE_GALLERY_URL}} token is filled here at install time (not at
# generation time) because it embeds this machine's attribution label — the same
# pattern as {{GO_PROXY_URL}} in templates/go.ps1.
#
# Attribution is recomputed here rather than read from envvars.ps1: the VS Code
# script deliberately does not write HKCU env vars, because nothing at runtime
# reads them for this ecosystem.

Write-Host '[endor-vscode] -- VS Code extensions ---------------------------------------'

# -- The attributed gallery URL --
# In repatch mode the prelude has already read the rendered URL out of the sidecar
# state, and MUST NOT recompute it: the Scheduled Task can fire at startup with
# nobody logged in, so $ConsoleUser is empty there and recomputing would mint a
# token attributed to no user at all.
if ($_EndorVSCodeMode -eq 'repatch') {
    Write-Host '[endor-vscode] re-applying with the gallery URL recorded at install time'
} else {
    $_vscSecret    = '{{API_SECRET}}'
    $_vscAttrLabel = "$ConsoleUser@$(Get-EndorHostLabel)"
    $_vscAttrUser  = Get-EndorAttrUsername -Label $_vscAttrLabel -ApiKeyId '{{API_KEY_ID}}'
    $ENDOR_VSCODE_GALLERY_URL = '{{VSCODE_GALLERY_BASE}}/_ak/' + (Get-EndorVSCodeToken -AttrUser $_vscAttrUser -Secret $_vscSecret)
    Write-Host "[endor-vscode] user attribution -> $_vscAttrLabel"
}

if (-not $ENDOR_VSCODE_GALLERY_URL) {
    Write-Warning '[endor-vscode] no gallery URL available -- refusing to patch product.json.'
    $EndorWarned = $true
    return
}

# -- Split the block into set-lines and delete-keys --
# '-key' lines delete a key, '"key": value' lines set one, '#' lines are comments.
$_vscSetLines   = @()
$_vscDeleteKeys = @()
foreach ($_line in ($VSCODE_GALLERY_BLOCK -split "`r`n|`n")) {
    $_t = $_line.Trim()
    if ($_t -eq '' -or $_t.StartsWith('#')) { continue }
    if ($_t.StartsWith('-')) { $_vscDeleteKeys += $_t.Substring(1).Trim() }
    else { $_vscSetLines += $_t.Replace('{{VSCODE_GALLERY_URL}}', $ENDOR_VSCODE_GALLERY_URL) }
}

if (($_vscSetLines -join '') -match '\{\{') {
    Write-Warning '[endor-vscode] unresolved {{...}} token in the VS Code gallery block.'
    Write-Warning '[endor-vscode]          Regenerate with generate.ps1 -- do not hand-edit generated scripts.'
    $EndorWarned = $true
}
if ($_vscSetLines.Count -eq 0) {
    Write-Warning '[endor-vscode] shared/blocks/vscodegallery.txt produced no keys to set.'
    $EndorWarned = $true
}

# -- Discover installs --
$_vscPaths = @(Get-VSCodeInstallPath -UserHome $UserHome)

if ($_vscPaths.Count -eq 0) {
    # Informational, not a warning -- matches the "go not installed" precedent in
    # templates/go.ps1. A machine without VS Code is not a misconfigured machine.
    Write-Host '[endor-vscode]   no VS Code installation found -- nothing to do'
    Write-Host '[endor-vscode]   (re-run this script after installing VS Code)'
} else {
    $_vscTouched = $false
    foreach ($_pj in $_vscPaths) {
        $_rc = Invoke-VSCodePatch -FilePath $_pj -Url $ENDOR_VSCODE_GALLERY_URL `
                 -SetLines $_vscSetLines -DeleteKeys $_vscDeleteKeys `
                 -Namespace '{{NAMESPACE}}' -Fqdn '{{FQDN}}' -DryRun:$DryRun
        if ($_rc -eq 0) {
            $_vscTouched = $true
            # In repatch mode a return of 0 means an update really did clobber
            # product.json since last time. Count it, so the race shows up in MDM
            # logs instead of being invisible.
            if ($_EndorVSCodeMode -eq 'repatch') {
                $_n = Get-VSCodeState 'repatch_count'
                if (-not $_n) { $_n = '0' }
                Set-VSCodeState -Key 'repatch_count' -Value ([string]([int]$_n + 1))
                Set-VSCodeState -Key 'last_repatch' -Value ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
            }
        } elseif ($_rc -eq 2) {
            $_vscTouched = $true
        } else {
            $EndorWarned = $true
        }
    }

    # -- Install the re-apply watcher (install mode only) --
    if ($_EndorVSCodeMode -ne 'repatch' -and $_vscTouched) {
        $_stateDir = Get-VSCodeStateDir
        $_repatch  = Join-Path $_stateDir 'endor-vscode-repatch.ps1'

        # Record state whether or not the watcher is wanted, so re-enabling it
        # later (or running the repatch script by hand) needs no re-install.
        if (-not $DryRun) {
            if (-not (Test-Path -LiteralPath $_stateDir)) {
                New-Item -ItemType Directory -Path $_stateDir -Force | Out-Null
            }
            # The watcher can fire at startup before anyone has logged in, so the
            # repatch script cannot re-run console-user detection. Record the
            # already-rendered URL and home here instead.
            Set-VSCodeState -Key 'gallery_url' -Value $ENDOR_VSCODE_GALLERY_URL
            Set-VSCodeState -Key 'user_home'   -Value $UserHome
        }

        if (-not $NoVSCodeWatcher) {
            if (-not $DryRun) {
                # The watcher needs a script at a stable path. Do NOT copy
                # $PSCommandPath: MDM tools routinely run scripts from a temp file
                # that is already gone by the time the task fires.
                [System.IO.File]::WriteAllText($_repatch,
                    (Get-EndorB64Decode $_EndorVSCodeRepatchB64),
                    [System.Text.UTF8Encoding]::new($false))
            }
            $null = Install-VSCodeWatcher -ScriptPath $_repatch -DryRun:$DryRun
            Write-VSCodeStateReport
        } else {
            # An explicit opt-out is an admin decision, so it is stated loudly but
            # does NOT set the warning flag -- failing every MDM check-in over a
            # chosen setting is alert fatigue, and alert fatigue is how real
            # warnings get ignored.
            Write-Host '[endor-vscode]       update watcher skipped (-NoVSCodeWatcher)'
            Write-Host '[endor-vscode]       NOTE: the patch is lost whenever VS Code updates -- monthly for'
            Write-Host '[endor-vscode]             stable, nightly for Insiders. Re-push this script on every'
            Write-Host '[endor-vscode]             MDM check-in, or accept unfiltered windows in between.'
        }
    }

    Write-Host "[endor-vscode]   covers: Extensions view search, install and auto-update, plus"
    Write-Host "[endor-vscode]           'code --install-extension' (the CLI reads product.json too)"
    Write-Host '[endor-vscode]   gallery: {{FQDN}}/v1/namespaces/{{NAMESPACE}}/firewall/vscode/_ak/<token>'
    Write-Host "[endor-vscode]   note: extension downloads still come from Microsoft's CDN by design --"
    Write-Host '[endor-vscode]         blocked versions are filtered out of the gallery response, so they'
    Write-Host '[endor-vscode]         are never offered. Keep *.vsassets.io / *.vscode-unpkg.net reachable'
    Write-Host '[endor-vscode]         through any egress proxy.'
    Write-Host '[endor-vscode] [done] VS Code done'
}

Remove-Variable _vscSecret, _vscAttrLabel, _vscAttrUser -ErrorAction SilentlyContinue
