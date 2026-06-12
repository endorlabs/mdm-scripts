# Deploy Claude Code via MDM Custom Profile

Claude Code reads managed settings from a Configuration Profile payload of type
`com.anthropic.claudecode`. This path is **tamper-resistant** — the profile is a
managed setting enforced by the operating system — and nothing extra runs on the
laptop. The tradeoff is that an update means regenerating the profile and
re-uploading it (see [Updating](#updating)).

## 1. Generate the profile

Run the generator with the customer's credentials. Use an **audit-only /
least-privilege** API credential — the key and secret are embedded in the profile
and delivered to every laptop.

`render.sh` builds the settings JSON; `render-plist.sh` wraps it into the
`.mobileconfig`. Pipe one into the other:

```sh
scripts/render.sh --agent claude \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o - \
| scripts/render-plist.sh \
  --identifier com.<customer>.ai-governance.claudecode \
  --organization "<Customer>" \
  --name "Claude Code — Endor AI Governance" \
  -o com.anthropic.claudecode.mobileconfig
```

- `render-plist.sh` is agent-agnostic; `--payload-type` defaults to Claude Code's
  `com.anthropic.claudecode`, so it is omitted here.
- `--identifier` is a unique reverse-DNS id in the customer's namespace; the inner
  payload derives as `<identifier>.settings`.
- `--organization` sets the profile's `PayloadOrganization`; `--name` sets the
  MDM-visible display name.
- UUIDs are generated fresh unless you pass `--profile-uuid` / `--content-uuid`.
- Add `--env ENDOR_AI_AUDIT_NO_BLOCKING=true` to the `render.sh` step for an
  initial monitor-only rollout.
- Needs `plutil` (macOS) for the `render-plist.sh` step.

The result validates as a property list:

```sh
plutil -lint com.anthropic.claudecode.mobileconfig
```

See `examples/claude/com.anthropic.claudecode.mobileconfig` for a sample.

## 2. Upload to the MDM

### Jamf Pro

1. **Computers → Configuration Profiles → New.**
2. Add an **Application & Custom Settings → Upload** payload and upload the
   `.mobileconfig` (or use a Custom Profile upload).
3. Set the **Scope** to the target computers.
4. **Save.** Jamf pushes the profile; the OS installs it as a managed setting.

> When embedding under a Jamf-owned outer profile, set
> `--profile-identifier` to that profile's id so the outer identity matches Jamf's.

### Kandji

1. **Library → Add New → Custom Profile.**
2. Upload the `.mobileconfig`.
3. Assign it to the target **Blueprint**.

## 3. Verify

After the profile lands, open Claude Code on a target machine and start a session.
The `SessionStart` hook installs/updates `endorctl` and begins reporting to the
configured Endor namespace. Confirm activity in the Endor audit log.

## Updating

Profile-delivered config does not auto-update. To ship a change:

1. Regenerate the `.mobileconfig` from the latest repo (step 1).
2. Re-upload it to the MDM and **bump the profile version**.
3. The MDM re-pushes it to the fleet.

How quickly the update lands depends on the MDM's push/check-in behavior.

## Linux and Windows (file-based, no profile)

`.mobileconfig` is macOS-only. On Linux and Windows, Claude Code reads the same
managed-settings JSON (the `env` + `hooks` that `render.sh --agent claude`
produces) as a **file** at a system path — so there's no `render-plist.sh` step:

| OS | Path | Deliver with |
| --- | --- | --- |
| Linux | `/etc/claude-code/managed-settings.json` (+ `managed-settings.d/`) | `runner.sh --agent claude` (default dest), or config mgmt (Ansible/etc.), or a JumpCloud Command |
| Windows | `C:\Program Files\ClaudeCode\managed-settings.json` | pre-generate `--target-os windows`, push via Intune — see [deploy-windows-intune.md](deploy-windows-intune.md) |

Both are admin-enforced (highest precedence; users can't override), same as the
macOS profile. Generate the Linux file with `render.sh --agent claude` (POSIX
hooks); generate the Windows file with `--target-os windows` (encoded PowerShell
hooks). For JumpCloud specifically, see [deploy-jumpcloud.md](deploy-jumpcloud.md).
