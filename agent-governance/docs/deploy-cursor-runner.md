# Deploy Cursor via MDM Custom Script (the runner)

Cursor's `hooks.json` is a plain file, not a profile payload, so it is delivered
by a script the MDM runs on each check-in. [`scripts/runner.sh`](../scripts/runner.sh)
is the generic runner: it pulls this public repo, and — only if the source
changed — rebuilds the agent's config with the customer's credentials and writes
it atomically. IT sets this up **once**; after that, hook updates flow from the
repo automatically.

```sh
runner.sh --agent cursor      # macOS: /Library/Application Support/Cursor/hooks.json
                              # Linux: /etc/cursor/hooks.json  (override either with --dest)
```

This page covers macOS (Jamf/Kandji); the same runner works on Linux (it picks the `/etc/cursor` default). **Windows** endpoints have no `git`/`sh`/`jq`, so they don't use the runner — pre-generate with `--target-os windows` and push via Intune ([docs/deploy-windows-intune.md](deploy-windows-intune.md)).

- **Endpoint needs:** `git` + `/bin/sh` + `jq`.
- **Not tamper-resistant:** a script-delivered file is not OS-enforced, so a
  developer could override it (e.g. via `~/.cursor/`). Use the profile path where
  tamper-resistance matters.
- **Credentials** come from MDM secure variables, never from the repo, and are
  read from the environment by `render.sh`. Use an **audit-only / least-privilege**
  credential.
  ```
  ENDOR_API_CREDENTIALS_KEY   ENDOR_API_CREDENTIALS_SECRET   ENDOR_NAMESPACE
  ```
- **Monitor-only rollout:** append `--env ENDOR_AI_AUDIT_NO_BLOCKING=true` — extra
  args pass straight through to `render.sh`.
- **Other agents / paths:** the runner is generic. A different script-delivered
  agent is `--agent <name>`; override the destination with `--dest <path>`.

## Jamf Pro

Jamf reserves positional parameters `$1`–`$3` (mount point, computer name, user),
so script parameters start at `$4`.

1. **Settings → Computer Management → Scripts → New.** Use a short wrapper that
   exports Jamf's `$4`–`$6` into the environment and calls the runner:
   ```sh
   #!/bin/sh
   export ENDOR_API_CREDENTIALS_KEY="$4"
   export ENDOR_API_CREDENTIALS_SECRET="$5"
   export ENDOR_NAMESPACE="$6"
   exec sh "$(dirname "$0")/runner.sh" --agent cursor
   ```
   (or clone the repo to a known path and point at `…/scripts/runner.sh`).
   Label the parameters (e.g. *Parameter 4 = API key*, *5 = API secret*, *6 = namespace*).
2. **Computers → Policies → New.** Add the **Scripts** payload, select the script,
   and fill in the credential parameters.
3. Set the **Trigger** to *Recurring Check-in* and **Execution Frequency** to *Ongoing*.
4. Set the **Scope** and **Save**.

## Kandji

Kandji exports script secrets as environment variables, so the runner needs **no
arguments**.

1. **Library → Add New → Custom Script.**
2. Paste a one-line run script: `exec /path/to/runner.sh --agent cursor`
   (or inline the repo clone + call).
3. Store the three credentials as **script secrets** named
   `ENDOR_API_CREDENTIALS_KEY`, `ENDOR_API_CREDENTIALS_SECRET`, `ENDOR_NAMESPACE`.
4. Set the **execution frequency** (e.g. every 15 minutes / daily).
5. Assign it to the target **Blueprint**.

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
