# Endor Package Firewall — MDM Script Generator

Generates self-contained shell scripts for IT admins to push via MDM (Kandji, Jamf, or any generic MDM tool). Once deployed, scripts configure developer machines to route package installations through the Endor Package Firewall — without overwriting existing custom configuration.

---

## Directory layout

```
bash/
├── generate.sh
├── lib/
│   └── common.sh
├── templates/
│   ├── envsh.sh             ← orchestration: writes env.sh, sources from shell profiles
│   ├── js.sh                ← orchestration: npm / yarn config file writes
│   ├── python.sh            ← orchestration: pip / uv config file writes
│   ├── go.sh                ← orchestration: go env file write
│   ├── maven.sh             ← orchestration: ~/.m2/settings.xml write (XML-aware)
│   ├── vscode.sh            ← orchestration: product.json gallery patch (JSON-aware)
│   └── remove.sh            ← orchestration: sentinel block removal
└── out/                     ← generated scripts (gitignore this)
    └── <namespace>/
        ├── endor-js.sh
        ├── endor-python.sh
        ├── endor-go.sh
        ├── endor-maven.sh
        ├── endor-all.sh
        ├── endor-vscode.sh
        ├── endor-vscode-repatch.sh
        └── endor-remove.sh

../shared/blocks/            ← edit these to customise what gets written to config files
├── envsh.txt                ← ~/.config/endor/env.sh content
├── npmrc.txt                ← ~/.npmrc content
├── yarnrc_classic.txt       ← ~/.yarnrc (yarn 1.x) content
├── yarnrc.txt               ← ~/.yarnrc.yml (yarn 2+) content
├── pipconf.txt              ← pip.conf content
├── uvtoml.txt               ← ~/.config/uv/uv.toml content
├── goenv.txt                ← go env file content  (path resolved via `go env GOENV`)
├── mavensettings.txt        ← ~/.m2/settings.xml fragment  (Maven mirror + server)
└── vscodegallery.txt        ← product.json extensionsGallery overrides (key-level merge)
```

---

## Step 1 — Generate the MDM scripts

Pass credentials as environment variables (not positional arguments — avoids shell history and `ps` exposure):

```bash
ENDOR_NAMESPACE=my-team \
ENDOR_API_KEY_ID=your-key-id \
ENDOR_API_SECRET=your-key-secret \
./generate.sh
```

Or using a `.env` file (add `.env` to `.gitignore`):

```bash
# .env
ENDOR_NAMESPACE=my-team
ENDOR_API_KEY_ID=your-key-id
ENDOR_API_SECRET=your-key-secret
```

```bash
set -a; source .env; set +a
./generate.sh
```

`ENDOR_FQDN` is optional and defaults to `https://factory.endorlabs.com`. Override it to target a different environment:

```bash
ENDOR_FQDN=https://factory.staging.endorlabs.com \
ENDOR_NAMESPACE=my-team \
ENDOR_API_KEY_ID=your-key-id \
ENDOR_API_SECRET=your-key-secret \
./generate.sh
```

Re-running `generate.sh` overwrites the same `out/<namespace>/` directory — no accumulation of stale directories.

---

## Step 2 — Upload to your MDM tool

Each script in `out/<env>-<namespace>/` is **fully self-contained** — no external files or dependencies needed at runtime.

### Which script to upload

