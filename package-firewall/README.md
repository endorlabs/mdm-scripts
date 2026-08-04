# Endor Package Firewall — MDM Script Generator

Generates self-contained scripts for IT admins to push via MDM. Once deployed, scripts configure developer machines to route package installations through the [Endor Package Firewall](https://docs.endorlabs.com/integrations/package-firewall) — without overwriting existing custom configuration.

Scripts are **idempotent** and safe to re-push on MDM check-in cycles.

---

## Platforms

| Directory | Platform |
|---|---|
| [`bash/`](bash/README.md) | macOS / Linux  |
| [`powershell/`](powershell/README.md) | Windows | 

See each directory's README for generation and deployment instructions.

---

## Package managers covered

| Ecosystem | Tools |
|---|---|
| JavaScript | npm, pnpm, yarn classic (1.x), yarn 2+ / berry, bun |
| Python | pip, uv, poetry |
| Go | go modules (via GOPROXY) |
| Java | Maven (via `~/.m2/settings.xml` mirror); Gradle when it reads `~/.m2` |
| VS Code extensions | VS Code and VS Code Insiders (via `product.json` extension gallery), including `code --install-extension` |

VS Code has prerequisites the other ecosystems do not — a macOS App Management (TCC) grant,
and a credential that necessarily lands in a world-readable file. Read the
[VS Code prerequisites](bash/README.md#vs-code-prerequisites) before deploying it.

VS Code is configured by patching `product.json` rather than through VS Code's
`ExtensionGalleryServiceUrl` enterprise policy. That policy looks like the natural fit but is
gated behind a GitHub Copilot Business/Enterprise entitlement, expects a different document
shape, and does not reach `code --install-extension` —
[docs/vscode-enterprise-policy.md](docs/vscode-enterprise-policy.md) records the details and
what would change that.

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
└── vscodegallery.txt  ← product.json extensionsGallery overrides  (key-level merge)
```

`vscodegallery.txt` is the one block that is not written verbatim into a config file: it is
applied as a key-level merge into VS Code's `product.json`, so keys it does not mention are
left exactly as VS Code shipped them. Its syntax is documented in the file itself.

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
| `endor-all.*` | Configure all package managers (single-script deploy) |
| `endor-vscode.*` | Configure VS Code + Insiders extension gallery. **Not** included in `endor-all.*` — deploy alongside it |
| `endor-vscode-repatch.*` | Installed by `endor-vscode.*` and run by the OS after VS Code updates. Written to `out/` only so you can read it; do not upload it |
| `endor-remove.*` | Strip all Endor configuration from a machine |

`endor-vscode.*` is deliberately kept out of `endor-all.*`: it is the only script that writes
inside an application bundle and the only one that installs a persistent daemon, so folding it
in would silently widen the blast radius of every existing `endor-all` deployment.

Each generated script is fully self-contained — no external files or dependencies at runtime.

> **Security**: add `out/` to `.gitignore`. Generated scripts contain API credentials in plaintext.

## Tests

```sh
cd package-firewall/tests && ./run-all.sh
```

Covers the VS Code ecosystem: the JSON editing primitives, patch/restore byte fidelity, the
update watcher, and the generated scripts end to end. No root, no network, and nothing touches
an installed VS Code. See [tests/README.md](tests/README.md) for what is and is not covered —
notably, the Windows-only surfaces are reported as skipped rather than passed.
