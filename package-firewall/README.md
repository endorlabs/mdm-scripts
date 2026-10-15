# Endor Package Firewall — MDM Script Generator

Generates self-contained scripts for IT admins to push via MDM. Once deployed, scripts configure developer machines to route package-manager traffic through the [Endor Package Firewall](https://docs.endorlabs.com/integrations/package-firewall) — without overwriting unrelated configuration.

Scripts are **idempotent** and safe to re-push on MDM check-in cycles.

Both generators target `https://factory.endorlabs.com` by default. EU tenants must set `ENDOR_FQDN=https://factory.eu.endorlabs.com` — see either platform README.

---

## Platforms

| Directory | Platform |
|---|---|
| [`bash/`](bash/README.md) | macOS / Linux  |
| [`powershell/`](powershell/README.md) | Windows | 

See each directory's README for generation and deployment instructions.

---

## Ecosystems covered

| Ecosystem | Tools |
|---|---|
| JavaScript | npm, pnpm, yarn classic (1.x), yarn 2+ / berry, bun |
| Python | pip, uv, poetry |
| Go | go modules (via GOPROXY) |
| Java | Maven (via `~/.m2/settings.xml` mirror); Gradle when it reads `~/.m2` |
| .NET | NuGet — dotnet CLI, NuGet CLI, Visual Studio, Rider, VS Code (via user-level `NuGet.Config`) |
| VS Code | Microsoft VS Code Stable extension gallery |

---

## Shared config blocks

Both the bash and PowerShell generators read block content from `shared/blocks/`:

```
shared/blocks/
├── envsh.txt          ← ~/.config/endor/env.sh content  (bash only)
├── npmrc.txt          ← .npmrc content
├── yarnrc_classic.txt ← .yarnrc content  (yarn 1.x)
├── yarnrc.txt         ← .yarnrc.yml content  (yarn 2+)
├── pipconf.txt        ← pip.conf / pip.ini content
├── uvtoml.txt         ← uv.toml content
├── goenv.txt          ← go env file content  (GOPROXY)
├── mavensettings.txt  ← ~/.m2/settings.xml fragment  (Maven mirror + server)
├── nugetconfig_sources.txt        ← NuGet.Config <packageSources> items  (clear + Endor source)
├── nugetconfig_credentials.txt    ← NuGet.Config <packageSourceCredentials> item
└── nugetconfig_sourcemapping.txt  ← NuGet.Config <packageSourceMapping> items  (only when the section exists)
```

Edit these files to customise what gets written to developer machines. The orchestration scripts (`templates/*.sh` / `templates/*.ps1`) control which files get written and in what order.

---

## Generated output

Running either generator produces these scripts in `out/<namespace>/`:

| Script | Purpose |
|---|---|
| `endor-js.*` | Configure JavaScript package managers only |
| `endor-python.*` | Configure Python package managers only |
| `endor-go.*` | Configure Go modules only |
| `endor-maven.*` | Configure Maven only |
| `endor-nuget.*` | Configure NuGet / .NET only |
| `endor-vscode.*` | Configure VS Code by the methods you enable: the `product.json` patch and/or the gallery policy (see [VS Code](#vs-code)) |
| `endor-all.*` | Configure all package managers (single-script deploy) |
| `endor-remove.*` | Strip all Endor configuration from a machine |
| `endor-vscode-disable-patch.*`, `endor-vscode-disable-policy.*` | Turn off one VS Code method, and leave everything else (see [Switching methods](#switching-methods-and-turning-one-off)) |
| `endor-vscode.mobileconfig`, `endor-vscode-policy.plist` | bash generator, with `ENDOR_VSCODE_ENABLE_POLICY`: VS Code's policy for Macs, as a configuration profile and as a property list, to upload to your MDM |

Each generated script carries all Endor configuration it needs; VS Code's Linux remediation also uses systemd and Python 3 as noted below.

> **Security**: add `out/` to `.gitignore`. Generated scripts and the VS Code profile contain API credentials in plaintext.

## VS Code

`endor-vscode.*` routes Microsoft VS Code Stable's extension gallery through the
firewall, by one or both of two methods. **Neither is on by default**: choose
with these generator variables. Values are `true`, `false`, `1` or `0`, in any
case.

| Variable | Method |
|---|---|
| `ENDOR_VSCODE_ENABLE_PATCH=true` | **Patch**: set `extensionsGallery.serviceUrl` in VS Code's `product.json` to the authenticated `/firewall/vscode/_ak/<token>` URL, remove `extensionUrlTemplate`, and keep it that way across VS Code updates |
| `ENDOR_VSCODE_ENABLE_POLICY=true` | **Policy**: set VS Code's `ExtensionGalleryServiceUrl` enterprise policy to the same URL |
| `ENDOR_VSCODE_POLICY_AUTH=github` or `microsoft` | Optional, with the policy only: the account VS Code asks users to sign in with. VS Code's default is `github` |

`ENDOR_VSCODE_MACOS_DAEMON`, from earlier versions of the bash generator, still
works as a deprecated name for `ENDOR_VSCODE_ENABLE_PATCH`. So
`ENDOR_VSCODE_MACOS_DAEMON=0`, which used to leave Linux patched, now turns the
patch off everywhere; `generate.sh` warns about it.

> [!IMPORTANT]
> **The policy turns the Extensions Marketplace off for anyone who isn't signed
> in with an eligible account.** Once `ExtensionGalleryServiceUrl` is set, VS
> Code shows extensions only after the user signs in, and it doesn't fall back to
> `product.json`. Eligible accounts:
>
> - with the default GitHub sign-in: a GitHub account with a Copilot Business or
>   Enterprise seat (trials count), or a GitHub Enterprise account (GHE.com, or an
>   Enterprise Managed User);
> - with `ENDOR_VSCODE_POLICY_AUTH=microsoft` (VS Code 1.137 or later): any
>   Microsoft Entra ID work or school account. Personal Microsoft accounts are
>   rejected.
>
> Enabling the patch as well doesn't change this. VS Code follows the policy; the
> patch then only keeps `code --install-extension` covered.

### Choosing a method

| | Patch | Policy |
|---|---|---|
| Covers | The editor and `code --install-extension` | The editor only. `code --install-extension` ignores the policy |
| Sign-in | Not needed | Required: an eligible account, above |
| Where it lives | `product.json` in each VS Code install | Linux: `/etc/vscode/policy.json`. Windows: `HKLM\SOFTWARE\Policies\Microsoft\VSCode`. macOS: managed preferences, from the `endor-vscode.mobileconfig` profile you upload to your MDM |
| What keeps it applied | A watcher reapplies it after every VS Code update (below) | Nothing needs to: updates don't touch it |
| macOS | The daemon re-signs VS Code with a certificate unique to each Mac. Users see a keychain prompt after each update, and the app no longer carries Microsoft's Team ID ([details](bash/README.md#macos-code-signing)) | VS Code is left as Microsoft shipped it. Deliver the policy with an MDM profile: users can't override managed preferences, but can override any other kind |
| VS Code versions | All | 1.99 or later; 1.106 or later on Linux; 1.137 or later for `ENDOR_VSCODE_POLICY_AUTH` |
| Credential | Readable by local users in `product.json` | Readable by local users in `policy.json`, the registry or managed preferences |

Both at once isn't a fallback: the editor follows the policy, and the command
line follows `product.json`. For users without an eligible account, adding the
policy turns off a Marketplace that the patch alone would have left working.

Whichever you choose, also block `marketplace.visualstudio.com/_apis`,
`*.gallery.vsassets.io` and `www.vscode-unpkg.net` at your web gateway, so a
session that isn't using the firewall fails closed.

### Switching methods, and turning one off

`endor-vscode.*` never removes a method that it wasn't generated with, because
that would turn the firewall off. When it finds one left by an earlier
deployment, it warns and exits 1, so your MDM reports it. Each method has its own
script to turn it off, which both generators write every time:

| Platform | Turn off the patch | Turn off the policy |
|---|---|---|
| macOS | `endor-vscode-disable-patch.sh`: removes the daemon, swaps Microsoft's original app back in, and deletes the signing identity | Remove the profile in your MDM. `endor-vscode-disable-policy.sh` reports whether one is still installed, and warns if it is |
| Linux | `endor-vscode-disable-patch.sh`: removes the dpkg hook, systemd units and timer, and restores `product.json` | `endor-vscode-disable-policy.sh`: removes Endor's keys from `/etc/vscode/policy.json` |
| Windows | `endor-vscode-disable-patch.ps1`: removes the scheduled task, and restores `product.json` | `endor-vscode-disable-policy.ps1`: removes Endor's values from `HKLM\SOFTWARE\Policies\Microsoft\VSCode` |
| Both | Run both scripts, or `endor-remove.*`, which also removes the package-manager configuration | |

The disable scripts run as root or SYSTEM, need no signed-in user, and accept
`--dry-run` (`-DryRun` on Windows).

To switch, replace the old method before removing it, so the firewall is never
off:

- **Patch to policy**: deploy `endor-vscode.*` generated with only
  `ENDOR_VSCODE_ENABLE_POLICY=true` (and, for Macs, upload the profile). Then
  deploy `endor-vscode-disable-patch.*`.
- **Policy to patch**: deploy `endor-vscode.*` generated with only
  `ENDOR_VSCODE_ENABLE_PATCH=true`. Then deploy `endor-vscode-disable-policy.*`,
  and on Macs remove the profile.
- **Both to one**: deploy `endor-vscode.*` generated with the method you keep,
  then the other method's disable script.

Until the old method is gone, the new `endor-vscode.*` warns about it. Make sure
no older `endor-vscode.*` is still assigned in your MDM: one generated with a
method turns it on again at its next run.

The disable scripts and `endor-remove.*` remove only what Endor set: other
`policy.json` keys, other registry values and other `product.json` settings
stay. They delete `policy.json` or the registry key only if `endor-vscode.*`
created it and nothing else is left in it.

The patch can be undone only while its worker is still in its state folder
(`/var/lib/endor/vscode-firewall`, `/Library/Application Support/Endor
Labs/vscode-firewall` or `%ProgramData%\Endor Labs\vscode-firewall`). If that
folder was deleted by hand, reinstall VS Code to get Microsoft's `product.json`
back.

### Upgrading from scripts generated before these variables

Before, generating without any VS Code variable patched VS Code on Linux and
Windows, and on macOS only with `ENDOR_VSCODE_MACOS_DAEMON=1`. Now it configures
nothing: `generate.*` warns, and the script prints a skip line. Scripts already
deployed keep working until you replace them. To keep patching, regenerate with
`ENDOR_VSCODE_ENABLE_PATCH=true`. In the bash script that also turns on the
macOS daemon; to patch Linux only, deploy `endor-vscode.sh` to Linux machines
only.

Scripts from generators that predate these variables, such as the one on
docs.endorlabs.com, behave as before.

### Patch: update remediation

The patch preserves every unrelated `product.json` value and reapplies only the
two managed properties after VS Code updates:

- macOS: root launchd daemon watching the VS Code app and users' VS Code update
  caches
- Linux: a dpkg hook (Debian, Ubuntu), a systemd path unit and a 1-minute
  timer, so a package upgrade is patched before apt or dpkg returns, and
  within a minute on RPM systems
- Windows: SYSTEM scheduled task using `FileSystemWatcher`, with a periodic rescan

Run the script as root/SYSTEM. Restart VS Code after the first deployment if it
was already open. `endor-remove.*` stops remediation and restores the stable
default values for the two managed gallery properties without reverting other
`product.json` changes. On macOS it swaps Microsoft's original app back in.

Supported scope is Microsoft VS Code Stable installed natively in its standard
system locations (including Windows User Installer paths). Insiders, VSCodium,
Code OSS, Snap, Flatpak, and arbitrary portable/tarball locations are not
managed. On Linux the patch requires systemd and Python 3, and the policy Python 3.
