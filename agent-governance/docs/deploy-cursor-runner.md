# Deploy Cursor via MDM Custom Script (the runner)

Cursor's `hooks.json` is a plain file, not a profile payload, so it is delivered
by a script the MDM runs on each check-in. [`scripts/runner.sh`](../scripts/runner.sh)
is the generic runner: it pulls this public repo, re-renders the config, and swaps
the file in atomically **only if it changed** — so repo updates *and* credential or
flag changes both take effect. IT sets this up **once**; after that, updates flow
automatically.

```sh
runner.sh --agent cursor      # macOS: /Library/Application Support/Cursor/hooks.json
                              # Linux: /etc/cursor/hooks.json  (override either with --dest)
```

This page covers macOS (Jamf/Kandji); the same runner works on Linux (it picks the `/etc/cursor` default). **Windows** endpoints have no `git`/`sh`/`jq`, so they don't use the runner — pre-generate with `--target-os windows` and push via Intune ([docs/deploy-windows-intune.md](deploy-windows-intune.md)).

- **Endpoint needs:** `git` + `/bin/sh` + `jq`.
- **Not tamper-resistant:** a script-delivered file is not OS-enforced, so a
  developer could override it (e.g. via `~/.cursor/`). Use the profile path where
  tamper-resistance matters.
- **Credentials** reach `render.sh` via the environment; the MDM script below
  sets them (Jamf parameters, or hard-coded inline for Kandji — see its caveat).
  Never commit them to the repo. Use an **audit-only / least-privilege** credential.
  ```
  ENDOR_API_CREDENTIALS_KEY   ENDOR_API_CREDENTIALS_SECRET   ENDOR_NAMESPACE
  ```
- **Monitor-only rollout:** append `--env ENDOR_AI_AUDIT_NO_BLOCKING=true` — extra
  args pass straight through to `render.sh`.
- **Other agents / paths:** the runner is generic. A different script-delivered
  agent is `--agent <name>`; override the destination with `--dest <path>`.

Both MDMs upload a **single** script. It can't assume `runner.sh` is already on
the machine, so the script is self-contained: it clones this repo (once), then
execs the runner from the clone. `runner.sh` pulls the latest on every run, so the
clone-if-absent only fetches the first time.

## Jamf Pro

Jamf reserves positional parameters `$1`–`$3` (mount point, computer name, user),
so your parameters start at `$4`.

1. **Settings → Computer Management → Scripts → New.** Paste:
   ```sh
   #!/bin/sh
   set -eu
   export ENDOR_API_CREDENTIALS_KEY="$4" ENDOR_API_CREDENTIALS_SECRET="$5" ENDOR_NAMESPACE="$6"
   REPO="/Library/Application Support/EndorAIGovernance/repo"
   mkdir -p "$(dirname "$REPO")"
   [ -d "$REPO/.git" ] || git clone --depth 1 https://github.com/endorlabs/mdm-scripts "$REPO"
   exec sh "$REPO/agent-governance/scripts/runner.sh" --agent cursor
   ```
   Label *Parameter 4 = API key*, *5 = API secret*, *6 = namespace*.
2. **Computers → Policies → New.** Add the **Scripts** payload, select the script,
   and fill in the credential parameters.
3. Set the **Trigger** to *Recurring Check-in* and **Execution Frequency** to *Ongoing*.
4. Set the **Scope** and **Save**.

## Kandji

Kandji Custom Scripts run as **root** and can run on a schedule, but Kandji has
**no secret store** — the script body is plaintext and visible to anyone with
admin access (there's no "script secret" env-var feature). So hard-code the three
values in the script, using an **audit-only / least-privilege** key, and rotate it.

1. **Library → Add New → Custom Script** (paste into the *Audit Script*):
   ```sh
   #!/bin/sh
   set -eu
   export ENDOR_API_CREDENTIALS_KEY='…' ENDOR_API_CREDENTIALS_SECRET='…' ENDOR_NAMESPACE='…'
   REPO="/Library/Application Support/EndorAIGovernance/repo"
   mkdir -p "$(dirname "$REPO")"
   [ -d "$REPO/.git" ] || git clone --depth 1 https://github.com/endorlabs/mdm-scripts "$REPO"
   exec sh "$REPO/agent-governance/scripts/runner.sh" --agent cursor
   ```
   **Single-quote** the hard-coded values (as shown) so a `"`, `$`, or backtick in a
   key can't break the assignment; if a value itself contains a single quote, write
   it as `'\''`.
2. Set **Execution Frequency** to *Run every 15 min* or *Run daily*.
3. Assign it to the target **Blueprint**.

## Verify

After a check-in, confirm `/Library/Application Support/Cursor/hooks.json` exists
on a target machine, then open Cursor and start a session — the `sessionStart`
hook installs/updates `endorctl` and begins reporting to the Endor namespace.
Confirm activity in the Endor audit log.

## Updating

No action needed. On each check-in the runner re-pulls the repo, re-renders the
config, and atomically swaps in the new `hooks.json` only if it changed — so repo
updates **and** credential/flag changes you make in the MDM both take effect. The
only thing IT does not control is timing — how quickly an update lands depends on
the MDM check-in interval (typically minutes to an hour).
