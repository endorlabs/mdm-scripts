# templates/maven.ps1
# Java / Maven ecosystem
#
# Config file written to the console user's Maven user-settings:
#   %USERPROFILE%\.m2\settings.xml
#
# Block content is defined in shared/blocks/mavensettings.txt.
# {{MAVEN_REGISTRY_URL}} is substituted at generation time. Credentials are NOT
# baked in -- settings.xml references ${env.ENDOR_ATTR_USER} / ${env.ENDOR_API_SECRET},
# which Maven expands at runtime from the env vars already set in HKCU:\Environment.

Write-Host '[endor-maven] -- Maven ----------------------------------------------------'

$mavenSettings = Join-Path $UserHome '.m2\settings.xml'

# Our <server> merges into any existing <servers> with no conflict (servers are
# keyed by id). A pre-existing <mirror> is a precedence consideration: Maven uses
# the FIRST matching mirror, so the Endor firewall mirror is ALWAYS inserted first
# to win. When a foreign mirror is present we warn (for admin awareness) but
# proceed unconditionally -- the firewall must be active.
if (Test-XmlForeignMirror -FilePath $mavenSettings) {
    Write-Warning "[endor-maven] an existing <mirror> is defined in $mavenSettings."
    Write-Warning '[endor-maven]   Maven uses the first matching <mirror>; the Endor firewall mirror'
    Write-Warning '[endor-maven]   will be inserted FIRST so it takes precedence. Your existing mirror'
    Write-Warning '[endor-maven]   is preserved but shadowed for repos the Endor catch-all (mirrorOf=*) covers.'
    $script:EndorWarned = $true
}

Invoke-UpsertXmlBlock `
    -FilePath $mavenSettings `
    -Content  $MAVEN_BLOCK `
    -Username $ConsoleUser `
    -DryRun:$DryRun

Write-Host "[endor-maven] settings.xml  -> $mavenSettings"
Write-Host '[endor-maven]   covers: maven (all versions), and Gradle when it reads ~/.m2'
Write-Host '[endor-maven]   mirror: {{MAVEN_REGISTRY_URL}} (mirrorOf=*)'
Write-Host '[endor-maven]   NOTE: credentials come from env vars (ENDOR_ATTR_USER/API_SECRET).'
Write-Host '[endor-maven] [done] Maven done'
