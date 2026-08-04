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
│   ├── vscode.ps1           ← orchestration: product.json gallery patch (JSON-aware)
│   ├── maven.ps1            ← orchestration: .m2\settings.xml write (XML-aware)
│   └── remove.ps1           ← orchestration: sentinel block + registry env var removal
└── out/                     ← generated scripts (gitignore this)
    └── <namespace>/
        ├── endor-js.ps1
        ├── endor-python.ps1
        ├── endor-go.ps1
        ├── endor-maven.ps1
        ├── endor-vscode.ps1
        ├── endor-vscode-repatch.ps1
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
└── vscodegallery.txt        ← product.json extensionsGallery overrides  (key-level merge)
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
| `endor-all.ps1` | Team uses multiple ecosystems — single-script deploy |
| `endor-vscode.ps1` | Team uses VS Code and/or VS Code Insiders extensions. **Not** part of `endor-all.ps1` — deploy it alongside. See [VS Code notes](#vs-code-notes) first. |



Upload the script file. Ensure it runs as **SYSTEM** — the script detects the logged-in console user internally via `explorer.exe` and writes config files to the correct user profile.

---

## How credentials are stored

All scripts share a common credential architecture:

**Registry** — persistent user-level environment variables written to `HKCU:\Environment`:

```
ENDOR_API_KEY_ID                          = <key-id>
ENDOR_API_SECRET                          = <secret>
ENDOR_ATTR_USER                           = <attributed username: <console-user>@<machine>>
ENDOR_AUTH_B64                            = <base64(attr-user:secret)>
ENDOR_API_SECRET_B64                      = <base64(secret)>
ENDOR_NPM_REGISTRY_URL                    = https://factory.endorlabs.com/v1/namespaces/my-team/firewall/npm/
POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME = <attr-user>
POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD = <secret>
```

Config files reference these as `${ENDOR_...}` env var placeholders — the tools expand them at
runtime from the process environment.

pip, uv, go and VS Code are **not** in that list: none of them can expand env vars in their
config, so those four get literal credentials baked in at install time. `ENDOR_PYPI_URL` and
`ENDOR_GO_PROXY_URL` are computed during the run but deliberately **not** written to the
registry, because nothing reads them there.

**Windows advantage over macOS:** `HKCU:\Environment` variables are inherited by every process the user starts — including Makefiles, git hooks, IDE terminals, and scheduled tasks. No shell profile sourcing required. This natively covers the non-interactive context gap.

**Credential rotation**: redeploy the MDM script with new credentials. `HKCU:\Environment` and
the four literal-credential consumers (pip, uv, go, VS Code) are all updated in place.
`endor-vscode.ps1` detects a rotated credential as `stale`, restores the original
`product.json` gallery, then re-patches it — so the captured original survives any number of
rotations.

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
| `%APPDATA%\uv\uv.toml` | uv | Literal — uv cannot expand env vars |

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

### `endor-vscode.ps1`

Patches the `extensionsGallery` object in VS Code's `product.json` so extension search,
install, update **and `code --install-extension`** all resolve through the firewall.

| Install path | Editions |
|---|---|
| `%ProgramFiles%\Microsoft VS Code{, Insiders}\resources\app\product.json` | system-wide |
| `<UserProfile>\AppData\Local\Programs\Microsoft VS Code{, Insiders}\...` | per-user |

Per-user paths are resolved from the **console user's** profile, not `%LOCALAPPDATA%` —
Intune runs as SYSTEM, whose `LOCALAPPDATA` lives under `C:\Windows`, so relying on the env
var would silently miss every per-user install on the fleet.

Exactly one key is set and one removed; every other key is left as VS Code shipped it,
including keys added by future VS Code versions:

| Key | Action | Why |
|---|---|---|
| `serviceUrl` | set | VS Code derives both `${serviceUrl}/extensionquery` (search) and `${serviceUrl}/vscode/{publisher}/{name}/latest` (install/update) from it |
| `extensionUrlTemplate` | **removed** | It is the fallback VS Code uses when the resource API returns 5xx. Left in place, a firewall outage would silently resolve versions from `www.vscode-unpkg.net` — bypassing the firewall at precisely the wrong moment. With the key absent that failure retries the firewall's own `extensionquery`, and fails the install if that fails too. Fail-closed. |
| `controlUrl` | untouched | Microsoft's malicious-extension revocation list — free defense in depth alongside Endor |
| `resourceUrlTemplate`, `itemUrl`, `publisherUrl`, `nlsBaseUrl`, `mcpUrl`, `accessSKUs` | untouched | README/changelog rendering, marketplace web views, language packs, Copilot entitlement |

**How enforcement works.** Blocked versions are filtered out of the gallery response, so they
are never offered and cannot be selected. Extension *downloads* still come from Microsoft's
CDN by design — the asset URLs come from the gallery response, and the firewall filters rather
than rewrites them. So:

- Keep `*.vsassets.io` and `*.vscode-unpkg.net` reachable through any egress proxy.
- Enforcement is **discovery-time**. Extensions already installed, sideloaded `.vsix` files,
  and anything installed before the patch landed are not retroactively caught.

**Managed marker instead of a sentinel block.** `product.json` is JSON, so it can carry
neither a `#` comment nor an env-var reference. The script adds one top-level key holding the
original `extensionsGallery` verbatim, base64-encoded, so `endor-remove.ps1` restores it
byte-for-byte. Re-running is a no-op when already current; a changed credential or namespace
is detected as `stale`, which restores the original first and then re-patches — the script
never patches on top of a patch.

Because PowerShell's `ConvertFrom-Json` accepts trailing commas (both the 5.1 and 7.x
implementations do), the validator additionally checks for a dangling comma before `}` or `]`
before installing a patched file. Without that check a corrupt `product.json` would pass
validation here and only fail inside VS Code's own strict parser.

