# Drives the NuGet.Config helpers from lib/common.ps1 against fixture files
# (the generated installer itself needs SYSTEM / console-user detection and
# registry writes), then checks the generator wires NuGet in. `dotnet nuget
# list source` validates what NuGet actually resolves when dotnet is installed.
# Mirrors tests/test-nuget.sh case for case.
$ErrorActionPreference = 'Stop'

$TestDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$PfDir     = (Resolve-Path (Join-Path $TestDir '..')).Path
$SourceUrl = 'https://factory.endorlabs.com/v1/namespaces/ci-smoke/firewall/nuget/v3/index.json'
$NuGetOrg  = 'https://api.nuget.org/v3/index.json'
$CorpUrl   = 'https://corp.example.com/nuget/v3/index.json'
$TempDir   = Join-Path ([IO.Path]::GetTempPath()) "endor-nuget-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $TempDir | Out-Null

$EndorWarned = $false
. (Join-Path $PfDir 'powershell/lib/common.ps1')
$Owner = if ($env:USERNAME) { $env:USERNAME } else { $env:USER }

$SourcesBlock = (Get-Content (Join-Path $PfDir 'shared/blocks/nugetconfig_sources.txt') -Raw -Encoding UTF8).Replace('{{NUGET_SOURCE_URL}}', $SourceUrl).TrimEnd()
$CredsBlock   = (Get-Content (Join-Path $PfDir 'shared/blocks/nugetconfig_credentials.txt') -Raw -Encoding UTF8).TrimEnd()
$MappingBlock = (Get-Content (Join-Path $PfDir 'shared/blocks/nugetconfig_sourcemapping.txt') -Raw -Encoding UTF8).TrimEnd()

$HaveDotnet = [bool](Get-Command dotnet -ErrorAction SilentlyContinue)
if ($HaveDotnet) { $env:DOTNET_NOLOGO = '1'; $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1' }

function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw "ASSERT: $Message" } }

# Mirrors templates/nuget.ps1. Warnings (3>) are dropped: Set-FileRestrictedAcl warns on non-Windows.
function Invoke-Apply {
    param([string]$File, [switch]$DryRun)
    Invoke-UpsertNuGetBlock -FilePath $File -Section 'packageSources'           -Content $SourcesBlock -Username $Owner -DryRun:$DryRun 3>$null
    Invoke-UpsertNuGetBlock -FilePath $File -Section 'packageSourceCredentials' -Content $CredsBlock   -Username $Owner -DryRun:$DryRun 3>$null
    if ((Test-Path $File) -and ((Get-Content $File -Raw -Encoding UTF8) -match '<packageSourceMapping')) {
        Invoke-UpsertNuGetBlock -FilePath $File -Section 'packageSourceMapping' -Content $MappingBlock -Username $Owner -DryRun:$DryRun 3>$null
    }
}
function Invoke-Remove { param([string]$File, [switch]$DryRun) Remove-NuGetBlocks -FilePath $File -DryRun:$DryRun }

function Assert-Xml { param([string]$File) $doc = New-Object System.Xml.XmlDocument; $doc.Load($File) }
function Get-Sha    { param([string]$File) (Get-FileHash -Algorithm SHA256 -LiteralPath $File).Hash }
function Get-Markers { param([string]$File) @(Get-Content -LiteralPath $File -Encoding UTF8 | Where-Object { $_.Contains($ENDOR_XML_BLOCK_START) }).Count }
# Assert-Sources <file> <url>... -- the sources NuGet resolves (skipped without dotnet)
function Assert-Sources {
    param([string]$File, [string[]]$Expected)
    if (-not $HaveDotnet) { return }
    $got = @(& dotnet nuget list source --configfile $File --format Short 2>$null |
             ForEach-Object { ($_ -split '\s+', 2)[1] } | Where-Object { $_ } | Sort-Object)
    $exp = @($Expected | Sort-Object)
    Assert (($got -join ' ') -eq ($exp -join ' ')) "sources mismatch for $File`n  got     : $($got -join ' ')`n  expected: $($exp -join ' ')"
}
# Assert-Restored <file> -- everything pre-install is back; only an empty created section may remain
function Assert-Restored {
    param([string]$File)
    Assert ((Get-Markers $File) -eq 0) 'markers left after removal'
    $now  = @(Get-Content -LiteralPath $File -Encoding UTF8 | Where-Object { $_ -notmatch 'packageSourceCredentials' })
    $orig = @(Get-Content -LiteralPath "$File.orig" -Encoding UTF8)
    Assert (($now -join "`n") -eq ($orig -join "`n")) "original content not restored in $File"
}
function New-Fixture {
    param([string]$Name, [string]$Content, [switch]$Bom)
    $f = Join-Path $TempDir "$Name/NuGet.Config"
    New-Item -ItemType Directory -Path (Split-Path $f) -Force | Out-Null
    [System.IO.File]::WriteAllText($f, $Content, [System.Text.UTF8Encoding]::new([bool]$Bom))
    Copy-Item $f "$f.orig"
    $f
}

