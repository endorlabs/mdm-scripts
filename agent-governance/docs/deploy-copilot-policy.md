# Deploy GitHub Copilot via a policy hook file (macOS / Linux / Windows)

GitHub Copilot loads hooks from several levels and combines them — **policy, then user, then project, then plugins**. The policy level is the one an administrator owns, and it is the only one a developer can't undo: hooks installed there **cannot be disabled with `disableAllHooks`** and **run regardless of folder trust state**. Installing it needs elevated privileges, so end users can't modify it.

That makes Copilot's story different from every other agent in this repo: there's no `.mobileconfig` and no managed preference domain involved, just a root-owned JSON file at a fixed path — yet it's still enforced, because Copilot itself treats that path as policy.

| OS | Policy hook path |
| --- | --- |
| macOS / Linux | `/etc/github-copilot/policy.d/endor.json` |
| Windows | `C:\ProgramData\GitHub\Copilot\policy.d\endor.json` |

## Scope: the CLI is covered, VS Code agent mode is not

Copilot exposes hooks on two local surfaces, and `endorctl ai-audit copilot` governs both. **Only the Copilot CLI reads the policy level**, so only the CLI can be centrally enforced today.

VS Code's Copilot agent mode reads hooks from workspace `.github/hooks/*.json`, the user directory `~/.copilot/hooks`, `chat.hookFilesLocations`, and plugins — none of which is an administrator-owned path. VS Code's enterprise controls (the `com.github.copilot` macOS preference domain, `HKLM\SOFTWARE\Policies\GitHubCopilot`, and `managed-settings.json`) expose a `ChatHooks` policy that only turns hooks **on or off**; there is no documented key that *deploys* hook content. So:

- **Copilot CLI** — enforced via `policy.d`, per this runbook.
- **VS Code agent mode** — no managed path. A developer can opt in by copying the same generated file to `~/.copilot/hooks/endor.json` (that directory is read by both surfaces). This is real coverage but **not tamper-resistant** — the file is user-writable, and the user can also set `disableAllHooks`. Treat it as best-effort until GitHub ships a managed hook path.

If your fleet standardizes on VS Code rather than the CLI, know that this path governs only the CLI half and plan accordingly.

## How it differs from the other agents

- **One JSON file, no profile step.** `render.sh --agent copilot` emits the finished artifact; there is no `render-plist.sh` stage, because Copilot has no macOS profile payload for hook content.
- **PascalCase event names are required.** The Copilot CLI picks its payload format from the casing of the event names in the config. Only the PascalCase form emits the `hook_event_name` field that `endorctl ai-audit copilot` uses to tell which event fired, so the generated config always uses it. (The lowerCamelCase form works only if you pass the event as an argument, e.g. `ai-audit copilot preToolUse`.)
- **No managed env block.** Like Codex, Copilot has no place to put managed environment variables, so audit credentials are baked into each hook command as `--api-key …` flags and behavior `--env` values are inlined. The file is the credential-bearing artifact — use an **audit-only** credential and keep it root-owned (`0644` is fine; `0600` will not work, since the hook is read as the developer's user).
- **One `command` key covers both surfaces.** The CLI documents `command` as the cross-platform fallback, "copied to both `bash` and `powershell` when those fields are absent", and it's the only command key VS Code understands. The two disagree on the timeout spelling — the CLI reads `timeoutSec`, VS Code reads `timeout` — so the generator emits both and each surface ignores the one it doesn't know.
- **Events.** Endor governs `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Stop`, and `SessionEnd`. `PreToolUse` is the enforcing one: the decision is written into both the CLI's top-level `permissionDecision` and VS Code's nested `hookSpecificOutput`, so a block works on either surface. Matchers are deliberately unused — VS Code parses but does not apply them.
- **Hooks run alongside the developer's own.** Policy hooks are combined with user and project hooks, not a replacement for them; the difference is that yours can't be switched off.

## 1. Generate the config

Use an **audit-only / least-privilege** API credential, since it's embedded in the file and delivered to every laptop.

```sh
# macOS / Linux
scripts/render.sh --agent copilot \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o endor.json

# Windows (encoded PowerShell hook)
scripts/render.sh --agent copilot --target-os windows \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o endor.json
```

For an initial monitor-only rollout, add `--env ENDOR_AI_AUDIT_NO_BLOCKING=true`. Ready-made samples (demo credentials) are at `examples/copilot/policy.json` and `examples/copilot/policy.windows.json`.

## 2. Deliver it

**macOS / Linux — the runner.** Set `AGENT=copilot` in [`runner.sh`](../scripts/runner.sh) and paste it into your MDM as a recurring script (Jamf script, Kandji Custom Script, JumpCloud Command). It fetches this repo at the pinned `REF`, re-renders, and swaps the file in only when the output changed — so credential and flag changes take effect without you re-uploading anything. It defaults to `/etc/github-copilot/policy.d/endor.json` and creates the directory if needed. See [the runner runbook](deploy-cursor-runner.md) for the MDM-specific setup and how credentials reach it.

**macOS / Linux — config management.** The artifact is just a file; deliver `/etc/github-copilot/policy.d/endor.json` with Ansible, Chef, Puppet, or Salt if you'd rather not fetch-and-render on the endpoint. Own it as root, mode `0644`.

**Windows — Intune.** Pre-generate with `--target-os windows` and push to `C:\ProgramData\GitHub\Copilot\policy.d\endor.json`. See [Deploy on Windows via Intune](deploy-windows-intune.md); the runner is POSIX-only.

Copilot also documents a Windows registry policy source (`HKLM\Software\Policies\GitHub\Copilot`) alongside `policy.d`. This repo doesn't generate registry content — **the file path is the supported target here**, and the two docs that mention the registry disagree on the exact key, so verify on a real endpoint before relying on it.

## 3. Verify

On a target machine, run `copilot` and start a session, then have it run a tool (a shell command or a file edit) to exercise `PreToolUse`/`PostToolUse`. The `SessionStart` hook installs/updates `endorctl` and begins reporting to your Endor namespace. Confirm the activity in the Endor audit log.

Two things worth checking explicitly, because they're what the policy level buys you:

```sh
# The policy file is present and root-owned
ls -l /etc/github-copilot/policy.d/endor.json

# It still applies with hooks "disabled" by the user and in an untrusted folder
printf '{"disableAllHooks": true}\n' > ~/.copilot/settings.json
```

Auditing should continue in both cases. Remove that `disableAllHooks` line when you're done testing.

## Updating

The runner re-renders on its own schedule, so macOS/Linux need no action after setup — bump `REF` to roll out a change to the generated config. Windows is pre-generated, so regenerate and re-push via Intune. The `endorctl` binary self-updates in the background either way, and governance rules are evaluated server-side at run time.
