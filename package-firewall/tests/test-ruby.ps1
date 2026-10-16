# Drives the Bundler (.bundle\config) and gem (.gemrc) helpers from lib/common.ps1
# against fixture files (the generated installer itself needs SYSTEM / console-user
# detection and registry writes), then checks the generator wires Ruby in.
# `bundle config get --parseable` (Bundler >= 2) and `gem sources -l` validate what
# the tools actually resolve when they are installed.
# Mirrors tests/test-bundler.sh and tests/test-gem.sh case for case.
$ErrorActionPreference = 'Stop'

$TestDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$PfDir       = (Resolve-Path (Join-Path $TestDir '..')).Path
$MirrorUrl   = 'https://factory.endorlabs.com/v1/namespaces/ci-smoke/firewall/gem/'
$HostKey     = 'FACTORY__ENDORLABS__COM'
$Creds       = 'dXNlcg%3D%3D:c2VjcmV0%2B%2F%3D'
$SourceUrl   = "https://$Creds@factory.endorlabs.com/v1/namespaces/ci-smoke/firewall/gem/"
$CorpUrl     = 'https://artifactory.example.com/api/gems/rubygems/'
$CorpGemUrl  = 'https://deploy:s3cret@gems.corp.example.com/'
$RubyGemsUrl = 'https://rubygems.org/'
$TempDir     = Join-Path ([IO.Path]::GetTempPath()) "endor-ruby-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $TempDir | Out-Null

$EndorWarned = $false
. (Join-Path $PfDir 'powershell/lib/common.ps1')
$Owner = if ($env:USERNAME) { $env:USERNAME } else { $env:USER }

$BundleBlock = (Get-Content (Join-Path $PfDir 'shared/blocks/bundleconfig.txt') -Raw -Encoding UTF8).Replace('{{GEM_MIRROR_URL}}', $MirrorUrl).TrimEnd()
$GemrcBlock  = (Get-Content (Join-Path $PfDir 'shared/blocks/gemrc.txt')        -Raw -Encoding UTF8).Replace('{{GEM_SOURCE_URL}}', $SourceUrl).TrimEnd()

$HaveBundle = $false
if (Get-Command bundle -ErrorAction SilentlyContinue) {
    $major = ((& bundle --version 2>$null) | Out-String) -replace '(?s)[^0-9]*([0-9]+).*', '$1'
    if ($major -match '^\d+$' -and [int]$major -ge 2) { $HaveBundle = $true }
}
$Gems = @()
$onPath = Get-Command gem -ErrorAction SilentlyContinue | Select-Object -First 1
if ($onPath) { $Gems += $onPath.Source }
if ((Test-Path '/usr/bin/gem') -and ($Gems -notcontains '/usr/bin/gem')) { $Gems += '/usr/bin/gem' }

