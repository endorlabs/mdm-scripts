# Deploy Cortex Code via the runner (macOS & Linux)

Snowflake Cortex Code ("CoCo") runs hooks in the Claude Code format, and `endorctl ai-audit cortexcode` (endorctl v1.7.1240 or later) audits them. Unlike the other agents, **Cortex Code has no managed or system hooks path** (as of 2026-11-15). It reads hooks only from a file in the user's own home:

1. `$CORTEX_HOME/hooks.json`, if `CORTEX_HOME` is set
2. else `$SNOWFLAKE_HOME/cortex/hooks.json`, if `SNOWFLAKE_HOME` is set
3. else `~/.snowflake/cortex/hooks.json`

So the runner writes a per-user file. Set `AGENT=cortexcode` in [`scripts/runner.sh`](../scripts/runner.sh) and paste it into your MDM as for [Cursor](deploy-cursor-runner.md). On each run it fetches this repo at `REF`, renders the hooks, and hands them to [`scripts/install-cortexcode.sh`](../scripts/install-cortexcode.sh), which puts them in each target user's file.

## Limits — read these before a rollout

- **Not tamper-resistant.** The file is owned by the user and the user can edit it, delete it, or set `CORTEX_HOME` so Cortex Code reads a different file. The next run puts Endor's hooks back in the default file, but sessions in between, or under a different `CORTEX_HOME`, are not audited. Treat this path as coverage for cooperative users, not as enforcement.
- **The credentials are in a file the user can read.** Every hook command carries the API key and secret. Use an **audit-only, least-privilege** key and rotate it. Moving credentials out of the user file is tracked under AI-955.
- **`CORTEX_HOME` and `SNOWFLAKE_HOME` are not honored.** They are set in the user's shell, which a root MDM script cannot see. The runner always writes `~/.snowflake/cortex/hooks.json` unless you set `DEST` (below).
- **Linux and Windows are untested.** No one has run Cortex Code with these hooks on Linux or Windows yet. On macOS, the hooks config is the one tested live on 2026-11-12, but the runner's macOS steps (console user, `dscl`, `sudo`, the JXA merge) have not yet run on a managed Mac. Pilot on a few machines first.
- **One unaudited session per new machine.** As with the other agents, the first session installs `endorctl` in the background and is not audited.
- **Claude Code hooks also run in Cortex Code.** Cortex Code also runs the hooks in `~/.claude/settings.json` and a project's `.claude/settings*.json`. If one of those has an `endorctl ai-audit claudecode` hook, Cortex Code runs it too, and those events are recorded as Claude Code events.

## What the runner does for `AGENT=cortexcode`

**Who gets the file.** By default:

- **macOS:** the console user, the person logged in at the screen. When no one is logged in, nothing is written and the run exits 0. The next scheduled run tries again.
- **Linux:** there is no single console user, and Cortex Code is a terminal agent that people often use over SSH. So every user with a login session gets the file: logind sessions (`loginctl`) where systemd runs, else `who`. Accounts below `UID_MIN` in `/etc/login.defs` (default 1000), such as `root` and the display manager's greeter, are skipped.

Set `TARGET_USER` at the top of `runner.sh` to name the users yourself, separated by spaces (`TARGET_USER="alice bob"`). The home directory comes from the system (`dscl` on macOS, `getent passwd` on Linux), never from root's `$HOME`.

**Where.** `<home>/.snowflake/cortex/hooks.json`. If your users set `CORTEX_HOME` or `SNOWFLAKE_HOME` to the same place, set `DEST` to match, with a leading `~/` for the target user's home, single-quoted so root's shell does not expand it:

```sh
DEST='~/.config/cortex/hooks.json'     # users have CORTEX_HOME=~/.config/cortex
```

An absolute `DEST` is used as is, for every target user.

**How it writes.** Root never opens a path in the user's home. Every read and write there runs as the user (`runuser` on Linux, `sudo -u` on macOS), with an empty environment. So a symlink the user puts at `~/.snowflake`, `~/.snowflake/cortex`, or `hooks.json` can reach only files that the user could already change. The new file is written beside the old one and renamed over it, so Cortex Code never reads half a file. The result is owned by the user, mode `600`. Directories the runner creates are owned by the user, mode `700`. A symlink at `hooks.json` itself is left as it is and the run fails, because it usually points into a dotfiles repository that a rename would cut off.

The user also controls those steps, so each one has a time limit (30 s, `--timeout` on `install-cortexcode.sh`) and at most 1 MiB of the user's file is read. A user whose step hangs (a stopped process, a lease on the file, a FIFO in its place) or whose file is larger than 1 MiB counts as failed. Their file is left as it is, the run goes on to the next user, and it exits non-zero at the end.

**Your users' own hooks are kept.** If the file already exists, the runner merges instead of overwriting:

