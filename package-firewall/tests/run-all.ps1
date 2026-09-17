$ErrorActionPreference = 'Stop'

$TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $TestDir 'test-vscode.ps1')
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& (Join-Path $TestDir 'test-nuget.ps1')
exit $LASTEXITCODE
