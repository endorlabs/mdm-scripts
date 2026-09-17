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
│   ├── maven.ps1            ← orchestration: .m2\settings.xml write (XML-aware)
│   ├── nuget.ps1            ← orchestration: %APPDATA%\NuGet\NuGet.Config write (section-aware XML)
│   ├── vscode.ps1           ← VS Code product.json patch + scheduled remediation
│   └── remove.ps1           ← orchestration: sentinel block + registry env var removal
└── out/                     ← generated scripts (gitignore this)
    └── <namespace>/
        ├── endor-js.ps1
        ├── endor-python.ps1
        ├── endor-go.ps1
        ├── endor-maven.ps1
        ├── endor-nuget.ps1
        ├── endor-vscode.ps1
        ├── endor-all.ps1
        └── endor-remove.ps1

../shared/blocks/            ← edit these to customise what gets written to config files
├── npmrc.txt                ← %USERPROFILE%\.npmrc content
├── yarnrc_classic.txt       ← %USERPROFILE%\.yarnrc (yarn 1.x) content
├── yarnrc.txt               ← %USERPROFILE%\.yarnrc.yml (yarn 2+) content
├── pipconf.txt              ← %APPDATA%\pip\pip.ini content
├── uvtoml.txt               ← %APPDATA%\uv\uv.toml content
├── goenv.txt                ← go env file content  (path resolved via `go env GOENV`)
├── mavensettings.txt        ← %USERPROFILE%\.m2\settings.xml fragment  (Maven mirror + server)
├── nugetconfig_sources.txt        ← NuGet.Config <packageSources> items  (clear + Endor source)
├── nugetconfig_credentials.txt    ← NuGet.Config <packageSourceCredentials> item
└── nugetconfig_sourcemapping.txt  ← NuGet.Config <packageSourceMapping> items  (only when the section exists)
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
| `endor-maven.ps1` | Team uses Java / Maven only |
| `endor-nuget.ps1` | Team uses .NET / NuGet only |
| `endor-vscode.ps1` | Team uses Microsoft VS Code Stable extensions |
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

### `endor-maven.ps1`

Writes an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| `%USERPROFILE%\.m2\settings.xml` | Maven (all versions); Gradle when it reads `~/.m2` | `${env.ENDOR_API_KEY_ID}` / `${env.ENDOR_API_SECRET}` env var refs |

Key behaviour:
- **XML-aware writer**: `settings.xml` is XML, so the generic sentinel `Invoke-UpsertBlock` cannot be used (it would append after `</settings>` and corrupt the file). `endor-maven.ps1` uses `Invoke-UpsertXmlBlock`, which inserts an XML-comment-delimited fragment **immediately before** `</settings>`.
- **Fresh machine**: if `settings.xml` does not exist, a complete minimal schema-referenced file is created wrapping the Endor fragment.
- **Existing file**: the fragment is spliced in before `</settings>`; other elements are preserved. Re-runs replace only the Endor fragment (idempotent).
- **`<mirror>` with `<mirrorOf>*</mirrorOf>`** routes every repository request through the firewall.
- **No baked credentials**: Maven expands `${env.*}` from the process environment. `ENDOR_API_KEY_ID` / `ENDOR_API_SECRET` are already in `HKCU:\Environment`, and a matching `<server id="endor-firewall">` attaches them to the mirror.
- **Removal**: `endor-remove.ps1` strips only the Endor fragment; if the file is left with an empty `<settings>` scaffold, it is deleted.

---

### `endor-nuget.ps1`

Writes registry env vars and Endor-managed blocks to:

| File | Covers | Credentials |
|---|---|---|
| `%APPDATA%\NuGet\NuGet.Config` | dotnet CLI, NuGet CLI, Visual Studio, Rider — every tool that reads the user-level NuGet config | `%ENDOR_ATTR_USER%` / `%ENDOR_API_SECRET%` env var refs |