function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw "ASSERT: $Message" } }
function Get-Sha      { param([string]$File) (Get-FileHash -Algorithm SHA256 -LiteralPath $File).Hash }
function Get-Markers  { param([string]$File) @(Get-Content -LiteralPath $File -Encoding UTF8 | Where-Object { $_ -eq $ENDOR_BLOCK_START }).Count }
function Get-KeyCount { param([string]$File, [string]$Key) @(Get-Content -LiteralPath $File -Encoding UTF8 | Where-Object { $_.StartsWith("${Key}: ") }).Count }
# Line-ending agnostic: Write-EndorFile uses the platform newline (CRLF on Windows) while the
# fixtures are written with LF, and Bundler/RubyGems accept either.
function Get-Text     { param([string]$File) (Get-Content -LiteralPath $File -Raw -Encoding UTF8).Replace("`r`n", "`n") }
function Test-SameContent { param([string]$A, [string]$B) (Get-Text $A) -eq (Get-Text $B) }
function Write-Fixture {
    param([string]$File, [string]$Content)
    New-Item -ItemType Directory -Path (Split-Path $File) -Force | Out-Null
    [System.IO.File]::WriteAllText($File, $Content.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
}
# Invoke-WithEnv <hashtable> <scriptblock> -- runs the block with env vars set ($null = removed), then restores them
function Invoke-WithEnv {
    param([hashtable]$Vars, [scriptblock]$Body)
    $saved = @{}
    foreach ($n in $Vars.Keys) {
        $saved[$n] = [Environment]::GetEnvironmentVariable($n)
        if ($null -eq $Vars[$n]) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue } else { Set-Item "Env:$n" $Vars[$n] }
    }
    try { & $Body } finally {
        foreach ($n in $saved.Keys) {
            if ($null -eq $saved[$n]) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue } else { Set-Item "Env:$n" $saved[$n] }
        }
    }
}
# Get-BundleSetting <file> <setting> [<extra env>] -- what Bundler resolves with <file> as its global config
function Get-BundleSetting {
    param([string]$File, [string]$Setting, [hashtable]$Env = @{})
    $vars = @{ BUNDLE_USER_CONFIG = $File; BUNDLE_DISABLE_VERSION_CHECK = '1'; BUNDLE_IGNORE_CONFIG = $null }
    foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
    Invoke-WithEnv $vars {
        Push-Location $TempDir
        try {
            $out = @(& bundle config get $Setting --parseable 2>$null)
            @($out | Where-Object { $_.StartsWith("$Setting=") } | ForEach-Object { $_.Substring($Setting.Length + 1) })[0]
        } finally { Pop-Location }
    }
}
function Assert-BundleSetting {
    param([string]$File, [string]$Setting, [string]$Expected)
    if (-not $HaveBundle) { return }
    $got = Get-BundleSetting $File $Setting
    Assert ($got -eq $Expected) "bundle resolves $Setting to '$got', expected '$Expected'"
}
# Assert-GemSources <home> <url>... -- the sources every available gem resolves from that home
function Assert-GemSources {
    param([string]$HomeDir, [string[]]$Expected)
    $exp = @($Expected | Sort-Object) -join ' '
    foreach ($g in $Gems) {
        $got = Invoke-WithEnv @{ HOME = $HomeDir; GEMRC = $null } {
            Push-Location $TempDir
            try { @(& $g sources -l 2>$null | Where-Object { $_ -like 'http*' } | Sort-Object) -join ' ' } finally { Pop-Location }
        }
        Assert ($got -eq $exp) "$g resolves '$got', expected '$exp' (HOME=$HomeDir)"
    }
}

# Mirror templates/ruby.ps1 and templates/remove.ps1. Warnings (3>) are dropped where noted: Set-FileRestrictedAcl warns on non-Windows.
function Invoke-BundleApply  { param([string]$File, [switch]$DryRun) Invoke-UpsertBundleConfig -FilePath $File -Content $BundleBlock -Username $Owner -DryRun:$DryRun 3>$null }
function Invoke-BundleRemove { param([string]$File, [switch]$DryRun) Remove-BundleConfig -FilePath $File -MirrorUrl $MirrorUrl -DryRun:$DryRun }
function Invoke-GemApply     { param([string]$HomeDir, [switch]$DryRun) Invoke-UpsertGemrc -FilePath (Join-Path $HomeDir '.gemrc') -XdgFile (Join-Path $HomeDir '.config/gem/gemrc') -Content $GemrcBlock -MirrorUrl $MirrorUrl -Username $Owner -DryRun:$DryRun }
function Invoke-GemRemove    { param([string]$HomeDir, [switch]$DryRun) Remove-Gemrc -FilePath (Join-Path $HomeDir '.gemrc') -MirrorUrl $MirrorUrl -DryRun:$DryRun }

# ===================================================================== Bundler
Write-Host "test: bundler -- fresh machine: created, idempotent, dry-run inert, no secret in the file, removal deletes (bundler: $(if ($HaveBundle) { 'on' } else { 'skipped' }))"
$f = Join-Path $TempDir 'fresh/.bundle/config'
Invoke-BundleApply $f
$lines = @(Get-Content $f)
Assert ($lines[0] -eq '---') 'missing --- header'
Assert ((Get-Markers $f) -eq 1) 'expected one block'
Assert ((Get-KeyCount $f 'BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/') -eq 1 -and (Get-KeyCount $f 'BUNDLE_MIRROR__RUBYGEMS__ORG') -eq 1) 'mirror keys missing'
Assert (-not (Get-Text $f).Contains("BUNDLE_$HostKey")) 'credential must not be in the file'
Assert-BundleSetting $f 'mirror.https://rubygems.org/' $MirrorUrl
Assert-BundleSetting $f 'mirror.rubygems.org' $MirrorUrl
$before = Get-Sha $f; Invoke-BundleApply $f; Assert ((Get-Sha $f) -eq $before) 'not idempotent'
Invoke-BundleApply $f -DryRun | Out-Null; Assert ((Get-Sha $f) -eq $before) 'dry-run wrote'
$out = Invoke-BundleRemove $f 6>&1 | Out-String; Assert (($out -match 'deleted \(was empty\)') -and -not (Test-Path $f)) 'Endor-only file not deleted'
$out = Invoke-BundleRemove $f 6>&1 | Out-String; Assert ($out -match 'skip \(not found\)') 'second removal not a no-op'
Invoke-BundleApply $f; Assert ((Get-Markers $f) -eq 1) 're-install after removal'

