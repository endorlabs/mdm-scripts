# Silence the progress stream; else PowerShell serializes it to stderr as "#< CLIXML"
# noise the MDM hook misreads as errors (2>$null / -ErrorAction don't cover it).
$ProgressPreference = 'SilentlyContinue'
$Bin = Join-Path $env:USERPROFILE '.endorctl\endorctl.exe'
$skip = $false
if ($env:ENDORCTL_SKIP_UPDATE -and (Test-Path $Bin)) { $skip = $true }
if (-not $skip) {
  switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { $arch = 'amd64' }
    'ARM64' { $arch = 'arm64' }
    default { exit 1 }
  }
  $url = "https://api.endorlabs.com/download/latest/endorctl_windows_$arch.exe"
  $archKey = 'ARCH_TYPE_WINDOWS_' + $arch.ToUpper()
  $current = ''
  if (Test-Path $Bin) {
    try {
      $line = (& $Bin --version 2>$null) | Select-String -Pattern 'version' | Select-Object -First 1
      if ($line) { $current = ($line.ToString() -split '\s+')[-1] }
    } catch {}
  }
  $latest = ''; $expectedSha = ''
  try {
    $meta = Invoke-RestMethod -Uri 'https://api.endorlabs.com/meta/version' -TimeoutSec 30
    $latest = [string]$meta.ClientVersion
    $expectedSha = [string]$meta.ClientChecksums.$archKey
  } catch {}
  $uptodate = ($current -and ((-not $latest) -or ($current -eq $latest)))
  if (-not $uptodate) {
    if ($expectedSha -notmatch '^[0-9a-fA-F]{64}$') { exit 1 }
    $dir = Split-Path $Bin
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    # Sweep leftovers from interrupted past runs. Age-gated so a concurrent
    # session's in-flight download is never deleted; the name cannot match the
    # installed binary ("endorctl.exe").
    Get-ChildItem -Path $dir -Filter 'endorctl-download-*' -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-60) } |
      Remove-Item -Force -ErrorAction SilentlyContinue
    $tmp = Join-Path $dir ('endorctl-download-' + [IO.Path]::GetRandomFileName())
    try { Invoke-WebRequest -Uri $url -OutFile $tmp -TimeoutSec 120 } catch { if (Test-Path $tmp) { Remove-Item -Force $tmp -ErrorAction SilentlyContinue }; exit 1 }
    if ((Get-FileHash -Algorithm SHA256 -Path $tmp).Hash -ne $expectedSha) { Remove-Item -Force $tmp -ErrorAction SilentlyContinue; exit 1 }
    Move-Item -Force $tmp $Bin
  }
}
