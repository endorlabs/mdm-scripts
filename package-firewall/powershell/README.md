# Endor Package Firewall — MDM Script Generator (Windows / PowerShell)

Generates self-contained PowerShell scripts for IT admins to push via MDM (Intune or any generic MDM tool). Once deployed, scripts configure developer machines to route package installations through the Endor Package Firewall — without overwriting existing custom configuration.

---

## Directory layout

```
powershell/
├── generate.ps1
├── lib/
│   └── common.ps1
├── templates/
│   ├── script-header.ps1    ← generated script preamble (user detection, arg parsing)
│   ├── envvars.ps1          ← orchestration: writes persistent env vars to HKCU registry
│   ├── js.ps1               ← orchestration: npm / yarn config file writes
│   ├── python.ps1           ← orchestration: pip / uv config file writes
│   ├── go.ps1               ← orchestration: go env file write
│   └── remove.ps1           ← orchestration: sentinel block + registry env var removal
└── out/                     ← generated scripts (gitignore this)
    └── <namespace>/
        ├── endor-js.ps1
        ├── endor-python.ps1
        ├── endor-go.ps1
        ├── endor-all.ps1
        └── endor-remove.ps1

../shared/blocks/            ← edit these to customise what gets written to config files
├── npmrc.txt                ← %USERPROFILE%\.npmrc content
├── yarnrc_classic.txt       ← %USERPROFILE%\.yarnrc (yarn 1.x) content
├── yarnrc.txt               ← %USERPROFILE%\.yarnrc.yml (yarn 2+) content
├── pipconf.txt              ← %APPDATA%\pip\pip.ini content
├── uvtoml.txt               ← %APPDATA%\uv\uv.toml content
└── goenv.txt                ← go env file content  (path resolved via `go env GOENV`)
```

---

## Step 1 — Generate the MDM scripts

Requires PowerShell Core (`pwsh`). Run from macOS, Linux, or Windows.

Pass credentials as environment variables:

```powershell
$env:ENDOR_NAMESPACE  = 'my-team'
$env:ENDOR_API_KEY_ID = 'your-key-id'
$env:ENDOR_API_SECRET = 'your-key-secret'
./generate.ps1
```

Or with a `.env` file (add `.env` to `.gitignore`):

```
# .env
ENDOR_NAMESPACE=my-team
ENDOR_API_KEY_ID=your-key-id
ENDOR_API_SECRET=your-key-secret
```

```powershell
Get-Content .env | Where-Object { $_ -match '^\s*[^#\s]' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    [System.Environment]::SetEnvironmentVariable($k.Trim(), $v.Trim())
}
./generate.ps1
```

`ENDOR_FQDN` is optional and defaults to `https://factory.endorlabs.com`:

```powershell
$env:ENDOR_FQDN       = 'https://factory.staging.endorlabs.com'
$env:ENDOR_NAMESPACE  = 'my-team'
$env:ENDOR_API_KEY_ID = 'your-key-id'
$env:ENDOR_API_SECRET = 'your-key-secret'
./generate.ps1
```

Re-running `generate.ps1` overwrites the same `out/<namespace>/` directory.

---

## Step 2 — Upload to your MDM tool

Each script in `out/<namespace>/` is **fully self-contained** — no external files or dependencies needed at runtime.

### Which script to upload

| Script | Use when |
|---|---|
| `endor-js.ps1` | Team uses JavaScript (npm, pnpm, yarn, bun) only |
| `endor-python.ps1` | Team uses Python (pip, uv, poetry) only |
| `endor-go.ps1` | Team uses Go only |
| `endor-all.ps1` | Team uses multiple ecosystems — single-script deploy |



Upload the script file. Ensure it runs as **SYSTEM** — the script detects the logged-in console user internally via `explorer.exe` and writes config files to the correct user profile.

---

## How credentials are stored

All scripts share a common credential architecture:

**Registry** — persistent user-level environment variables written to `HKCU:\Environment`:

```
ENDOR_API_KEY_ID                          = <key-id>
ENDOR_API_SECRET                          = <secret>
ENDOR_AUTH_B64                            = <base64(key-id:secret)>
ENDOR_NPM_REGISTRY_URL                    = https://factory.endorlabs.com/v1/namespaces/my-team/firewall/npm/
ENDOR_PYPI_URL                            = https://<key-id>:<secret>@factory.endorlabs.com/v1/namespaces/my-team/firewall/pypi/simple/
POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME = <key-id>
POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD = <secret>
```

Config files reference these as `${ENDOR_...}` env var placeholders — the tools expand them at runtime from the process environment.

**Windows advantage over macOS:** `HKCU:\Environment` variables are inherited by every process the user starts — including Makefiles, git hooks, IDE terminals, and scheduled tasks. No shell profile sourcing required. This natively covers the non-interactive context gap.

**Credential rotation**: redeploy the MDM script with new credentials. `HKCU:\Environment` and `pip.ini` (which contains literal credentials) are both updated in place.

---

## What the scripts do

### `endor-js.ps1`

Writes registry env vars and an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| `%USERPROFILE%\.npmrc` | npm (all), pnpm (8–11.x), yarn classic (1.x), bun | `${ENDOR_AUTH_B64}` env var ref |
| `%USERPROFILE%\.yarnrc.yml` | yarn 2+ / berry (v3.1+) | `${ENDOR_API_KEY_ID}:${ENDOR_API_SECRET}` env var refs |

### `endor-go.ps1`

Writes `ENDOR_GO_PROXY_URL` to `HKCU:\Environment` and an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| Go env file (path from `go env GOENV`) | go modules (all versions) | Literal — baked into `GOPROXY` URL at generation time |

