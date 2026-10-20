# Endor Package Firewall — MDM Script Generator

Generates self-contained shell scripts for IT admins to push via MDM (Kandji, Jamf, or any generic MDM tool). Once deployed, scripts configure developer machines to route package installations through the Endor Package Firewall — without overwriting existing custom configuration.

---

## Directory layout

```
bash/
├── generate.sh
├── lib/
│   └── common.sh
├── templates/
│   ├── envsh.sh             ← orchestration: writes env.sh, sources from shell profiles
│   ├── js.sh                ← orchestration: npm / yarn config file writes
│   ├── python.sh            ← orchestration: pip / uv config file writes
│   ├── go.sh                ← orchestration: go env file write
│   ├── maven.sh             ← orchestration: ~/.m2/settings.xml write (XML-aware)
│   ├── nuget.sh             ← orchestration: ~/.nuget/NuGet/NuGet.Config write (section-aware XML)
│   ├── vscode.sh            ← VS Code: product.json patch + launchd/systemd remediation, policy.json
│   └── remove.sh            ← orchestration: sentinel block removal
└── out/                     ← generated scripts (gitignore this)
    └── <namespace>/
        ├── endor-js.sh
        ├── endor-python.sh
        ├── endor-go.sh
        ├── endor-maven.sh
        ├── endor-nuget.sh
        ├── endor-vscode.sh
        ├── endor-all.sh
        └── endor-remove.sh

../shared/blocks/            ← edit these to customise what gets written to config files
├── envsh.txt                ← ~/.config/endor/env.sh content
├── npmrc.txt                ← ~/.npmrc content
├── yarnrc_classic.txt       ← ~/.yarnrc (yarn 1.x) content
├── yarnrc.txt               ← ~/.yarnrc.yml (yarn 2+) content
├── pipconf.txt              ← pip.conf content
├── uvtoml.txt               ← ~/.config/uv/uv.toml content
├── goenv.txt                ← go env file content  (path resolved via `go env GOENV`)
├── mavensettings.txt        ← ~/.m2/settings.xml fragment  (Maven mirror + server)
├── nugetconfig_sources.txt        ← NuGet.Config <packageSources> items  (clear + Endor source)
├── nugetconfig_credentials.txt    ← NuGet.Config <packageSourceCredentials> item
└── nugetconfig_sourcemapping.txt  ← NuGet.Config <packageSourceMapping> items  (only when the section exists)
```

---

## Step 1 — Generate the MDM scripts

Pass credentials as environment variables (not positional arguments — avoids shell history and `ps` exposure):

```bash
ENDOR_NAMESPACE=my-team \
ENDOR_API_KEY_ID=your-key-id \
ENDOR_API_SECRET=your-key-secret \
./generate.sh
```

Or using a `.env` file (add `.env` to `.gitignore`):

```bash
# .env
ENDOR_NAMESPACE=my-team
ENDOR_API_KEY_ID=your-key-id
ENDOR_API_SECRET=your-key-secret
```

```bash
set -a; source .env; set +a
./generate.sh
```

`ENDOR_FQDN` is optional and defaults to the US host. EU tenants must set it:

| Tenant | Base URL |
|---|---|
| US (default) | `https://factory.endorlabs.com` |
| EU | `https://factory.eu.endorlabs.com` |

```bash
ENDOR_FQDN=https://factory.eu.endorlabs.com \
ENDOR_NAMESPACE=my-team \
ENDOR_API_KEY_ID=your-key-id \
ENDOR_API_SECRET=your-key-secret \
./generate.sh
```

The value must be lowercase `https://` followed by a host of letters, digits, dots and hyphens, optionally followed by `:` and a numeric port — for example `https://factory.eu.endorlabs.com` or `https://factory.eu.endorlabs.com:8443`. Trailing `/` characters are stripped first, so `https://factory.eu.endorlabs.com/` and `https://factory.eu.endorlabs.com///` are both accepted.

Everything else makes `generate.sh` exit non-zero rather than emit registry URLs that fail on the developer machine or inject the value into the generated scripts: a path, query string, fragment, userinfo, whitespace, a shell metacharacter or any other character outside that set; a missing or uppercased scheme; and `http://`. Plaintext `http://` is rejected rather than downgraded — both hosted base URLs are https, and the generated configuration sends Basic Auth credentials on every request.

