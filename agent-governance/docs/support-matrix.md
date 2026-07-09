# Support matrix

Every combination of agent × installation mechanism × OS this repo covers, and how it's delivered.

| # | Agent | Mechanism | OS | Provider(s) | How it's delivered | Runbook |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Cursor | Manual / Enterprise | — | Cursor Team hooks | `render.sh --agent cursor` → drop the file, or paste into the Team-hooks dashboard | [manual / enterprise](deploy-manual-enterprise.md) |
| 2 | Cursor | MDM | macOS | Kandji, Jamf, JumpCloud | `runner.sh (AGENT=cursor)` → `/Library/Application Support/Cursor/hooks.json` | [runner](deploy-cursor-runner.md), [jumpcloud](deploy-jumpcloud.md) |
| 3 | Cursor | MDM | Linux | JumpCloud · config mgmt | `runner.sh (AGENT=cursor)` → `/etc/cursor/hooks.json` | [runner](deploy-cursor-runner.md), [jumpcloud](deploy-jumpcloud.md) |
| 4 | Cursor | MDM | Windows | Intune, JumpCloud | `--target-os windows` → push to `C:\ProgramData\Cursor\hooks.json` (system-wide) or `%USERPROFILE%\.cursor\hooks.json` (per-user) | [intune](deploy-windows-intune.md), [jumpcloud](deploy-jumpcloud.md) |
| 5 | Claude Code | Manual / Enterprise | — | Claude admin console | `render.sh --agent claude` → drop the file, or set as server-managed settings | [manual / enterprise](deploy-manual-enterprise.md) |
| 6 | Claude Code | MDM | macOS | Kandji, Jamf, JumpCloud | `render-plist.sh` → `.mobileconfig` profile (tamper-resistant) | [profile](deploy-claude-profile.md), [jumpcloud](deploy-jumpcloud.md) |
| 7 | Claude Code | MDM | Linux | JumpCloud · config mgmt | `runner.sh (AGENT=claude)` → `/etc/claude-code/managed-settings.json` | [profile](deploy-claude-profile.md#linux-and-windows-the-same-settings-as-a-file), [jumpcloud](deploy-jumpcloud.md) |
| 8 | Claude Code | MDM | Windows | Intune, JumpCloud | `--target-os windows` → push to `C:\Program Files\ClaudeCode\managed-settings.json` | [intune](deploy-windows-intune.md), [jumpcloud](deploy-jumpcloud.md) |

## How delivery differs by OS

- **macOS Claude** is the only **profile** path (`.mobileconfig`, OS-enforced, tamper-resistant). Every other cell is a **plain JSON file** at a system path.
- **macOS and Linux** can keep that file current automatically with `runner.sh` (re-render and swap-on-change, on the MDM's schedule).
- **Windows** can't run the POSIX runner (no `sh`), so you **pre-generate** (`--target-os windows`) and push the file centrally.
- **Config management** (Ansible, Chef, Puppet, Salt, …) works for any file-based cell on any OS — the artifact is just JSON at a known path. The one exception is the macOS Claude profile (row 6), which needs an MDM to install the `.mobileconfig`.

## Worth knowing

- **The runner needs only `curl` + `tar` on the endpoint** (rows 2, 3, 7), both of which ship with macOS and Linux. The profile path (row 6) and the Windows pre-generate path (rows 4, 8) also need nothing beyond what ships with the OS. Prefer not to run the fetch-and-render on endpoints at all? Deliver the pre-generated file via config management instead.
- **Smoke-test Windows before a fleet rollout.** The encoded PowerShell hook is verified by decode/round-trip; confirm `endorctl.exe` installs and audits on a real Windows endpoint for both agents before going wide.
- **Generation is POSIX-only** — `render.sh` needs `sh` + `awk` + `sed` (and `iconv` + `base64` for Windows targets), all standard system tools. A Windows-only admin generates under WSL or Git Bash.
- **Cursor Team hooks** take a manual paste of the generated `hooks.json` — supported, not automated.
- **JumpCloud** delivers files via a Command (no native file-push) and recurs via *Run as Repeating* (which can miss a window during device sleep); macOS profiles go through its MDM Custom Configuration Profile policy, which rewrites the outer profile UUID/identifier.
