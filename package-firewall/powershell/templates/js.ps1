# templates/js.ps1
# JavaScript ecosystem -- npm . pnpm . yarn classic . yarn 2+ (berry) . bun
#
# Config files written to the console user's profile:
#   %USERPROFILE%\.npmrc          npm (all), pnpm (8+), yarn classic (1.x), bun
#   %USERPROFILE%\.yarnrc         yarn classic (1.x) registry redirect
#   %USERPROFILE%\.yarnrc.yml     yarn 2+ / berry (does NOT read .npmrc for registry)
#
# Auth note: .npmrc uses _auth, username, _password (attributed-user credentials).
#   _authToken causes 401 with bun. _auth is verified working for all tools above.
#
# Yarn classic reads .npmrc for auth and .yarnrc for registry -- both written here.
# Yarn 2+ does NOT read .npmrc -- .yarnrc.yml handles both registry and auth.
# Bun on Windows reads .npmrc for both registry and auth -- covered by .npmrc write.
#
# Registry env vars (ENDOR_NPM_REGISTRY_URL, ENDOR_AUTH_B64, etc.) are set in
# HKCU:\Environment by the env vars step above and are available to all processes.

Write-Host '[endor-js] -- JavaScript package managers --------------------------------'

# -- .npmrc --
# Covers: npm (all versions), pnpm (8.x-11.x), yarn classic (1.x), bun (auth)
Test-KeyConflict `
    -FilePath (Join-Path $UserHome '.npmrc') `
    -Pattern  '^registry=' `
    -Label    'registry'

Invoke-UpsertBlock `
    -FilePath  (Join-Path $UserHome '.npmrc') `
    -Content   $NPMRC_BLOCK `
    -Username  $ConsoleUser `
    -DryRun:$DryRun

Write-Host "[endor-js] .npmrc        -> $(Join-Path $UserHome '.npmrc')"
Write-Host '[endor-js]   covers: npm, pnpm, yarn classic (auth), bun'

# -- .yarnrc --
# Covers: yarn classic (1.x) -- registry redirect; auth comes from .npmrc above
Test-KeyConflict `
    -FilePath (Join-Path $UserHome '.yarnrc') `
    -Pattern  '^registry ' `
    -Label    'registry'

Invoke-UpsertBlock `
    -FilePath  (Join-Path $UserHome '.yarnrc') `
    -Content   $YARNRC_CLASSIC_BLOCK `
    -Username  $ConsoleUser `
    -DryRun:$DryRun

Write-Host "[endor-js] .yarnrc       -> $(Join-Path $UserHome '.yarnrc')"
Write-Host '[endor-js]   covers: yarn classic (1.x)'

# -- .yarnrc.yml --
# Covers: yarn 2+ / berry (v3.1+ for user-level config; per-project for earlier)
Test-KeyConflict `
    -FilePath (Join-Path $UserHome '.yarnrc.yml') `
    -Pattern  '^npmRegistryServer:' `
    -Label    'npmRegistryServer'

Invoke-UpsertBlock `
    -FilePath  (Join-Path $UserHome '.yarnrc.yml') `
    -Content   $YARNRC_BLOCK `
    -Username  $ConsoleUser `
    -DryRun:$DryRun

Write-Host "[endor-js] .yarnrc.yml   -> $(Join-Path $UserHome '.yarnrc.yml')"
Write-Host '[endor-js]   covers: yarn 2+ (berry v3.1+)'
Write-Host '[endor-js] [done] JavaScript done'
