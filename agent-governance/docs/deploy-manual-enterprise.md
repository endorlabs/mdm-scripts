# Manual & enterprise-platform install (no MDM)

For trials, individual developers, or orgs that govern through the agent's own
enterprise platform rather than MDM. Generate the config with `render.sh` and
either drop it at a local path (manual) or supply it to the vendor platform
(enterprise). Unlike the MDM/managed paths, **manual local files are not
tamper-resistant** — the developer can edit them; use MDM (the other runbooks)
where enforcement matters. The enterprise platforms *are* centrally managed.

Generate the config for the developer's OS first:

```sh
# macOS / Linux (POSIX hooks)
scripts/render.sh --agent cursor --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o hooks.json
scripts/render.sh --agent claude --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o settings.json

# Windows (encoded PowerShell hooks)
scripts/render.sh --agent cursor --target-os windows … -o hooks.json
scripts/render.sh --agent claude --target-os windows … -o settings.json
```

## Manual — drop the file locally

| Agent | Scope | macOS / Linux | Windows |
| --- | --- | --- | --- |
| **Cursor** | per-user | `~/.cursor/hooks.json` | `%APPDATA%\Cursor\hooks.json` |
| **Cursor** | per-project | `<repo>/.cursor/hooks.json` | same (in the repo) |
| **Claude Code** | per-user | `~/.claude/settings.json` | `%USERPROFILE%\.claude\settings.json` |
| **Claude Code** | per-project | `<repo>/.claude/settings.json` | same (in the repo) |

Use the **Windows-generated** config (`--target-os windows`) when the file lands on
a Windows machine, the POSIX one for macOS/Linux. Restart the agent (or start a new
session) to pick it up.

## Enterprise platform — supply the config centrally

### Cursor — Team hooks (Enterprise plan)
Configure hooks in the Cursor admin/Team dashboard; Cursor cloud-delivers them to
members on login and supports **OS-specific targeting**. Paste the body of the
generated `hooks.json` (POSIX for macOS/Linux targets, the `--target-os windows`
variant for Windows targets) into the matching OS slot.

### Claude Code — server-managed settings
In the Claude admin console, set **server-managed settings** with the same `env` +
`hooks` that `render.sh --agent claude` produces. Server-managed settings are the
**highest-precedence** scope (above local and MDM), so this alone can govern the
fleet without touching MDM. (The hook commands are identical to the file form;
generate per target OS as above.)

## Which to use

- **Manual** — fastest to try; not enforced; good for a single machine or a pilot.
- **Enterprise platform** — centrally managed by the vendor, no MDM needed; the
  cleanest path if you already run Cursor Enterprise / Claude's admin console.
- **MDM** (other runbooks) — OS-enforced/tamper-resistant; use when you need that.
