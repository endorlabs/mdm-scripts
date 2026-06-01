# Endor Package Firewall — MDM Script Generator: Design & Decisions

This document captures the architecture decisions, tradeoffs, and known challenges behind the MDM script generator. It is intended as context for anyone extending the tooling or deploying it at scale.

---

## Problem statement

Developer machines need to route package installations through the Endor Package Firewall. The firewall requires credentials. Those credentials must reach the right config files for each package manager (npm, pip, uv, poetry, yarn, and eventually Go).

The constraints:

- **IT admin does the deployment** via an MDM tool (Kandji, Jamf, or generic). The developer does nothing.
- **MDM scripts run as root.** Config must be written to the logged-in user's home, not `/var/root`.
- **Machines are heterogeneous.** Some have npm only, some have Python only, some have both. Shell config files may or may not exist.
- **Existing developer config must be preserved.** An admin's `.npmrc` with a corporate proxy or a developer's custom pip config must survive the MDM push.
- **Scripts must be idempotent.** MDM tools re-run scripts on check-in. Re-running must not corrupt state.
- **No runtime dependencies.** Scripts are deployed to machines that may have no internet access at run time; they must be self-contained.

---

## Architecture decisions

### 1. Self-contained generated scripts

**Decision:** `generate.sh` produces standalone shell scripts with all logic and credentials inlined. No external files or network calls at runtime.

**Why:** MDM environments are constrained. Scripts must run in any network condition, cannot assume any toolchain beyond bash, and must not pull dependencies at deploy time. Inlining `lib/common.sh` into each output script satisfies this.

**Tradeoff:** Generated scripts are larger and must be regenerated when credentials rotate. Accepted — the alternative (fetching config at runtime) introduces failure modes that are worse at scale.

---

### 2. Sentinel block pattern

**Decision:** Every config file write uses a clearly delimited block:

```
# ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) =====
...
# ===== END ENDOR PACKAGE FIREWALL =====
```

**Why:** Config files like `.npmrc`, `.zshrc`, and `pip.conf` are personal. Overwriting them entirely would destroy developer customisation and break other tools. The sentinel lets the script surgically replace only its own content on re-runs.

**Behaviour matrix:**

| Scenario | Result |
|---|---|
| First run, no file | File created with sentinel block only |
| First run, file exists | Block appended; existing content untouched |
| Re-run / MDM check-in | Only the sentinel block is replaced |
| Admin config outside the block | Preserved forever |
| Developer edits inside the block | Overwritten on next MDM push — this is intentional |
| Conflicting key outside the block | Warning emitted to MDM log; admin resolves manually |