Write-Host 'test: fresh machine -- created, idempotent, dry-run inert, removal restores nuget.org'
$f = Join-Path $TempDir 'fresh/NuGet/NuGet.Config'
Invoke-Apply $f; Assert-Xml $f
Assert ((Get-Markers $f) -eq 2) 'expected two blocks'
$raw = Get-Content -LiteralPath $f -Raw -Encoding UTF8
Assert ($raw.Contains('<clear />') -and $raw.Contains('value="%ENDOR_ATTR_USER%"')) 'block content missing'
Assert-Sources $f @($SourceUrl)
$before = Get-Sha $f; Invoke-Apply $f; Assert ((Get-Sha $f) -eq $before) 'not idempotent'
Invoke-Apply $f -DryRun | Out-Null; Assert ((Get-Sha $f) -eq $before) 'dry-run wrote'
$out = Invoke-Remove $f 6>&1 | Out-String; Assert ($out -match 'nuget.org default restored') 'nuget.org not restored'
Assert-Xml $f; Assert ((Get-Markers $f) -eq 0) 'markers left'
Assert-Sources $f @($NuGetOrg)
$out = Invoke-Remove $f 6>&1 | Out-String; Assert ($out -match 'skip \(no Endor block\)') 'second removal not a no-op'
Invoke-Apply $f; Assert-Sources $f @($SourceUrl)                # re-install after removal

Write-Host 'test: dotnet default config (BOM, nuget.org) -- merged, superseded, restored'
$f = New-Fixture 'default' -Bom "<?xml version=`"1.0`" encoding=`"utf-8`"?>`r`n<configuration>`r`n  <packageSources>`r`n    <add key=`"nuget.org`" value=`"$NuGetOrg`" protocolVersion=`"3`" />`r`n  </packageSources>`r`n</configuration>`r`n"
$EndorWarned = $false; Test-NuGetSourceConflict -FilePath $f; Assert (-not $EndorWarned) 'nuget.org alone must not warn'
Invoke-Apply $f; Assert-Xml $f
Assert (@(Get-Content $f | Where-Object { $_.Contains('<packageSources>') }).Count -eq 1) 'section duplicated'
Assert-Sources $f @($SourceUrl)
$before = Get-Sha $f; Invoke-Apply $f; Assert ((Get-Sha $f) -eq $before) 'not idempotent'
$out = Invoke-Remove $f 6>&1 | Out-String; Assert ($out -notmatch 'default restored') 'nuget.org re-added although present'
Assert-Restored $f; Assert-Sources $f @($NuGetOrg)

Write-Host 'test: private feed -- warning fires, feed superseded, restored without adding nuget.org'
$f = New-Fixture 'feed' @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="corp" value="$CorpUrl" />
  </packageSources>
</configuration>
"@
$EndorWarned = $false; Test-NuGetSourceConflict -FilePath $f 3>$null; Assert $EndorWarned 'corp feed should warn'
Invoke-Apply $f; Assert-Sources $f @($SourceUrl)
$EndorWarned = $false; Test-NuGetSourceConflict -FilePath $f 3>$null; Assert $EndorWarned 'warning should persist on re-run'
$EndorWarned = $false
Invoke-Remove $f | Out-Null; Assert-Restored $f
Assert (-not (Get-Content $f -Raw).Contains('api.nuget.org')) 'nuget.org added next to private feed'
Assert-Sources $f @($CorpUrl)

Write-Host 'test: customer <clear /> above our block -- disabled (only the first clear counts), restored'
$f = New-Fixture 'userclear' @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="$NuGetOrg" protocolVersion="3" />
  </packageSources>
