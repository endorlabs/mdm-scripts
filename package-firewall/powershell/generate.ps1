#!/usr/bin/env pwsh
# generate.ps1 — Endor Package Firewall MDM Script Generator (Windows / PowerShell)
#
# Produces self-contained, MDM-deployable PowerShell scripts that configure
# developer machines to route package installations through the Endor Package Firewall.
#
# Usage:
#   $env:ENDOR_NAMESPACE='my-team'
#   $env:ENDOR_API_KEY_ID='key-id'
#   $env:ENDOR_API_SECRET='key-secret'
#   ./generate.ps1
#
# Or with a .env file (add .env to .gitignore):
#   Get-Content .env | ForEach-Object {
#     $k, $v = $_ -split '=', 2
#     [System.Environment]::SetEnvironmentVariable($k, $v)
#   }
#   ./generate.ps1
#
# Environment variables:
#   ENDOR_NAMESPACE    Required. Your Endor namespace (e.g. my-team)
#   ENDOR_API_KEY_ID   Required. API key ID (Basic Auth username)
#   ENDOR_API_SECRET   Required. API secret  (Basic Auth password)
#   ENDOR_FQDN         Optional. Base URL (default: https://factory.endorlabs.com)
#
# To customise config blocks, edit shared/blocks/*.txt directly.
# To customise orchestration logic, edit templates/*.ps1 directly.
#
# Output (out/<namespace>/):
#   endor-js.ps1       — JavaScript: npm . pnpm . yarn classic · yarn 2+ . bun
#   endor-python.ps1   — Python:     pip . uv . poetry
#   endor-go.ps1       — Go:         go modules (GOPROXY -> %APPDATA%\go\env)
#   endor-maven.ps1    — Maven:      Maven (settings.xml -> %USERPROFILE%\.m2\settings.xml)
#   endor-all.ps1      — All of the above (single-script MDM deploy)
#   endor-remove.ps1   — Offboarding: strips Endor config + registry env vars
#
# All scripts accept -DryRun: prints what would change without writing anything.
# All scripts are idempotent — safe to re-push on MDM check-in cycles.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$LibDir          = Join-Path $ScriptDir 'lib'
$TmplDir         = Join-Path $ScriptDir 'templates'
$SharedBlocksDir = Join-Path $ScriptDir '..\shared\blocks'

# -- Validate required env vars ------------------------------------------------
foreach ($var in @('ENDOR_NAMESPACE', 'ENDOR_API_KEY_ID', 'ENDOR_API_SECRET')) {
    if (-not (Get-Item "Env:$var" -ErrorAction SilentlyContinue)) {
        Write-Error "$var is required"
        exit 1
    }
}

$ENDOR_NAMESPACE  = $env:ENDOR_NAMESPACE
$ENDOR_API_KEY_ID = $env:ENDOR_API_KEY_ID
$ENDOR_API_SECRET = $env:ENDOR_API_SECRET
$FQDN = if ($env:ENDOR_FQDN) { $env:ENDOR_FQDN.TrimEnd('/') } else { 'https://factory.endorlabs.com' }

# Reject credential characters that would corrupt generated scripts/URLs.
if ("${ENDOR_API_KEY_ID}${ENDOR_API_SECRET}" -match '[^A-Za-z0-9+/=_.-]') {
    Write-Error 'ENDOR_API_KEY_ID / ENDOR_API_SECRET contain unsupported characters'
    exit 1
}

# -- Compute derived values ----------------------------------------------------
# Credentials are NOT precomputed here. The per-machine attributed username
# (<console-user>@<machine>) only exists on the developer's machine, so all
# auth values are computed at install time by templates/envvars.ps1. Only
# machine-independent values are derived here.
$FQDN_HOST        = $FQDN -replace '^https?://', ''
$TRUSTED_HOST     = $FQDN_HOST -replace ':.*', ''

$NPM_REGISTRY_URL  = "$FQDN/v1/namespaces/$ENDOR_NAMESPACE/firewall/npm/"
$NPM_REGISTRY_HOST = "$FQDN_HOST/v1/namespaces/$ENDOR_NAMESPACE/firewall/npm/"
$PYPI_URL          = "$FQDN/v1/namespaces/$ENDOR_NAMESPACE/firewall/pypi/simple/"
$MAVEN_REGISTRY_URL = "$FQDN/v1/namespaces/$ENDOR_NAMESPACE/firewall/maven/"

