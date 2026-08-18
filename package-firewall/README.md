# Endor Package Firewall — MDM Script Generator

Generates self-contained scripts for IT admins to push via MDM. Once deployed, scripts configure developer machines to route package-manager traffic through the [Endor Package Firewall](https://docs.endorlabs.com/integrations/package-firewall) — without overwriting unrelated configuration.

Scripts are **idempotent** and safe to re-push on MDM check-in cycles.

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
└── mavensettings.txt  ← ~/.m2/settings.xml fragment  (Maven mirror + server)
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
| `endor-vscode.*` | Patch VS Code `product.json` and install update remediation |
| `endor-all.*` | Configure all package managers (single-script deploy) |
| `endor-remove.*` | Strip all Endor configuration from a machine |

Each generated script carries all Endor configuration it needs; VS Code's Linux remediation also uses systemd and Python 3 as noted below.

> **Security**: add `out/` to `.gitignore`. Generated scripts contain API credentials in plaintext.

## VS Code update remediation

`endor-vscode.*` sets `extensionsGallery.serviceUrl` to the authenticated
`/firewall/vscode/_ak/<token>` endpoint and removes `extensionUrlTemplate`, so
VS Code cannot fall back to the upstream extension download template. It
preserves every unrelated `product.json` value and reapplies only those two
managed properties after VS Code updates:

- macOS: root launchd daemon watching `/Applications`
- Linux: systemd path/service units watching native `code` package locations
- Windows: SYSTEM scheduled task using `FileSystemWatcher`, with a periodic rescan

Run the script as root/SYSTEM. Restart VS Code after the first deployment if it
was already open. `endor-remove.*` stops remediation and restores the stable
default values for the two managed gallery properties without reverting other
`product.json` changes.

Supported scope is Microsoft VS Code Stable installed natively in its standard
system locations (including Windows User Installer paths). Insiders, VSCodium,
Code OSS, Snap, Flatpak, and arbitrary portable/tarball locations are not
managed. Linux requires systemd and Python 3.

The authenticated gallery URL is stored in `product.json` and must be readable
by local users so VS Code can consume it. On macOS, changing a resource inside
the application bundle invalidates the original code-signature seal; the script
does not ad-hoc re-sign the application.