**Known risk:** If the sentinel marker text ever changes between generator versions, old blocks become invisible to the new script. The new script will append a second block instead of replacing the first, leaving duplicate (and potentially conflicting) config. The sentinel text is therefore treated as a stable contract and must not change. See [Scale challenges](#scale-challenges).

---

### 3. `ENDOR_FQDN` instead of `ENDOR_ENV`

**Decision:** The base URL is provided as `ENDOR_FQDN` (defaulting to `https://factory.endorlabs.com`) rather than a named environment enum (`stg | prod | local`).

**Why:** Named environments create implicit coupling between the generator and Endor's infrastructure topology. Every new environment or custom deployment (e.g. a customer running their own factory instance) would require a code change. A direct URL is more general and requires no coordination.

**Tradeoff:** The generator no longer knows "which environment" it is generating for. Any environment-specific behaviour (there was one: `strict-ssl=false` for `local`) must be handled by the caller setting the appropriate URL, not by the generator branching on env name.

---

### 4. Credential architecture: `env.sh` as single source of truth

**Decision:** All credentials are written once to `~/.config/endor/env.sh`. Config files reference these as environment variables where the tool supports it. Shell profiles get a single `source` line.

**Why this matters at scale:** Before this change, credentials were baked into every config file individually (`.npmrc`, `.yarnrc.yml`, `uv.toml`, and shell profiles). Rotating credentials required regenerating and redeploying the MDM script AND updating multiple files on every developer machine. With `env.sh`, credential rotation is a single file update.

**Structure of `env.sh`:**

```bash
export ENDOR_API_KEY_ID="..."
export ENDOR_API_SECRET="..."
export ENDOR_AUTH_B64="..."           # base64(key:secret) — npm/pnpm/yarn/bun
export ENDOR_NPM_REGISTRY_URL="..."   # npm, yarn 2+
export ENDOR_PYPI_URL="..."           # uv (with credentials embedded in URL)
export POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME="..."
export POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD="..."
```

**Future extensibility:** Go will need `GOPROXY`, `GONOSUMCHECK`, `GONOSUMDB` set as environment variables. These slot directly into `env.sh` with no changes to shell profile logic or the sentinel block mechanism. The shell profile source line is already there.

---

### 5. Environment variable references in config files

**Decision:** Config files use `${ENDOR_...}` references rather than baked credential values, wherever the tool supports env var expansion.

| Tool | Config file | Credential approach |
|---|---|---|
| npm, pnpm, yarn classic, bun | `.npmrc` | `${ENDOR_AUTH_B64}` (value only — npm expands `${VAR}` in values, not keys) |
| yarn 2+ / berry | `.yarnrc.yml` | `${ENDOR_API_KEY_ID}:${ENDOR_API_SECRET}` |
| uv | `uv.toml` | `${ENDOR_PYPI_URL}` |
| pip | `pip.conf` | **Literal** — pip does not support env var expansion |
| poetry | shell profile / env.sh | `POETRY_HTTP_BASIC_*` env vars |

**Why:** Keeps credentials out of individual config files. `.npmrc`, `.yarnrc.yml`, and `uv.toml` are credential-free; auditing or sharing them does not leak secrets.

**Version requirements:**
- npm `${VAR}` expansion: npm 7+
- yarn berry `${VAR}` expansion: yarn 3+
- uv `${VAR}` expansion: uv 0.2+

These are all modern enough to be safe assumptions for active developer machines. Older clients will silently treat `${VAR}` as a literal string and fail authentication — they will not crash, but installs will fail with 401.

---

### 6. pip exception

**Decision:** `pip.conf` is the only config file that contains baked credentials.

**Why:** pip's config file parser does not support environment variable expansion. There is no pip-native equivalent of `${VAR}`. pip does respect `PIP_INDEX_URL` as an env var override, but that has the same non-interactive limitation as all env-var approaches (see below) and would mean pip fails in CI without additional setup.

**Accepted risk:** Credentials are in `pip.conf` in plaintext (standard for pip). The file is `chmod 600`. Credentials may appear in verbose pip logs (`pip install -v`).

---

### 7. Shell profile strategy

**Decision:** Shell profiles receive a single sentinel-managed `source` line pointing to `env.sh`, not the credentials themselves.

**Why:** Previously, each shell profile received a full credential block (POETRY env vars). As more ecosystems are added (Go, future tools), this approach would scatter credentials across multiple shell profile blocks, making rotation and removal complex. One `source` line per profile is the stable interface.

**Non-interactive limitation:** Env var references in config files (`${ENDOR_AUTH_B64}` etc.) only resolve when the shell sources `env.sh`. This means:

- **Interactive terminals:** work (shell sources profile on startup)
- **IDE terminals (VS Code, IntelliJ):** work (spawn login shells)
- **npm/pip run from Makefiles or non-login scripts:** may not have env vars set
- **CI/CD pipelines on the same machine:** will not have env vars unless they explicitly source `env.sh`

This is an accepted tradeoff for MDM-managed developer workstations where interactive use is the primary case. pip is exempt from this limitation because its credentials are literal.

---

### 8. Overrides directory

**Decision:** IT admins can place custom template files in `overrides/` to completely replace the default JS, Python, or remove templates. `generate.sh` checks for overrides before falling back to defaults.

**Why:** Teams may have non-standard requirements — additional registry scopes, custom auth formats, extra config keys. Rather than adding an ever-growing list of env vars and flags, a full template override gives complete control. Override files go through the same `{{PLACEHOLDER}}` substitution as the defaults.

**What overrides cannot do:** `envsh.sh` (the credential setup template) is not overridable by design. It is infrastructure, not configuration. Overriding it would risk breaking the credential sourcing that all other templates depend on.

---

## Scale challenges

### Credential rotation

Rotating credentials requires:
1. Regenerating the MDM scripts with new credentials (new `env.sh` content)
2. Deploying the new script via MDM

**Gap:** `pip.conf` must also be updated because it contains literal credentials. This cannot currently be avoided. A future improvement would be a lightweight "credential refresh" script that only updates `env.sh` and `pip.conf`, without touching the rest of the config files.

### Sentinel drift

If `ENDOR_BLOCK_START` / `ENDOR_BLOCK_END` ever change between generator versions, machines that received the old script will have an orphaned block. The new script will not find the old block (exact match required), and will append a second block. Both blocks will be active, which may cause unexpected tool behaviour depending on how each tool resolves duplicate keys.

**Mitigation (not yet implemented):** A fuzzy pre-scan for any line matching `BEGIN ENDOR PACKAGE FIREWALL` before writing, stripping it and emitting a warning if the exact sentinel doesn't match. This was considered but deferred to keep the initial implementation simple.

### Non-standard shell setups

The shell profile discovery (`~/.zshrc`, `~/.bash_profile`, `~/.bashrc`) covers the common cases but misses:

- **fish:** `~/.config/fish/config.fish` — different syntax (`set -x VAR value`)
- **nushell:** `~/.config/nushell/config.nu` — different syntax entirely
- **Non-default zsh config:** some teams use `~/.config/zsh/.zshrc` via `ZDOTDIR`

Developers on these shells will not have `env.sh` sourced automatically. They will get a warning during MDM deployment but no config. Tools that require env vars (poetry, Go, yarn 2+ in some setups) will fail with 401 on first use.

**Mitigation options:** Add fish support. Add a `~/.profile` fallback (sourced by most POSIX shells including dash). Document the manual step for nushell users.

### Conflict detection vs. resolution

The `warn_if_key_conflict` function emits a warning when a conflicting key (e.g. `registry=`) exists outside an Endor block. It does not resolve the conflict. At scale, these warnings appear in MDM logs and require an admin to investigate manually.

The warning is intentionally non-blocking — we do not know whether the existing value is intentional (a corporate proxy that should take precedence) or accidental. Automatic resolution would risk breaking existing infrastructure.

**Recommendation:** Periodically audit MDM logs for `[endor] WARNING:` lines. Each one represents a machine where key precedence may not behave as expected.

### MDM script contains plaintext credentials

The generated scripts in `out/<namespace>/` contain the API key and secret in plaintext (needed to write `env.sh` at deploy time). These files must be treated as secrets:

- Add `out/` to `.gitignore` — never commit generated scripts
- Restrict who can view the MDM policy in Kandji/Jamf
- Rotate credentials if the `out/` directory is accidentally exposed

---

## Open problems

| Problem | Status | Notes |
|---|---|---|
| Sentinel drift on version upgrade | Not implemented | Fuzzy scan deferred |
| fish / nushell shell profile support | Not implemented | `~/.config/fish/config.fish` requires different syntax |
| npm key expansion (`//host/:_auth`) | Partial | Auth scope key must be literal; only the value uses `${VAR}` |
| yarn 2+ < 3.0 | Untested | `${VAR}` expansion may not work on older berry versions |
| Go ecosystem | Not implemented | Designed for: `GOPROXY`, `GONOSUMCHECK` slot into `env.sh` |
| Credential rotation without full redeploy | Not implemented | Would need a separate lightweight refresh script |
| CI pipelines on managed machines | Not addressed | pip works; npm/uv/poetry require `source ~/.config/endor/env.sh` |

---

## Goals and current gaps

Three goals were defined for this system. This section scores the current state against each and identifies the specific gaps that remain open.

---

### Goal 1 — Ease of use for IT admin and easy retriggers

**What this means:** An IT admin should be able to generate scripts, deploy them, and retrigger them without deep knowledge of package managers or bash. Credential rotation and config changes should require minimal effort.

**Current state**

| Capability | Status |
|---|---|
| Single-command generation (`generate.sh`) | ✓ Done |
| Self-contained output scripts (no runtime deps) | ✓ Done |
| Idempotent — safe to retrigger on MDM check-in | ✓ Done |
| `--dry-run` to preview before deploying | ✓ Done |
| Plain-text block files (`templates/blocks/*.txt`) — no bash needed to customise config | ✓ Done |
| Credential rotation without full script redeploy | ✗ Not done |
| Validation before deployment (smoke-test against firewall) | ✗ Not done |
| Two-level override system (`overrides/` vs `overrides/blocks/`) — distinction not obvious | ⚠ Friction |

**Key gaps**

- **Credential rotation is a full redeploy.** Changing the API key requires regenerating all scripts and re-uploading to MDM. At scale (hundreds of machines) this is high blast radius for what should be a lightweight operation. A dedicated `endor-refresh-creds.sh` script that only updates `env.sh` and `pip.conf` would reduce this significantly.

- **No pre-deployment validation.** There is nothing that confirms the generated script will actually authenticate against the firewall before it is pushed to machines. A bad `ENDOR_API_SECRET` causes silent 401s across every device. A simple `generate.sh --validate` that makes a test request would catch this before deployment.

- **The `{{PLACEHOLDER}}` vs `${ENDOR_...}` distinction in block files.** IT admins editing `templates/blocks/npmrc.txt` need to know that `{{NPM_REGISTRY_HOST}}` is substituted at generation time while `${ENDOR_AUTH_B64}` is expanded at runtime by npm. This rule is non-obvious from the file alone and is a source of mistakes.

---

### Goal 2 — Avoid breaking developer workflow; no pages for IT

**What this means:** The MDM push must not break existing developer tooling, interrupt in-progress work, or create failures that wake someone up. Errors must be visible and diagnosable — not silent 401s.

**Current state**

| Capability | Status |
|---|---|
| Sentinel blocks preserve all config outside Endor's section | ✓ Done |
| `warn_if_key_conflict` detects conflicting keys before writing | ✓ Done |
| `chmod 600` on all written files | ✓ Done |
| `--dry-run` lets IT preview impact | ✓ Done |
| pip always works (literal creds, no env var dependency) | ✓ Done |
| npm/uv/yarn work in non-interactive shells (Makefiles, hooks, scripts) | ✗ Not done |
| Fish / nushell users get working config | ✗ Not done |
| Graceful handling when no user is logged in at MDM run time | ✗ Not done |
| Conflict warnings surface to the developer, not just MDM logs | ✗ Not done |

**Key gaps**

- **Non-interactive shell contexts silently fail.** Developers running `npm install` from a Makefile, a git hook, or any script that does not source `~/.zshrc` will get a 401 with no explanation. pip works because it uses literal credentials; npm/uv/yarn do not. The inconsistency makes debugging harder — the developer sees pip work and npm fail from the same terminal session depending on how it was launched.

- **No console user → hard abort.** If MDM runs the script while no user is logged in (lab machine, shared device, FileVault login screen), `detect_console_user` exits 1 and the machine is never configured. MDM marks the policy as failed and may page the IT admin. There is no "wait and retry when user logs in" behaviour.

- **Conflict warnings go to MDM logs, not the developer.** `warn_if_key_conflict` emits to stderr, which MDM captures. The developer whose `.npmrc` has a conflicting `registry=` line never sees the warning. Their install may silently use the wrong registry depending on key precedence, or fail entirely. The warning should produce output that the developer encounters directly (e.g. a comment written adjacent to the sentinel block, or a message on next terminal open).

- **Fish and nushell users are unconfigured silently.** They receive no error — tools just fail with 401. A developer on fish who runs `npm install` will not connect this to the MDM push.

---

### Goal 3 — Least element of surprise; extensible for future ecosystems

**What this means:** The system should behave predictably, be easy to reason about, and make adding new ecosystems (Go, Ruby, Rust) straightforward without rearchitecting anything.

**Current state**

| Capability | Status |
|---|---|
| Sentinel pattern is consistent across all config files | ✓ Done |
| `env.sh` is the single credential source — new ecosystems add vars here | ✓ Done |
| Go env vars (`GOPROXY` etc.) slot into `env.sh` with no other changes | ✓ Done |
| `templates/blocks/*.txt` — one file per config target, independently editable | ✓ Done |
| Architecture decisions documented in `DESIGN.md` | ✓ Done |
| `${VAR}` vs `{{PLACEHOLDER}}` distinction is self-evident in block files | ✗ Not done |
| Silent 401 on old tool versions (yarn 2.x, uv < 0.2) | ✗ Not done |
| Sentinel drift on generator version upgrade | ✗ Not done |
| Adding a new ecosystem requires changes in multiple files | ⚠ Friction |

**Key gaps**

- **`${VAR}` vs `{{PLACEHOLDER}}` is a hidden contract.** In the same `.txt` file, `{{NPM_REGISTRY_HOST}}` is replaced at generation time and `${ENDOR_AUTH_B64}` is left for the tool to expand at runtime. The distinction is invisible unless you read the documentation. Anyone editing a block file without knowing this rule will either accidentally bake in a value that should be dynamic, or leave a `{{...}}` that never gets substituted. The block files should carry a short header comment explaining both syntaxes.

- **Old tool versions fail silently with 401.** yarn 2.x (berry before 3.0) and uv < 0.2 do not expand `${VAR}` in their config files. The generated config is syntactically valid; the tool just treats `${ENDOR_AUTH_B64}` as a literal string and sends it as the auth token. The developer gets a 401 with no indication that their tool version is the cause.

- **Sentinel drift is undocumented in the code.** The `ENDOR_BLOCK_START` / `ENDOR_BLOCK_END` strings are defined once in `lib/common.sh` and treated as a stable contract, but there is no enforcement. A future contributor who changes the marker text (to add a version number, say) will silently orphan all existing deployments. The constant should have a prominent warning comment.

- **Adding a new ecosystem touches multiple files.** Adding Go requires: a new `templates/blocks/goproxy.txt`, a new `templates/go.sh`, edits to `templates/blocks/envsh.txt`, edits to `generate.sh` (to call `build_script` for go), and edits to `templates/remove.sh`. The path is logical but not documented, and it is easy to miss a file. A brief "how to add a new ecosystem" section in `DESIGN.md` would reduce this friction.

---

### Summary

| Goal | Score | Biggest gap |
|---|---|---|
| IT admin ease of use / retriggers | 7/10 | Credential rotation requires full script redeploy; no pre-deployment validation |
| Developer workflow safety / no pages | 6/10 | Non-interactive shells silently fail; no-user-logged-in hard aborts MDM |
| Least surprise / extensibility | 7/10 | `${VAR}` vs `{{}}` distinction is invisible; silent failures on old tool versions |

The 6/10 on goal 2 is the most actionable. The non-interactive shell gap and the hard abort on no-console-user are the most likely to cause a 3am page. Both are solvable without architectural changes.

---

## Path to 10/10

Each work item below is independent — they can be picked up in any order. Priority is marked where one item unblocks another.

---

### Goal 1 — IT admin ease of use (7 → 10)

#### 1a. Credential refresh script — `endor-refresh-creds.sh`

A generated script that only updates `~/.config/endor/env.sh` and `pip.conf`. Does not touch `.npmrc`, `.yarnrc.yml`, `uv.toml`, or shell profiles (those don't contain credentials any more, so they never need updating). IT deploys this when rotating the API key — no config file archaeology required.

What it does:
- Overwrites the sentinel block in `~/.config/endor/env.sh` with new credential values
- Replaces the sentinel block in each `pip.conf` location with the new `PIP_INDEX_URL`
- Exits 0 on success; reports each file updated

`generate.sh` produces this as `out/<namespace>/endor-refresh-creds.sh` alongside the existing scripts.

#### 1b. Pre-deployment credential validation — `--validate` flag

`generate.sh --validate` makes a single unauthenticated probe + authenticated request to the firewall before generating any output:

```
$ ENDOR_NAMESPACE=my-team ENDOR_API_KEY_ID=key ENDOR_API_SECRET=wrong ./generate.sh --validate
[validate] Checking https://factory.endorlabs.com ... reachable
[validate] Checking credentials ... FAILED (HTTP 401)
Error: credentials rejected by firewall. Check ENDOR_API_KEY_ID and ENDOR_API_SECRET.
```

On success, generation proceeds normally. On failure, no `out/` directory is written. Prevents deploying scripts that will 401 on every device.

Implementation: a `curl` call in `generate.sh` before the output directory is created.

#### 1c. Self-documenting block files

Add a short header comment to every `templates/blocks/*.txt` file explaining the two syntaxes inline:

```
# {{PLACEHOLDER}} — substituted at generation time by generate.sh
# ${ENDOR_VAR}    — env var reference, expanded at runtime by the tool reading this file
```

This removes the need to consult documentation when editing a block file. Three lines, no code change.

---

### Goal 2 — Developer workflow safety / no pages (6 → 10)

This goal has the most work and the highest priority items.

#### 2a. LaunchAgent plist for macOS — solves non-interactive context gap

The fundamental problem: env vars in `~/.config/endor/env.sh` are only visible to shells that source it. Makefile targets, git hooks, pre-commit, IDEs with their own process trees, and `cron` jobs never source shell profiles.

The macOS-native solution is a **LaunchAgent** — a per-user plist loaded at login that calls `launchctl setenv` for each variable. This makes them visible to every process the user launches, regardless of how it was started.

Generated file: `~/Library/LaunchAgents/com.endorlabs.firewall.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.endorlabs.firewall</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>
      /bin/launchctl setenv ENDOR_AUTH_B64 "actual-value" &amp;&amp;
      /bin/launchctl setenv ENDOR_NPM_REGISTRY_URL "actual-value" &amp;&amp;
      /bin/launchctl setenv ENDOR_PYPI_URL "actual-value" &amp;&amp;
      /bin/launchctl setenv ENDOR_API_KEY_ID "actual-value" &amp;&amp;
      /bin/launchctl setenv ENDOR_API_SECRET "actual-value"
    </string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
```

The plist is loaded with `launchctl load` by the MDM script. From that point forward, all processes — npm, uv, git hooks, Makefiles — see the Endor env vars. The shell profile `source` line remains for poetry (which reads from shell environment at invocation time) and for interactive use.

This is the single highest-impact change. It closes the non-interactive gap cleanly without changing the credential architecture or config file format.

Credential rotation: `endor-refresh-creds.sh` (1a) also updates the plist and reloads it with `launchctl unload && launchctl load`.

#### 2b. Graceful no-console-user handling

Currently: `detect_console_user` exits 1 → MDM marks policy failed → potential alert.

Better behaviour: if no console user is detected, install the MDM script itself as a LaunchAgent that runs once at next login, then exit 0. The machine will configure itself when someone logs in. MDM sees success; the device configures itself.

```bash
detect_console_user() {
  ...
  if [[ -z "$user" || "$user" == "root" ]]; then
    echo "[endor] No console user detected — scheduling configuration for next login." >&2
    _install_login_once_agent
    exit 0   # MDM sees success; agent handles the rest
  fi
  echo "$user"
}
```

`_install_login_once_agent` writes a LaunchAgent plist pointing to the current script, with `RunAtLoad true` and `LaunchOnlyOnce true`. Once it runs successfully at login it removes itself.

This eliminates the paging scenario entirely for lab machines and devices provisioned before anyone logs in.

#### 2c. Developer-visible conflict warnings

Currently: `warn_if_key_conflict` writes to stderr, visible in MDM logs. The developer never sees it.

Better: write the warning as a comment adjacent to the sentinel block so the developer encounters it when they open their config file:

```ini
# [endor] WARNING: 'registry' also set above outside Endor block — verify precedence.
# ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) =====
registry=${ENDOR_NPM_REGISTRY_URL}
...
# ===== END ENDOR PACKAGE FIREWALL =====
```

The comment sits just before the `BEGIN` marker. It is not inside the sentinel so it is not overwritten on re-run. The developer sees it the next time they open `.npmrc`. Implementation: modify `upsert_block` in `common.sh` to accept an optional `conflict_warning` parameter, written as a comment above the block.

#### 2d. Fish shell support

Write `~/.config/fish/conf.d/endor.fish` with fish syntax:

```fish
# Endor Package Firewall — source ~/.config/endor/env.sh
if test -f $HOME/.config/endor/env.sh
    fenv source $HOME/.config/endor/env.sh
end
```

`conf.d/` is auto-sourced by fish — no edits to `config.fish` needed. Add detection in `envsh.sh` alongside the existing bash/zsh profile loop.

Note: `fenv` (fish env) is required for sourcing POSIX-style exports. It ships with `bass` (a common fish plugin). Without it, env vars must be set with `set -x VAR value` syntax. The safest approach: detect whether `bass` / `fenv` is available and fall back to writing fish `set -x` statements directly.

#### 2e. Tool version detection — warn before writing env var references

Before writing `${VAR}` refs to `.yarnrc.yml` or `uv.toml`, check whether the installed tool supports env var expansion and emit a named warning if it does not:

```
[endor] WARNING: yarn 2.4.3 detected — ${VAR} expansion requires yarn 3+.
[endor]          .yarnrc.yml will be written with env var references but auth may fail.
[endor]          Upgrade yarn or add overrides/blocks/yarnrc.txt with literal credentials.
```

This turns a silent 401 into an actionable message in MDM logs. Implementation: shell `command -v yarn && yarn --version` check in `js.sh` template, guarded so absence of yarn is not an error.

---

### Goal 3 — Least surprise / extensibility (7 → 10)

#### 3a. Self-documenting block files (same as 1c)

Already listed above. Eliminates the biggest "element of surprise" in the system.

#### 3b. Sentinel stability enforcement in `common.sh`

Add a prominently visible warning on `ENDOR_BLOCK_START` / `ENDOR_BLOCK_END` in `lib/common.sh`:

```bash
# ╔══════════════════════════════════════════════════════════════════════╗
# ║  SENTINEL CONTRACT — DO NOT CHANGE THESE STRINGS                    ║
# ║  Changing them orphans all existing deployments. Machines that       ║
# ║  received a prior script will have an undetected block that the new  ║
# ║  script cannot find or remove, causing duplicate config on re-run.   ║
# ╚══════════════════════════════════════════════════════════════════════╝
ENDOR_BLOCK_START="# ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) ====="
ENDOR_BLOCK_END="# ===== END ENDOR PACKAGE FIREWALL ====="
```

Additionally, implement the fuzzy pre-scan in `upsert_block`: before writing, grep for any line matching `BEGIN ENDOR PACKAGE FIREWALL` (case-insensitive, ignoring decoration). If found but not matching the exact sentinel, strip it and emit a warning. This handles version upgrades gracefully.

#### 3c. "How to add a new ecosystem" guide

Add a section to `DESIGN.md` with exact steps for adding Go (as a worked example):

1. Add env vars to `templates/blocks/envsh.txt` (`GOPROXY`, `GONOSUMCHECK`, `GONOSUMDB`, `GOPRIVATE`)
2. Create `templates/blocks/goenv.txt` (the env var block — Go uses env vars, not a config file)
3. Create `templates/go.sh` (orchestration: detect Go installation, write a `goenv.txt`-based block to `~/.config/go/env` if Go's native config is preferred, otherwise rely on `env.sh`)
4. Add `emit_block_assignment "GO_BLOCK" ...` to `emit_all_blocks()` in `generate.sh`
5. Add `build_script` call for `go.sh` in `generate.sh`
6. Add removal of Go config file to `templates/remove.sh`
7. Add Go to the LaunchAgent plist (2a) — Go reads `GOPROXY` from the process environment

This makes the path explicit and reduces the chance of missing a step.

#### 3d. Separate `envsh.sh` into overridable infrastructure

Currently `envsh.sh` is not overridable by design. But the `SOURCE_BLOCK` (the `source ~/.config/endor/env.sh` line) is hardcoded. As more shells are added (fish via 2d), the shell detection logic grows. Moving the per-shell sourcing logic into its own template (or making the list of profiles configurable) would make this extensible without touching `envsh.sh` orchestration.

Low priority — only matters when adding non-bash shell support.

---

### Priority order

| Item | Goal | Impact | Effort | Do first |
|---|---|---|---|---|
| 2a — LaunchAgent plist | 2 | Eliminates non-interactive gap entirely | Medium | Yes |
| 2b — Graceful no-user handling | 2 | Eliminates most likely page scenario | Low | Yes |
| 1b — `--validate` flag | 1 | Prevents mass 401 deployments | Low | Yes |
| 1a — Refresh creds script | 1 | Reduces rotation blast radius | Medium | After 2a (plist needs refresh too) |
| 1c / 3a — Block file headers | 1, 3 | Removes biggest UX confusion | Trivial | Any time |
| 3b — Sentinel fuzzy scan + warning | 3 | Prevents orphaned blocks on upgrade | Low | Any time |
| 2c — Developer-visible warnings | 2 | Turns silent failures into diagnosable ones | Low | Any time |
| 2d — Fish support | 2 | Covers non-bash developers | Low | After 2a |
| 2e — Tool version detection | 2 | Turns silent 401s into named warnings | Low | Any time |
| 3c — Ecosystem guide in DESIGN.md | 3 | Reduces friction for next ecosystem | Trivial | Any time |