Write-Host 'test: bundler -- credential via environment (the HKCU model) is what Bundler applies to the firewall host'
if ($HaveBundle) {
    $got = Get-BundleSetting $f 'factory.endorlabs.com' @{ "BUNDLE_$HostKey" = $Creds }
    Assert ($got -eq $Creds) "env credential not applied: '$got'"
}

Write-Host 'test: bundler -- existing config: other keys preserved, removal restores the original byte-for-byte'
$f = Join-Path $TempDir 'existing/.bundle/config'
Write-Fixture $f "---`nBUNDLE_JOBS: `"4`"`nBUNDLE_PATH: `"vendor/bundle`"`n"; Copy-Item $f "$f.orig"
Invoke-BundleApply $f; Assert ((Get-Markers $f) -eq 1) 'expected one block'
$t = Get-Text $f; Assert ($t.Contains('BUNDLE_JOBS: "4"') -and $t.Contains('BUNDLE_PATH: "vendor/bundle"')) 'user keys lost'
Assert-BundleSetting $f 'mirror.https://rubygems.org/' $MirrorUrl; Assert-BundleSetting $f 'jobs' '4'
$out = Invoke-BundleRemove $f 6>&1 | Out-String; Assert ($out -match 'block removed') 'block not removed'
Assert (Test-SameContent $f "$f.orig") 'original not restored'
$out = Invoke-BundleRemove $f 6>&1 | Out-String; Assert ($out -match 'skip \(no Endor block\)') 'second removal not a no-op'

Write-Host 'test: bundler -- existing file without a trailing newline: block starts on its own line'
$f = Join-Path $TempDir 'nonl/.bundle/config'
Write-Fixture $f "---`nBUNDLE_JOBS: `"4`""
Invoke-BundleApply $f
$lines = @(Get-Content $f); Assert (($lines -contains 'BUNDLE_JOBS: "4"') -and ($lines -contains $ENDOR_BLOCK_START)) 'block glued to last line'

Write-Host "test: bundler -- file rewritten by 'bundle config' (keys kept, sentinels gone): one copy of each key after re-run"
$f = Join-Path $TempDir 'rewritten/.bundle/config'
Write-Fixture $f "---`nBUNDLE_JOBS: `"4`"`nBUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: `"$MirrorUrl`"`nBUNDLE_MIRROR__RUBYGEMS__ORG: `"$MirrorUrl`"`n"; Copy-Item $f "$f.orig"
$out = Invoke-BundleApply $f -DryRun 6>&1 | Out-String; Assert ($out -match '2 stale Endor line') 'dry-run should report stale lines'
Assert (Test-SameContent $f "$f.orig") 'dry-run wrote'
$out = Invoke-BundleApply $f 6>&1 | Out-String; Assert ($out -match '2 stale Endor line') 'stale lines not reported'
Assert ((Get-Markers $f) -eq 1 -and (Get-KeyCount $f 'BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/') -eq 1 -and (Get-KeyCount $f 'BUNDLE_MIRROR__RUBYGEMS__ORG') -eq 1) 'keys duplicated'
Assert-BundleSetting $f 'mirror.https://rubygems.org/' $MirrorUrl
Copy-Item "$f.orig" $f -Force                                        # removal with no sentinels at all
$out = Invoke-BundleRemove $f 6>&1 | Out-String; Assert ($out -match 'block removed') 'stale lines not removed'
Assert ((Get-KeyCount $f 'BUNDLE_MIRROR__RUBYGEMS__ORG') -eq 0 -and (Get-Text $f).Contains('BUNDLE_JOBS: "4"')) 'removal wrong'