**The update watcher.** VS Code replaces `product.json` on every update — roughly monthly for
stable, **nightly for Insiders** — on a schedule unrelated to MDM check-in. So
`endor-vscode.ps1` also registers a Scheduled Task at `\Endor\PackageFirewall-VSCode`, running
as `NT AUTHORITY\SYSTEM` with startup, logon and hourly triggers. Task Scheduler has no
file-watch trigger, so the logon trigger stands in for "the user updated, then relaunched" and
the hourly repetition is the real backstop.

The race is not fully closable: if a developer relaunches VS Code before the task fires, that
one session talks to the public marketplace. It is therefore made *countable* rather than
invisible — each re-apply bumps `repatch_count` in the sidecar state, and later runs print it
(`watcher has re-applied the patch 4x (last: ...)`). Pass `-NoVSCodeWatcher` to skip the task;
the script then says so loudly but still exits 0, because failing every MDM check-in over a
deliberate setting is just alert fatigue.

Sidecar state lives at `%ProgramData%\Endor\PackageFirewall\vscode\`, ACL-restricted to
`SYSTEM` (resolved from the well-known SID `S-1-5-18`, since that account name is localised on
non-English Windows). It holds the rendered gallery URL, which the Scheduled Task reads back —
the task can fire at startup with nobody logged in, so it cannot recompute the attributed
token itself.

<a id="vs-code-notes"></a>
#### VS Code notes — read before deploying

1. **Run as SYSTEM or Administrator**, and note that a running VS Code can hold
   `product.json` open. The script checks writability up front and reports a permission
   problem as such rather than half-applying a patch.
2. **The gallery token is readable by every user, and that is unavoidable.** `product.json`
   must stay readable by everyone who runs VS Code, and the credential is a URL path segment,
   so any local user can read a working firewall token — it also appears in VS Code's own
   logs. VS Code offers no env-var indirection in `product.json`. Mitigate blast radius, not
   exposure: **use a dedicated, separately revocable API key for VS Code**, never the same one
   as npm/PyPI/Maven.
3. **Restart VS Code** after install or removal — `product.json` is read once at startup.

#### Troubleshooting

A blocked extension produces an **error line in the Output -> Window channel** even though
enforcement is working correctly:

```
Error while getting the latest version for the extension <publisher>.<name>
```

That is the expected path: the firewall answers `/latest` with `400`, VS Code classifies it as
a client error and retries `extensionquery`, where the blocked version is filtered out. Set
`Developer: Set Log Level... -> Trace` and filter on `[Marketplace]` to see it. There is no
"Marketplace" output channel — those strings are view names.

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
| `../shared/blocks/vscodegallery.txt` | VS Code `product.json` → `extensionsGallery` (merged key-by-key, not written verbatim) |

To change orchestration logic (which files get written, in what order), edit the relevant `templates/*.ps1` file directly.

Both support the same placeholder syntax as the macOS version:

| Syntax | When resolved | Use for |
|---|---|---|
| `{{PLACEHOLDER}}` | Generation time by `generate.ps1` | Values baked into the config file (e.g. registry host) |
| `${ENDOR_VAR}` | Runtime by the tool reading the config file | Credential values — resolved from registry env vars |

There are **two** rounds of `{{...}}` substitution, because per-developer attribution
(`<console-user>@<machine>`) does not exist until the script runs on the developer's machine:

| Placeholder | Resolved |
|---|---|
| `{{NAMESPACE}}`, `{{FQDN}}`, `{{FQDN_HOST}}`, `{{API_KEY_ID}}`, `{{API_SECRET}}`, `{{API_SECRET_B64}}`, `{{NPM_REGISTRY_URL}}`, `{{NPM_REGISTRY_HOST}}`, `{{PYPI_URL}}`, `{{TRUSTED_HOST}}`, `{{MAVEN_REGISTRY_URL}}`, `{{VSCODE_GALLERY_BASE}}` | Generation time, by `Invoke-Substitute` in `generate.ps1` |
| `{{NPM_AUTH_B64}}`, `{{PIP_INDEX_URL}}`, `{{GO_PROXY_URL}}`, `{{VSCODE_GALLERY_URL}}` | **Install time**, by the orchestration template on the developer's machine |

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

Deploy `endor-remove.ps1`. It strips the sentinel block from every managed config file,
deletes the Endor `HKCU:\Environment` values and, for VS Code, unregisters the Scheduled Task,
restores the original `extensionsGallery` from the marker, drops the marker, and deletes the
sidecar state. Restart VS Code afterwards.

Deploy `endor-remove.ps1` to strip all Endor configuration from a machine. It:

- Removes the sentinel block from `.npmrc`, `.yarnrc.yml`, `pip.ini`, `uv.toml`, the go env file, and `.m2\settings.xml`
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
| VS Code `product.json` | **Contains the gallery token in a file every user can read**, and must, because VS Code reads it as the user and offers no indirection. Use a **dedicated, separately revocable API key** for VS Code so rotation and revocation do not disturb the other ecosystems. |
| VS Code sidecar state | `%ProgramData%\Endor\PackageFirewall\vscode\` — holds the rendered gallery URL for the Scheduled Task. ACL-restricted to `SYSTEM`, so better protected than `product.json` itself. |
| `-DryRun` output | Redacts the VS Code `_ak/<token>` path segment. The other ecosystems echo full credentialed URLs; VS Code deviates deliberately, because this token is a bearer credential in a URL *path* and MDM consoles retain script output for far more people than can read the target file. |


| Item | Note |
|---|---|
| `HKCU:\Environment` | Contains credentials as plain REG_SZ strings. Access is restricted to the owning user by default Windows ACLs. |
| `pip.ini` | Contains credentials in the `index-url`. File is ACL-restricted to owner. Credentials may appear in pip debug logs (`pip install -v`). pip cannot use env var references. |
| `.npmrc`, `.yarnrc.yml`, `uv.toml` | Contain `${VAR}` references only — no credentials baked in. |
| `.m2\settings.xml` | Contains `${env.*}` references only — no credentials baked in. ACL-restricted to owner. |
| API secret in MDM | Generated scripts contain the API key and secret in plaintext (used to write registry env vars). Restrict access to the Intune policy and the generated `out/` directory. |
| `out/` directory | Add to `.gitignore`. Do not commit generated scripts to source control. |
