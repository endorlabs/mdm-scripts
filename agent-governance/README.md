# agent-governance

Deploy Endor Labs audit hooks to every AI coding agent on your fleet — Claude Code and Cursor — through your MDM.

## What this is

Endor's AI governance works through **hooks** wired into developer AI tools. Whenever a developer does something — starts a session, runs a tool, edits a file — the hook calls `endorctl ai-audit`, which records the action and, when you turn enforcement on, blocks the ones your policies disallow.

This directory of the public [`mdm-scripts`](https://github.com/endorlabs/mdm-scripts) repo gets those hooks onto every laptop and keeps them current. You run one generator to produce a tool's config, then deliver it however your fleet is managed — an MDM profile, a recurring script, or your config-management tooling. The repo is **credential-free**: your Endor API credentials are supplied at generation time and never stored here.

## Quick start — try it on one machine

Generate a config and drop it in your own user directory. Nothing is enforced this way (a local file isn't tamper-proof), but it's the fastest way to see hooks fire and watch the audit log.

```sh
# Cursor — writes ~/.cursor/hooks.json
scripts/render.sh --agent cursor \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o ~/.cursor/hooks.json

# Claude Code — writes ~/.claude/settings.json
scripts/render.sh --agent claude \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o ~/.claude/settings.json
```

Start a new session in the tool: the hook installs `endorctl` on first run and begins reporting to your Endor namespace. When you're ready to roll this out to the fleet, pick a deployment path below.

## Choose how to deploy

Each tool is delivered the way it best supports it. On macOS, Claude Code takes a tamper-resistant MDM **profile**; Cursor's config is a plain file delivered by a small **script**. A laptop can run any combination.

| Tool | macOS delivery | Why | Runbook |
| --- | --- | --- | --- |
| **Claude Code** | MDM **Custom Profile** (`.mobileconfig`) | Claude reads a managed-settings profile payload (`com.anthropic.claudecode`), enforced by the OS | [Deploy Claude via profile](docs/deploy-claude-profile.md) |
| **Cursor** | MDM **Custom Script** (the runner) | `hooks.json` is a plain file, not a profile payload | [Deploy Cursor via the runner](docs/deploy-cursor-runner.md) |

**Linux** delivers the same JSON as a file — Cursor at `/etc/cursor/hooks.json`, Claude at `/etc/claude-code/managed-settings.json` — via the runner or your config management (Ansible, Chef, …).

**Windows** has no `.mobileconfig`. You pre-generate the config (`--target-os windows`) and push the file with **Intune**; the hook is a self-contained `powershell` command that runs regardless of how the agent launches it. See [Deploy on Windows via Intune](docs/deploy-windows-intune.md).

Other paths: [JumpCloud](docs/deploy-jumpcloud.md) (any OS), and [manual / enterprise-platform install](docs/deploy-manual-enterprise.md) for trials or orgs governing through Cursor Team hooks / Claude's admin console. The full agent × OS × MDM grid is the [support matrix](docs/support-matrix.md).

## The generator

[`scripts/render.sh`](scripts/render.sh) builds a tool's config as JSON. For the Claude macOS profile, pipe that JSON through [`scripts/render-plist.sh`](scripts/render-plist.sh), which wraps it in the profile envelope and converts it to a `.mobileconfig`.

```sh
# Cursor hooks.json
scripts/render.sh --agent cursor \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o hooks.json

# Claude Code settings.json
scripts/render.sh --agent claude \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o settings.json

# Claude Code MDM profile (.mobileconfig) — upload to your MDM
scripts/render.sh --agent claude \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o - \
| scripts/render-plist.sh \
  --identifier com.acme.ai-governance.claudecode --organization "Acme Corp" \
  --name "Claude Code — Endor AI Governance" \
  -o com.anthropic.claudecode.mobileconfig

# Windows config (push via Intune)
scripts/render.sh --agent cursor --target-os windows \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o cursor-hooks.json
```

**Credentials** resolve flag → environment variable → prompt (the prompt only appears on a TTY, so unattended runs never hang):

| Flag | Env fallback | Default |
| --- | --- | --- |
| `--api-key` | `ENDOR_API_CREDENTIALS_KEY` | — (required) |
| `--api-secret` | `ENDOR_API_CREDENTIALS_SECRET` | — (required) |
| `--namespace` | `ENDOR_NAMESPACE` | — (required) |
| `--api-url` | `ENDOR_API` | `https://api.endorlabs.com` |

**`--target-os {macos,linux,windows}`** (default `macos`; macOS and Linux are identical POSIX) chooses the hook form. `windows` inlines the PowerShell bootstrap as a base64 `powershell -NoProfile -EncodedCommand …` so it runs under Git Bash, PowerShell, or cmd alike.

**Behavior settings** go through `--env KEY=VALUE` (repeatable) and land in the right place per tool. Response caching is on by default; monitor-only mode is just `--env ENDOR_AI_AUDIT_NO_BLOCKING=true`.

**`--skip-endorctl-update`** makes the session hook use an already-installed `endorctl` instead of checking for a newer one every session — useful once the fleet is provisioned. It passes through the runner too.

`render.sh` also takes `-o/--output` (`-` for stdout). `render-plist.sh` is agent-agnostic — `--payload-type` (default `com.anthropic.claudecode`) selects the app, and `--identifier`/`--organization` are required, with `--name`, `--profile-identifier`, and the UUID flags optional. Run either script with `--help` for the full list.

### Enforcing vs. monitor-only

- **Enforcing** (default): policy-violating actions get a "block" verdict and the agent halts.
- **Monitor-only** (`--env ENDOR_AI_AUDIT_NO_BLOCKING=true`): every action is still evaluated and recorded, but nothing is blocked.

A good rollout starts in monitor-only, watches the Endor audit log over a representative period to confirm the policies aren't catching false positives, then regenerates without the flag to enforce.

## How it works

**`endorctl` installs and updates itself.** It isn't shipped per tool — the generated session hook runs [`download_endorctl.sh`](scripts/download_endorctl.sh) (or [`download_endorctl.ps1`](scripts/download_endorctl.ps1) on Windows), which installs the binary on first run and refreshes it when a new version ships, verifying a SHA-256 each time. So the only things that change after setup are the config (when you regenerate it) and the governance rules (server-side at Endor, fetched at run time).

**What needs re-delivery when it changes:**

| What changes | How it updates | Your action |
| --- | --- | --- |
| `endorctl` binary | Self-updates on session start (SHA-256 verified); `--skip-endorctl-update` pins it | None |
| Governance rules | Server-side at Endor, fetched at run time | None |
| Claude profile config (macOS) | Regenerate the `.mobileconfig`, re-upload to the MDM | Re-upload |
| Cursor runner config (macOS/Linux) | Repo is re-pulled and re-rendered on each check-in | None after setup |
| Windows config | Regenerate (`--target-os windows`), re-push via Intune | Re-push |

**Security properties:**

- **Tamper-resistance.** A profile-delivered config (Claude on macOS) is an OS-enforced managed setting — hard for a developer to override. A script-delivered file (Cursor, and the file-based Linux/Windows paths) is not OS-enforced; a determined developer could override it. Cursor has no profile mechanism today, so the profile path is Claude-only.
- **Least-privilege credentials.** A generated profile carries the API key and secret to every laptop — scope it to an **audit-only** credential.
- **Pin the revision.** The runner executes this repo's code as root (via the MDM), so it can fetch a specific `--ref` (tag, branch, or commit) instead of the branch tip — each device then runs only a reviewed revision. The runbook wrappers set a `REF` you bump deliberately to roll out a change; without one, it tracks the default branch.
- **Credential isolation (Claude).** The `env` block exports into every subprocess Claude spawns, including any `endorctl` the agent itself runs. To keep audit credentials out of the agent's process tree, hook-scoped variables use an `AGENT_HOOK_ENDOR_*` prefix that `endorctl` doesn't read natively, and the hook passes them through as `--api-key …` flags.
- **Robust quoting.** Credentials and `--env` values are escaped for their target — the shell (POSIX, via `@sh`), PowerShell (single-quote doubling), and JSON (`jq`) — and `$VAR` references in the generated commands are quoted, so a value containing a space, quote, `$`, `;`, `*`, or `` ` `` never word-splits or breaks the hook.

## Prerequisites

Each script needs only what's standard to where it runs; the laptop paths stay light, and `plutil` is only the concern of the admin who builds Claude profiles.

| Script | Runs on | Needs |
| --- | --- | --- |
| [`download_endorctl.sh`](scripts/download_endorctl.sh) | developer laptop (inlined into the session hook) | POSIX `sh` + `curl` (plus `awk`/`sed`/`uname`/`mktemp`/`tr` and `sha256sum` or `shasum` — all standard on macOS & Linux) |
| [`download_endorctl.ps1`](scripts/download_endorctl.ps1) | Windows laptop (encoded into the session hook) | Windows PowerShell 5.1 (built in) |
| [`scripts/render.sh`](scripts/render.sh) | admin machine (macOS/Linux, or Windows via Git Bash/WSL), or laptop via the runner | `jq`; for `--target-os windows` also `iconv` + `base64` |
| [`scripts/render-plist.sh`](scripts/render-plist.sh) | admin machine (macOS) | `jq` + `plutil` |
| [`scripts/runner.sh`](scripts/runner.sh) | developer laptop (run by the MDM) | `git` + POSIX `sh` + `jq` |

## Repository layout

```
scripts/
  download_endorctl.sh    endorctl bootstrap, POSIX (macOS/Linux session hook)
  download_endorctl.ps1   endorctl bootstrap, PowerShell (Windows session hook)
  render.sh               generate a tool's config as JSON
  render-plist.sh         wrap a config (stdin) into a .mobileconfig profile
  runner.sh               MDM runner: clone → render → swap-if-changed
examples/                 checked-in samples (demo creds, placeholder UUIDs)
docs/                     deployment runbooks + the support matrix
```

## Examples

`examples/` holds one checked-in sample per output shape, generated with demo credentials (`PEPE` / `PAPA` / namespace `spiderman`) and placeholder profile UUIDs:

| Shape | Agent | File |
| --- | --- | --- |
| JSON (POSIX hooks) | Claude | `examples/claude/settings.json` |
| MDM profile (plist) | Claude | `examples/claude/com.anthropic.claudecode.mobileconfig` |
| JSON (encoded PowerShell hook) | Claude | `examples/claude/settings.windows.json` |
| JSON (POSIX hooks) | Cursor | `examples/cursor/hooks.json` |
| JSON (encoded PowerShell hook) | Cursor | `examples/cursor/hooks.windows.json` |

There's no separate Linux example: `settings.json` is exactly what Claude reads as the Linux `/etc/claude-code/managed-settings.json` and as the inner payload of the macOS profile, and JumpCloud reuses these same files. Only the Windows samples differ (the encoded `powershell` hook). After changing a script, regenerate the affected examples with the commands above so they stay in sync.

## Extending

To add another agent: add a `build_<agent>` jq builder and a `case` arm in [`scripts/render.sh`](scripts/render.sh), plus a default `--dest` in [`scripts/runner.sh`](scripts/runner.sh) if it's script-delivered.
