# Deploy on Windows via Intune

Windows has no Configuration Profiles for these tools — both agents read a plain JSON config from a known path. So the pattern is different from macOS: you **pre-generate the config on a macOS/Linux admin machine** (the generator is a POSIX shell script; a plain Windows laptop has no `sh`) and use **Microsoft Intune** to place the file. The endpoint never runs the generator.

## How the Windows hook runs

The generated config's hook is one self-contained command:

```
powershell -NoProfile -EncodedCommand <base64-UTF16LE of download_endorctl.ps1 + the audit call>
```

Base64 is plain alphanumeric, so it runs identically whether the agent launches the hook through Git Bash, PowerShell, or cmd — and `powershell.exe` (5.1) ships with Windows, so nothing extra is needed on the endpoint. The readable source is [`download_endorctl.ps1`](../scripts/download_endorctl.ps1); the config just carries its encoding.

## 1. Generate the config (admin machine)

Generate on macOS/Linux, or on Windows under Git Bash (ships with Git for Windows) or WSL — the output is identical.

```sh
# Cursor
scripts/render.sh --agent cursor --target-os windows \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o cursor-hooks.json

# Claude Code
scripts/render.sh --agent claude --target-os windows \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o claude-managed-settings.json
```

Add `--env ENDOR_AI_AUDIT_NO_BLOCKING=true` for a monitor-only rollout, or `--skip-endorctl-update` to pin to the installed binary. (Generating Windows configs needs `sh` + `awk` + `sed` + `iconv` + `base64`, all standard on macOS/Linux.)

## 2. Where the file goes

| Agent | Path | Notes |
| --- | --- | --- |
| **Cursor** | `C:\ProgramData\Cursor\hooks.json` (system-wide) or `%USERPROFILE%\.cursor\hooks.json` (per-user) | system-wide outranks per-user |
| **Claude Code** | `C:\Program Files\ClaudeCode\managed-settings.json` (+ `managed-settings.d\`) | managed settings; users can't override |

## 3. Push with Intune

Use a **Platform script** (Devices → Scripts → Add → Windows 10 and later) or a Win32 app, run in system context, that writes the generated JSON to the path above:

```powershell
$dest = "$env:ProgramData\Cursor\hooks.json"   # or C:\Program Files\ClaudeCode\managed-settings.json
# Paste the generated config between the single-quoted here-string markers. Single
# quotes (@'  '@) keep it literal so PowerShell doesn't interpret $ / quotes in it.
$json = @'
<paste the contents of the generated cursor-hooks.json / managed-settings.json here>
'@
New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
Set-Content -Path $dest -Value $json -Encoding UTF8
```

Scope it to the target device or user groups. (For the per-user path `%USERPROFILE%\.cursor\hooks.json`, run the script in the user's context instead of system.)

An Intune **platform script runs once per device** — it re-runs only when you change the script content (and once for each new user who signs in, when run in user context). That's fine for a config that only changes when you regenerate it. If you want Intune to keep re-asserting the file on a schedule — e.g. to repair drift if a user edits or deletes it — use a **Remediation** instead (Devices → Remediations: a detection + remediation script pair, scheduled Once / Hourly / Daily; requires Windows Enterprise E3/E5).

## Endpoint prerequisites

Just `powershell.exe` (Windows PowerShell 5.1, built in) — invoked by the hook. There's no on-endpoint generation, so `git`/`jq` aren't needed, and `endorctl.exe` installs itself on the first session via the inlined `download_endorctl.ps1`.

## Updating

Regenerate the config (step 1) and re-deploy it. Since a platform script only re-runs when its content changes, "re-push" means updating the script body (the embedded JSON) in the policy — re-saving an unchanged policy won't re-run. There's no on-endpoint auto-pull on Windows, so updates are centrally driven.