The block content and behaviour are identical to the macOS version (see [`bash/README.md`](../bash/README.md#endor-nugetsh)): `<clear />` supersedes every other source, the block is merged *into* the existing section, a pre-existing user `<clear />` is disabled reversibly, `<packageSourceMapping>` gets a `*` → `endor-firewall` block only when the section already exists, and a non-nuget.org source outside the block warns and exits 1.

Windows-specific notes:
- **Credentials come from `HKCU:\Environment`**, which every user process inherits — Visual Studio and Rider launched from the Start menu included. The macOS gap for IDEs launched outside a shell does not exist here.
- **`ClearTextPassword` is still used**, not NuGet's encrypted `Password`. Encryption is DPAPI-bound to the user who wrote it; a script running as SYSTEM would produce a value the developer cannot decrypt. The `%VAR%` reference keeps the secret out of the file anyway.
- **Removal** strips only the Endor blocks, restores a disabled user `<clear />`, keeps every section and never deletes the file. If `<packageSources>` ends up with no item, the dotnet default `nuget.org` entry is put back; nuget.org is never added next to a surviving private feed.
- **Limits**: a repo-level `nuget.config` overrides the user file for that repo (commit the firewall as the only source there too — snippet in the bash README); `dotnet nuget add source` appends after our block, so a developer-added source is live until the next MDM run.

---

### `endor-vscode.ps1`

Patches Microsoft VS Code Stable's installation-level `product.json`. It sets
`extensionsGallery.serviceUrl` to:

```
https://factory.endorlabs.com/v1/namespaces/<namespace>/firewall/vscode/_ak/<base64url-token>
```

The token is the unpadded Base64 URL encoding of
`ENDOR_API_KEY_ID:ENDOR_API_SECRET`. The structural JSON edit preserves
unrelated product and gallery fields and removes
`extensionsGallery.extensionUrlTemplate` entirely to disable VS Code's direct
upstream fallback.

The script:

- Finds system installs in Program Files, User Installer copies under
  `C:\Users\<user>\AppData\Local\Programs\Microsoft VS Code`, and current
  ten-character versioned resource directories.
- Installs the **Endor VS Code Extension Firewall** scheduled task as SYSTEM.
  Its `FileSystemWatcher` responds to updater replacements and rescans every
  minute to recover missed events and discover later installs.
- Modifies only `serviceUrl` and `extensionUrlTemplate`, preserving all other
  current `product.json` values during updates and credential rotation.

Run through Intune as SYSTEM. Restart VS Code after initial deployment if it is
open. Supported scope is Microsoft VS Code Stable native installs only;
Insiders, VSCodium/Code OSS, Store/packaged variants, and arbitrary portable
locations are excluded.

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
| `../shared/blocks/mavensettings.txt` | `%USERPROFILE%\.m2\settings.xml` |
| `../shared/blocks/nugetconfig_sources.txt` | `%APPDATA%\NuGet\NuGet.Config` → `<packageSources>` |
| `../shared/blocks/nugetconfig_credentials.txt` | `%APPDATA%\NuGet\NuGet.Config` → `<packageSourceCredentials>` |
| `../shared/blocks/nugetconfig_sourcemapping.txt` | `%APPDATA%\NuGet\NuGet.Config` → `<packageSourceMapping>` (only when the section exists) |

To change orchestration logic (which files get written, in what order), edit the relevant `templates/*.ps1` file directly.

Both support the same placeholder syntax as the macOS version:

| Syntax | When resolved | Use for |
|---|---|---|
| `{{PLACEHOLDER}}` | Generation time by `generate.ps1` | Values baked into the config file (e.g. registry host) |
| `${ENDOR_VAR}` | Runtime by the tool reading the config file | Credential values — resolved from registry env vars |

Available placeholders: `{{API_KEY_ID}}`, `{{API_SECRET}}`, `{{NPM_REGISTRY_URL}}`, `{{NPM_REGISTRY_HOST}}`, `{{NPM_AUTH_B64}}`, `{{PYPI_URL}}`, `{{PIP_INDEX_URL}}`, `{{TRUSTED_HOST}}`, `{{GO_PROXY_URL}}`, `{{MAVEN_REGISTRY_URL}}`, `{{NUGET_SOURCE_URL}}`, `{{VSCODE_SERVICE_URL}}`, `{{NAMESPACE}}`, `{{FQDN}}`, and `{{ATTR_USER}}` (filled at install time by the templates that support it)

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

- Removes the sentinel block from `.npmrc`, `.yarnrc.yml`, `pip.ini`, `uv.toml`, the go env file, `.m2\settings.xml`, and `NuGet.Config`
- Deletes all `ENDOR_*` and `POETRY_HTTP_BASIC_ENDOR_FIREWALL_*` keys from `HKCU:\Environment`
- Stops and removes the VS Code scheduled task, then restores the stable defaults for the two managed gallery properties
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
| `.m2\settings.xml` | Contains `${env.*}` references only — no credentials baked in. ACL-restricted to owner. |
| `NuGet.Config` | Contains `%ENDOR_*%` references only — no credentials baked in. ACL-restricted to owner. |
| VS Code `product.json` | Contains the authenticated `_ak/<token>` gallery URL and is readable by local users because VS Code must consume it. |
| `%ProgramData%\Endor Labs\vscode-firewall` | ACL-restricted to SYSTEM and Administrators; contains the remediation worker. |
| API secret in MDM | Generated scripts contain the API key and secret in plaintext (used to write registry env vars). Restrict access to the Intune policy and the generated `out/` directory. |
| `out/` directory | Add to `.gitignore`. Do not commit generated scripts to source control. |