| Script | Use when |
|---|---|
| `endor-js.sh` | Team uses JavaScript (npm, pnpm, yarn, bun) only |
| `endor-python.sh` | Team uses Python (pip, uv, poetry) only |
| `endor-go.sh` | Team uses Go only |
| `endor-maven.sh` | Team uses Java / Maven only |
| `endor-all.sh` | Team uses multiple ecosystems — single-script deploy |
| `endor-vscode.sh` | Team uses VS Code and/or VS Code Insiders extensions. **Not** part of `endor-all.sh` — deploy it alongside. See [VS Code prerequisites](#vs-code-prerequisites) first. |

`endor-vscode-repatch.sh` is *not* uploaded. `endor-vscode.sh` embeds and installs it; it
is written out only so you can read what gets installed.

Upload the script file. Ensure it runs as **root** — the script detects the logged-in console user internally and writes config files to the correct home directory.

---

## How credentials are stored

All scripts share a common credential architecture:

**`~/.config/endor/env.sh`** — single credential source, written by every install script:
```bash
export ENDOR_API_KEY_ID="..."
export ENDOR_API_SECRET="..."
export ENDOR_AUTH_B64="..."          # base64(key:secret) — used by npm/pnpm/yarn/bun
export ENDOR_ATTR_USER="..."         # attributed username — <console-user>@<machine>
export ENDOR_API_SECRET_B64="..."    # base64(secret)
export ENDOR_NPM_REGISTRY_URL="..."  # used by npm, yarn 2+
export POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME="..."
export POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD="..."
```

pip, uv, go and VS Code are **not** in that list: none of them can expand env vars in
their config, so those four get literal credentials baked in at install time.

Shell profiles (`.zshrc`, `.bash_profile`, `.bashrc`) each get a one-line sentinel block that sources this file. Config files reference env vars rather than baking credentials — except pip, which cannot expand env vars.

**Credential rotation**: update `env.sh` on target machines (redeploy MDM script). No config
file changes needed — except for the four consumers that cannot use env vars (pip, uv, go,
VS Code), which the redeployed script rewrites in place. `endor-vscode.sh` detects a rotated
credential as `stale`, restores the original `product.json` gallery, then re-patches it, so
the captured original is never lost across rotations.

---

## What the scripts do

### `endor-js.sh`

Writes `~/.config/endor/env.sh` and an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| `~/.npmrc` | npm (all), pnpm (8–11.x), yarn classic (1.x), bun | `${ENDOR_AUTH_B64}` env var ref |
| `~/.yarnrc.yml` | yarn 2+ / berry | `${ENDOR_API_KEY_ID}:${ENDOR_API_SECRET}` env var refs |

Key behaviour:
- **`_auth` (base64)** is used instead of `_authToken` — required for bun compatibility (`_authToken` causes 401 with bun)
- Yarn classic needs `.npmrc` for auth (`.yarnrc` alone fails) — covered by `.npmrc` write
- `bunfig.toml` is project-level and intentionally not written by MDM; document separately for devs who prefer it

### `endor-go.sh`

Writes `~/.config/endor/env.sh` and an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| Go env file (path from `go env GOENV`) | go modules (all versions) | Literal — baked into `GOPROXY` URL at generation time |

Key behaviour:
- **Path detection**: the script runs `go env GOENV` (with the user's `HOME`) to find the correct path — on macOS this is `~/Library/Application Support/go/env`, on Linux `~/.config/go/env`. Falls back to the OS default if `go` is not installed.
- **GOPROXY** is set to `https://<key>:<secret>@factory.endorlabs.com/.../firewall/go/,direct` — the `,direct` suffix falls back to the upstream module proxy if a module is not blocked
- Credentials are baked in at generation time because Go env files do not support env var expansion
- The go env file is read by all `go` commands regardless of shell — covers IDE terminals, Makefiles, git hooks, and non-interactive scripts
- The go env file takes lower precedence than the `GOPROXY` process env var, so project-level overrides (`go env -w` in a workspace) remain possible
- Sentinel comment lines (`# ...`) are silently skipped by `go env` parsing

---

### `endor-python.sh`

Writes `~/.config/endor/env.sh` and an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| `~/.pip/pip.conf` | pip (legacy path) | Literal — pip cannot expand env vars |
| `~/.config/pip/pip.conf` | pip (XDG / Linux standard) | Literal |
| `~/Library/Application Support/pip/pip.conf` | pip (macOS primary) | Literal |
| `~/.config/uv/uv.toml` | uv (does **not** read pip.conf) | literal credential (uv cannot expand env vars) |

Key behaviour:
- **pip**: uses a named `[endor-firewall]` section — preserves any existing `[global]` settings; credentials are literal (pip limitation)
- **uv**: uv ignores pip.conf entirely; `~/.config/uv/uv.toml` is the user-level global config; carries a literal credential baked in at install time
- **poetry**: credentials are in `env.sh` as `POETRY_HTTP_BASIC_ENDOR_FIREWALL_*` — no separate write step

> For poetry, developers still need to add the source to `pyproject.toml` (URL only, no credentials):
> ```toml
> [[tool.poetry.source]]
> name     = "endor-firewall"
> url      = "https://factory.endorlabs.com/v1/namespaces/my-team/firewall/pypi/simple/"
> priority = "primary"
> ```

---

### `endor-maven.sh`

Writes an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| `~/.m2/settings.xml` | Maven (all versions); Gradle when it reads `~/.m2` | `${env.ENDOR_API_KEY_ID}` / `${env.ENDOR_API_SECRET}` env var refs |

Key behaviour:
- **XML-aware writer**: `settings.xml` is XML, so the generic `#`-sentinel `upsert_block` cannot be used (it would append after `</settings>` and corrupt the file). `endor-maven.sh` uses `upsert_xml_block`, which inserts an XML-comment-delimited fragment **immediately before** `</settings>` so it always lands inside the `<settings>` root.
- **Fresh machine**: if `~/.m2/settings.xml` does not exist, a complete minimal schema-referenced `settings.xml` is created wrapping the Endor fragment.
- **Existing file**: the fragment is spliced in before `</settings>`; all other elements (e.g. an admin `<profile>`) are preserved. Re-runs replace only the Endor fragment (idempotent).
- **`<mirror>` with `<mirrorOf>*</mirrorOf>`** routes every repository request through the firewall — the Maven equivalent of npm's `registry=`.
- **No baked credentials**: Maven natively expands `${env.*}` from process environment variables. The required `ENDOR_API_KEY_ID` / `ENDOR_API_SECRET` are already exported by `env.sh`, and a matching `<server id="endor-firewall">` attaches them to the mirror — so no new credential plumbing is added.
- **Removal**: `endor-remove.sh` strips only the Endor fragment; if the file is left with an empty `<settings>` scaffold (was Endor-only), it is deleted.

---

### `endor-vscode.sh`

Patches the `extensionsGallery` object in VS Code's `product.json` so extension search,
install, update **and `code --install-extension`** all resolve through the firewall.

| Install path | Editions |
|---|---|
| `/Applications/Visual Studio Code{, - Insiders}.app/Contents/Resources/app/product.json` | macOS, system |
| `~/Applications/Visual Studio Code{, - Insiders}.app/...` | macOS, per-user |
| `/usr/share/code{,-insiders}/resources/app/product.json` | Linux (.deb / .rpm) |
| `/opt/visual-studio-code{,-insiders}/resources/app/product.json` | Linux (tarball / AUR) |

Exactly one key is set and one removed; every other key is left as VS Code shipped it,
including keys added by future VS Code versions:

| Key | Action | Why |
|---|---|---|
| `serviceUrl` | set | VS Code derives both `${serviceUrl}/extensionquery` (search) and `${serviceUrl}/vscode/{publisher}/{name}/latest` (install/update) from it |
| `extensionUrlTemplate` | **removed** | It is the fallback VS Code uses when the resource API returns 5xx. Left in place, a firewall outage would silently resolve versions from `www.vscode-unpkg.net` — bypassing the firewall at precisely the wrong moment. With the key absent that failure retries the firewall's own `extensionquery` instead, and fails the install if that fails too. Fail-closed. |
| `controlUrl` | untouched | Microsoft's malicious-extension revocation list — free defense in depth alongside Endor |
| `resourceUrlTemplate`, `itemUrl`, `publisherUrl`, `nlsBaseUrl`, `mcpUrl`, `accessSKUs` | untouched | README/changelog rendering, marketplace web views, language packs, Copilot entitlement |

**How enforcement works.** Blocked versions are filtered out of the gallery response, so
they are never offered and cannot be selected. Extension *downloads* still come from
Microsoft's CDN by design — the asset URLs come from the gallery response, and the firewall
filters rather than rewrites them. Consequences worth knowing:

- Keep `*.vsassets.io` and `*.vscode-unpkg.net` reachable through any egress proxy, or
  installs break.
- Enforcement is **discovery-time**. Extensions already installed, sideloaded `.vsix`
  files, and anything installed before the patch landed are not retroactively caught.

**Managed marker instead of a sentinel block.** `product.json` is JSON, so it can carry
neither a `#` comment nor an `${ENDOR_*}` reference. The script adds one top-level key:

```json
"_endorPackageFirewall": {"schema":1,"namespace":"…","appVersion":"…","via":"awk","originalExtensionsGalleryB64":"…"}
```

`originalExtensionsGalleryB64` is the original `extensionsGallery` block verbatim, so
`endor-remove.sh` restores it byte-for-byte. It travels with the file and cannot desync
from it. Re-running is a no-op when already current; a changed credential or namespace is
detected as `stale`, which restores the original first and then re-patches — the script
never patches on top of a patch.

**The update watcher.** VS Code replaces `product.json` on every update — roughly monthly
for stable, **nightly for Insiders** — on a schedule unrelated to MDM check-in. So
`endor-vscode.sh` also installs a re-apply hook:

| Platform | Hook |
|---|---|
| macOS | `/Library/LaunchDaemons/com.endorlabs.pkgfirewall.vscode.plist` — `WatchPaths` on each `product.json` *and* its parent directory (the updater swaps the whole directory), plus an hourly `StartInterval` backstop |
| Linux | `endor-vscode-firewall.{service,path,timer}` under systemd; `/etc/cron.hourly/endor-vscode-firewall` when systemd is absent |

The race is not fully closable: if a developer relaunches VS Code before the watcher fires,
that one session talks to the public marketplace. It is therefore made *countable* rather
than invisible — each re-apply bumps `repatch_count` in the sidecar state, and subsequent
runs print it (`watcher has re-applied the patch 4× (last: …)`). Pass
`--no-vscode-watcher` to skip the hook; the script then says so loudly but still exits 0,
because failing every MDM check-in over a deliberate setting is just alert fatigue.

Sidecar state (not inside the app bundle, `0600`, root-owned):
`/Library/Application Support/Endor/package-firewall/vscode/` on macOS,
`/var/lib/endor/package-firewall/vscode/` on Linux.

<a id="vs-code-prerequisites"></a>
#### VS Code prerequisites — read before deploying

1. **macOS Ventura+ needs the App Management TCC grant.** Writing inside an `.app` bundle
   signed by another developer is gated by `SystemPolicyAppBundles`, and **root is not
   exempt**. Grant your MDM agent App Management (or Full Disk Access) via a PPPC profile.
   Without it the script fails loudly with an explanation rather than silently no-op'ing.
2. **The gallery token is world-readable, and that is unavoidable.** `product.json` is
   `root:wheel 0644` and must stay readable by every user who runs VS Code. Because the
   credential is a URL path segment, any local user can read a working firewall token, and
   it also appears in VS Code's own logs. VS Code offers no env-var indirection in
   `product.json` — this is a property of the only delivery channel it gives us. Mitigate
   blast radius, not exposure: **use a dedicated, separately revocable API key for VS
   Code**, never the same one as npm/PyPI/Maven.
3. **`codesign --verify` will report the bundle as modified.** Expected — `product.json` is
   inside the `CodeResources` seal. VS Code still runs (this is how every Open VSX
   deployment works), though it may re-prompt for Keychain access once. **Do not re-sign to
   "fix" it**: ad-hoc re-signing strips the hardened-runtime entitlements and changes the
   designated requirement, which *would* durably break stored GitHub auth.
4. **snap and flatpak installs cannot be patched.** Their payload is mounted read-only. The
   script detects them by path, explains, and warns rather than failing silently. Use the
   `.deb`/`.rpm`/tarball build instead.
5. **Restart VS Code** after install or removal — `product.json` is read once at startup.

#### Troubleshooting

A blocked extension produces an **error line in the Output → Window channel** even though
enforcement is working correctly:

```
Error while getting the latest version for the extension <publisher>.<name>
```

That is the expected path: the firewall answers `/latest` with `400`, VS Code classifies it
as a client error and retries `extensionquery`, where the blocked version is filtered out.
Set `Developer: Set Log Level… → Trace` and filter on `[Marketplace]` to see it. There is no
"Marketplace" output channel — those strings are view names.

---

## Customising

To change what gets written to a config file on target machines, edit the relevant file in `../shared/blocks/` directly:

| File | Written to |
|---|---|
| `../shared/blocks/envsh.txt` | `~/.config/endor/env.sh` |
| `../shared/blocks/npmrc.txt` | `~/.npmrc` |
| `../shared/blocks/yarnrc_classic.txt` | `~/.yarnrc` (yarn 1.x) |
| `../shared/blocks/yarnrc.txt` | `~/.yarnrc.yml` (yarn 2+) |
| `../shared/blocks/pipconf.txt` | `~/.pip/pip.conf`, `~/.config/pip/pip.conf`, `~/Library/Application Support/pip/pip.conf` |
| `../shared/blocks/uvtoml.txt` | `~/.config/uv/uv.toml` |
| `../shared/blocks/goenv.txt` | `~/.config/go/env` |
| `../shared/blocks/mavensettings.txt` | `~/.m2/settings.xml` |
| `../shared/blocks/vscodegallery.txt` | VS Code `product.json` → `extensionsGallery` (merged key-by-key, not written verbatim) |

To change orchestration logic (which files get written, in what order, with what warnings), edit the relevant `templates/*.sh` file directly.

Both support `{{PLACEHOLDER}}` substitution at generation time and `${ENDOR_VAR}` env var references at runtime:

| Syntax | When resolved | Use for |
|---|---|---|
| `{{PLACEHOLDER}}` | Generation time by `generate.sh` | Values baked into the config file (e.g. registry host in a key position) |
| `${ENDOR_VAR}` | Runtime by the tool reading the config file | Credential values — kept out of config files, resolved from `env.sh` |

There are in fact **two** rounds of `{{...}}` substitution, because per-developer
attribution (`<console-user>@<machine>`) does not exist until the script runs on the
developer's machine:

| Placeholder | Resolved |
|---|---|
| `{{NAMESPACE}}`, `{{FQDN}}`, `{{FQDN_HOST}}`, `{{API_KEY_ID}}`, `{{API_SECRET}}`, `{{API_SECRET_B64}}`, `{{NPM_REGISTRY_URL}}`, `{{NPM_REGISTRY_HOST}}`, `{{PYPI_URL}}`, `{{TRUSTED_HOST}}`, `{{MAVEN_REGISTRY_URL}}`, `{{VSCODE_GALLERY_BASE}}` | Generation time, by `substitute()` in `generate.sh` |
| `{{ATTR_USER}}`, `{{NPM_AUTH_B64}}`, `{{PIP_INDEX_URL}}`, `{{ENDOR_PYPI_URL}}`, `{{GO_PROXY_URL}}`, `{{VSCODE_GALLERY_URL}}` | **Install time**, by the orchestration template on the developer's machine |

---

## Preserving existing configuration

Scripts use a **sentinel block** pattern — they write only a clearly delimited section and leave everything else in the config file untouched.

```ini
# existing admin config — never touched
legacy-peer-deps=true
//private.registry.corp/:_authToken=abc123

# ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) =====
registry=https://factory.endorlabs.com/v1/namespaces/my-team/firewall/npm/
always-auth=true
//factory.endorlabs.com/v1/namespaces/my-team/firewall/npm/:_auth=...
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

## Removing the configuration

Deploy `endor-remove.sh`. It strips the sentinel block from every managed config file and,
for VS Code, removes the update watcher, restores the original `extensionsGallery` from the
marker, drops the marker, and deletes the sidecar state. Restart VS Code afterwards.

For the sentinel-block files you can also do it by hand — delete everything between and
including the `BEGIN` and `END` marker lines. `product.json` is the exception: it has no
sentinel block, so restoring it by hand means base64-decoding
`_endorPackageFirewall.originalExtensionsGalleryB64` back over the `extensionsGallery`
object, or simply reinstalling VS Code.

You can deploy a removal script that does this automatically:

```bash
ENDOR_BLOCK_START="# ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) ====="
ENDOR_BLOCK_END="# ===== END ENDOR PACKAGE FIREWALL ====="

remove_block() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -qF "$ENDOR_BLOCK_START" "$file" || return 0
  local tmp; tmp=$(mktemp)
  awk -v start="$ENDOR_BLOCK_START" -v end="$ENDOR_BLOCK_END" '
    index($0, start) { skip=1; next }
    index($0, end)   { skip=0; next }
    !skip             { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  echo "Removed Endor block from $file"
}
```

---

## Security notes

| Item | Note |
|---|---|
| `~/.config/endor/env.sh` | Contains all credentials in plaintext. File is `chmod 600`. This is the only credential file for npm/uv/yarn/poetry. |
| `pip.conf` | Contains credentials in the index-url. File is `chmod 600`. Credentials may appear in pip debug logs (`pip install -v`). pip cannot use env var references. |
| `.npmrc`, `.yarnrc.yml`, `uv.toml` | Contain `${VAR}` references only — no credentials baked in. |
| `~/.m2/settings.xml` | Contains `${env.*}` references only — no credentials baked in. File is `chmod 600`. |
| Shell profiles | Contain a single `source ~/.config/endor/env.sh` line. No credentials. |
| API secret in MDM | The generated scripts contain the API key and secret in plaintext (used to write `env.sh`). Restrict access to the MDM policy and the generated `out/` directory. |
| VS Code `product.json` | **Contains the gallery token in a world-readable file (`0644`)** and must, because VS Code reads it as the user and offers no indirection. Any local user can read a working firewall credential, and it also lands in VS Code's own logs. Use a **dedicated, separately revocable API key** for VS Code so rotation and revocation do not disturb the other ecosystems. |
| VS Code sidecar state | `/Library/Application Support/Endor/package-firewall/vscode/` (macOS) or `/var/lib/endor/package-firewall/vscode/` (Linux). Holds the rendered gallery URL for the watcher. `0600`, root-owned — strictly better protected than `product.json` itself. |
| `--dry-run` output | Redacts the VS Code `_ak/<token>` path segment. The other ecosystems echo full credentialed URLs; VS Code deviates deliberately, because this token is a bearer credential in a URL *path* and MDM consoles retain script output for far more people than can read the target file. |
| `out/` directory | Add to `.gitignore`. Do not commit generated scripts to source control. |