- A hook whose command contains `ai-audit cortexcode` is Endor's. Each run removes all of Endor's hooks and adds the current ones, so a credential change replaces them and never duplicates them. A hand-installed `endorctl ai-audit cortexcode` hook (from the Endor example) counts as Endor's and is replaced too.
- Every other hook, matcher group, event, and top-level key stays where it was. Endor's groups go after the user's in each event.
- A file that holds only Endor's hooks, or nothing, is replaced with the rendered file.
- The JSON work runs in JXA (`osascript`, on every Mac) or `python3` on Linux. There is no `jq` on the endpoint.
- **If the file is not valid JSON, or has a shape the merge does not know, it is left untouched.** The runner prints the reason to stderr and exits non-zero, so your MDM shows the failure. The same happens on a Linux machine with no `python3` whose file holds anything besides the current Endor hooks.

The file is replaced only when the result changes. If the user changes the file while a run is merging it, that run writes nothing and the next run merges the new content.

**Endpoint needs:** `curl` + `tar` (as for every runner agent), plus `runuser` (util-linux) or `sudo` to act as the user, and `python3` on Linux for the merge. All ship with macOS and with the common Linux desktop distributions.

## Jamf Pro

1. **Settings → Computer Management → Scripts → New.** Paste the credential line, then the body of `scripts/runner.sh`:
   ```sh
   #!/bin/sh
   export ENDOR_API_CREDENTIALS_KEY="$4" ENDOR_API_CREDENTIALS_SECRET="$5" ENDOR_NAMESPACE="$6"
   # …contents of scripts/runner.sh below (set AGENT=cortexcode, REF=<tag>)…
   ```
   Label *Parameter 4 = API key*, *5 = API secret*, *6 = namespace*.
2. **Computers → Policies → New**: add the **Scripts** payload, select the script, and fill in the credential parameters.
3. Set the **Trigger** to *Recurring Check-in* and also *Login*, so a user gets the file soon after logging in. Set **Execution Frequency** to *Ongoing*.
4. Set the **Scope** and **Save**.

## Kandji

Kandji has no secret store, so the script body is plaintext to every Kandji admin. Hard-code an audit-only key, single-quoted, and rotate it.

1. **Library → Add New → Custom Script.** Paste the credential line, then the body of `scripts/runner.sh`:
   ```sh
   #!/bin/sh
   export ENDOR_API_CREDENTIALS_KEY='…' ENDOR_API_CREDENTIALS_SECRET='…' ENDOR_NAMESPACE='…'
   # …contents of scripts/runner.sh below (set AGENT=cortexcode, REF=<tag>)…
   ```
   If a value contains a single quote, write it as `'\''`.
2. Set **Execution Frequency** to *Run every 15 min*. A frequent schedule matters more here than for the system-path agents, because a run with no one at the console writes nothing.
3. Assign it to the target **Blueprint**.

## JumpCloud

1. **Device Management → Commands → New**, target **Mac** or **Linux**. The body is the credential line, then `scripts/runner.sh` with `AGENT=cortexcode`, exactly as in [the JumpCloud runbook](deploy-jumpcloud.md#macos--linux--the-runner-via-a-command). Keep the default root user: the runner switches to each target user itself.
2. Set the launch type to **Run as Repeating** (e.g. hourly). You can add the **login** trigger too.
3. Scope it to a Device Group.

## Windows (pre-generate, untested)

The runner does not run on Windows. You can pre-generate the file and place it per user, but no one has tested Cortex Code hooks on Windows yet:

```sh
scripts/render.sh --agent cortexcode --target-os windows \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o cortexcode-hooks.json
```

Place it at `%USERPROFILE%\.snowflake\cortex\hooks.json` with a script that runs **as the signed-in user** (Intune: *Run this script using the logged on credentials*; JumpCloud: *Run As Signed In User*). This overwrites the file: there is no merge on Windows, so a user's own hooks there are lost. The session hook downloads `endorctl` in the foreground on Windows, so it has a 1800 s timeout.

## Manual (one machine)

To try it on your own machine, with the merge:

```sh
d=$(mktemp -d)
scripts/render.sh --agent cortexcode \
  --api-key "$KEY" --api-secret "$SECRET" --namespace "$NS" -o "$d/hooks.json"
scripts/install-cortexcode.sh --users "$(id -un)" "$d/hooks.json"
rm -rf "$d"
```

Or write it directly with `-o ~/.snowflake/cortex/hooks.json`, which overwrites any hooks you already have.

## Verify

After a run, on the endpoint:

1. The file exists at the user's path, owned by the user, mode `600`:
   ```sh
   stat -f '%Su %Lp %N' /Users/<user>/.snowflake/cortex/hooks.json    # macOS: <user> 600 …
   stat -c '%U %a %n'   /home/<user>/.snowflake/cortex/hooks.json     # Linux: <user> 600 …
   ```
2. It holds Endor's five hooks: `grep -c 'ai-audit cortexcode' <path>` prints `5`. Any hooks the user had before are still there.
3. The MDM log shows `install-cortexcode.sh: <user>: wrote <path>` (or `is current` on later runs). `no logged-in user to install for` means no one was logged in during that run.
4. As that user, start a Cortex Code session. The first session on a machine installs `endorctl` in the background. Start a second session and send a prompt. In Endor, the session appears in the AI inventory with the agent **Cortex Code**, and its events appear in the audit log.

## Updating

Nothing to do. Each scheduled run re-fetches `REF`, re-renders, merges, and replaces the file only if the result changed. To move to a new release, bump `REF`.
