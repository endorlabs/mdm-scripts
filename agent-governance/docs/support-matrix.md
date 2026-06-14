# Support matrix

How each supported coding agent × installation mechanism × OS is delivered by this
repo. All rows below are covered.

| # | Agent | Mechanism | OS | Config | How this repo delivers it | Runbook |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Cursor | Manual / Cursor Enterprise | — | `hooks.json` | `render.sh --agent cursor` → drop the file, or paste into the Enterprise (Team hooks) dashboard | [manual/enterprise](deploy-manual-enterprise.md) |
| 2 | Cursor | MDM | macOS | Kandji, Jamf, JumpCloud | `runner.sh --agent cursor` → `/Library/Application Support/Cursor/hooks.json` | [cursor-runner](deploy-cursor-runner.md), [jumpcloud](deploy-jumpcloud.md) |
| 3 | Cursor | MDM | Linux | JumpCloud · config mgmt | `runner.sh --agent cursor` → `/etc/cursor/hooks.json` | [cursor-runner](deploy-cursor-runner.md), [jumpcloud](deploy-jumpcloud.md) |
| 4 | Cursor | MDM | Windows | Intune, JumpCloud | `render.sh --agent cursor --target-os windows` → push to `C:\ProgramData\Cursor\hooks.json` (system-wide, preferred) or `%APPDATA%\Cursor\hooks.json` (per-user) | [intune](deploy-windows-intune.md), [jumpcloud](deploy-jumpcloud.md) |
| 5 | Claude Code | Manual / Claude Enterprise | — | `settings.json` | `render.sh --agent claude` → drop the file, or supply to the admin console (server-managed settings) | [manual/enterprise](deploy-manual-enterprise.md) |
| 6 | Claude Code | MDM | macOS | Kandji, Jamf, JumpCloud | `render-plist.sh` → `.mobileconfig` profile (tamper-resistant) | [claude-profile](deploy-claude-profile.md), [jumpcloud](deploy-jumpcloud.md) |
| 7 | Claude Code | MDM | Linux | JumpCloud · config mgmt | `runner.sh --agent claude` → `/etc/claude-code/managed-settings.json` | [claude-profile](deploy-claude-profile.md#linux-and-windows-file-based-no-profile), [jumpcloud](deploy-jumpcloud.md) |
| 8 | Claude Code | MDM | Windows | Intune, JumpCloud | `render.sh --agent claude --target-os windows` → push to `C:\Program Files\ClaudeCode\managed-settings.json` | [intune](deploy-windows-intune.md), [jumpcloud](deploy-jumpcloud.md) |

## Delivery shape by OS

- **macOS Claude** is the only **profile** path (`.mobileconfig`, OS-enforced, tamper-resistant). Every other cell is a **plain JSON file** at a system path.
- **macOS/Linux** can keep the file current automatically with `runner.sh` (re-render + swap-on-change on a schedule / check-in).
- **Windows** has no `git`/`jq` on the endpoint, so you **pre-generate** (`--target-os windows`, which inlines the PowerShell bootstrap as `powershell -EncodedCommand …`) and push the file centrally.
- **Config management** (Ansible, Chef, Puppet, Salt, …) works for **any file-based cell** on any OS — the artifact is just a JSON file at a known path. Generate it with `render.sh` and have your tooling place it. The only cell this does *not* cover is the macOS Claude **profile** (row 6), which needs an MDM to install the `.mobileconfig`.

## Caveats / things to know

- **Endpoint prerequisites for the runner** (rows 2, 3, 7): the endpoint needs `git` + `jq`. The profile path (row 6) and the Windows pre-generate path (rows 4, 8) need nothing beyond what ships with the OS. Where you don't want `git`/`jq` on Linux, deliver the pre-generated file via a Command/config-management instead of the runner.
- **Windows is decode-verified, not yet run-verified.** The encoded PowerShell round-trips correctly, but it has not been executed on a real Windows endpoint — smoke-test `endorctl.exe` install + audit on both agents before fleet rollout.
- **Generation is POSIX-only** (`render.sh` needs `sh`+`jq`, plus `iconv`+`base64` for Windows targets). A Windows-only admin generates under WSL/Git Bash.
- **Cursor Enterprise (Team hooks)** is a manual paste of the generated `hooks.json` into the dashboard — supported, not automated.
- **JumpCloud** delivers files via a **Command** (no native file-push) and recurs via **Run as Repeating** (which can miss a window during device sleep); macOS profiles go through its **MDM Custom Configuration Profile** policy, which rewrites the outer profile UUID/identifier.
