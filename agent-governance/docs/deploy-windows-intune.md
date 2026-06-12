# Deploy on Windows via Intune

Windows isn't Jamf/Kandji + Configuration Profiles — there's no `.mobileconfig`.
Both agents read a plain JSON config from a known path, and you push it with
**Microsoft Intune**. Unlike the macOS Cursor runner, you do **not** run the
generator on the endpoint: a Windows laptop has no `jq`/`sh`. Instead you
**pre-generate the Windows config on a macOS/Linux admin machine** and have
Intune place the file.

## How the Windows hooks run

The generated config's hook commands are a single self-contained call:

```
powershell -NoProfile -EncodedCommand <base64-UTF16LE of download_endorctl.ps1 + the audit call>
```

Base64 is plain alphanumeric, so it runs identically whether the agent launches
hooks through Git Bash, PowerShell, or cmd — and `powershell.exe` (5.1) ships with
Windows, so nothing extra is needed on the endpoint. The readable source is
[`download_endorctl.ps1`](../scripts/download_endorctl.ps1); the config just carries its
encoding.

## 1. Generate the Windows configs (admin machine)

> `render.sh` is POSIX. Generate on macOS/Linux, or on a Windows admin box under
> **Git Bash** (ships with Git for Windows) or **WSL** with `jq` installed — the
> output is identical. The endpoint never runs the generator.


```sh
# Cursor
scripts/render.sh --agent cursor --target-os windows \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o cursor-hooks.json

# Claude Code
scripts/render.sh --agent claude --target-os windows \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o claude-managed-settings.json
```

Add `--env ENDOR_AI_AUDIT_NO_BLOCKING=true` for a monitor-only rollout, or
`--skip-endorctl-update` to pin to the installed binary. Generating Windows
configs needs `jq` + `iconv` + `base64` (all standard on macOS/Linux).

## 2. Target paths on Windows

| Agent | Path | Notes |
| --- | --- | --- |
| **Cursor** | `%APPDATA%\Cursor\hooks.json` (per-user) or `C:\ProgramData\Cursor\hooks.json` (system-wide) | system-wide outranks per-user |
| **Claude Code** | `C:\Program Files\ClaudeCode\managed-settings.json` (+ `managed-settings.d\`) | managed settings; users can't override |

## 3. Push with Intune

Use a **Platform script** (Devices → Scripts → Add → Windows 10 and later) or a
**Win32 app**, run in system context, that writes the generated JSON to the path
above. A minimal platform-script body (with the generated JSON embedded or fetched):

```powershell
$dest = "$env:ProgramData\Cursor\hooks.json"          # or the Claude path
New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
Set-Content -Path $dest -Value $json -Encoding UTF8    # $json = the generated config
```

Scope it to the target device/user groups.

## Endpoint prerequisites

Only `powershell.exe` (Windows PowerShell 5.1, built in) — invoked by the hook —
and `git` is **not** needed (no on-endpoint generation). `endorctl.exe` installs
itself on first session via the inlined `download_endorctl.ps1`.

## Updating

Re-generate the config (step 1) and re-push via Intune; Intune redeploys to the
fleet. There's no on-endpoint auto-pull on Windows — updates are centrally driven
from Intune.
