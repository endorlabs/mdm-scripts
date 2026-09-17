# templates/nuget.ps1
# .NET / NuGet ecosystem -- dotnet CLI . NuGet CLI . Visual Studio . Rider
#
# Config file: %APPDATA%\NuGet\NuGet.Config (read by every NuGet-based tool).
# Blocks come from shared/blocks/nugetconfig_*.txt. Credentials are env var
# refs (%ENDOR_ATTR_USER% / %ENDOR_API_SECRET%) resolved by NuGet from the
# HKCU:\Environment values written in envvars.ps1 -- inherited by Visual Studio,
# Rider, IDE terminals, build scripts and scheduled tasks alike.
#
# NuGet queries every enabled source with no priority, so ours must be the only
# public one: the block's <clear /> supersedes everything above it (nuget.org
# included). NuGet reads only the first <packageSources> section per file, so
# the block is merged INTO the existing section -- see Invoke-UpsertNuGetBlock.

Write-Host '[endor-nuget] -- NuGet / .NET ---------------------------------------------'

# Optional: use {{ATTR_USER}} in nugetconfig_credentials.txt to bake literals.
$NUGET_CREDENTIALS_BLOCK = $NUGET_CREDENTIALS_BLOCK.Replace('{{ATTR_USER}}', $ENDOR_ATTR_USER)

$nugetConfig = Join-Path $AppData 'NuGet\NuGet.Config'

# Private feeds outside the block are superseded by <clear /> -- warn the admin.
Test-NuGetSourceConflict -FilePath $nugetConfig

Invoke-UpsertNuGetBlock -FilePath $nugetConfig -Section 'packageSources'           -Content $NUGET_SOURCES_BLOCK     -Username $ConsoleUser -DryRun:$DryRun
Invoke-UpsertNuGetBlock -FilePath $nugetConfig -Section 'packageSourceCredentials' -Content $NUGET_CREDENTIALS_BLOCK -Username $ConsoleUser -DryRun:$DryRun

# Only when the user already maps packages to sources: a mapping that never
# names endor-firewall would resolve nothing from it.
if ((Test-Path $nugetConfig) -and ((Get-Content $nugetConfig -Raw -Encoding UTF8) -match '<packageSourceMapping')) {
    Invoke-UpsertNuGetBlock -FilePath $nugetConfig -Section 'packageSourceMapping' -Content $NUGET_SOURCEMAPPING_BLOCK -Username $ConsoleUser -DryRun:$DryRun
}

Write-Host "[endor-nuget] NuGet.Config  -> $nugetConfig"
Write-Host '[endor-nuget]   source: {{NUGET_SOURCE_URL}} (replaces nuget.org via <clear />; credentials via HKCU env vars)'
Write-Host '[endor-nuget] [done] NuGet done'