`ENDOR_NAMESPACE` is checked separately, against a different rule: letters, digits, dots, hyphens and underscores — underscore is allowed here, and there is no scheme or port. Empty, `.` and `..` are rejected outright, because they would collapse the `out/<namespace>/` path. Names that merely look unusual, such as `.hidden`, `...` or `-rf`, are accepted: they stay inside `out/` and contain no character that could alter the generated scripts.

`ENDOR_VSCODE_ENABLE_PATCH` and `ENDOR_VSCODE_ENABLE_POLICY` choose how `endor-vscode.sh` and `endor-all.sh` configure VS Code: patch `product.json`, set VS Code's `ExtensionGalleryServiceUrl` policy, or both. Both are off by default, so without them the scripts leave VS Code alone. Each takes `true`, `false`, `1` or `0`, in any case; any other value makes `generate.sh` exit non-zero. `ENDOR_VSCODE_POLICY_AUTH` (`github` or `microsoft`) is optional and allowed only with the policy. It has no default: unset, the script sets no sign-in provider (and removes one it set before), so VS Code uses its own default. `ENDOR_VSCODE_MACOS_DAEMON` is a deprecated name for `ENDOR_VSCODE_ENABLE_PATCH`: `generate.sh` warns, and stops if the two disagree. So `ENDOR_VSCODE_MACOS_DAEMON=0`, which used to leave Linux patched, now turns the patch off on Linux too. Read [the comparison](../README.md#vs-code) and [`endor-vscode.sh`](#endor-vscodesh) before enabling either. **The policy turns the Extensions Marketplace off for anyone who isn't signed in with an eligible account.**

```bash
ENDOR_VSCODE_ENABLE_PATCH=true      # patch product.json (on macOS, the re-signing daemon)
ENDOR_VSCODE_ENABLE_POLICY=true     # set the ExtensionGalleryServiceUrl policy
ENDOR_VSCODE_POLICY_AUTH=microsoft  # optional, with the policy: sign in with Entra ID
```

Re-running `generate.sh` overwrites the same `out/<namespace>/` directory — no accumulation of stale directories.

---

## Step 2 — Upload to your MDM tool

Each script in `out/<namespace>/` carries all Endor configuration it needs. The Linux VS Code worker requires Python 3 and systemd.

### Which script to upload

| Script | Use when |
|---|---|
| `endor-js.sh` | Team uses JavaScript (npm, pnpm, yarn, bun) only |
| `endor-python.sh` | Team uses Python (pip, uv, poetry) only |
| `endor-go.sh` | Team uses Go only |
| `endor-maven.sh` | Team uses Java / Maven only |
| `endor-nuget.sh` | Team uses .NET / NuGet only |
| `endor-vscode.sh` | Team uses Microsoft VS Code Stable extensions |
| `endor-all.sh` | Team uses multiple ecosystems — single-script deploy |


Upload the script file. Ensure it runs as **root** — the script detects the logged-in console user internally and writes config files to the correct home directory.

The scripts take one optional argument, `--dry-run`. They ignore the target volume, computer name and user that Jamf Pro passes as `$1`–`$3`, and any script parameters left empty, so `--dry-run` also works as a Jamf parameter.

---

## How credentials are stored

All scripts share a common credential architecture:

**`~/.config/endor/env.sh`** — single credential source, written by every install script:
```bash
export ENDOR_API_KEY_ID="..."
export ENDOR_API_SECRET="..."
export ENDOR_AUTH_B64="..."          # base64(key:secret) — used by npm/pnpm/yarn/bun
export ENDOR_NPM_REGISTRY_URL="..."  # used by npm, yarn 2+
export ENDOR_PYPI_URL="..."          # used by uv
export POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME="..."
export POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD="..."
```

Shell profiles (`.zshrc`, `.bash_profile`, `.bashrc`) each get a one-line sentinel block that sources this file. Config files reference env vars rather than baking credentials — except pip, which cannot expand env vars.

