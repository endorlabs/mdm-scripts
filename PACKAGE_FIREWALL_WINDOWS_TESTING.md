# Endor Labs Package Firewall — Windows Testing Guide

Tests the [Endor Labs Package Firewall](https://docs.endorlabs.com/integrations/package-firewall) on **Windows** for JavaScript package managers (npm, pnpm, yarn, bun) and Python package managers (pip, uv, poetry).

> **Architecture note:** The Endor Labs Package Firewall exposes a direct proxy URL (`factory.endorlabs.com`) that package managers can point at without requiring JFrog Artifactory as an intermediary. All configurations below use this direct URL. For Artifactory-mediated setups, replace the firewall URL with your Artifactory virtual repo URL.

## Test packages

| Ecosystem | Package                           | Expected result                                                      |
| --------- | --------------------------------- | -------------------------------------------------------------------- |
| npm       | `aiohttp` *(n/a — use `express`)* | ✅ Allowed — installs successfully                                    |
| npm       | `endor-firewall-test@1.0.0`       | ❌ Blocked — 404 Not Found (via Artifactory) / 403 Forbidden (direct) |
| PyPI      | `aiohttp`                         | ✅ Allowed — installs successfully                                    |
| PyPI      | `endor-firewall-test==1.0.0`      | ❌ Blocked — 403 Forbidden                                            |

---

## JavaScript / Node.js Package Managers

The Endor Labs npm firewall URL is:
```
https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/npm/
```

---

### npm

#### How it works

npm reads `.npmrc` files in a layered order (later layers override earlier ones):

1. **Project-level:** `.npmrc` in the project root directory
2. **User-level:** `%USERPROFILE%\.npmrc` (e.g. `C:\Users\<you>\.npmrc`)
3. **Global:** `%APPDATA%\npm\etc\npmrc` (or wherever `npm prefix -g` points)
4. **Built-in:** shipped defaults

On Windows, `%USERPROFILE%` is typically `C:\Users\<username>` and `%APPDATA%` is `C:\Users\<username>\AppData\Roaming`.

#### Configuration

**User-level** `%USERPROFILE%\.npmrc`:
```ini
registry=https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/npm/
```

Alternatively, set via CLI (writes to user-level `.npmrc`):
```powershell
npm config set registry "https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/npm/"
```

#### Test commands

```powershell
# Verify npm is using the firewall registry
npm config get registry

# Should install successfully
npm install express

# Should fail — blocked by firewall
npm install endor-firewall-test@1.0.0
```

#### Expected result

```
# Blocked package (direct firewall URL)
npm error code E403
npm error 403 Forbidden - GET https://factory.endorlabs.com/.../endor-firewall-test-1.0.0.tgz

# Blocked package (via Artifactory)
npm error code E404
npm error 404 Not Found - GET https://<artifactory-host>/artifactory/api/npm/<repo>/endor-firewall-test/-/endor-firewall-test-1.0.0.tgz
```

---

### pnpm

#### How it works

pnpm respects `.npmrc` files (same lookup order as npm) **and** its own `pnpm-workspace.yaml` scoping. On Windows the user-level file is the same `%USERPROFILE%\.npmrc`.

pnpm config file lookup order:
1. Project `.npmrc` (project root)
2. Workspace root `.npmrc`
3. `%USERPROFILE%\.npmrc` (user-level)

#### Configuration

**User-level** `%USERPROFILE%\.npmrc`:
```ini
registry=https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/npm/
```

Or via CLI:
```powershell
pnpm config set registry "https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/npm/"
```

#### Test commands

```powershell
# Verify pnpm is using the firewall registry
pnpm config get registry

# Should install successfully
pnpm add express

# Should fail — blocked by firewall
pnpm add endor-firewall-test@1.0.0
```

#### Expected result

```
# Blocked package
 ERR_PNPM_FETCH_403  403 Forbidden: endor-firewall-test@1.0.0
```

---

### yarn (Classic — v1)

#### How it works

Yarn Classic reads `.yarnrc` for its own settings and also inherits `registry` from `.npmrc`. However, the canonical way to set the registry in Yarn Classic is via `.yarnrc`.

Config file lookup order on Windows:
1. Project `.yarnrc` (project root)
2. `%USERPROFILE%\.yarnrc` (user-level)
3. Global yarn config (set by `yarn config set --global`)

#### Configuration

**User-level** `%USERPROFILE%\.yarnrc`:
```yaml
registry "https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/npm/"
```

Or via CLI:
```powershell
yarn config set registry "https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/npm/"
```

#### Test commands

```powershell
# Verify yarn is using the firewall registry
yarn config get registry

# Should install successfully
yarn add express

# Should fail — blocked by firewall
yarn add endor-firewall-test@1.0.0
```

#### Expected result

```
# Blocked package
error An unexpected error occurred: "https://factory.endorlabs.com/.../endor-firewall-test-1.0.0.tgz: Request failed \"403 Forbidden\"".
```

---

### yarn (Berry — v2/v3/v4)

#### How it works

Yarn Berry uses `.yarnrc.yml` (YAML format) instead of `.yarnrc`. It does **not** read `.npmrc`. Config lookup on Windows:

1. Project `.yarnrc.yml` (project root, walking up to filesystem root)
2. `%USERPROFILE%\.yarnrc.yml` (user-level, Yarn Berry v3.1+)

> **Note:** Global user-level `.yarnrc.yml` support was added in Yarn Berry v3.1. For earlier Berry versions, the registry must be set per-project.

#### Configuration

**User-level** `%USERPROFILE%\.yarnrc.yml`:
```yaml
npmRegistryServer: "https://factory.endorlabs.com/v1/namespaces/<namespace>/firewall/npm/"
npmAuthIdent: "<username>:<password>"
```

`npmAuthIdent` is the Base64-decoded form; Yarn will encode it when sending requests. Alternatively use `npmAuthToken` if your credential is a bearer token.

**Per-project** `.yarnrc.yml` (if user-level isn't available):
```yaml
npmRegistryServer: "https://factory.endorlabs.com/v1/namespaces/<namespace>/firewall/npm/"
npmAuthIdent: "<username>:<password>"
```

#### Test commands

```powershell
# Verify
yarn config get npmRegistryServer

# Should install successfully
yarn add express

# Should fail — blocked by firewall
yarn add endor-firewall-test@1.0.0
```

---

### bun

#### How it works

Bun reads `bunfig.toml` for registry configuration. It does **not** use `.npmrc` or `.yarnrc` for registry settings (though it reads `.npmrc` for scoped package auth tokens).

Config file lookup on Windows:
1. Project `bunfig.toml` (project root)
2. `%USERPROFILE%\.bunfig.toml` (user-level global config)

#### Configuration

**User-level** `%USERPROFILE%\.bunfig.toml`:
```toml
[install]
registry = "https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/npm/"
```

**Per-project** `bunfig.toml` (project root):
```toml
[install]
registry = "https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/npm/"
```

#### Test commands

```powershell
# Should install successfully
bun add express

# Should fail — blocked by firewall
bun add endor-firewall-test@1.0.0
```

#### Expected result

```
# Blocked package
error: GET https://factory.endorlabs.com/.../endor-firewall-test-1.0.0.tgz - 403 Forbidden
```

---

## JavaScript Summary

| Tool     | Windows config file          | Global (user-level) support   | Credential method                      |
| -------- | ---------------------------- | ----------------------------- | -------------------------------------- |
| npm      | `%USERPROFILE%\.npmrc`       | ✅ Auto-detected               | Embedded in URL                        |
| pnpm     | `%USERPROFILE%\.npmrc`       | ✅ Auto-detected (same as npm) | Embedded in URL                        |
| yarn v1  | `%USERPROFILE%\.yarnrc`      | ✅ Auto-detected               | Embedded in URL                        |
| yarn v2+ | `%USERPROFILE%\.yarnrc.yml`  | ✅ v3.1+ only                  | `npmAuthIdent` or `npmAuthToken` field |
| bun      | `%USERPROFILE%\.bunfig.toml` | ✅ Auto-detected               | Embedded in URL                        |

> All four package managers use the same firewall npm endpoint. The firewall is registry-protocol-agnostic for npm traffic.

---

## Python Package Managers — Windows Equivalents

The Python firewall URL is:
```
https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/pypi/simple/
```

The core behavior is the same as Linux/macOS, but config file paths differ on Windows.

---

### pip (Windows)

#### How it works

pip config file lookup on Windows (later overrides earlier):

1. **Global (system-wide):** `%ProgramData%\pip\pip.ini` (e.g. `C:\ProgramData\pip\pip.ini`)
2. **User-level:** `%APPDATA%\pip\pip.ini` (e.g. `C:\Users\<you>\AppData\Roaming\pip\pip.ini`)
3. **Site (virtualenv):** `%VIRTUAL_ENV%\pip.ini`

> **Windows note:** On Windows the config file is `pip.ini` (not `pip.conf`), and it lives under `%APPDATA%\pip\` rather than `~/.config/pip/`. The `[global]` INI section and key names are identical to Linux.

#### Configuration

`%APPDATA%\pip\pip.ini`:
```ini
[global]
index-url = https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/pypi/simple/
trusted-host = factory.endorlabs.com
```

Create the directory if it does not exist:
```powershell
mkdir "$env:APPDATA\pip" -ErrorAction SilentlyContinue
notepad "$env:APPDATA\pip\pip.ini"
```

#### Test commands

```powershell
# Verify pip is using the firewall index
pip config list

# Should install successfully
pip install aiohttp

# Should fail with 403 Forbidden
pip install "endor-firewall-test==1.0.0"
```

#### Expected result

```
# Blocked package
ERROR: 403 Client Error: Forbidden for url: https://factory.endorlabs.com/.../endor_firewall_test-1.0.0-py3-none-any.whl.metadata
```

---

### uv (Windows)

#### How it works

uv config file lookup on Windows (project overrides user, which overrides system):

1. `--config-file` CLI flag or `UV_CONFIG_FILE` env var
2. `uv.toml` in the project directory (or any parent up to the root)
3. **User-level:** `%APPDATA%\uv\uv.toml` (e.g. `C:\Users\<you>\AppData\Roaming\uv\uv.toml`)
4. **System-level:** `%SystemDrive%\ProgramData\uv\uv.toml` (on Windows; less common)

> The user-level path is `%APPDATA%\uv\uv.toml` on Windows, equivalent to `~/.config/uv/uv.toml` on Linux/macOS. Credentials are embedded directly in the index URL — no separate credential store needed.

#### Configuration

**Global (user-level)** — applies to all projects:

Create `%APPDATA%\uv\uv.toml`:
```powershell
mkdir "$env:APPDATA\uv" -ErrorAction SilentlyContinue
notepad "$env:APPDATA\uv\uv.toml"
```

`%APPDATA%\uv\uv.toml`:
```toml
[[index]]
url = "https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/pypi/simple/"
default = true
```

**Per-project** — place `uv.toml` in the project directory (overrides global):
```toml
[[index]]
url = "https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/pypi/simple/"
default = true
```

#### Test commands

```powershell
# Initialize a new project (if needed)
uv init --no-workspace

# Should install successfully
uv add aiohttp

# Should fail with 403 Forbidden
uv add "endor-firewall-test==1.0.0"
```

#### Expected result

```
# Blocked package
error: Failed to fetch: `https://factory.endorlabs.com/.../endor_firewall_test-1.0.0-py3-none-any.whl.metadata`
  Caused by: HTTP status client error (403 Forbidden) for url (...)
```

---

### poetry (Windows)

#### How it works

Poetry's `pyproject.toml`-based source declaration is cross-platform — the file itself is identical to Linux/macOS. The only Windows-specific difference is **where Poetry stores its global config and credential keyring**.

Credentials via environment variables work identically on Windows. Set them in PowerShell:

```powershell
$env:POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME = "<username>"
$env:POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD = "<password>"
```

For persistent env vars across sessions, set them as user environment variables:
```powershell
[System.Environment]::SetEnvironmentVariable("POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME", "<username>", "User")
[System.Environment]::SetEnvironmentVariable("POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD", "<password>", "User")
```

> **macOS keychain caveat (Linux/Mac-specific):** The keychain issue with `+` characters in tokens does not apply to Windows. However, Windows Credential Manager (used by Poetry on Windows) has its own quirks — env vars remain the most reliable cross-platform approach.

> **Source name underscore bug:** The same bug applies on Windows — always use **hyphens** in source names (e.g. `endor-firewall`), not underscores.

> **No global default index:** Same limitation as Linux — each project must declare `[[tool.poetry.source]]` in `pyproject.toml`. There is no system-wide Poetry registry setting.

#### Configuration

1. Add source to `pyproject.toml` (identical to Linux):

```toml
[[tool.poetry.source]]
name = "endor-firewall"
url = "https://factory.endorlabs.com/v1/namespaces/<namespace>/firewall/pypi/simple/"
priority = "primary"
```

Or via CLI:
```powershell
poetry source add endor-firewall "https://factory.endorlabs.com/v1/namespaces/<namespace>/firewall/pypi/simple/" --priority=primary
```

2. Set credentials as environment variables (PowerShell):

```powershell
$env:POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME = "<username>"
$env:POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD = "<password>"
```

#### Test commands

```powershell
# Initialize a new project (if needed)
poetry init --no-interaction

# Should install successfully
poetry add aiohttp

# Should fail with 403 Forbidden
poetry add "endor-firewall-test==1.0.0"
```

#### Expected result

```
# Blocked package
Source (endor-firewall): Failed to retrieve metadata at https://factory.endorlabs.com/.../endor_firewall_test-1.0.0-py3-none-any.whl.metadata
403 Client Error: Forbidden for url: https://factory.endorlabs.com/.../endor_firewall_test-1.0.0-py3-none-any.whl
```

---

## Python Summary (Windows vs Linux/macOS)

| Tool   | Linux/macOS config path      | Windows config path                      | Credential method                |
| ------ | ---------------------------- | ---------------------------------------- | -------------------------------- |
| pip    | `~/.config/pip/pip.conf`     | `%APPDATA%\pip\pip.ini`                  | Embedded in URL                  |
| uv     | `~/.config/uv/uv.toml`       | `%APPDATA%\uv\uv.toml`                   | Embedded in URL                  |
| poetry | `pyproject.toml` per project | `pyproject.toml` per project (unchanged) | Env vars (`POETRY_HTTP_BASIC_*`) |

> **Key difference:** On Windows, `pip` uses `.ini` extension and lives under `%APPDATA%\pip\`, and `uv` uses `%APPDATA%\uv\`. The config file syntax and key names are identical across platforms.

---

## Firewall behavior (all platforms)

- Allowed packages return **307** (redirect to public registry for download)
- Blocked packages return **403 Forbidden** (direct firewall) or **404 Not Found** (via Artifactory) on the `.whl.metadata` or `.tgz` fetch, halting installation
- Transitive dependencies are also checked — if any dep in the tree is blocked, the entire install fails

---

## Windows-specific troubleshooting

| Issue                                  | Cause                               | Fix                                                                                                            |
| -------------------------------------- | ----------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `pip config list` shows no `index-url` | Config file not found               | Verify `%APPDATA%\pip\pip.ini` exists (not `pip.conf`)                                                         |
| uv ignores `uv.toml`                   | Wrong directory                     | Place file at `%APPDATA%\uv\uv.toml` for global, or project root for per-project                               |
| Poetry 401 errors despite env vars set | Env vars not in current shell scope | Use `[System.Environment]::SetEnvironmentVariable` with `"User"` scope, then restart terminal                  |
| Poetry env var not picked up           | Underscore in source name           | Rename source to use hyphens: `endor-firewall` not `endor_firewall`                                            |
| npm/pnpm ignores `.npmrc`              | Wrong path                          | Confirm `%USERPROFILE%\.npmrc` exists; run `npm config list` to see all active sources                         |
| Yarn Berry ignores `.yarnrc.yml`       | Yarn v3.0 or earlier                | User-level `.yarnrc.yml` requires v3.1+; use per-project config for earlier versions                           |
| TLS/SSL errors on Windows              | Corporate proxy or self-signed cert | Add `strict-ssl=false` (npm) or `ssl_verify = false` (uv) as a temporary diagnostic; do not ship to production |
