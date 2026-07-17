# Deploy Codex via an MDM profile (macOS)

On macOS, OpenAI Codex reads managed configuration from a Configuration Profile that Forces the `com.openai.codex` preference domain — specifically a base64-encoded `requirements.toml` under the key `requirements_toml_base64`. Hooks that come from a **managed / requirements source are auto-trusted by policy** and can't be disabled from Codex's hook browser, so a profile is **tamper-resistant**: the OS enforces it and the developer can't opt out. The one tradeoff, as with Claude, is that an update means regenerating the profile and re-uploading it.

You'll generate a `.mobileconfig` on an admin Mac (you need `plutil` and `base64`, both native to macOS), then upload it through Jamf or Kandji.

## Prerequisites

Nothing beyond what the other agents need — the `requirements.toml` is emitted with `printf` (no TOML tooling), and Codex parses it with its own built-in parser, so **no TOML library is required on the admin machine or the endpoint**.

- **Admin machine:** `plutil` + `base64` (native to macOS) for the profile; `sh` + `awk` + `sed` for `render.sh`, plus `iconv` + `base64` for `--target-os windows`.
- **Endpoint:** just the hook runtime the other agents use — POSIX `sh` + `curl` on macOS/Linux, PowerShell 5.1 on Windows — and a **Codex build that supports managed hooks**: the `hooks` feature (stable, on by default) and the `requirements_toml_base64` managed preference on macOS. Verified against Codex CLI 0.142.2; older builds without managed-hook support won't apply these.

## How it differs from Claude

- **Codex takes TOML, not JSON.** `render.sh --agent codex` emits a `requirements.toml`; `render-plist.sh --style mcx` base64-encodes it and wraps it in the `com.openai.codex` MCX manifest.
- **No managed env block.** Claude carries audit credentials in a profile `env` block; Codex has no equivalent, so the credentials are baked into each hook command. The profile is the credential-bearing artifact either way — use an **audit-only** credential.
- **One artifact, inline hooks.** Codex runs a hook `command` through a shell exactly like Claude, so the same self-installing `endorctl` bootstrap is inlined — there is no separate script to deliver.
- **Events.** Endor governs `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, and `Stop`. `allow_managed_hooks_only = true` in the generated file makes Codex ignore any user/project/plugin hooks and run only these.

## 1. Generate the profile

`render.sh` builds the `requirements.toml` and `render-plist.sh --style mcx` wraps it into the `.mobileconfig` — pipe one into the other. Use an **audit-only / least-privilege** API credential, since it's embedded in the profile and delivered to every laptop.

```sh
scripts/render.sh --agent codex \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o - \
| scripts/render-plist.sh --style mcx \
  --identifier com.<customer>.ai-governance.codex \
  --organization "<Customer>" \
  --name "Codex - Endor AI Governance" \
  -o com.openai.codex.mobileconfig
```

- `--style mcx` selects the Forced-preferences envelope; `--pref-domain` (default `com.openai.codex`) and `--pref-key` (default `requirements_toml_base64`) are the managed-preference target.
- `--identifier` is a unique reverse-DNS id in your namespace; the inner payload becomes `<identifier>.settings`.
- `--organization` sets the profile's `PayloadOrganization`, and `--name` the MDM-visible display name.
- UUIDs are generated fresh unless you pass `--profile-uuid` / `--content-uuid`.
- For an initial monitor-only rollout, add `--env ENDOR_AI_AUDIT_NO_BLOCKING=true` to the `render.sh` step.

Confirm it's a valid property list before uploading (there's a ready-made sample at `examples/codex/com.openai.codex.mobileconfig`):

```sh
plutil -lint com.openai.codex.mobileconfig
```

## 2. Upload to the MDM

**Jamf Pro** — Computers → Configuration Profiles → New; add an **Application & Custom Settings → Upload** payload with the `.mobileconfig`; set the **Scope**; Save. (If you embed it under a Jamf-owned outer profile, set `--profile-identifier` to that profile's id so the outer identity matches.)

**Kandji** — Library → Add New → Custom Profile; upload the `.mobileconfig`; assign it to the target Blueprint.

## 3. Verify

Open Codex on a target machine and start a session. The `SessionStart` hook installs/updates `endorctl` and begins reporting to your Endor namespace; run a tool (a shell command or file edit) to exercise `PreToolUse`/`PostToolUse`. Confirm the activity in the Endor audit log. Because the hooks arrive from a managed source, Codex trusts them automatically — there is no per-user approval prompt.

## Updating

Profile-delivered config doesn't auto-update. To ship a change, regenerate the `.mobileconfig` (step 1), re-upload it to the MDM with a **bumped profile version**, and the MDM re-pushes it. How fast it lands depends on the MDM's check-in behavior.

## Linux and Windows: the same requirements, as a file

The profile is macOS-only. On Linux and Windows, Codex reads the *same* managed `requirements.toml` as a plain file at a system path — no `render-plist.sh` step, still admin-enforced (root/Administrator-owned) and its hooks still auto-trusted.

| OS | Path | Deliver with |
| --- | --- | --- |
| Linux | `/etc/codex/requirements.toml` | [`runner.sh (AGENT=codex)`](deploy-cursor-runner.md), config management, or a [JumpCloud](deploy-jumpcloud.md) Command |
| Windows | `%ProgramData%\OpenAI\Codex\requirements.toml` | pre-generate `--target-os windows`, push via [Intune](deploy-windows-intune.md) |

Generate the Linux file with `render.sh --agent codex` (POSIX hooks) and the Windows file with `--target-os windows` (encoded PowerShell hooks). On macOS you can also deliver `/etc/codex/requirements.toml` via the runner instead of a profile; the profile is the tamper-resistant path when you want MDM enforcement.