# -- Output directory ----------------------------------------------------------
$OutDir = Join-Path $ScriptDir "out\$ENDOR_NAMESPACE"
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# -- Template substitution -----------------------------------------------------
# Uses String.Replace() (literal, not regex) to avoid issues with $ in values.
function Invoke-Substitute {
    param([string]$Content)
    $r = $Content
    # Attribution tokens ({{PIP_INDEX_URL}}, {{ENDOR_PYPI_URL}}, {{GO_PROXY_URL}},
    # {{NPM_AUTH_B64}}) are NOT substituted here — the generated scripts fill
    # them at install time from the values computed in envvars.ps1.
    $r = $r.Replace('{{NAMESPACE}}',          $ENDOR_NAMESPACE)
    $r = $r.Replace('{{API_KEY_ID}}',         $ENDOR_API_KEY_ID)
    $r = $r.Replace('{{API_SECRET}}',         $ENDOR_API_SECRET)
    $r = $r.Replace('{{FQDN}}',               $FQDN)
    $r = $r.Replace('{{FQDN_HOST}}',          $FQDN_HOST)
    $r = $r.Replace('{{NPM_REGISTRY_URL}}',   $NPM_REGISTRY_URL)
    $r = $r.Replace('{{NPM_REGISTRY_HOST}}',  $NPM_REGISTRY_HOST)
    $r = $r.Replace('{{PYPI_URL}}',           $PYPI_URL)
    $r = $r.Replace('{{TRUSTED_HOST}}',       $TRUSTED_HOST)
    $r = $r.Replace('{{MAVEN_REGISTRY_URL}}', $MAVEN_REGISTRY_URL)
    $r
}

# Get-BlockAssignment <varname> <filepath>
# Reads a block file, applies substitutions, and emits a PowerShell single-quoted
# here-string assignment. Single-quoted delimiter leaves ${ENDOR_VAR} refs
# literal in the output file -- tools expand them at runtime from process env vars.
function Get-BlockAssignment {
    param([string]$VarName, [string]$FilePath)
    $raw         = Get-Content $FilePath -Raw -Encoding UTF8
    $substituted = (Invoke-Substitute $raw).TrimEnd()
    # Backtick-dollar produces a literal '$' in the output string
    "`$$VarName = @'`n$substituted`n'@`n"
}

function Get-AllBlocks {
    (
        '# -- Block content (from shared/blocks/) --',
        (Get-BlockAssignment 'NPMRC_BLOCK'          (Join-Path $SharedBlocksDir 'npmrc.txt')),
        (Get-BlockAssignment 'YARNRC_CLASSIC_BLOCK' (Join-Path $SharedBlocksDir 'yarnrc_classic.txt')),
        (Get-BlockAssignment 'YARNRC_BLOCK'         (Join-Path $SharedBlocksDir 'yarnrc.txt')),
        (Get-BlockAssignment 'PIP_BLOCK'            (Join-Path $SharedBlocksDir 'pipconf.txt')),
        (Get-BlockAssignment 'UV_BLOCK'             (Join-Path $SharedBlocksDir 'uvtoml.txt')),
        (Get-BlockAssignment 'GO_BLOCK'             (Join-Path $SharedBlocksDir 'goenv.txt')),
        (Get-BlockAssignment 'MAVEN_BLOCK'          (Join-Path $SharedBlocksDir 'mavensettings.txt')),
        '# --',
        ''
    ) -join "`n"
}

# Get-ScriptHeader <scriptname> <description>
# Reads script-header.ps1 template, substitutes {{...}} values, and inserts
# the inlined common.ps1 content at {{COMMON_CONTENT}}.
function Get-ScriptHeader {
    param([string]$ScriptName, [string]$Description)
    $tpl    = Get-Content (Join-Path $TmplDir 'script-header.ps1') -Raw -Encoding UTF8
    $common = Get-Content (Join-Path $LibDir  'common.ps1')        -Raw -Encoding UTF8
    $r = Invoke-Substitute $tpl
    $r = $r.Replace('{{DESCRIPTION}}',    $Description)
    $r = $r.Replace('{{SCRIPTNAME}}',     $ScriptName)
    $r = $r.Replace('{{COMMON_CONTENT}}', $common)
    $r
}

# Warning footer appended to install scripts (MDM alert hook, mirrors bash).
$ScriptFooter = @'

# -- Exit non-zero if any warnings were emitted (MDM alert hook) --
if ($EndorWarned) {
    Write-Host ''
    Write-Warning '[endor] Script completed with warnings -- review output above.'
    exit 1
}
'@

# Build-Script <template> <outputpath> <description>
function Build-Script {
    param([string]$Template, [string]$OutputPath, [string]$Description)
    $name   = Split-Path $OutputPath -Leaf
    $parts  = @(
        (Get-ScriptHeader -ScriptName $name -Description $Description),
        (Get-AllBlocks),
        '# == Env vars setup =====================================================',
        (Invoke-Substitute (Get-Content (Join-Path $TmplDir 'envvars.ps1') -Raw -Encoding UTF8)),
        '',
        (Invoke-Substitute (Get-Content $Template -Raw -Encoding UTF8)),
        $ScriptFooter
    )
    Set-Content -Path $OutputPath -Value ($parts -join "`n") -Encoding UTF8
}