Write-Host "test: bundler -- real 'bundle config set --global' rewrite, then re-run (bundler: $(if ($HaveBundle) { 'on' } else { 'skipped' }))"
if ($HaveBundle) {
    $f = Join-Path $TempDir 'real/.bundle/config'; Invoke-BundleApply $f
    Invoke-WithEnv @{ BUNDLE_USER_CONFIG = $f; BUNDLE_DISABLE_VERSION_CHECK = '1' } { Push-Location $TempDir; try { & bundle config set --global timeout 20 *> $null } finally { Pop-Location } }
    Assert ((Get-Markers $f) -eq 0) 'Bundler should have dropped the sentinels'
    Invoke-BundleApply $f | Out-Null; Assert ((Get-Markers $f) -eq 1) 'block not re-added'
    Assert ((Get-KeyCount $f 'BUNDLE_MIRROR__RUBYGEMS__ORG') -eq 1 -and (Get-Text $f).Contains('BUNDLE_TIMEOUT: "20"')) 'duplicate or lost key'
    Assert-BundleSetting $f 'mirror.https://rubygems.org/' $MirrorUrl; Assert-BundleSetting $f 'timeout' '20'
    Invoke-BundleRemove $f | Out-Null; Assert ((Get-Text $f).Contains('BUNDLE_TIMEOUT: "20"') -and (Get-Markers $f) -eq 0) 'user key lost on removal'
}

Write-Host 'test: bundler -- pre-existing rubygems.org mirror (registry): warning fires, Endor key wins, restored on removal'
$f = Join-Path $TempDir 'registry/.bundle/config'
Write-Fixture $f "---`nBUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: `"$CorpUrl`"`n"; Copy-Item $f "$f.orig"
$EndorWarned = $false; Test-BundleMirrorConflict -FilePath $f -MirrorUrl $MirrorUrl 3>$null; Assert $EndorWarned 'registry mirror should warn'
Invoke-BundleApply $f; Assert ((Get-Text $f).Contains($CorpUrl)) "user's line removed"
Assert-BundleSetting $f 'mirror.https://rubygems.org/' $MirrorUrl                                # last key wins
$EndorWarned = $false; Test-BundleMirrorConflict -FilePath $f -MirrorUrl $MirrorUrl 3>$null; Assert $EndorWarned 'warning should persist on re-run'
$EndorWarned = $false
Invoke-BundleRemove $f | Out-Null; Assert (Test-SameContent $f "$f.orig") 'original not restored'
Assert-BundleSetting $f 'mirror.https://rubygems.org/' $CorpUrl

Write-Host "test: bundler -- mirror.all: warning names it; the user's key is kept"
$f = Join-Path $TempDir 'all/.bundle/config'
Write-Fixture $f "---`nBUNDLE_MIRROR__ALL: `"$CorpUrl`"`n"; Copy-Item $f "$f.orig"
$EndorWarned = $false; $w = Test-BundleMirrorConflict -FilePath $f -MirrorUrl $MirrorUrl 3>&1 | Out-String
Assert ($EndorWarned -and $w -match 'mirror\.all') 'mirror.all should warn by name'
$EndorWarned = $false
Invoke-BundleApply $f; Assert ((Get-Text $f).Contains('BUNDLE_MIRROR__ALL')) 'mirror.all removed'
Invoke-BundleRemove $f | Out-Null; Assert (Test-SameContent $f "$f.orig") 'original not restored'

Write-Host 'test: bundler -- our own keys and unrelated keys raise no warning'
$f = Join-Path $TempDir 'clean/.bundle/config'
Write-Fixture $f "---`nBUNDLE_JOBS: `"4`"`nBUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: `"$MirrorUrl`"`n"
$EndorWarned = $false; Test-BundleMirrorConflict -FilePath $f -MirrorUrl $MirrorUrl; Assert (-not $EndorWarned) 'false warning'

Write-Host 'test: bundler -- user fallback_timeout for rubygems.org: pinned to 0 inside the block, restored on removal'
$f = Join-Path $TempDir 'fallback/.bundle/config'
Write-Fixture $f "---`nBUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/__FALLBACK_TIMEOUT: `"3`"`n"; Copy-Item $f "$f.orig"
$out = Invoke-BundleApply $f -DryRun 6>&1 | Out-String; Assert ($out -match 'fallback_timeout') 'dry-run should mention fallback_timeout'
Assert (Test-SameContent $f "$f.orig") 'dry-run wrote'
$out = Invoke-BundleApply $f 6>&1 | Out-String; Assert ($out -match 'fallback_timeout') 'NOTE missing'
$lines = @(Get-Content $f)
Assert (($lines -contains 'BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/__FALLBACK_TIMEOUT: "0"') -and ($lines -contains 'BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/__FALLBACK_TIMEOUT: "3"')) 'fallback not pinned / user line lost'
Assert-BundleSetting $f 'mirror.https://rubygems.org/.fallback_timeout' '0'
$before = Get-Sha $f; Invoke-BundleApply $f | Out-Null; Assert ((Get-Sha $f) -eq $before) 'not idempotent'
Invoke-BundleRemove $f | Out-Null; Assert (Test-SameContent $f "$f.orig") 'original not restored'

