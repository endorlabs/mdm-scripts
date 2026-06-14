# agent-governance

Govern every AI coding agent on your fleet. MDM-deployed audit hooks for AI coding agents, wired to Endor Labs.

## What this is

Endor's AI governance works by installing **hooks** into developer AI tools (Claude Code, Cursor). A hook runs whenever the developer does something — starts a session, runs a tool, edits a file — and calls `endorctl ai-audit`, which records the action and, when configured to, blocks actions that are not allowed.

This directory of the public [`mdm-scripts`](https://github.com/endorlabs/mdm-scripts) repo is how those hooks get onto every developer's laptop through the customer's **MDM** — Jamf/Kandji on macOS, Intune on Windows — and stay current as Endor improves them. It is **credential-free**: credentials are supplied when the configuration is generated and are never stored here.

[`scripts/render.sh`](scripts/render.sh) generates each tool's config as JSON, built with `jq` (correct escaping by construction). The Claude MDM profile is produced by piping that JSON through [`scripts/render-plist.sh`](scripts/render-plist.sh), which adds the profile envelope and converts to a `.mobileconfig` with `plutil`. See [Prerequisites](#prerequisites) for what each script needs.

## Two delivery styles, one per tool

The repo ships **both** delivery styles, and they coexist — a laptop can have any combination. Each tool uses whichever it best supports:

| Tool | Delivery | Why | Runbook |
| --- | --- | --- | --- |
| **Claude Code** | MDM **Custom Profile** (`.mobileconfig`) | Supports a managed-settings profile payload (`com.anthropic.claudecode`). Enforced by the OS, so it is tamper-resistant. | [docs/deploy-claude-profile.md](docs/deploy-claude-profile.md) |
| **Cursor** | MDM **Custom Script** (the runner) | `hooks.json` is a plain file, not a profile payload. | [docs/deploy-cursor-runner.md](docs/deploy-cursor-runner.md) |

The table above is the macOS picture. **Windows** has no `.mobileconfig` — both agents read a plain JSON config that you pre-generate (`--target-os windows`) and push with **Intune**; see [docs/deploy-windows-intune.md](docs/deploy-windows-intune.md). On Windows the hook command is a self-contained `powershell -NoProfile -EncodedCommand …` (the encoded [`download_endorctl.ps1`](scripts/download_endorctl.ps1) + audit), so it runs regardless of how the agent launches hooks.

**Linux** uses the same file-based delivery — Cursor at `/etc/cursor/hooks.json`, Claude at `/etc/claude-code/managed-settings.json` — via `runner.sh` or your config management (Ansible/Chef/etc.). **JumpCloud** (any of the three OSes) is covered in [docs/deploy-jumpcloud.md](docs/deploy-jumpcloud.md). Not using MDM at all? See [manual & enterprise install](docs/deploy-manual-enterprise.md). The full OS × mechanism matrix is in [docs/support-matrix.md](docs/support-matrix.md).

`endorctl` itself is not delivered per tool — the generated config's session hook installs and keeps it current via [`download_endorctl.sh`](scripts/download_endorctl.sh) (SHA-256 verified). **Codex is not supported yet** (see [Not yet supported](#not-yet-supported)).

## Prerequisites

Each script depends only on tools standard to its environment. The endpoint paths (run on developer laptops) stay light; `plutil` is needed only by the admin who builds Claude profiles.

| Script | Runs on | Requires |
| --- | --- | --- |
| [`download_endorctl.sh`](scripts/download_endorctl.sh) | developer laptop (inlined into the session hook) | POSIX `sh` + `curl` (plus `awk`/`sed`/`uname`/`mktemp`/`tr` and `sha256sum` or `shasum` — all standard on macOS & Linux) |
| [`download_endorctl.ps1`](scripts/download_endorctl.ps1) | Windows developer laptop (encoded into the session hook) | Windows PowerShell 5.1 (built in) |
| [`scripts/render.sh`](scripts/render.sh) | admin machine (macOS/Linux, or Windows via Git Bash/WSL), or laptop via the runner | `jq`; for `--target-os windows` also `iconv` + `base64` |
| [`scripts/render-plist.sh`](scripts/render-plist.sh) | admin machine (macOS) | `jq`, `plutil` (macOS) |
| [`scripts/runner.sh`](scripts/runner.sh) | developer laptop (run by the MDM) | `git` + POSIX `sh` + `jq` (it calls `render.sh`) |

`endorctl` is not a prerequisite — the session hook installs and updates it (see [How updates reach the fleet](#how-updates-reach-the-fleet)).

## The generator

```sh
# Cursor hooks.json
scripts/render.sh --agent cursor \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o hooks.json

# Claude Code settings.json (local / dev use)
scripts/render.sh --agent claude \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o settings.json

# Claude Code MDM profile (.mobileconfig) — upload to your MDM
scripts/render.sh --agent claude \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o - \
| scripts/render-plist.sh \
  --identifier com.acme.ai-governance.claudecode --organization "Acme Corp" \
  --name "Claude Code — Endor AI Governance" \
  -o com.anthropic.claudecode.mobileconfig

# Windows config (push via Intune — see docs/deploy-windows-intune.md)
scripts/render.sh --agent cursor --target-os windows \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o cursor-hooks.json
```

`--target-os {macos,linux,windows}` (default `macos`; macos and linux are identical POSIX) selects the hook command form. `windows` inlines `download_endorctl.ps1` + the audit call as a base64-encoded `powershell -NoProfile -EncodedCommand …`, which runs whether the agent launches hooks via Git Bash, PowerShell, or cmd.

Credentials resolve **flag → environment variable → prompt** (the prompt fires only when stdin is a TTY, so unattended MDM runs never block):

| Flag | Env fallback | Default |
| --- | --- | --- |
| `--api-key` | `ENDOR_API_CREDENTIALS_KEY` | — (required) |
| `--api-secret` | `ENDOR_API_CREDENTIALS_SECRET` | — (required) |
| `--namespace` | `ENDOR_NAMESPACE` | — (required) |
| `--api-url` | `ENDOR_API` | `https://api.endorlabs.com` |

Behavior settings — anything `endorctl` reads, e.g. monitor-only mode — go through `--env KEY=VALUE` (repeatable). They are routed to the right place per format: Claude's `env` block, Cursor's inline `sessionStart` prefix. Response caching (`ENDOR_AI_AUDIT_CACHE_ENABLED=true`) is on by default; passing the same key again overrides it.

`--skip-endorctl-update` makes the session hook use an already-installed `endorctl` as-is — no per-session version check or network call — and installs only when the binary is missing. Use it to avoid the meta/version round-trip (and occasional re-download) on every session once the fleet is provisioned. It flows through the runner too: `runner.sh --agent cursor --skip-endorctl-update`.

`render.sh` also takes `-o/--output PATH` (`-` for stdout). Profile envelope flags live on `render-plist.sh`, which is agent-agnostic — it embeds whatever settings JSON it's piped under the chosen payload type: `--identifier` (required, reverse-DNS base for the inner payload), `--organization` (required), `--payload-type` (the app's managed-settings domain, default `com.anthropic.claudecode`), `--name`, `--profile-identifier`, `--profile-uuid`, `--content-uuid` (UUIDs default to freshly generated). Run either script with `--help` for the full list.

### Enforcing vs. monitor-only

- **Enforcing** (default): `endorctl` returns "block" verdicts for policy-violating actions and the agent halts.
- **Monitor-only** (`--env ENDOR_AI_AUDIT_NO_BLOCKING=true`): every action is still evaluated and recorded, but nothing is blocked.

Recommended rollout: start with `--env ENDOR_AI_AUDIT_NO_BLOCKING=true`, watch the Endor audit log over a representative period, confirm the policies aren't catching false positives, then re-generate without it to turn enforcement on.

## How updates reach the fleet

| What changes | How it updates | Customer action |
| --- | --- | --- |
| **`endorctl` binary** | Self-updates on session start (SHA-256 verified); `--skip-endorctl-update` pins to the installed binary | None |
| **Governance rules** | Server-side at Endor, fetched at run time | None |
| **Claude profile config** (macOS) | Regenerate the `.mobileconfig` and re-upload to the MDM | Re-upload on change |
| **Cursor runner config** (macOS) | Repo is re-pulled and rebuilt on each MDM check-in | None after one-time setup |
| **Windows config** (either agent) | Regenerate (`--target-os windows`) and re-push via Intune | Re-push on change |

## Security properties

- **Tamper-resistance.** A profile-delivered config (Claude) is a managed setting enforced by the OS, so it is hard for a developer to override. A script-delivered config (Cursor `hooks.json`) is a plain file and is **not** OS-enforced — a determined developer could override it (e.g. via `~/.cursor/`). Tamper-resistance for Cursor would require a profile-based mechanism.
- **Credentials embedded in the profile.** A generated profile carries the API key and secret to every laptop. Scope this to an **audit-only / least-privilege** credential.
- **Credential env-var isolation (Claude).** The `settings.json`/profile `env` block exports into every subprocess Claude spawns, including any `endorctl` the agent itself runs. To keep audit credentials out of the agent's process tree, hook-scoped vars use the `AGENT_HOOK_ENDOR_*` prefix (names `endorctl` does not read natively); the hook commands pass them through as `--api-key …` flags. Behavior flags (`ENDOR_AI_AUDIT_CACHE_ENABLED`, `ENDOR_AI_AUDIT_NO_BLOCKING`) keep their canonical names.

## Not yet supported

- **Codex.** Adding it needs a generator path (`--agent codex` plus a `build_codex` jq builder in `render.sh`) and confirmation that Codex reads an MDM-managed configuration.

## Repository layout

```
scripts/
  download_endorctl.sh                endorctl bootstrap, POSIX (macOS/Linux session hook)
  download_endorctl.ps1               endorctl bootstrap, PowerShell (Windows session hook)
  render.sh                           JSON generator (jq): --agent {claude,cursor} --target-os {macos,linux,windows}
  render-plist.sh                     wraps a settings JSON (stdin) into a .mobileconfig (jq + plutil); --payload-type selects the app
  runner.sh                           generic MDM runner: --agent <name> (clone → render → atomic write)
examples/                             checked-in samples (demo creds, placeholder UUIDs)
  claude/{settings.json, settings.windows.json, com.anthropic.claudecode.mobileconfig}
  cursor/{hooks.json, hooks.windows.json}
docs/                                 runbooks (manual/enterprise, Jamf/Kandji, the runner, Windows/Intune, JumpCloud) + support-matrix.md
```

### Examples

A checked-in sample per output shape lives under `examples/`, generated with demo credentials (`PEPE` / `PAPA` / namespace `spiderman`); the profile UUIDs are obvious placeholders (`…-AAAA…` / `…-BBBB…`).

| Shape | Agent | File |
| --- | --- | --- |
| JSON (POSIX hooks) | Claude | `examples/claude/settings.json` |
| MDM profile (plist) | Claude | `examples/claude/com.anthropic.claudecode.mobileconfig` |
| JSON (encoded PowerShell hook) | Claude | `examples/claude/settings.windows.json` |
| JSON (POSIX hooks) | Cursor | `examples/cursor/hooks.json` |
| JSON (encoded PowerShell hook) | Cursor | `examples/cursor/hooks.windows.json` |

`settings.json` is the same JSON Claude reads as the Linux `/etc/claude-code/managed-settings.json` and as the inner payload of the macOS `.mobileconfig` — so there's no separate Linux example, and JumpCloud reuses these same files. Only the **Windows** examples differ (the hook is the encoded `powershell` form). Monitor-only isn't a separate sample — it's any of these plus `--env ENDOR_AI_AUDIT_NO_BLOCKING=true`.

After changing a script, regenerate the affected examples so they stay in sync (the commands are in this section).

Credentials and `--env` values are quoted robustly — values containing spaces, single quotes, `$`, `;`, `*`, or `"` are escaped for the shell (POSIX, via `@sh`), PowerShell (single-quote doubling), and JSON (`jq`). `$VAR` references in the generated commands are quoted too, so values never word-split or glob at hook runtime.

To add a new agent: add a `build_<agent>` jq builder and a `case` arm in `scripts/render.sh` (and a default `--dest` in `scripts/runner.sh` if it is script-delivered).