**Credential rotation**: update `env.sh` on target machines (redeploy MDM script). No config file changes needed.

---

## What the scripts do

### `endor-js.sh`

Writes `~/.config/endor/env.sh` and an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| `~/.npmrc` | npm (all), pnpm (8–11.x), yarn classic (1.x), bun | `${ENDOR_AUTH_B64}` env var ref |
| `~/.yarnrc.yml` | yarn 2+ / berry | `${ENDOR_API_KEY_ID}:${ENDOR_API_SECRET}` env var refs |

Key behaviour:
- **`_auth` (base64)** is used instead of `_authToken` — required for bun compatibility (`_authToken` causes 401 with bun)
- Yarn classic needs `.npmrc` for auth (`.yarnrc` alone fails) — covered by `.npmrc` write
- `bunfig.toml` is project-level and intentionally not written by MDM; document separately for devs who prefer it

### `endor-go.sh`

Writes `~/.config/endor/env.sh` and an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| Go env file (path from `go env GOENV`) | go modules (all versions) | Literal — baked into `GOPROXY` URL at generation time |

Key behaviour:
- **Path detection**: the script runs `go env GOENV` (with the user's `HOME`) to find the correct path — on macOS this is `~/Library/Application Support/go/env`, on Linux `~/.config/go/env`. Falls back to the OS default if `go` is not installed.
- **GOPROXY** is set to `https://<key>:<secret>@factory.endorlabs.com/.../firewall/go/,direct` — the `,direct` suffix falls back to the upstream module proxy if a module is not blocked
- Credentials are baked in at generation time because Go env files do not support env var expansion
- The go env file is read by all `go` commands regardless of shell — covers IDE terminals, Makefiles, git hooks, and non-interactive scripts
- The go env file takes lower precedence than the `GOPROXY` process env var, so project-level overrides (`go env -w` in a workspace) remain possible
- Sentinel comment lines (`# ...`) are silently skipped by `go env` parsing

---

### `endor-python.sh`

Writes `~/.config/endor/env.sh` and an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| `~/.pip/pip.conf` | pip (legacy path) | Literal — pip cannot expand env vars |
| `~/.config/pip/pip.conf` | pip (XDG / Linux standard) | Literal |
| `~/Library/Application Support/pip/pip.conf` | pip (macOS primary) | Literal |
| `~/.config/uv/uv.toml` | uv (does **not** read pip.conf) | `${ENDOR_PYPI_URL}` env var ref |

Key behaviour:
- **pip**: uses a named `[endor-firewall]` section — preserves any existing `[global]` settings; credentials are literal (pip limitation)
- **uv**: uv ignores pip.conf entirely; `~/.config/uv/uv.toml` is the user-level global config; references `${ENDOR_PYPI_URL}`
- **poetry**: credentials are in `env.sh` as `POETRY_HTTP_BASIC_ENDOR_FIREWALL_*` — no separate write step

> For poetry, developers still need to add the source to `pyproject.toml` (URL only, no credentials):
> ```toml
> [[tool.poetry.source]]
> name     = "endor-firewall"
> url      = "https://factory.endorlabs.com/v1/namespaces/my-team/firewall/pypi/simple/"
> priority = "primary"
> ```

---

### `endor-maven.sh`

Writes an Endor-managed block to:

| File | Covers | Credentials |
|---|---|---|
| `~/.m2/settings.xml` | Maven (all versions); Gradle when it reads `~/.m2` | `${env.ENDOR_API_KEY_ID}` / `${env.ENDOR_API_SECRET}` env var refs |

Key behaviour:
- **XML-aware writer**: `settings.xml` is XML, so the generic `#`-sentinel `upsert_block` cannot be used (it would append after `</settings>` and corrupt the file). `endor-maven.sh` uses `upsert_xml_block`, which inserts an XML-comment-delimited fragment **immediately before** `</settings>` so it always lands inside the `<settings>` root.
- **Fresh machine**: if `~/.m2/settings.xml` does not exist, a complete minimal schema-referenced `settings.xml` is created wrapping the Endor fragment.
- **Existing file**: the fragment is spliced in before `</settings>`; all other elements (e.g. an admin `<profile>`) are preserved. Re-runs replace only the Endor fragment (idempotent).
- **`<mirror>` with `<mirrorOf>*</mirrorOf>`** routes every repository request through the firewall — the Maven equivalent of npm's `registry=`.
- **No baked credentials**: Maven natively expands `${env.*}` from process environment variables. The required `ENDOR_API_KEY_ID` / `ENDOR_API_SECRET` are already exported by `env.sh`, and a matching `<server id="endor-firewall">` attaches them to the mirror — so no new credential plumbing is added.
- **Removal**: `endor-remove.sh` strips only the Endor fragment; if the file is left with an empty `<settings>` scaffold (was Endor-only), it is deleted.

---

### `endor-nuget.sh`

Writes `~/.config/endor/env.sh` and Endor-managed blocks to:

| File | Covers | Credentials |
|---|---|---|
| `~/.nuget/NuGet/NuGet.Config` | dotnet CLI, NuGet CLI, Rider, VS Code — every tool that reads the user-level NuGet config (the Mono-era `~/.config/NuGet/` path is not managed) | `%ENDOR_ATTR_USER%` / `%ENDOR_API_SECRET%` env var refs |

What ends up in the file (merged into the existing sections, never duplicated):

```xml
<packageSources>
  <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />   <!-- pre-existing, kept but superseded -->
  <!-- ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) ===== -->
  <clear />
  <add key="endor-firewall" value="https://factory.endorlabs.com/v1/namespaces/my-team/firewall/nuget/v3/index.json" protocolVersion="3" />
  <!-- ===== END ENDOR PACKAGE FIREWALL ===== -->
</packageSources>
<packageSourceCredentials>
  <!-- ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) ===== -->
  <endor-firewall>
    <add key="Username" value="%ENDOR_ATTR_USER%" />
    <add key="ClearTextPassword" value="%ENDOR_API_SECRET%" />
  </endor-firewall>
  <!-- ===== END ENDOR PACKAGE FIREWALL ===== -->
</packageSourceCredentials>
```

Key behaviour:
- **`<clear />` is the enforcement.** NuGet queries every enabled source with no priority, so the Endor source must be the only public one. The block's `<clear />` supersedes every source listed above it (nuget.org included); those lines stay in the file and become active again on removal.
- **Merged into the existing section.** NuGet reads only the *first* `<packageSources>` section in a file and only the *first* `<clear />` inside it. The writer therefore inserts the block as the section's last items (creating the section or the file when absent) and rewrites a pre-existing user `<clear />` as `<!-- endor-bak <clear /> -->` so ours takes effect — the same reversible trick the pip writer uses. Re-runs replace only the Endor block.
- **Credentials** live in a `<packageSourceCredentials>` child named after the source key. `ClearTextPassword` is required off Windows (the encrypted form is DPAPI-only); `%VAR%` references are NuGet's syntax on every OS and resolve from `env.sh`, so no secret is written to the file. To bake literals instead, use `{{ATTR_USER}}` / `{{API_SECRET}}` in `nugetconfig_credentials.txt`.
- **`<packageSourceMapping>`** gets a third block (`<clear />` + pattern `*` → `endor-firewall`) only when the user already has that section; otherwise NuGet lets every source serve every package and nothing is needed.
- **Private feeds** (Artifactory, Azure Artifacts) are superseded by the `<clear />` too, so the script warns and exits 1 when it finds a non-nuget.org source outside the block; re-add such a feed in a repo-level `nuget.config`, or edit the block. Customers who already route through Artifactory should use the registry-side integration instead of this script.
- **Removal** strips only the Endor blocks, restores a disabled user `<clear />`, keeps every section and never deletes the file. If `<packageSources>` ends up with no item, the dotnet default `nuget.org` entry is put back (an empty section means "No sources found"); nuget.org is never added next to a surviving private feed.
- **Limits**: a repo-level `nuget.config` overrides the user file for that repo (see below; same as every ecosystem here); `dotnet nuget add source` appends after our block, so a developer-added source is live until the next MDM run; IDEs launched from the Dock do not inherit `env.sh`, so they get a 401 rather than a silent bypass.

> **Repo-level `nuget.config`.** NuGet applies files found from the drive root down to the project folder *after* the user-level file. A repo that commits `<clear />` + nuget.org (Microsoft's recommended repo pattern) therefore bypasses the firewall for that repo, and a repo that merely adds a source keeps it alive next to the firewall. For full enforcement, commit the firewall as the only public source in each repo as well. No credentials go in the repo: the user-level block attaches them by source key, so the key must be exactly `endor-firewall`.
> ```xml
> <?xml version="1.0" encoding="utf-8"?>
> <configuration>
>   <packageSources>
>     <clear />
>     <add key="endor-firewall" value="https://factory.endorlabs.com/v1/namespaces/my-team/firewall/nuget/v3/index.json" protocolVersion="3" />
>   </packageSources>
> </configuration>
> ```

---

### `endor-vscode.sh`

Routes Microsoft VS Code Stable's extension gallery through the firewall, by the
methods `endor-vscode.sh` was generated with (see [the comparison](../README.md#vs-code)):

- **The patch** (`ENDOR_VSCODE_ENABLE_PATCH=true`): edits `product.json`, and
  keeps it edited across VS Code updates.
- **The policy** (`ENDOR_VSCODE_ENABLE_POLICY=true`): sets VS Code's
  `ExtensionGalleryServiceUrl` policy.

With neither, the script prints a skip line and changes nothing. Both use the same
URL:

```
https://factory.endorlabs.com/v1/namespaces/my-team/firewall/vscode/_ak/<base64url-token>
```

The token is the unpadded Base64 URL encoding of
`ENDOR_API_KEY_ID:ENDOR_API_SECRET`.

Run as root. Restart VS Code after initial deployment if it is open.

Supported scope: Microsoft VS Code Stable at
`/Applications/Visual Studio Code.app`, or at
`/usr/share/code/resources/app/product.json`, where Microsoft's `.deb` and
`.rpm` packages install it. Insiders, VSCodium, Code OSS (including Arch's
`code` package), Snap, Flatpak, and arbitrary portable/tarball installs are
excluded.

#### The patch

Patches Microsoft VS Code Stable's installation-level `product.json`:

```json
{
  "extensionsGallery": {
    "serviceUrl": "https://factory.endorlabs.com/v1/namespaces/my-team/firewall/vscode/_ak/<base64url-token>"
  }
}
```

The patch preserves every unrelated field and removes
`extensionsGallery.extensionUrlTemplate` entirely, which disables VS Code's
direct upstream fallback.

The script applies immediately and installs drift remediation:

- **macOS**: `/Library/LaunchDaemons/com.endorlabs.vscode-firewall.plist` runs a
  worker when `/Applications/Visual Studio Code.app` or a user's VS Code update
  cache (`~/Library/Caches/com.microsoft.VSCode.ShipIt`) changes, and every 60
  seconds. It re-signs VS Code: read [macOS code signing](#macos-code-signing)
  before enabling the patch for Macs.
- **Linux**: three triggers run the same worker, one at a time (a lock under
  `/var/lib/endor/vscode-firewall`):
  - **dpkg hook** (Debian, Ubuntu): `/etc/dpkg/dpkg.cfg.d/endor-vscode-firewall`
    runs the worker after every dpkg run, so an upgrade through apt,
    unattended-upgrades or `dpkg -i` is patched before the command returns.
  - **Path unit**: `endor-vscode-firewall.path` watches
    `/usr/share/code/resources/app`. dpkg and rpm unpack a new VS Code as
    temporary files and rename them into place at the end, so the worker
    waits for that (up to 5 minutes) before patching.
  - **Timer**: `endor-vscode-firewall.timer` runs the worker every minute. It
    catches changes the path unit misses: systemd doesn't watch while the
    worker runs. On RPM systems (Fedora, RHEL), which have no built-in package
    hook, the path unit and the timer are what patch an upgrade.

  File-integrity tools (`debsums`, `rpm -V`, AIDE) report `product.json` as
  modified. That is expected.

Re-running is idempotent. Credential rotation and updater remediation modify
only `serviceUrl` and `extensionUrlTemplate`; every other current
`product.json` value is preserved.

#### The policy

> [!IMPORTANT]
> Once the policy is set, VS Code turns the Extensions Marketplace off until the
> user signs in with an eligible account. With VS Code's default sign-in
> provider (GitHub, as of VS Code 1.142), which applies when
> `ENDOR_VSCODE_POLICY_AUTH` is unset, or with `ENDOR_VSCODE_POLICY_AUTH=github`,
> that is a GitHub account with a Copilot Business or Enterprise seat, or a
> GitHub Enterprise account. With `ENDOR_VSCODE_POLICY_AUTH=microsoft`, it is a
> Microsoft Entra ID work or school account. It doesn't fall back to
> `product.json`. See [the comparison](../README.md#vs-code).

- **Linux**: the script writes `ExtensionGalleryServiceUrl`, and
  `ExtensionGalleryAuthProvider` when `ENDOR_VSCODE_POLICY_AUTH` is set, into
  `/etc/vscode/policy.json`, which VS Code 1.106 and later read. Other keys in
  the file are kept. The file is mode `0644`, because VS Code runs as the user.
  The script refuses to change a `policy.json` that is a symbolic link, isn't
  owned by root, or that others can write to, or that isn't a JSON object (VS
  Code then ignores every policy in it). It also leaves alone a URL that isn't
  Endor's, and a sign-in provider it didn't set; it warns and exits 1 in each
  case. A record in `/var/lib/endor/vscode-policy` (root only) says whether the
  script created the file and which provider it wrote, so removal takes only
  what Endor set. The record never holds the URL.
- **macOS**: VS Code reads the policy from the `com.microsoft.VSCode`
  preference domain. Deliver it with an MDM configuration profile for that
  domain, with the key `ExtensionGalleryServiceUrl` (and, optionally,
  `ExtensionGalleryAuthProvider`). Users can't override a managed preference.
  `endor-vscode.sh` doesn't install profiles; on a Mac it prints a reminder.

The script warns when the installed VS Code is too old for the policy: older
than 1.106 on Linux, or than 1.137 with `ENDOR_VSCODE_POLICY_AUTH`. With the
patch enabled too, an old VS Code is only a note for the first, because the
patch covers it until it's updated.

#### A method left by an earlier deployment

`endor-vscode.sh` never removes a method it wasn't generated with: that would
turn the firewall off. If the patch (the daemon or systemd units, the worker, or
an Endor URL in `product.json`) or the policy (an Endor URL in
`/etc/vscode/policy.json`) is still in place from an earlier deployment, the
script leaves it, warns and exits 1. To clear the warning, regenerate with that
method's variable to keep it, or run `endor-remove.sh` to remove it.

#### macOS code signing

Microsoft's code signature seals `product.json`. Editing it in place makes
Gatekeeper report "Visual Studio Code is damaged and can't be opened" the first
time an updated VS Code launches. So the worker never edits the app in place:

1. It copies the app into `/Library/Application Support/Endor Labs/vscode-firewall/`
   (root only) and checks that the copy is Microsoft's code, changed at most by
   Endor's `product.json` edit.
2. It patches the copy, signs the outer app with a certificate unique to the Mac,
   and swaps it into `/Applications`. Microsoft's original is kept for removal.
3. When VS Code downloads an update, the worker patches and signs the download
   before VS Code installs it, so the first session after **Restart to Update**
   already uses the firewall.

The certificate is self-signed, valid for 10 years and renewed 30 days before it
expires. Its key is non-exportable and lives in the System keychain. Nothing has to
trust it, and no MDM profile is needed. The app's designated requirement accepts
Microsoft's certificate or the Mac's own, so VS Code's updater keeps installing
Microsoft releases.

The worker leaves alone any app it can't vouch for: another signer, ad-hoc or
unsigned builds, added or changed files, or nested code not signed by Microsoft.
It logs a warning and exits non-zero.

What users and admins notice:

- **A keychain prompt after each VS Code update**, and once at the first
  migration: macOS asks for the login password before VS Code can use its "Code
  Safe Storage" item. Choose **Always Allow**. **Deny** only hides saved sign-ins
  (GitHub, Settings Sync) for that session; nothing is deleted, and the next
  launch asks again.
- **One privacy prompt at migration**: permissions such as access to Documents
  are asked for once more after the first migration, not after updates.
- **A different signer**: VS Code shows `Authority=Endor Labs VS Code Firewall (…)`
  and `TeamIdentifier=not set`, and is not notarized. EDR, Santa or PPPC rules
  keyed on Microsoft's Team ID `UBF8T346G9` no longer match it; review them
  before deploying.
- **Open sessions** keep running and use the firewall from their next start.

For defense in depth, block `marketplace.visualstudio.com/_apis` and
`www.vscode-unpkg.net` at your web gateway, so a session that is not using the
firewall can't find or update extensions. This matters with the policy alone
too: `code --install-extension` ignores the policy.

Don't block `*.gallery.vsassets.io` or `*.gallerycdn.vsassets.io`. The firewall
checks each extension download, then redirects VS Code to those hosts for the
file, and VS Code reads each extension's manifest and signature from
`*.gallerycdn.vsassets.io` directly. Blocking either breaks installs and updates
through the firewall. Because these hosts stay reachable, a `.vsix` downloaded
by hand can still be installed.

Troubleshooting, as root:

```bash
/bin/bash "/Library/Application Support/Endor Labs/vscode-firewall/worker.sh" --status
tail -n 50 "/Library/Logs/Endor Labs/vscode-firewall.log"
codesign -dvv "/Applications/Visual Studio Code.app"
```

`endor-remove.sh` swaps Microsoft's original app back in (byte-identical and
notarized) and deletes the signing identity. If there is no original, for example
on a Mac first patched in place by an earlier version of this script, it restores
`product.json` in a re-signed copy, and VS Code's next update replaces that with
Microsoft's build.

---

## Customising

To change what gets written to a config file on target machines, edit the relevant file in `../shared/blocks/` directly:

| File | Written to |
|---|---|
| `../shared/blocks/envsh.txt` | `~/.config/endor/env.sh` |
| `../shared/blocks/npmrc.txt` | `~/.npmrc` |
| `../shared/blocks/yarnrc_classic.txt` | `~/.yarnrc` (yarn 1.x) |
| `../shared/blocks/yarnrc.txt` | `~/.yarnrc.yml` (yarn 2+) |
| `../shared/blocks/pipconf.txt` | `~/.pip/pip.conf`, `~/.config/pip/pip.conf`, `~/Library/Application Support/pip/pip.conf` |
| `../shared/blocks/uvtoml.txt` | `~/.config/uv/uv.toml` |
| `../shared/blocks/goenv.txt` | `~/.config/go/env` |
| `../shared/blocks/mavensettings.txt` | `~/.m2/settings.xml` |
| `../shared/blocks/nugetconfig_sources.txt` | `~/.nuget/NuGet/NuGet.Config` → `<packageSources>` |
| `../shared/blocks/nugetconfig_credentials.txt` | `~/.nuget/NuGet/NuGet.Config` → `<packageSourceCredentials>` |
| `../shared/blocks/nugetconfig_sourcemapping.txt` | `~/.nuget/NuGet/NuGet.Config` → `<packageSourceMapping>` (only when the section exists) |

To change orchestration logic (which files get written, in what order, with what warnings), edit the relevant `templates/*.sh` file directly.

Both support `{{PLACEHOLDER}}` substitution at generation time and `${ENDOR_VAR}` env var references at runtime:

| Syntax | When resolved | Use for |
|---|---|---|
| `{{PLACEHOLDER}}` | Generation time by `generate.sh` | Values baked into the config file (e.g. registry host in a key position) |
| `${ENDOR_VAR}` | Runtime by the tool reading the config file | Credential values — kept out of config files, resolved from `env.sh` |

Available placeholders: `{{API_KEY_ID}}`, `{{API_SECRET}}`, `{{NPM_REGISTRY_URL}}`, `{{NPM_REGISTRY_HOST}}`, `{{NPM_AUTH_B64}}`, `{{PYPI_URL}}`, `{{PIP_INDEX_URL}}`, `{{TRUSTED_HOST}}`, `{{GO_PROXY_URL}}`, `{{MAVEN_REGISTRY_URL}}`, `{{NUGET_SOURCE_URL}}`, `{{VSCODE_SERVICE_URL}}`, `{{NAMESPACE}}`, `{{FQDN}}`, and `{{ATTR_USER}}` (filled at install time by the templates that support it)

---

## Preserving existing configuration

Scripts use a **sentinel block** pattern — they write only a clearly delimited section and leave everything else in the config file untouched.

```ini
# existing admin config — never touched
legacy-peer-deps=true
//private.registry.corp/:_authToken=abc123

# ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) =====
registry=https://factory.endorlabs.com/v1/namespaces/my-team/firewall/npm/
always-auth=true
//factory.endorlabs.com/v1/namespaces/my-team/firewall/npm/:_auth=...
# ===== END ENDOR PACKAGE FIREWALL =====
```

| Scenario | Behaviour |
|---|---|
| Fresh machine | File created with Endor block only |
| Existing file, no Endor block | Block appended; existing content preserved |
| Re-run / MDM check-in | Only the Endor block is replaced; rest untouched |
| Admin edits outside the block | Preserved forever |
| Admin edits inside the block | Overwritten on next MDM push — block is Endor-managed |
| Conflicting key outside block | Warning emitted to MDM log; admin resolves manually |

---

## Removing the configuration

To remove the Endor firewall configuration from a machine, deploy
`endor-remove.sh`. It removes package-manager sentinel blocks, unloads the VS
Code launchd daemon or systemd units, timer and dpkg hook, and restores the stable default values for
`serviceUrl` and `extensionUrlTemplate`. Other `product.json` modifications are
left intact. On Linux it also removes Endor's keys from `/etc/vscode/policy.json`,
and the file itself if `endor-vscode.sh` created it and nothing else is in it. On
macOS, remove the policy's configuration profile in your MDM.

You can deploy a removal script that does this automatically:

```bash
ENDOR_BLOCK_START="# ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) ====="
ENDOR_BLOCK_END="# ===== END ENDOR PACKAGE FIREWALL ====="

remove_block() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -qF "$ENDOR_BLOCK_START" "$file" || return 0
  local tmp; tmp=$(mktemp)
  awk -v start="$ENDOR_BLOCK_START" -v end="$ENDOR_BLOCK_END" '
    index($0, start) { skip=1; next }
    index($0, end)   { skip=0; next }
    !skip             { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  echo "Removed Endor block from $file"
}
```

---

## Security notes

| Item | Note |
|---|---|
| `~/.config/endor/env.sh` | Contains all credentials in plaintext. File is `chmod 600`. This is the only credential file for npm/uv/yarn/poetry. |
| `pip.conf` | Contains credentials in the index-url. File is `chmod 600`. Credentials may appear in pip debug logs (`pip install -v`). pip cannot use env var references. |
| `.npmrc`, `.yarnrc.yml`, `uv.toml` | Contain `${VAR}` references only — no credentials baked in. |
| `~/.m2/settings.xml` | Contains `${env.*}` references only — no credentials baked in. File is `chmod 600`. |
| `~/.nuget/NuGet/NuGet.Config` | Contains `%ENDOR_*%` references only — no credentials baked in (unless you opt into the `{{ATTR_USER}}` / `{{API_SECRET}}` fill). File is `chmod 600`. |
| VS Code `product.json` | Contains the authenticated `_ak/<token>` gallery URL and is readable by local users because VS Code must consume it. |
| VS Code worker state | Root-owned (`0700`) and contains the generated remediation worker. |
| `/etc/vscode/policy.json` | Contains the authenticated `_ak/<token>` gallery URL and is readable by local users (`0644`) because VS Code must read it. |
| `/var/lib/endor/vscode-policy` | Root-only (`0700`). Records whether the script created `policy.json` and which sign-in provider it wrote; never the URL. |
| Shell profiles | Contain a single `source ~/.config/endor/env.sh` line. No credentials. |
| API secret in MDM | The generated scripts contain the API key and secret in plaintext (used to write `env.sh`). Restrict access to the MDM policy and the generated `out/` directory. |
| `out/` directory | Add to `.gitignore`. Do not commit generated scripts to source control. |
