# Deploy via JumpCloud (macOS, Linux, Windows)

JumpCloud covers all three OSes with two building blocks:

- **Commands** — run a script on devices. macOS/Linux run as **root**; Windows runs
  as **`NT AUTHORITY\System`**. Launch types include **Run as Repeating** (recurring),
  Run on Every Login, manual, and webhook. Use Commands to write a config file to a
  path and/or to run the runner.
- **MDM Custom Configuration Profile** (macOS only) — upload a `.mobileconfig`.
  JumpCloud signs it and rewrites the outer `PayloadIdentifier`/`PayloadUUID`, so you
  don't set `--profile-identifier`/`--profile-uuid` when generating for JumpCloud.

There's no native "push a file" feature — file delivery is a Command that writes the
file. Pick the row for your agent + OS below.

| Agent | OS | Mechanism |
| --- | --- | --- |
| Claude Code | macOS | **MDM Custom Configuration Profile** (`.mobileconfig`) — tamper-resistant |
| Claude Code | Linux | **Command** → `runner.sh --agent claude` (writes `/etc/claude-code/managed-settings.json`) |
| Claude Code | Windows | **Command (PowerShell)** writing the pre-generated config to `C:\Program Files\ClaudeCode\managed-settings.json` |
| Cursor | macOS | **Command** → `runner.sh --agent cursor` |
| Cursor | Linux | **Command** → `runner.sh --agent cursor` (writes `/etc/cursor/hooks.json`) |
| Cursor | Windows | **Command (PowerShell)** writing the pre-generated config to `C:\ProgramData\Cursor\hooks.json` |

Credentials come from JumpCloud (never the repo). Use an **audit-only /
least-privilege** Endor credential.

## macOS — Claude (profile)

1. Generate the `.mobileconfig` (see [deploy-claude-profile.md](deploy-claude-profile.md));
   you can omit `--profile-identifier`/`--profile-uuid` since JumpCloud rewrites them.
2. **Device Management → Policy Management → Mac → MDM Custom Configuration Profile**,
   upload the file, scope to a Device Group. (Devices must be MDM-enrolled.)
3. To update: regenerate and re-upload.

## macOS / Linux — the runner (Command)

This is the JumpCloud equivalent of a Jamf recurring policy / Kandji schedule.

1. **Device Management → Commands → New**, target **Mac** or **Linux**, interpreter
   Bash/Shell. Body — export creds and run the runner from a cloned repo:
   ```sh
   #!/bin/sh
   set -eu
   export ENDOR_API_CREDENTIALS_KEY='…' ENDOR_API_CREDENTIALS_SECRET='…' ENDOR_NAMESPACE='…'
   # This runs as root, so clone to a root-owned protected path — never /tmp, where
   # a local user could pre-create the dir and get root to run their code.
   case "$(uname -s)" in
     Darwin) REPO="/Library/Application Support/EndorAIGovernance/repo" ;;
     *)      REPO="/var/lib/endor-ai-governance/repo" ;;
   esac
   mkdir -p "$(dirname "$REPO")"
   [ -d "$REPO/.git" ] || git clone --depth 1 https://github.com/endorlabs/mdm-scripts "$REPO"
   exec sh "$REPO/agent-governance/scripts/runner.sh" --agent cursor    # or: --agent claude (Linux)
   ```
   **Single-quote** the hard-coded values so a `"`, `$`, or backtick can't break the
   assignment (escape any literal single quote as `'\''`). Endpoint needs `git` + `jq`.
2. Set the launch type to **Run as Repeating** (e.g. hourly) so credential/flag and
   repo changes flow automatically — the runner re-renders and swaps only on change.
3. Scope to a Device Group.

> The runner needs `git`+`jq` on the endpoint. If you'd rather not require those, use
> the file-writing Command pattern below (pre-generate, embed the JSON) on Linux too.

## Windows — Command (PowerShell)

Windows endpoints have no `git`/`jq`, so **pre-generate** the config on a macOS/Linux
(or WSL/Git Bash) admin box and have the Command write it:

```sh
scripts/render.sh --agent cursor --target-os windows --api-key … --api-secret … --namespace … -o cursor-hooks.json
```

Then a JumpCloud **Windows Command** (PowerShell, runs as SYSTEM) that writes it to the
system path:

```powershell
$dest = "C:\ProgramData\Cursor\hooks.json"   # or C:\Program Files\ClaudeCode\managed-settings.json
New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
Set-Content -Path $dest -Value @'
<paste the generated JSON here>
'@ -Encoding UTF8
```

Set it to **Run as Repeating** to keep it current; to update, edit the embedded JSON
and re-push. For a per-user path (`%APPDATA%\Cursor\hooks.json`) use JumpCloud's
**"Run As Signed In User"** command template instead of the SYSTEM default.

## Caveats

- **Repeating commands** use device-local time and can miss their window if the device
  is asleep at the scheduled time — pick a frequency (e.g. hourly) that tolerates a miss.
- macOS Commands writing into protected paths need the JumpCloud agent to have **Full
  Disk Access** (else "Operation Not Permitted").
