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
│   └── remove.sh            ← orchestration: sentinel block removal
└── out/                     ← generated scripts (gitignore this)
    └── <namespace>/
        ├── endor-js.sh
        ├── endor-python.sh
        ├── endor-all.sh
        └── endor-remove.sh

../shared/blocks/            ← edit these to customise what gets written to config files
├── envsh.txt                ← ~/.config/endor/env.sh content
├── npmrc.txt                ← ~/.npmrc content
├── yarnrc_classic.txt       ← ~/.yarnrc (yarn 1.x) content
├── yarnrc.txt               ← ~/.yarnrc.yml (yarn 2+) content
├── pipconf.txt              ← pip.conf content
└── uvtoml.txt               ← ~/.config/uv/uv.toml content
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
| `endor-all.sh` | Team uses both — single-script deploy |

### Kandji

1. Library → Custom Scripts → Add Script
2. Paste the script content or upload the file
3. Set **Run as**: Root
4. Set **Execution Frequency**: Run once per device (or on every check-in for ongoing enforcement)
5. Assign to the relevant device blueprint

### Jamf Pro

1. Settings → Scripts → New
2. Paste the script content
3. Policies → New Policy → Scripts → add your script
4. Set **Execution Frequency** as appropriate
5. Scope to the target devices

### Generic MDM

Upload the script file. Ensure it runs as **root** — the script detects the logged-in console user internally and writes config files to the correct home directory.

---

## How credentials are stored

All scripts share a common credential architecture:

**`~/.config/endor/env.sh`** — single credential source, written by every install script:
```bash
export ENDOR_API_KEY_ID="..."
export ENDOR_API_SECRET="..."
export ENDOR_AUTH_B64="..."          # base64(key:secret) — used by npm/pnpm/yarn/bun
export ENDOR_NPM_REGISTRY_URL="..."  # used by npm, yarn 2+
export ENDOR_PYPI_URL="..."          # used by uv
export POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME="..."
export POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD="..."
```

Shell profiles (`.zshrc`, `.bash_profile`, `.bashrc`) each get a one-line sentinel block that sources this file. Config files reference env vars rather than baking credentials — except pip, which cannot expand env vars.

**Credential rotation**: update `env.sh` on target machines (redeploy MDM script). No config file changes needed.

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

### `endor-python.sh`

Writes `~/.config/endor/env.sh` and an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| `~/.pip/pip.conf` | pip (legacy path) | Literal — pip cannot expand env vars |
| `~/.config/pip/pip.conf` | pip (XDG / Linux standard) | Literal |
| `~/Library/Application Support/pip/pip.conf` | pip (macOS primary) | Literal |
| `~/.config/uv/uv.toml` | uv (does **not** read pip.conf) | `${ENDOR_PYPI_URL}` env var ref |

Key behaviour:
- **pip**: uses a named `[endor-firewall]` section — preserves any existing `[global]` settings; credentials are literal (pip limitation)
- **uv**: uv ignores pip.conf entirely; `~/.config/uv/uv.toml` is the user-level global config; references `${ENDOR_PYPI_URL}`
- **poetry**: credentials are in `env.sh` as `POETRY_HTTP_BASIC_ENDOR_FIREWALL_*` — no separate write step

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
| `../shared/blocks/envsh.txt` | `~/.config/endor/env.sh` |
| `../shared/blocks/npmrc.txt` | `~/.npmrc` |
| `../shared/blocks/yarnrc_classic.txt` | `~/.yarnrc` (yarn 1.x) |
| `../shared/blocks/yarnrc.txt` | `~/.yarnrc.yml` (yarn 2+) |
| `../shared/blocks/pipconf.txt` | `~/.pip/pip.conf`, `~/.config/pip/pip.conf`, `~/Library/Application Support/pip/pip.conf` |
| `../shared/blocks/uvtoml.txt` | `~/.config/uv/uv.toml` |

To change orchestration logic (which files get written, in what order, with what warnings), edit the relevant `templates/*.sh` file directly.

Both support `{{PLACEHOLDER}}` substitution at generation time and `${ENDOR_VAR}` env var references at runtime:

| Syntax | When resolved | Use for |
|---|---|---|
| `{{PLACEHOLDER}}` | Generation time by `generate.sh` | Values baked into the config file (e.g. registry host in a key position) |
| `${ENDOR_VAR}` | Runtime by the tool reading the config file | Credential values — kept out of config files, resolved from `env.sh` |

Available placeholders: `{{API_KEY_ID}}`, `{{API_SECRET}}`, `{{NPM_REGISTRY_URL}}`, `{{NPM_REGISTRY_HOST}}`, `{{NPM_AUTH_B64}}`, `{{PYPI_URL}}`, `{{PIP_INDEX_URL}}`, `{{TRUSTED_HOST}}`, `{{NAMESPACE}}`, `{{FQDN}}`

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

To remove the Endor firewall configuration from a machine, delete the sentinel block from each file — everything between and including the `BEGIN` and `END` marker lines.

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
| Shell profiles | Contain a single `source ~/.config/endor/env.sh` line. No credentials. |
| API secret in MDM | The generated scripts contain the API key and secret in plaintext (used to write `env.sh`). Restrict access to the MDM policy and the generated `out/` directory. |
| `out/` directory | Add to `.gitignore`. Do not commit generated scripts to source control. |
