# templates/python.ps1
# Python ecosystem -- pip . uv . poetry
#
# Config files written to the console user's profile:
#   %APPDATA%\pip\pip.ini      pip (Windows primary -- .ini not .conf)
#   %APPDATA%\uv\uv.toml       uv  (does NOT read pip.ini)
#
# Credential approach per tool:
#   pip    -- literal credentials in pip.ini (pip cannot expand env vars)
#   uv     -- ${ENDOR_PYPI_URL} env var ref; resolved from HKCU:\Environment at runtime
#   poetry -- POETRY_HTTP_BASIC_ENDOR_FIREWALL_* set in HKCU:\Environment above
#
# pip uses [endor-firewall] named section -- avoids clobbering admin's [global].
#
# macOS uses ~/.config/pip/pip.conf + ~/.pip/pip.conf + ~/Library/.../pip.conf.
# Windows uses a single %APPDATA%\pip\pip.ini (no multi-path search needed).

Write-Host '[endor-python] -- Python package managers --------------------------------'

# -- pip.ini --
# Windows: %APPDATA%\pip\pip.ini (equivalent of ~/.config/pip/pip.conf on macOS/Linux)
# pip does not support env var expansion -- credentials are literal values.
$_pipIni = Join-Path $AppData 'pip\pip.ini'

Test-KeyConflict `
    -FilePath $_pipIni `
    -Pattern  '^index-url' `
    -Label    'index-url (pip)'

Invoke-UpsertBlock `
    -FilePath  $_pipIni `
    -Content   $PIP_BLOCK `
    -Username  $ConsoleUser `
    -DryRun:$DryRun

Write-Host "[endor-python] pip.ini -> $_pipIni"
Write-Host '[endor-python]   covers: pip'
Remove-Variable _pipIni

# -- uv.toml --
# uv does NOT read pip.ini. %APPDATA%\uv\uv.toml is the user-level global config.
# uv supports ${VAR} expansion -- ENDOR_PYPI_URL is resolved from HKCU:\Environment.
$_uvToml = Join-Path $AppData 'uv\uv.toml'

Test-KeyConflict `
    -FilePath $_uvToml `
    -Pattern  '^\[\[index\]\]' `
    -Label    '[[index]] (uv)'

Invoke-UpsertBlock `
    -FilePath  $_uvToml `
    -Content   $UV_BLOCK `
    -Username  $ConsoleUser `
    -DryRun:$DryRun

Write-Host "[endor-python] uv.toml -> $_uvToml"
Write-Host '[endor-python]   covers: uv'
Remove-Variable _uvToml

# -- poetry --
# POETRY_HTTP_BASIC_ENDOR_FIREWALL_* are set in HKCU:\Environment by the env vars
# step above -- no separate write here. These persist across sessions for all
# processes, including non-interactive IDE terminals.
#
# Developers still need to add the source URL to pyproject.toml (URL only, no credentials):
#   [[tool.poetry.source]]
#   name     = "endor-firewall"
#   url      = "{{PYPI_URL}}"
#   priority = "primary"
#
# Source name must use hyphens not underscores -- Poetry's POETRY_HTTP_BASIC_ env
# var lookup replaces hyphens with underscores in the source name.

Write-Host '[endor-python]   poetry : credentials via HKCU:\Environment (POETRY_HTTP_BASIC_ENDOR_FIREWALL_*)'
Write-Host '[endor-python]   NOTE   : open a new terminal for env vars to take effect'
Write-Host '[endor-python] [done] Python done'
