# Deploy via JumpCloud (macOS, Linux, Windows)

JumpCloud can deliver to all three OSes using two building blocks:

- **Commands** run a script on devices — as **root** on macOS/Linux, as **`NT AUTHORITY\System`** on Windows. They support recurring execution (**Run as Repeating**) plus login and webhook triggers. This is how you run the runner or write a config file.
- **MDM Custom Configuration Profiles** (macOS only) deliver a `.mobileconfig`. JumpCloud signs the profile and rewrites its outer `PayloadIdentifier`/`PayloadUUID`, so you don't pass `--profile-identifier`/`--profile-uuid` when generating for JumpCloud.

There's no native "push a file" feature — file delivery is just a Command that writes the file. Use an **audit-only / least-privilege** credential throughout, supplied through JumpCloud and never the repo. Find your agent + OS below:

| Agent | OS | Mechanism |
| --- | --- | --- |
| Claude Code | macOS | MDM Custom Configuration Profile (`.mobileconfig`) — tamper-resistant |
| Claude Code | Linux | Command → `runner.sh (AGENT=claude)` → `/etc/claude-code/managed-settings.json` |
| Claude Code | Windows | Command (PowerShell) writes the pre-generated config to `C:\Program Files\ClaudeCode\managed-settings.json` |
| Cursor | macOS | Command → `runner.sh (AGENT=cursor)` |
| Cursor | Linux | Command → `runner.sh (AGENT=cursor)` → `/etc/cursor/hooks.json` |
| Cursor | Windows | Command (PowerShell) writes the pre-generated config to `C:\ProgramData\Cursor\hooks.json` |

## macOS — Claude via profile

Generate the `.mobileconfig` ([see the profile runbook](deploy-claude-profile.md); omit `--profile-identifier`/`--profile-uuid`, since JumpCloud rewrites them). Then in **Device Management → Policy Management → Mac → MDM Custom Configuration Profile**, upload the file and scope it to a Device Group (devices must be MDM-enrolled). To update, regenerate and re-upload.

## macOS & Linux — the runner via a Command

This is JumpCloud's equivalent of a Jamf recurring policy or a Kandji schedule.

1. **Device Management → Commands → New**, target **Mac** or **Linux**, interpreter Bash/Shell. The body is the credential line, then the contents of [`scripts/runner.sh`](../scripts/runner.sh):
   ```sh
   #!/bin/sh
   export ENDOR_API_CREDENTIALS_KEY='…' ENDOR_API_CREDENTIALS_SECRET='…' ENDOR_NAMESPACE='…'
   # …contents of scripts/runner.sh below (set AGENT=cursor or claude, REF=<tag>)…
   ```
   Single-quote the values so a `"`, `$`, or backtick can't break the assignment (escape any literal single quote as `'\''`). In `runner.sh`, set `AGENT` and `REF` (a reviewed tag/commit to pin). The endpoint needs only `curl` + `tar` (both ship with macOS/Linux).
2. Set the launch type to **Run as Repeating** (e.g. hourly) so each run re-fetches `REF` and re-renders, swapping only on change — repo and credential/flag changes flow automatically.
3. Scope it to a Device Group.

If you'd rather not fetch-and-render on the endpoint at all, use the file-writing Command pattern below (pre-generate, embed the JSON) for Linux too.

## Windows — a PowerShell Command

Windows endpoints can't run the POSIX runner (no `sh`), so **pre-generate** the config on a macOS/Linux (or WSL/Git Bash) admin box:

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
