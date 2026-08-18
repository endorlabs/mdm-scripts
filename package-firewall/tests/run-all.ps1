$ErrorActionPreference = 'Stop'

$TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $TestDir 'test-vscode.ps1')
exit $LASTEXITCODE
