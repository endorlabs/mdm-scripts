# Deploy Claude Cowork via an organization plugin

A Claude Cowork task does not run on the member's laptop. Its hooks run in a cloud workspace (Linux x86_64, user `root`, a fresh one for every task) that no MDM profile and no managed-settings file reaches. The one thing that does reach it is a **plugin**: Cowork loads the hooks of every plugin installed for the member.

So Cowork gets the same Claude Code hooks as the [profile path](deploy-claude-profile.md), packaged as a plugin that an organization Owner installs for everyone. `render.sh --agent claude-cowork` builds that plugin for one tenant.

> **Status: in validation.** The build is tested here. Installing the plugin as Required for a whole organization has not been verified end to end yet, and the limits under [What this does not cover](#what-this-does-not-cover) apply.

## How it differs from the other agents

- **A plugin, not a config file.** The output is a ZIP (or a directory) with five files, not one JSON file:

  ```
  .claude-plugin/plugin.json   name and version
  hooks/hooks.json             the hook events; holds no credential
  scripts/endor-hook.sh        loads endor.env and runs endorctl ai-audit claudecode
  scripts/bootstrap.sh         the endorctl download (a copy of download_endorctl.sh)
  endor.env                    your API URL, namespace, key and secret
  ```

- **Credentials live in `endor.env`.** A plugin's `hooks.json` has no `env` block, so each hook calls `scripts/endor-hook.sh`, which reads `endor.env` from the plugin and passes the values to `endorctl` as flags.
- **The key is readable inside every task.** Every member of the organization, Claude itself, and any other plugin's hooks can read `endor.env` in the workspace. Use a key with the **AI Audit role only**, and treat the ZIP as a secret.
- **`endorctl` is not in the plugin.** It is about 350 MB; a plugin is limited to 200 MB and Cowork refuses a `bin/` directory. The `SessionStart` hook downloads it in the background, as it does on a laptop, and every task starts in a new workspace. Hooks let actions through until the binary is in place, so **roughly the first minute of every task is not audited**.
- **Same events and policies as Claude Code.** `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `ConfigChange` and `Stop`, audited by `endorctl ai-audit claudecode` against the same policies.
- **No `--target-os`.** The workspace is Linux whatever the member's machine is. `--target-os windows` is refused.

## 1. Build the plugin

You need this repository, a POSIX shell, and `zip`. Run the build in your own terminal: it handles the API key.

```sh
export ENDOR_NAMESPACE='acme.engineering'        # the namespace, not a URL
export ENDOR_API_CREDENTIALS_KEY='<key>'         # AI Audit role only
export ENDOR_API_CREDENTIALS_SECRET='<secret>'
# export ENDOR_API='https://api.eu.endorlabs.com'  # only if your tenant is not on api.endorlabs.com

scripts/render.sh --agent claude-cowork -o endor-cowork-governance.zip
```

| Input | Flag | Environment variable | Default |
| --- | --- | --- | --- |
| API key | `--api-key` | `ENDOR_API_CREDENTIALS_KEY` | required |
| API secret | `--api-secret` | `ENDOR_API_CREDENTIALS_SECRET` | required |
| Namespace | `--namespace` | `ENDOR_NAMESPACE` | required |
| API URL | `--api-url` | `ENDOR_API` | `https://api.endorlabs.com` |

A value given as a flag wins over the environment variable; with neither, `render.sh` prompts for it. The build refuses a namespace that contains `/` or `:`, because a URL pasted there produces a plugin whose every send fails with nothing shown to the user.

`-o` decides the form:

- **A path ending in `.zip`** writes a ZIP to upload. It is created readable by you only (`0600`).
- **Any other path** writes the plugin as a directory, for the repository route below. The directory must be new or empty.

### Or build it from your MDM

[`scripts/runner.sh`](../scripts/runner.sh) builds the plugin too. Set `AGENT=claude-cowork`, paste it into your MDM as a script, supply the credentials as for the other agents (see [the runner runbook](deploy-cursor-runner.md)), and scope it to the **one machine** of the Owner who uploads the plugin, never the fleet: the ZIP holds the key.

Each run fetches this repository at the pinned `REF` and rebuilds the plugin. The ZIP is replaced only when the plugin's files changed, and the script's output says so: `plugin changed - upload ...` means a re-upload is due, `plugin unchanged` means nothing to do. By default the ZIP is written root-only to `/Library/Application Support/EndorAIGovernance/endor-cowork-governance.zip` (macOS) or `/var/lib/endor-ai-governance/` (Linux); set `DEST` to write it elsewhere. An administrator hands the file to the user who uploads it.

`--env KEY=VALUE` and `--skip-endorctl-update` work as for the other agents and are written into `endor.env`. For a monitor-only start, add `--env ENDOR_AI_AUDIT_NO_BLOCKING=true`. A sample built with demo credentials is at `examples/claude-cowork/`.

## 2. Install it for the organization

Organization plugins need a Team or Enterprise plan, an organization **Owner**, and Cowork and Skills turned on.

1. Open **Organization settings > Plugins & skills**.
2. Add the plugin, one of two ways:
   - **Upload** `endor-cowork-governance.zip`.
   - **Sync a private GitHub repository** that holds the plugin directory (build with `-o <directory>` and commit all five files, `endor.env` included). Claude refuses a public repository. A sync picks up a change only when the `version` in `.claude-plugin/plugin.json` goes up.
3. Set the plugin to **Required**. It is then installed for every member, and members cannot turn it off or remove it.

Keep exactly one copy installed. A member who also uploaded the plugin personally gets every event twice.

## 3. Verify

Check Endor's records, not Claude's answer: an allowed action is silent, and Claude's own summary of what a hook did is not reliable.

1. As a member who never installed the plugin, open the **Cowork** tab (not Chat), start a task and send `hi`. This starts the `endorctl` download.
2. After about two minutes, ask: `Run this in the cloud workspace and paste the output verbatim: date -u; ls -la ~/.endorctl; ~/.endorctl/endorctl --version`. A printed version and an `.update-check` file mean the binary is ready.
3. Send a prompt that uses a tool, such as `List the files in the current folder.`, then `ok` a minute later. `endorctl` sends its queue at most every 30 seconds and only when another hook runs.
4. List the events in the namespace:

   ```sh
   endorctl api list -r AgentHookEvent -n "$ENDOR_NAMESPACE" --list-all \
     --filter "meta.create_time >= date(2026-01-01T00:00:00Z)"
   ```

   Each event should carry the member's email as the user, not `root`.

If nothing arrives, look at `~/.endorctl/aigovernance/localdb/` in the workspace. Queued rows there mean the sends are failing: check the namespace and the key's role.

## Updating

| What changes | Your action |
| --- | --- |
| API key or secret (rotation) | Rebuild, then re-upload the ZIP. For a synced repository, commit the new `endor.env` and raise `version` in `plugin.json`. |
| Namespace, API URL, `--env` settings | The same: rebuild and re-deliver. |
| A new plugin release in this repository | Pull, rebuild, re-deliver. The release carries a higher `version`. |
| `endorctl` | None. Each task downloads the current release. |
| Policies | None. They are evaluated from Endor at run time. |

## What this does not cover

- **Claude Chat.** Chat ignores plugin hooks. Connector calls and code runs in Chat are neither blocked nor recorded.
- **The start of each task.** Until `endorctl` is downloaded, hooks let actions through unrecorded. A scheduled task acts the moment its workspace starts, so its first commands can fall in this window.
- **The end of each task.** Events still queued when the workspace is discarded are lost. There is no `SessionEnd` hook yet.
- **File transfers.** `device_stage_files` and `device_commit_files` are recorded as generic tool calls: file rules do not see their paths and the secrets check does not run on them.
- **Members' laptops are affected too.** A Required plugin also syncs to each member's Claude Code. On a machine that already has the MDM hooks, both sets run and every event is recorded twice. The plugin's hooks do not yet stand down outside Cowork.
- **Tenants off `api.endorlabs.com`.** Events and policy lookups go to your `--api-url`, but the `endorctl` download always comes from `https://api.endorlabs.com`, so the workspace needs to reach both.
- **Hooks fail open.** A hook that crashes or times out lets the action through, as on every other agent.
