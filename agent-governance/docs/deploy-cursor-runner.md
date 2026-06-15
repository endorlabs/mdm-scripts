# Deploy Cursor via the runner (macOS & Linux)

Cursor's `hooks.json` is a plain file, not a profile payload, so it's delivered by a small script the MDM runs on each check-in. [`scripts/runner.sh`](../scripts/runner.sh) does the work: it pulls this repo, re-renders the config, and atomically swaps the file in **only if it changed** — so both repo updates and any credential or flag change you make in the MDM take effect. You set it up once; after that, updates flow on their own.

```sh
runner.sh --agent cursor      # macOS: /Library/Application Support/Cursor/hooks.json
                              # Linux: /etc/cursor/hooks.json   (override either with --dest)
```

This page covers macOS (Jamf, Kandji); the same runner works on Linux with the `/etc/cursor` default. Windows endpoints have no `git`/`sh`/`jq`, so they don't use the runner — pre-generate with `--target-os windows` and push via [Intune](deploy-windows-intune.md) instead.

A few things to know going in:

- **The endpoint needs `git`, `/bin/sh`, and `jq`.**
- **It isn't tamper-resistant.** A plain file isn't OS-enforced, so a developer could override it (e.g. via `~/.cursor/`). This repo has no OS-enforced delivery for Cursor — only Claude has that, via its [managed-settings profile](deploy-claude-profile.md). Tamper-resistance for Cursor would need a profile mechanism it doesn't expose today.
- **Credentials reach `render.sh` through the environment**, set by the MDM script below (Jamf parameters, or hard-coded inline for Kandji). Never commit them. Use an **audit-only / least-privilege** credential:
  ```
  ENDOR_API_CREDENTIALS_KEY   ENDOR_API_CREDENTIALS_SECRET   ENDOR_NAMESPACE
  ```
- **For a monitor-only rollout**, append `--env ENDOR_AI_AUDIT_NO_BLOCKING=true` — extra args pass straight through to `render.sh`.
- **The runner is generic** — `--agent <name>` for another script-delivered agent, `--dest <path>` to override where the file lands.
- **Pin a version.** The scripts below set `REF`, fetch that ref, and pass it to the runner — so each device runs a known, reviewed revision of this repo rather than whatever is at the branch tip (root is executing this code, so that matters). They default to `main` (tracks latest); set `REF` to a reviewed tag or commit (e.g. `v1.0.0`) to pin, and bump it deliberately to roll out a change.

Both MDMs upload a **single** script, and it can't assume `runner.sh` is already on the machine — so the script is self-contained: it clones this repo once, then execs the runner from the clone (which pulls the latest on every run).

## Jamf Pro

Jamf reserves positional parameters `$1`–`$3` (mount point, computer, user), so yours start at `$4`.

1. **Settings → Computer Management → Scripts → New**, and paste:
   ```sh
   #!/bin/sh
   set -eu
   export ENDOR_API_CREDENTIALS_KEY="$4" ENDOR_API_CREDENTIALS_SECRET="$5" ENDOR_NAMESPACE="$6"
   REF="main"   # pin to a reviewed tag or commit in production (e.g. v1.0.0)
   REPO="/Library/Application Support/EndorAIGovernance/repo"
   mkdir -p "$(dirname "$REPO")"
   [ -d "$REPO/.git" ] || { git init -q "$REPO"; git -C "$REPO" remote add origin https://github.com/endorlabs/mdm-scripts; }
   git -C "$REPO" fetch --depth 1 origin "$REF"
   git -C "$REPO" -c advice.detachedHead=false checkout -f FETCH_HEAD
   exec sh "$REPO/agent-governance/scripts/runner.sh" --agent cursor --ref "$REF"
   ```
   Label *Parameter 4 = API key*, *5 = API secret*, *6 = namespace*.
2. **Computers → Policies → New** — add the **Scripts** payload, select the script, and fill in the credential parameters.
3. Set the **Trigger** to *Recurring Check-in* and **Execution Frequency** to *Ongoing*.
4. Set the **Scope** and **Save**.

## Kandji

Kandji Custom Scripts run as **root** and can run on a schedule, but Kandji has **no secret store** — the script body is plaintext and visible to anyone with admin access. So hard-code the three values, using an **audit-only / least-privilege** key, and rotate it.

1. **Library → Add New → Custom Script**, and paste into the *Audit Script*:
   ```sh
   #!/bin/sh
   set -eu
   export ENDOR_API_CREDENTIALS_KEY='…' ENDOR_API_CREDENTIALS_SECRET='…' ENDOR_NAMESPACE='…'
   REF="main"   # pin to a reviewed tag or commit in production (e.g. v1.0.0)
   REPO="/Library/Application Support/EndorAIGovernance/repo"
   mkdir -p "$(dirname "$REPO")"
   [ -d "$REPO/.git" ] || { git init -q "$REPO"; git -C "$REPO" remote add origin https://github.com/endorlabs/mdm-scripts; }
   git -C "$REPO" fetch --depth 1 origin "$REF"
   git -C "$REPO" -c advice.detachedHead=false checkout -f FETCH_HEAD
   exec sh "$REPO/agent-governance/scripts/runner.sh" --agent cursor --ref "$REF"
   ```
   **Single-quote** the values (as shown) so a `"`, `$`, or backtick can't break the assignment; if a value contains a single quote, write it as `'\''`.
2. Set **Execution Frequency** to *Run every 15 min* or *Run daily*.
3. Assign it to the target **Blueprint**.

## Verify

After a check-in, confirm `/Library/Application Support/Cursor/hooks.json` exists on a target machine, then open Cursor and start a session — the `sessionStart` hook installs/updates `endorctl` and begins reporting. Confirm the activity in the Endor audit log.

## Updating

Nothing to do. Each check-in re-pulls the repo, re-renders, and swaps the file in only if it changed — so repo updates **and** credential/flag changes both take effect. The only thing outside your control is timing: how quickly an update lands depends on the MDM check-in interval (minutes to an hour).