Write-Host 'test: bundler -- Endor-only file left by a rewrite is deleted; a user credential line is not ours'
$f = Join-Path $TempDir 'only/.bundle/config'
Write-Fixture $f "---`nBUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: `"$MirrorUrl`"`nBUNDLE_MIRROR__RUBYGEMS__ORG: `"$MirrorUrl`"`n"; Copy-Item $f "$f.orig"
$out = Invoke-BundleRemove $f -DryRun 6>&1 | Out-String; Assert (($out -match 'DELETE file') -and (Test-SameContent $f "$f.orig")) 'dry-run wrong'
$out = Invoke-BundleRemove $f 6>&1 | Out-String; Assert (($out -match 'deleted \(was empty\)') -and -not (Test-Path $f)) 'not deleted'
Write-Fixture $f "---`nBUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: `"$MirrorUrl`"`nBUNDLE_${HostKey}: `"$Creds`"`n"
Invoke-BundleRemove $f | Out-Null; Assert (@(Get-Content $f) -contains "BUNDLE_${HostKey}: `"$Creds`"") 'user credential line removed'

# ========================================================================= gem
Write-Host "test: gem -- fresh machine: created, idempotent, dry-run inert, no backup, removal deletes (gem: $(if ($Gems.Count) { $Gems -join ', ' } else { 'skipped' }))"
$h = Join-Path $TempDir 'gfresh'; New-Item -ItemType Directory -Path $h | Out-Null; $f = Join-Path $h '.gemrc'
Invoke-GemApply $h 3>$null
$lines = @(Get-Content $f)
Assert ($lines[0] -eq '---' -and (Get-Markers $f) -eq 1 -and ($lines -contains ':sources:') -and ($lines -contains "- $SourceUrl")) 'block wrong'
Assert (-not (Test-Path "$f.endor-bak")) 'no backup expected on a fresh machine'
Assert-GemSources $h @($SourceUrl)
$before = Get-Sha $f; Invoke-GemApply $h 3>$null; Assert ((Get-Sha $f) -eq $before) 'not idempotent'
Invoke-GemApply $h -DryRun | Out-Null; Assert ((Get-Sha $f) -eq $before) 'dry-run wrote'
$out = Invoke-GemRemove $h -DryRun 6>&1 | Out-String; Assert (($out -match 'DELETE') -and (Test-Path $f)) 'dry-run wrong'
$out = Invoke-GemRemove $h 6>&1 | Out-String; Assert (($out -match 'deleted \(Endor-made\)') -and -not (Test-Path $f)) 'not deleted'
$out = Invoke-GemRemove $h 6>&1 | Out-String; Assert ($out -match 'skip \(not found\)') 'second removal not a no-op'
Invoke-GemApply $h 3>$null; Assert ((Get-Markers $f) -eq 1) 're-install after removal'

Write-Host 'test: gem -- existing .gemrc: backed up once, sources replaced, other keys kept, private source warns, restored byte-for-byte'
$h = Join-Path $TempDir 'gexisting'; $f = Join-Path $h '.gemrc'
Write-Fixture $f "---`ngem: --no-document`n# keep me`n:sources:`n- $RubyGemsUrl`n- $CorpGemUrl`n:verbose: true`n"; Copy-Item $f "$f.orig"
$out = Invoke-GemApply $h -DryRun 6>&1 | Out-String
Assert (($out -match 'backup') -and ($out -match 'gems\.corp\.example\.com') -and ($out -notmatch 's3cret')) 'dry-run should announce backup and masked sources'
Assert (Test-SameContent $f "$f.orig") 'dry-run wrote'
$EndorWarned = $false; $out = Invoke-GemApply $h 6>&1 3>$null | Out-String; Assert $EndorWarned 'private server should warn'
Assert (($out -match 'backed up') -and ($out -match '\*\*\*@gems\.corp') -and ($out -notmatch 's3cret')) 'NOTE / backup message wrong'
Assert (Test-SameContent "$f.endor-bak" "$f.orig") 'backup differs from original'
$t = Get-Text $f
Assert ($t.Contains("gem: --no-document`n") -and $t.Contains("# keep me`n") -and $t.Contains(":verbose: true`n")) 'user keys lost'
Assert (-not $t.Contains($RubyGemsUrl) -and -not $t.Contains('gems.corp') -and (Get-KeyCount $f ':sources') -eq 0 -and @(Get-Content $f | Where-Object { $_ -eq ':sources:' }).Count -eq 1) 'sources not replaced'
Assert-GemSources $h @($SourceUrl)
$before = Get-Sha $f; $bbefore = Get-Sha "$f.endor-bak"; $EndorWarned = $false; $out = Invoke-GemApply $h 6>&1 3>$null | Out-String
Assert (((Get-Sha $f) -eq $before) -and ((Get-Sha "$f.endor-bak") -eq $bbefore) -and -not $EndorWarned -and ($out -notmatch 'NOTE')) 'not idempotent, second backup, or repeated NOTE'
$out = Invoke-GemRemove $h -DryRun 6>&1 | Out-String; Assert (($out -match 'RESTORE') -and (Test-Path "$f.endor-bak")) 'dry-run wrong'
$out = Invoke-GemRemove $h 6>&1 | Out-String; Assert ($out -match 'original restored') 'not restored'
Assert ((Test-SameContent $f "$f.orig") -and -not (Test-Path "$f.endor-bak")) 'original differs or backup left'
Assert-GemSources $h @($RubyGemsUrl, $CorpGemUrl)
$out = Invoke-GemRemove $h 6>&1 | Out-String; Assert (($out -match 'skip \(no Endor block\)') -and (Test-SameContent $f "$f.orig")) 'second removal touched the file'

Write-Host 'test: gem -- only the XDG file exists: .gemrc built from it, XDG untouched; removal deletes .gemrc'
$h = Join-Path $TempDir 'gxdg'; $f = Join-Path $h '.gemrc'; $x = Join-Path $h '.config/gem/gemrc'
Write-Fixture $x "gem: --no-document`n:sources:`n- $RubyGemsUrl`n"; Copy-Item $x "$h/xdg.orig"
$out = Invoke-GemApply $h -DryRun 6>&1 | Out-String; Assert (($out -match 'BUILD') -and -not (Test-Path $f)) 'dry-run wrong'
Invoke-GemApply $h 3>$null
Assert ((Test-Path $f) -and -not (Test-Path "$f.endor-bak")) 'file missing or backup created'
$t = Get-Text $f; Assert ($t.Contains('gem: --no-document') -and -not $t.Contains($RubyGemsUrl) -and (Get-Markers $f) -eq 1) 'built file wrong'
Assert (Test-SameContent $x "$h/xdg.orig") 'XDG file touched'
Assert-GemSources $h @($SourceUrl)
Invoke-GemRemove $h | Out-Null; Assert ((-not (Test-Path $f)) -and (Test-SameContent $x "$h/xdg.orig")) 'removal wrong'

Write-Host 'test: gem -- both files exist: XDG ignored and untouched, .gemrc handled like an existing file'
$h = Join-Path $TempDir 'gboth'; $f = Join-Path $h '.gemrc'; $x = Join-Path $h '.config/gem/gemrc'
Write-Fixture $x ":sources:`n- $CorpGemUrl`n"; Copy-Item $x "$h/xdg.orig"
Write-Fixture $f ":sources:`n- $RubyGemsUrl`n"; Copy-Item $f "$f.orig"
$EndorWarned = $false; Invoke-GemApply $h 3>$null | Out-Null; Assert (-not $EndorWarned) 'rubygems.org alone must not warn'
Assert ((Test-SameContent "$f.endor-bak" "$f.orig") -and (Test-SameContent $x "$h/xdg.orig")) 'backup or XDG wrong'
Assert-GemSources $h @($SourceUrl)
Invoke-GemRemove $h | Out-Null; Assert ((Test-SameContent $f "$f.orig") -and (Test-SameContent $x "$h/xdg.orig")) 'removal wrong'

Write-Host "test: gem -- file rewritten by 'gem sources' (canonical dump, no sentinels, rubygems.org re-added): re-run leaves ours only"
$h = Join-Path $TempDir 'grewritten'; $f = Join-Path $h '.gemrc'
Write-Fixture $f "---`n:backtrace: `"true`"`n:sources:`n- `"$SourceUrl`"`n- `"$RubyGemsUrl`"`n:update_sources: `"true`"`ngem: `"--no-document`"`n"; Copy-Item $f "$f.orig"
$EndorWarned = $false; $out = Invoke-GemApply $h 6>&1 3>$null | Out-String
Assert (-not (Test-Path "$f.endor-bak")) 'a file that is already ours must not be backed up'
Assert (($out -match [regex]::Escape($RubyGemsUrl)) -and ($out -notmatch '\*\*\*@factory') -and -not $EndorWarned) 'note should list rubygems.org only'
Assert ((Get-Markers $f) -eq 1 -and @(Get-Content $f | Where-Object { $_ -eq ':sources:' }).Count -eq 1 -and @(Get-Content $f | Where-Object { $_.Contains('firewall/gem/') }).Count -eq 1) 'duplicates'
$t = Get-Text $f; Assert ($t.Contains(':backtrace: "true"') -and $t.Contains(':update_sources: "true"') -and $t.Contains('gem: "--no-document"')) 'keys lost'
Assert-GemSources $h @($SourceUrl)
Copy-Item "$f.orig" $f -Force; $out = Invoke-GemRemove $h 6>&1 | Out-String
Assert (($out -match 'deleted \(Endor-made\)') -and -not (Test-Path $f)) 'url-only recognition failed'
Write-Fixture $f ":sources:`n- $RubyGemsUrl`n"; Copy-Item $f "$f.orig" -Force
Invoke-GemApply $h 3>$null | Out-Null
Write-Fixture $f "---`n:sources:`n- `"$SourceUrl`"`n- `"$RubyGemsUrl`"`n"                       # dev ran gem sources --add after install
$out = Invoke-GemRemove $h 6>&1 | Out-String; Assert (($out -match 'original restored') -and (Test-SameContent $f "$f.orig")) 'backup should still win'

Write-Host 'test: gem -- flow-style :sources: [a, b] (breaks both parsers): replaced by the block form'
$h = Join-Path $TempDir 'gflow'; $f = Join-Path $h '.gemrc'
Write-Fixture $f ":sources: [$RubyGemsUrl, $CorpGemUrl]`n"; Copy-Item $f "$f.orig"
$EndorWarned = $false; Invoke-GemApply $h 3>$null | Out-Null; Assert $EndorWarned 'private url inside the flow list should warn'
Assert (-not (Get-Text $f).Contains('[')) 'flow style left in place'
Assert-GemSources $h @($SourceUrl)
Invoke-GemRemove $h | Out-Null; Assert (Test-SameContent $f "$f.orig") 'original not restored'

Write-Host "test: gem -- command defaults carrying --source / -s / --clear-sources warn; harmless ones don't; Endor block ignored"
$s = Join-Path $TempDir 'gwarn/sys-gemrc'
foreach ($line in @('gem: --no-document --source https://other.example.com/', 'install: -s https://other.example.com/', 'update: --clear-sources --source https://x/')) {
    Write-Fixture $s "$line`n"; $EndorWarned = $false; Test-GemrcSourceOverride -FilePaths @($s) 3>$null
    Assert $EndorWarned "no warning for: $line"
}
foreach ($line in @('gem: --no-document', ':sources:', '- https://other.example.com/', 'install: --user-install --no-document')) {
    Write-Fixture $s "$line`n"; $EndorWarned = $false; Test-GemrcSourceOverride -FilePaths @($s)
    Assert (-not $EndorWarned) "false warning for: $line"
}
Write-Fixture $s "$ENDOR_BLOCK_START`ngem: --source https://x/`n$ENDOR_BLOCK_END`n"
$EndorWarned = $false; Test-GemrcSourceOverride -FilePaths @($s, (Join-Path $TempDir 'does-not-exist')); Assert (-not $EndorWarned) 'block / missing file should not warn'

# ================================================================== generator
Write-Host 'test: generator emits endor-ruby.ps1 and wires Ruby into endor-all.ps1 / endor-remove.ps1'
$env:ENDOR_NAMESPACE = 'ci-smoke'; $env:ENDOR_API_KEY_ID = 'ci-smoke-key-id'; $env:ENDOR_API_SECRET = 'ci-smoke-secret'; Remove-Item Env:ENDOR_FQDN -ErrorAction SilentlyContinue
& (Join-Path $PfDir 'powershell/generate.ps1') *> $null
if ($LASTEXITCODE) { throw "generator failed with exit code $LASTEXITCODE" }
$out = Join-Path $PfDir 'powershell/out/ci-smoke'
foreach ($name in @('endor-ruby.ps1', 'endor-all.ps1', 'endor-remove.ps1')) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $out $name), [ref]$tokens, [ref]$errors) | Out-Null
    Assert ($errors.Count -eq 0) "$name has parse errors: $($errors[0].Message)"
}
$ruby = Get-Content (Join-Path $out 'endor-ruby.ps1') -Raw
Assert ($ruby.Contains($MirrorUrl)) 'mirror url not substituted'
Assert ($ruby.Contains("'BUNDLE_$HostKey'") -and $ruby.Contains('= $ENDOR_BUNDLE_CREDS')) 'HKCU credential var missing'
Assert (-not $ruby.Contains("BUNDLE_${HostKey}: ")) 'credential must not be in the bundle block'
Assert ($ruby.Contains('- {{GEM_SOURCE_URL}}') -and $ruby.Contains("`$GEMRC_BLOCK.Replace('{{GEM_SOURCE_URL}}'") -and $ruby.Contains('$ENDOR_GEM_SOURCE_URL = "https://')) 'gem source fill missing'
Assert ($ruby.Contains('Invoke-UpsertBundleConfig') -and $ruby.Contains('Invoke-UpsertGemrc') -and $ruby.Contains('Test-GemrcSourceOverride')) 'ruby section missing'
Assert (-not ($ruby -match '\{\{(GEM_MIRROR_URL|BUNDLE_HOST_KEY)\}\}')) 'unresolved token in endor-ruby.ps1'
Assert ((Get-Content (Join-Path $out 'endor-all.ps1') -Raw).Contains('Invoke-UpsertGemrc')) 'endor-all.ps1 lacks Ruby'
$rm = Get-Content (Join-Path $out 'endor-remove.ps1') -Raw
Assert ($rm.Contains("Remove-BundleConfig -FilePath (Join-Path `$UserHome '.bundle\config') -MirrorUrl '$MirrorUrl'") -and $rm.Contains('Remove-Gemrc') -and $rm.Contains("'BUNDLE_$HostKey'")) 'endor-remove.ps1 lacks Ruby'

