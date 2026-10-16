# templates/ruby.ps1
# Ruby ecosystem -- Bundler (bundle install . add . update . lock) and the gem CLI
# (gem install . update . fetch)
#
# Bundler -- %USERPROFILE%\.bundle\config, Bundler's global config, read by every
# Ruby on the machine (RubyInstaller, uru, ...). Block: shared/blocks/bundleconfig.txt.
# Mechanism: a Bundler *mirror*. `mirror.https://rubygems.org/` sends every
# request a Gemfile makes to rubygems.org to the firewall instead, so Gemfile
# and Gemfile.lock stay untouched (the lock keeps `remote: https://rubygems.org/`)
# and private `source "..." do` blocks are not redirected. The bare-host key
# `mirror.rubygems.org` also catches http:// spellings. Credentials are NOT in
# this file: Bundler reads any BUNDLE_* environment variable as a setting, so
# envvars.ps1 writes BUNDLE_<FIREWALL_HOST>="user:password" to HKCU:\Environment
# and Bundler applies it to every request to that host -- inherited by IDEs,
# terminals and build scripts alike (same model as npm / maven / nuget).
#
# gem -- %USERPROFILE%\.gemrc, read by every Ruby. Block: shared/blocks/gemrc.txt.
# gem queries EVERY url in :sources:, so the user's sources are replaced by the
# firewall (the file is backed up verbatim to .gemrc.endor-bak and restored on
# removal). The credential is literal in the source url: gemrc has no env var
# expansion and RubyGems has no other credential channel for downloads (same as
# pip). No root copy on Windows: an elevated PowerShell keeps the user's
# USERPROFILE, so there is no `sudo gem install` case to cover.

Write-Host '[endor-ruby] -- Ruby / Bundler ----------------------------------------------'

$_bundleConfig = Join-Path $UserHome '.bundle\config'

# A pre-existing rubygems.org mirror or mirror.all means the machine already
# routes through a registry -- warn the admin (our keys still go in last).
Test-BundleMirrorConflict -FilePath $_bundleConfig -MirrorUrl '{{GEM_MIRROR_URL}}'

Invoke-UpsertBundleConfig -FilePath $_bundleConfig -Content $BUNDLE_BLOCK -Username $ConsoleUser -DryRun:$DryRun

Write-Host "[endor-ruby] bundle config -> $_bundleConfig"
Write-Host '[endor-ruby]    mirror: https://rubygems.org -> {{GEM_MIRROR_URL}}'
Write-Host '[endor-ruby]   covers: bundler (every Ruby version)'
Write-Host '[endor-ruby]   credentials: HKCU env var BUNDLE_{{BUNDLE_HOST_KEY}} (written above)'
Remove-Variable _bundleConfig

Write-Host ''
Write-Host '[endor-ruby] -- Ruby / gem --------------------------------------------------'

# The attributed source url is filled at install time (literal credentials, like pip).
$GEMRC_BLOCK = $GEMRC_BLOCK.Replace('{{GEM_SOURCE_URL}}', $ENDOR_GEM_SOURCE_URL)

$_gemrc    = Join-Path $UserHome '.gemrc'
$_gemrcXdg = Join-Path $UserHome '.config\gem\gemrc'

# Command defaults that add sources (gem: --source ...) bypass :sources:; check the
# user files and each Ruby's system-wide gemrc (never edited, only reported).
# RubyInstaller puts gem.cmd under <drive>:\RubyXX-x64\bin; PATH may also have one.
$_gemExes = @()
$_onPath = Get-Command gem -ErrorAction SilentlyContinue | Select-Object -First 1
if ($_onPath) { $_gemExes += $_onPath.Source }
if ($env:SystemDrive) {
    $_gemExes += @(Get-ChildItem -Path (Join-Path $env:SystemDrive 'Ruby*\bin\gem.cmd') -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
$_gemrcSys = @()
foreach ($_exe in ($_gemExes | Select-Object -Unique)) {
    try {
        $_dir = @(& $_exe env 2>$null | Where-Object { $_ -match 'SYSTEM CONFIGURATION DIRECTORY:\s*(.+)$' } | ForEach-Object { $Matches[1].Trim() }) | Select-Object -First 1
        if ($_dir) { $_gemrcSys += (Join-Path $_dir 'gemrc') }
    } catch { $_dir = $null }   # a gem that cannot run (shim without its Ruby) is simply not checked
}
Test-GemrcSourceOverride -FilePaths (@($_gemrc, $_gemrcXdg) + $_gemrcSys)
Remove-Variable _gemExes, _onPath, _gemrcSys -ErrorAction SilentlyContinue
Remove-Variable _exe, _dir -ErrorAction SilentlyContinue

Invoke-UpsertGemrc -FilePath $_gemrc -XdgFile $_gemrcXdg -Content $GEMRC_BLOCK -MirrorUrl '{{GEM_MIRROR_URL}}' -Username $ConsoleUser -DryRun:$DryRun

Write-Host "[endor-ruby] gemrc         -> $_gemrc"
Write-Host '[endor-ruby]    source: {{GEM_MIRROR_URL}} (the only source; credentials literal in the url)'
Write-Host '[endor-ruby]   covers: gem install / update / fetch (every Ruby version)'
Write-Host '[endor-ruby] [done] Ruby done'
Remove-Variable _gemrc, _gemrcXdg
