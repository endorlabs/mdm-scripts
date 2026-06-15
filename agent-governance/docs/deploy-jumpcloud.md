# Deploy via JumpCloud (macOS, Linux, Windows)

JumpCloud can deliver to all three OSes using two building blocks:

- **Commands** run a script on devices — as **root** on macOS/Linux, as **`NT AUTHORITY\System`** on Windows. They support recurring execution (**Run as Repeating**) plus login and webhook triggers. This is how you run the runner or write a config file.
- **MDM Custom Configuration Profiles** (macOS only) deliver a `.mobileconfig`. JumpCloud signs the profile and rewrites its outer `PayloadIdentifier`/`PayloadUUID`, so you don't pass `--profile-identifier`/`--profile-uuid` when generating for JumpCloud.

There's no native "push a file" feature — file delivery is just a Command that writes the file. Use an **audit-only / least-privilege** credential throughout, supplied through JumpCloud and never the repo. Find your agent + OS below:

| Agent | OS | Mechanism |
| --- | --- | --- |
| Claude Code | macOS | MDM Custom Configuration Profile (`.mobileconfig`) — tamper-resistant |
| Claude Code | Linux | Command → `runner.sh --agent claude` → `/etc/claude-code/managed-settings.json` |
| Claude Code | Windows | Command (PowerShell) writes the pre-generated config to `C:\Program Files\ClaudeCode\managed-settings.json` |
| Cursor | macOS | Command → `runner.sh --agent cursor` |
| Cursor | Linux | Command → `runner.sh --agent cursor` → `/etc/cursor/hooks.json` |
| Cursor | Windows | Command (PowerShell) writes the pre-generated config to `C:\ProgramData\Cursor\hooks.json` |

## macOS — Claude via profile

Generate the `.mobileconfig` ([see the profile runbook](deploy-claude-profile.md); omit `--profile-identifier`/`--profile-uuid`, since JumpCloud rewrites them). Then in **Device Management → Policy Management → Mac → MDM Custom Configuration Profile**, upload the file and scope it to a Device Group (devices must be MDM-enrolled). To update, regenerate and re-upload.

## macOS & Linux — the runner via a Command

This is JumpCloud's equivalent of a Jamf recurring policy or a Kandji schedule.

1. **Device Management → Commands → New**, target **Mac** or **Linux**, interpreter Bash/Shell. The body exports the credentials and runs the runner from a cloned repo:
   ```sh
   #!/bin/sh
   set -eu
   export ENDOR_API_CREDENTIALS_KEY='…' ENDOR_API_CREDENTIALS_SECRET='…' ENDOR_NAMESPACE='…'
   REF="main"   # pin to a reviewed tag or commit in production (e.g. v1.0.0)
   # Runs as root, so clone to a root-owned protected path — never /tmp, where a
   # local user could pre-create the dir and trick root into running their code.
   case "$(uname -s)" in
     Darwin) REPO="/Library/Application Support/EndorAIGovernance/repo" ;;
     *)      REPO="/var/lib/endor-ai-governance/repo" ;;
   esac
   mkdir -p "$(dirname "$REPO")"
   [ -d "$REPO/.git" ] || { git init -q "$REPO"; git -C "$REPO" remote add origin https://github.com/endorlabs/mdm-scripts; }
   git -C "$REPO" fetch --depth 1 origin "$REF"
   git -C "$REPO" -c advice.detachedHead=false checkout -f FETCH_HEAD
   exec sh "$REPO/agent-governance/scripts/runner.sh" --agent cursor --ref "$REF"    # or: --agent claude (Linux)
   ```
   **Single-quote** the values so a `"`, `$`, or backtick can't break the assignment (escape any literal single quote as `'\''`). Set `REF` to a reviewed tag or commit to pin the revision (it defaults to `main`). The endpoint needs `git` + `jq`.
2. Set the launch type to **Run as Repeating** (e.g. hourly) so repo and credential/flag changes flow automatically — the runner re-renders and swaps only on change.
3. Scope it to a Device Group.

If you'd rather not require `git`/`jq` on Linux, use the file-writing Command pattern below (pre-generate, embed the JSON) for Linux too.

## Windows — a PowerShell Command

Windows endpoints have no `git`/`jq`, so **pre-generate** the config on a macOS/Linux (or WSL/Git Bash) admin box:

```sh
scripts/render.sh --agent cursor --target-os windows --api-key … --api-secret … --namespace … -o cursor-hooks.json
```

Then a JumpCloud **Windows Command** (PowerShell, runs as SYSTEM) writes it to the system path:

```powershell
$dest = "C:\ProgramData\Cursor\hooks.json"   # or C:\Program Files\ClaudeCode\managed-settings.json
New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
Set-Content -Path $dest -Value @'
<paste the generated JSON here>
'@ -Encoding UTF8
```

Set it to **Run as Repeating** to keep it current; to update, edit the embedded JSON and re-push. For a per-user `%USERPROFILE%\.cursor\hooks.json`, use JumpCloud's **"Run As Signed In User"** template instead of the SYSTEM default.

## Things to watch

- **Repeating commands** fire in the device's local time zone and can miss their window if the device is asleep — pick a frequency (e.g. hourly) that tolerates the occasional miss.
- A macOS Command writing into a protected path needs the JumpCloud agent to have **Full Disk Access**, or it fails with "Operation Not Permitted."
