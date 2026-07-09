# Deploy Cursor via the runner (macOS & Linux)

Cursor's `hooks.json` is a plain file, not a profile payload, so it's delivered by a script your MDM runs on a schedule. That script is [`scripts/runner.sh`](../scripts/runner.sh): you **paste it into your MDM** as the script body. On each run it fetches this repo at a pinned revision, renders the config, and atomically swaps the file in **only if it changed** — so repo updates and any credential or flag change both take effect. Set it up once; after that, updates flow on their own.

A few things to know:

- **The endpoint needs only `curl` and `tar`**, both of which ship with macOS and Linux. The runner downloads the repo tarball at `REF` from GitHub and renders on the machine with system tools alone. (Windows endpoints don't use the runner — pre-generate with `--target-os windows` and push via [Intune](deploy-windows-intune.md) instead.)
- **It isn't tamper-resistant.** A plain file isn't OS-enforced; a developer could override it (e.g. via `~/.cursor/`). Only Claude has an OS-enforced path, via its [managed-settings profile](deploy-claude-profile.md).
- **Settings live at the top of `runner.sh`** — set `AGENT` (`cursor` or `claude`), `REF` (the revision to run), and optionally `EXTRA` (e.g. `--env ENDOR_AI_AUDIT_NO_BLOCKING=true` for monitor-only) or `DEST` (to override the install path).
- **Pin a version.** `REF` defaults to `main` (tracks latest); set it to a reviewed tag or commit (e.g. `v1.0.0`) so each device runs a known revision, since the runner executes this repo's code as root. Bump it deliberately to roll out a change.
- **Credentials** must be in the environment before the runner renders. You add them at the top of the pasted script, per your MDM (below). Use an **audit-only / least-privilege** credential — never commit them.

In each MDM, the script body is: your credential lines, then the contents of `scripts/runner.sh` (with `AGENT`/`REF` set).

## Jamf Pro

Jamf reserves positional parameters `$1`–`$3` (mount point, computer, user), so yours start at `$4`.

1. **Settings → Computer Management → Scripts → New.** Paste the credential line, then the body of `scripts/runner.sh`:
   ```sh
   #!/bin/sh
   export ENDOR_API_CREDENTIALS_KEY="$4" ENDOR_API_CREDENTIALS_SECRET="$5" ENDOR_NAMESPACE="$6"
   # …contents of scripts/runner.sh below (set AGENT=cursor, REF=<tag>)…
   ```
   Label *Parameter 4 = API key*, *5 = API secret*, *6 = namespace*.
2. **Computers → Policies → New** — add the **Scripts** payload, select the script, and fill in the credential parameters.
3. Set the **Trigger** to *Recurring Check-in* and **Execution Frequency** to *Ongoing*.
4. Set the **Scope** and **Save**.

## Kandji

Kandji Custom Scripts run as **root** and can run on a schedule, but Kandji has **no secret store** — the script body is plaintext and visible to anyone with admin access. So hard-code the values (single-quoted), using an audit-only key, and rotate it.

1. **Library → Add New → Custom Script.** Paste the credential line, then the body of `scripts/runner.sh`:
   ```sh
   #!/bin/sh
   export ENDOR_API_CREDENTIALS_KEY='…' ENDOR_API_CREDENTIALS_SECRET='…' ENDOR_NAMESPACE='…'
   # …contents of scripts/runner.sh below (set AGENT=cursor, REF=<tag>)…
   ```
   Single-quote the values so a `"`, `$`, or backtick can't break the assignment; if a value contains a single quote, write it as `'\''`.
2. Set **Execution Frequency** to *Run every 15 min* or *Run daily*.
3. Assign it to the target **Blueprint**.

## Verify

After a run, confirm `/Library/Application Support/Cursor/hooks.json` (or `/etc/cursor/hooks.json` on Linux) exists, then open Cursor and start a session — the `sessionStart` hook installs/updates `endorctl` and begins reporting. Confirm the activity in the Endor audit log.

## Updating

Nothing to do. Each scheduled run re-fetches the repo at `REF` and re-renders, swapping the file in only if it changed — so repo updates **and** credential/flag changes both take effect. To move to a new release, bump `REF`. How quickly an update lands depends on the MDM's schedule (minutes to an hour).