# Build-RemoveScript <outputpath>
# Remove script needs no block variables — skips Get-AllBlocks and env vars setup.
function Build-RemoveScript {
    param([string]$OutputPath)
    $name  = Split-Path $OutputPath -Leaf
    $parts = @(
        (Get-ScriptHeader -ScriptName $name -Description 'Removes Endor Package Firewall configuration from all managed files and registry env vars.'),
        (Invoke-Substitute (Get-Content (Join-Path $TmplDir 'remove.ps1') -Raw -Encoding UTF8))
    )
    Set-Content -Path $OutputPath -Value ($parts -join "`n") -Encoding UTF8
}

# -- Generate per-ecosystem install scripts ------------------------------------
Build-Script `
    (Join-Path $TmplDir 'js.ps1') `
    (Join-Path $OutDir  'endor-js.ps1') `
    'Configures JavaScript package managers (npm, pnpm, yarn, bun) for Endor Package Firewall.'

Build-Script `
    (Join-Path $TmplDir 'python.ps1') `
    (Join-Path $OutDir  'endor-python.ps1') `
    'Configures Python package managers (pip, uv, poetry) for Endor Package Firewall.'

Build-Script `
    (Join-Path $TmplDir 'go.ps1') `
    (Join-Path $OutDir  'endor-go.ps1') `
    'Configures Go modules (GOPROXY) for Endor Package Firewall.'

Build-Script `
    (Join-Path $TmplDir 'maven.ps1') `
    (Join-Path $OutDir  'endor-maven.ps1') `
    'Configures Maven (~\.m2\settings.xml) for Endor Package Firewall.'

# -- Generate remove script ----------------------------------------------------
Build-RemoveScript (Join-Path $OutDir 'endor-remove.ps1')

# -- Generate combined all.ps1 -------------------------------------------------
$_allName  = 'endor-all.ps1'
$_allParts = @(
    (Get-ScriptHeader -ScriptName $_allName -Description 'Configures all package managers for Endor Package Firewall. Covers: npm . pnpm . yarn classic . yarn 2+ . bun . pip . uv . poetry . go . maven'),
    (Get-AllBlocks),
    '# == Env vars setup =====================================================',
    (Invoke-Substitute (Get-Content (Join-Path $TmplDir 'envvars.ps1') -Raw -Encoding UTF8)),
    '',
    '# == JavaScript =========================================================',
    (Invoke-Substitute (Get-Content (Join-Path $TmplDir 'js.ps1') -Raw -Encoding UTF8)),
    '',
    '# == Python =============================================================',
    (Invoke-Substitute (Get-Content (Join-Path $TmplDir 'python.ps1') -Raw -Encoding UTF8)),
    '',
    '# == Go =================================================================',
    (Invoke-Substitute (Get-Content (Join-Path $TmplDir 'go.ps1') -Raw -Encoding UTF8)),
    '',
    '# == Maven ==============================================================',
    (Invoke-Substitute (Get-Content (Join-Path $TmplDir 'maven.ps1') -Raw -Encoding UTF8)),
    '',
    "Write-Host ''",
    "Write-Host '[endor] [done] All package managers configured for $ENDOR_NAMESPACE (js + python + go + maven).'",
    $ScriptFooter
)
Set-Content -Path (Join-Path $OutDir $_allName) -Value ($_allParts -join "`n") -Encoding UTF8
Remove-Variable -Name _allName, _allParts

# -- Summary -------------------------------------------------------------------
Write-Host ''
Write-Host "OK  Generated -> $OutDir"
Write-Host ''
Write-Host ('   {0,-24}  {1}' -f 'endor-js.ps1',     'npm . pnpm . yarn classic . yarn 2+ . bun')
Write-Host ('   {0,-24}  {1}' -f 'endor-python.ps1', 'pip . uv . poetry')
Write-Host ('   {0,-24}  {1}' -f 'endor-go.ps1',     'go modules (GOPROXY)')
Write-Host ('   {0,-24}  {1}' -f 'endor-maven.ps1',  'maven (~\.m2\settings.xml)')
Write-Host ('   {0,-24}  {1}' -f 'endor-all.ps1',    'all of the above (single-script deploy)')
Write-Host ('   {0,-24}  {1}' -f 'endor-remove.ps1', 'offboarding -- strips all Endor config + registry env vars')
Write-Host ''
Write-Host '   All scripts accept -DryRun to preview changes without writing anything.'
Write-Host '   Upload to your MDM tool (Intune). Each script is self-contained and idempotent.'
Write-Host ''
Write-Host '   To customise: edit shared/blocks/*.txt (shared config content)'
Write-Host '                 or templates/*.ps1 (orchestration logic)'
Write-Host ''
Write-Host '   Re-running overwrites the same output directory.'