Key behaviour:
- **Path detection**: the script runs `go env GOENV` (with the user's `APPDATA`) to find the correct path — Windows default is `%APPDATA%\go\env`. Falls back to this default if `go` is not installed.
- **GOPROXY** is set to `https://<key>:<secret>@factory.endorlabs.com/.../firewall/go/,direct` — the `,direct` suffix falls back to the upstream module proxy if a module is not blocked
- Credentials are baked in at generation time because Go env files do not support env var expansion
- The go env file is read by all `go` commands regardless of shell or terminal — covers IDE terminals, Makefiles, git hooks, and non-interactive scripts
- The go env file takes lower precedence than the `GOPROXY` process env var, so project-level overrides (`go env -w` in a workspace) remain possible
- Sentinel comment lines (`# ...`) are silently skipped by `go env` parsing

---

### `endor-python.ps1`

Writes registry env vars and an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| `%APPDATA%\pip\pip.ini` | pip | Literal — pip cannot expand env vars |
| `%APPDATA%\uv\uv.toml` | uv | `${ENDOR_PYPI_URL}` env var ref |

Poetry credentials (`POETRY_HTTP_BASIC_ENDOR_FIREWALL_*`) are written to the registry — no separate config file needed.

> For poetry, developers still need to add the source to `pyproject.toml` (URL only, no credentials):
> ```toml
> [[tool.poetry.source]]
> name     = "endor-firewall"
> url      = "https://factory.endorlabs.com/v1/namespaces/my-team/firewall/pypi/simple/"
> priority = "primary"
> ```

---

## Customising

To change what gets written to a config file on target machines, edit the relevant file in `../shared/blocks/` directly:

| File | Written to |
|---|---|
| `../shared/blocks/npmrc.txt` | `%USERPROFILE%\.npmrc` |
| `../shared/blocks/yarnrc_classic.txt` | `%USERPROFILE%\.yarnrc` (yarn 1.x) |
| `../shared/blocks/yarnrc.txt` | `%USERPROFILE%\.yarnrc.yml` (yarn 2+) |
| `../shared/blocks/pipconf.txt` | `%APPDATA%\pip\pip.ini` |
| `../shared/blocks/uvtoml.txt` | `%APPDATA%\uv\uv.toml` |
| `../shared/blocks/goenv.txt` | `%APPDATA%\go\env` |

To change orchestration logic (which files get written, in what order), edit the relevant `templates/*.ps1` file directly.

Both support the same placeholder syntax as the macOS version:

| Syntax | When resolved | Use for |
|---|---|---|
| `{{PLACEHOLDER}}` | Generation time by `generate.ps1` | Values baked into the config file (e.g. registry host) |
| `${ENDOR_VAR}` | Runtime by the tool reading the config file | Credential values — resolved from registry env vars |

Available placeholders: `{{API_KEY_ID}}`, `{{API_SECRET}}`, `{{NPM_REGISTRY_URL}}`, `{{NPM_REGISTRY_HOST}}`, `{{NPM_AUTH_B64}}`, `{{PYPI_URL}}`, `{{PIP_INDEX_URL}}`, `{{TRUSTED_HOST}}`, `{{NAMESPACE}}`, `{{FQDN}}`

---

## Preserving existing configuration

Scripts use the same **sentinel block** pattern as the macOS version:

```ini
; existing admin config — never touched
legacy-peer-deps=true

# ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) =====
registry=${ENDOR_NPM_REGISTRY_URL}
always-auth=true
//factory.endorlabs.com/v1/namespaces/my-team/firewall/npm/:_auth=${ENDOR_AUTH_B64}
# ===== END ENDOR PACKAGE FIREWALL =====
```

| Scenario | Behaviour |
|---|---|
| Fresh machine | File created with Endor block only |
| Existing file, no Endor block | Block appended; existing content preserved |
| Re-run / MDM check-in | Only the Endor block is replaced; rest untouched |
| Admin edits outside the block | Preserved forever |
| Admin edits inside the block | Overwritten on next MDM push — block is Endor-managed |
| Conflicting key outside block | Warning emitted to MDM log; admin resolves manually |

---

## Dry run

All generated scripts accept `-DryRun` to preview changes without writing anything:

```powershell
.\endor-all.ps1 -DryRun
```

Useful for validating what the script will do before deploying to devices.

---

## Removing the configuration

Deploy `endor-remove.ps1` to strip all Endor configuration from a machine. It:

- Removes the sentinel block from `.npmrc`, `.yarnrc.yml`, `pip.ini`, and `uv.toml`
- Deletes all `ENDOR_*` and `POETRY_HTTP_BASIC_ENDOR_FIREWALL_*` keys from `HKCU:\Environment`
- Deletes config files that are empty after block removal

```powershell
.\endor-remove.ps1 -DryRun   # preview first
.\endor-remove.ps1            # apply
```

---

## Security notes

| Item | Note |
|---|---|
| `HKCU:\Environment` | Contains credentials as plain REG_SZ strings. Access is restricted to the owning user by default Windows ACLs. |
| `pip.ini` | Contains credentials in the `index-url`. File is ACL-restricted to owner. Credentials may appear in pip debug logs (`pip install -v`). pip cannot use env var references. |
| `.npmrc`, `.yarnrc.yml`, `uv.toml` | Contain `${VAR}` references only — no credentials baked in. |
| API secret in MDM | Generated scripts contain the API key and secret in plaintext (used to write registry env vars). Restrict access to the Intune policy and the generated `out/` directory. |
| `out/` directory | Add to `.gitignore`. Do not commit generated scripts to source control. |
