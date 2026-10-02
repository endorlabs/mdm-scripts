# Deploy Claude Code via an MDM profile (macOS)

On macOS, Claude Code reads managed settings from a Configuration Profile payload of type `com.anthropic.claudecode`, so a profile is **tamper-resistant** — the OS enforces it, and nothing extra runs on the laptop. The one tradeoff: an update means regenerating the profile and re-uploading it.

You'll generate a `.mobileconfig` on an admin Mac (you need `plutil`, which is native to macOS), then upload it through Jamf or Kandji.

## 1. Generate the profile

`render.sh` builds the settings JSON and `render-plist.sh` wraps it into the `.mobileconfig` — pipe one into the other. Use an **audit-only / least-privilege** API credential, since the key and secret are embedded in the profile and delivered to every laptop.

```sh
scripts/render.sh --agent claude \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o - \
| scripts/render-plist.sh \
  --identifier com.<customer>.ai-governance.claudecode \
  --organization "<Customer>" \
  --name "Claude Code - Endor AI Governance" \
  -o com.anthropic.claudecode.mobileconfig
```

- `--identifier` is a unique reverse-DNS id in your namespace; the inner payload becomes `<identifier>.settings`.
- `--organization` sets the profile's `PayloadOrganization`, and `--name` the MDM-visible display name.
- UUIDs are generated fresh unless you pass `--profile-uuid` / `--content-uuid`.
- `--payload-type` defaults to `com.anthropic.claudecode`, so it's omitted here.
- For an initial monitor-only rollout, add `--env ENDOR_AI_AUDIT_NO_BLOCKING=true` to the `render.sh` step.

Confirm it's a valid property list before uploading (there's a ready-made sample at `examples/claude/com.anthropic.claudecode.mobileconfig`):

```sh
plutil -lint com.anthropic.claudecode.mobileconfig
```

Then check its line endings and that the embedded `SessionStart` hook still parses as shell. `plutil -lint` passes a file that has picked up Windows (CRLF) line endings — from a Windows checkout, an editor, or a paste into a web form — but macOS keeps the stray carriage returns when it installs the profile, and the hook command carries real newlines. The profile is generated with a wrapper that strips them at run time, so a CRLF file still works, but treat any non-zero count as a sign the file was altered after rendering and re-render it:

```sh
grep -c $'\r' com.anthropic.claudecode.mobileconfig      # must print 0
plutil -extract 'PayloadContent.0.hooks.SessionStart.0.hooks.0.command' raw -o - \
  com.anthropic.claudecode.mobileconfig | sh -n           # must print nothing
```

Keep the file as generated: don't open it in an editor, and upload the file itself rather than pasting its contents. Run the same two checks on the copy you download back from the MDM after uploading, if it offers one.

## 2. Upload to the MDM

**Jamf Pro** — Computers → Configuration Profiles → New; add an **Application & Custom Settings → Upload** payload with the `.mobileconfig`; set the **Scope**; Save. Jamf pushes it and the OS installs it as a managed setting. (If you embed it under a Jamf-owned outer profile, set `--profile-identifier` to that profile's id so the outer identity matches.)

**Kandji** — Library → Add New → Custom Profile; upload the `.mobileconfig`; assign it to the target Blueprint.

## 3. Verify

On one test machine that has the profile, confirm the installed managed preference carries the hook intact — this is the exact text Claude Code runs, whatever happened to the file on the way through the MDM:

```sh
plutil -extract 'hooks.SessionStart.0.hooks.0.command' raw -o - \
  '/Library/Managed Preferences/com.anthropic.claudecode.plist' | sh -n
```

Then open Claude Code and start a session. The `SessionStart` hook installs/updates `endorctl` (in the background, so `~/.endorctl/.update-check` appears once the version check has run) and begins reporting to your Endor namespace — confirm the activity in the Endor audit log, then assign the profile to the rest of the fleet.

## Updating

Profile-delivered config doesn't auto-update. To ship a change, regenerate the `.mobileconfig` (step 1), re-upload it to the MDM with a **bumped profile version**, and the MDM re-pushes it. How fast it lands depends on the MDM's check-in behavior.

## Linux and Windows: the same settings, as a file

`.mobileconfig` is macOS-only. On Linux and Windows, Claude reads the *same* managed-settings JSON (the `env` + `hooks` that `render.sh --agent claude` produces) as a plain file at a system path — no `render-plist.sh` step, but still admin-enforced and highest-precedence.

| OS | Path | Deliver with |
| --- | --- | --- |
| Linux | `/etc/claude-code/managed-settings.json` (+ `managed-settings.d/`) | [`runner.sh (AGENT=claude)`](deploy-cursor-runner.md), config management, or a [JumpCloud](deploy-jumpcloud.md) Command |
| Windows | `C:\Program Files\ClaudeCode\managed-settings.json` | pre-generate `--target-os windows`, push via [Intune](deploy-windows-intune.md) |

Generate the Linux file with `render.sh --agent claude` (POSIX hooks) and the Windows file with `--target-os windows` (encoded PowerShell hooks).