</configuration>
"@
$out = Invoke-UpsertNuGetBlock -FilePath $f -Section 'packageSources' -Content $SourcesBlock -Username $Owner -DryRun 6>&1 | Out-String
Assert ($out -match 'endor-bak') 'dry-run should announce the disabled clear'
Assert ((Get-Sha $f) -eq (Get-Sha "$f.orig")) 'dry-run wrote'
$out = Invoke-Apply $f 6>&1 | Out-String; Assert ($out -match 'NOTE: existing <clear />') 'NOTE missing'
Assert ((Get-Content $f -Raw).Contains('<!-- endor-bak <clear /> -->')) 'user clear not disabled'
Assert-Sources $f @($SourceUrl)                                 # nuget.org really gone
$before = Get-Sha $f; $out = Invoke-Apply $f 6>&1 | Out-String
Assert (($out -notmatch 'NOTE') -and ((Get-Sha $f) -eq $before)) 'not idempotent or repeated NOTE'
Invoke-Remove $f | Out-Null; Assert-Restored $f; Assert-Sources $f @($NuGetOrg)

Write-Host 'test: existing <packageSourceMapping> -- pattern * routed to endor-firewall, mappings restored'
$f = New-Fixture 'mapping' @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nuget.org" value="$NuGetOrg" protocolVersion="3" />
    <add key="corp" value="$CorpUrl" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="corp"><package pattern="Corp.*" /></packageSource>
    <packageSource key="nuget.org"><package pattern="*" /></packageSource>
  </packageSourceMapping>
</configuration>
"@
Invoke-Apply $f; Assert-Xml $f
Assert ((Get-Markers $f) -eq 3) 'expected three blocks'
Assert ((Get-Content $f -Raw).Contains('<packageSource key="endor-firewall">')) 'mapping block missing'
Assert-Sources $f @($SourceUrl)
Invoke-Remove $f | Out-Null; Assert-Restored $f; Assert-Sources $f @($NuGetOrg, $CorpUrl)

Write-Host 'test: self-closing sections and unrelated <config> -- expanded and preserved'
$f = New-Fixture 'selfclose' @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <config>
    <add key="globalPackagesFolder" value="D:\nuget-packages" />
  </config>
  <packageSources />
</configuration>
'@
Invoke-Apply $f; Assert-Xml $f
Assert ((Get-Markers $f) -eq 2) 'expected two blocks'
Assert ((Get-Content $f -Raw).Contains('globalPackagesFolder')) '<config> lost'
Assert-Sources $f @($SourceUrl)
Invoke-Remove $f | Out-Null; Assert-Xml $f
Assert ((Get-Content $f -Raw).Contains('globalPackagesFolder')) '<config> lost on removal'
Assert-Sources $f @($NuGetOrg)

Write-Host 'test: malformed file (no </configuration>) is left untouched with a warning'
$f = New-Fixture 'bad' "<?xml version=`"1.0`"?>`n<configuration>`n  <packageSources>`n"
$before = Get-Sha $f; $EndorWarned = $false
Invoke-Apply $f 3>$null
Assert ($EndorWarned -and ((Get-Sha $f) -eq $before)) 'malformed file should warn and stay untouched'
$EndorWarned = $false

Write-Host 'test: generator emits endor-nuget.ps1 and wires NuGet into endor-all.ps1 / endor-remove.ps1'
$env:ENDOR_NAMESPACE = 'ci-smoke'; $env:ENDOR_API_KEY_ID = 'ci-smoke-key-id'; $env:ENDOR_API_SECRET = 'ci-smoke-secret'
& (Join-Path $PfDir 'powershell/generate.ps1') *> $null
if ($LASTEXITCODE) { throw "generator failed with exit code $LASTEXITCODE" }
$out = Join-Path $PfDir 'powershell/out/ci-smoke'
foreach ($name in @('endor-nuget.ps1', 'endor-all.ps1', 'endor-remove.ps1')) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $out $name), [ref]$tokens, [ref]$errors) | Out-Null
    Assert ($errors.Count -eq 0) "$name has parse errors: $($errors[0].Message)"
}
$nuget = Get-Content (Join-Path $out 'endor-nuget.ps1') -Raw
Assert ($nuget.Contains($SourceUrl) -and -not $nuget.Contains('{{NUGET_SOURCE_URL}}')) 'endor-nuget.ps1 URL not substituted'
Assert ((Get-Content (Join-Path $out 'endor-all.ps1') -Raw).Contains($SourceUrl)) 'endor-all.ps1 lacks NuGet'
Assert ((Get-Content (Join-Path $out 'endor-remove.ps1') -Raw).Contains('Remove-NuGetBlocks')) 'endor-remove.ps1 lacks NuGet'

Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
$mode = if ($HaveDotnet) { 'on' } else { 'skipped' }
Write-Host "ok: nuget tests passed (dotnet validation: $mode)"
exit 0
