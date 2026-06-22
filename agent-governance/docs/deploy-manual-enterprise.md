# Manual & enterprise-platform install (no MDM)

For trials, individual developers, or orgs that govern through an agent's own enterprise platform instead of MDM. You generate the config the same way, then either drop it at a local path (manual) or hand it to the vendor platform (enterprise). Manual local files **aren't tamper-resistant** — a developer can edit them — so use an [MDM path](../README.md#choose-how-to-deploy) where enforcement matters; the enterprise platforms, by contrast, are centrally managed.

## Quick start (manual)

Generate a config for the developer's OS and drop it in their user directory:

```sh
# macOS / Linux
scripts/render.sh --agent cursor --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o ~/.cursor/hooks.json
scripts/render.sh --agent claude --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o ~/.claude/settings.json

# Windows (encoded PowerShell hooks)
scripts/render.sh --agent cursor --target-os windows … -o "$USERPROFILE\.cursor\hooks.json"
scripts/render.sh --agent claude --target-os windows … -o "$USERPROFILE\.claude\settings.json"
```

Restart the agent (or start a new session) and it picks up the config — the hook installs `endorctl` on first run and starts reporting.

## Where the file goes

| Agent | Scope | macOS / Linux | Windows |
| --- | --- | --- | --- |
| **Cursor** | per-user | `~/.cursor/hooks.json` | `%USERPROFILE%\.cursor\hooks.json` |
| **Cursor** | per-project | `<repo>/.cursor/hooks.json` | same (in the repo) |
| **Claude Code** | per-user | `~/.claude/settings.json` | `%USERPROFILE%\.claude\settings.json` |
| **Claude Code** | per-project | `<repo>/.claude/settings.json` | same (in the repo) |

Use the `--target-os windows` config when the file lands on Windows, and the default POSIX config for macOS/Linux.

## Enterprise platform (centrally managed, no MDM)

If you run Cursor's or Claude's enterprise platform, you can govern the fleet without touching MDM — generate the config as above and supply it through the platform:

- **Cursor — Team hooks** (Enterprise plan). Configure hooks in the Team dashboard; Cursor cloud-delivers them to members on login and supports OS-specific targeting. Paste the body of the generated `hooks.json` (POSIX for macOS/Linux, the `--target-os windows` variant for Windows) into the matching OS slot.
- **Claude Code — server-managed settings.** In the Claude admin console, set server-managed settings to the same `env` + `hooks` that `render.sh --agent claude` produces. These are the **highest-precedence** scope, so this alone can govern the fleet.

## Which to use

- **Manual** — fastest to try; not enforced; good for one machine or a pilot.
- **Enterprise platform** — centrally managed by the vendor, no MDM needed; the cleanest path if you already run Cursor Enterprise or Claude's admin console.
- **MDM** — OS-enforced and tamper-resistant; use it when enforcement matters. See the [deployment runbooks](../README.md#choose-how-to-deploy).
