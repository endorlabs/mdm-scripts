# templates/maven.ps1
# Java / Maven ecosystem
#
# Config file written to the console user's Maven user-settings:
#   %USERPROFILE%\.m2\settings.xml
#
# Block content is defined in shared/blocks/mavensettings.txt.
# {{MAVEN_REGISTRY_URL}} is substituted at generation time. Credentials are NOT
# baked in -- settings.xml references ${env.ENDOR_API_KEY_ID} / ${env.ENDOR_API_SECRET},
# which Maven expands at runtime from the env vars already set in HKCU:\Environment.

Write-Host '[endor-maven] -- Maven ----------------------------------------------------'

$mavenSettings = Join-Path $UserHome '.m2\settings.xml'

# Warn if the admin already defines a mirror outside an Endor block --
# Maven mirror precedence could conflict and needs a human decision.
Test-KeyConflict `
    -FilePath $mavenSettings `
    -Pattern  '<mirror>' `
    -Label    'existing <mirror> (Maven)'

Invoke-UpsertXmlBlock `
    -FilePath $mavenSettings `
    -Content  $MAVEN_BLOCK `
    -Username $ConsoleUser `
    -DryRun:$DryRun

Write-Host "[endor-maven] settings.xml  -> $mavenSettings"
Write-Host '[endor-maven]   covers: maven (all versions), and Gradle when it reads ~/.m2'
Write-Host '[endor-maven]   mirror: {{MAVEN_REGISTRY_URL}} (mirrorOf=*)'
Write-Host '[endor-maven]   NOTE: credentials come from env vars (ENDOR_API_KEY_ID/SECRET).'
Write-Host '[endor-maven] [done] Maven done'