Write-Host 'test: credential variable follows Bundler''s host mapping (EU host with port, dashed host)'
$env:ENDOR_NAMESPACE = 'ci-smoke-eu'; $env:ENDOR_FQDN = 'https://factory.eu.endorlabs.com:8443'; $env:ENDOR_API_KEY_ID = 'k'; $env:ENDOR_API_SECRET = 's'
& (Join-Path $PfDir 'powershell/generate.ps1') *> $null
$eu = Get-Content (Join-Path $PfDir 'powershell/out/ci-smoke-eu/endor-ruby.ps1') -Raw
Assert ($eu.Contains("'BUNDLE_FACTORY__EU__ENDORLABS__COM'") -and $eu.Contains('https://factory.eu.endorlabs.com:8443/v1/namespaces/ci-smoke-eu/firewall/gem/')) 'EU host key wrong'
$env:ENDOR_NAMESPACE = 'ci-smoke-dash'; $env:ENDOR_FQDN = 'https://fw-test.example.com'
& (Join-Path $PfDir 'powershell/generate.ps1') *> $null
Assert ((Get-Content (Join-Path $PfDir 'powershell/out/ci-smoke-dash/endor-ruby.ps1') -Raw).Contains("'BUNDLE_FW___TEST__EXAMPLE__COM'")) 'dashed host key wrong'
Remove-Item -LiteralPath (Join-Path $PfDir 'powershell/out/ci-smoke-eu'), (Join-Path $PfDir 'powershell/out/ci-smoke-dash') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:ENDOR_FQDN -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "ok: ruby tests passed (bundler validation: $(if ($HaveBundle) { 'on' } else { 'skipped' }); gem validation: $(if ($Gems.Count) { 'on -- ' + ($Gems -join ', ') } else { 'skipped' }))"
exit 0
