# Endor Package Firewall — MDM Script Generator

Generates self-contained scripts for IT admins to push via MDM. Once deployed, scripts configure developer machines to route package installations through the [Endor Package Firewall](https://docs.endorlabs.com/integrations/package-firewall) — without overwriting existing custom configuration.

Scripts are **idempotent** and safe to re-push on MDM check-in cycles.

---

## Platforms

| Directory | Platform | MDM tools |
|---|---|---|
| [`bash/`](bash/README.md) | macOS / Linux | Kandji, Jamf Pro, any generic MDM |
| [`powershell/`](powershell/README.md) | Windows | Microsoft Intune, any generic MDM |

See each directory's README for generation and deployment instructions.

---

## Package managers covered

| Ecosystem | Tools |
|---|---|
| JavaScript | npm, pnpm, yarn classic (1.x), yarn 2+ / berry, bun |
| Python | pip, uv, poetry |

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
└── uvtoml.txt         ← uv.toml content
```

Edit these files to customise what gets written to developer machines. The orchestration scripts (`templates/*.sh` / `templates/*.ps1`) control which files get written and in what order.

---

## Generated output

Running either generator produces four scripts in `out/<namespace>/`:

| Script | Purpose |
|---|---|
| `endor-js.*` | Configure JavaScript package managers only |
| `endor-python.*` | Configure Python package managers only |
| `endor-all.*` | Configure all package managers (single-script deploy) |
| `endor-remove.*` | Strip all Endor configuration from a machine |

Each generated script is fully self-contained — no external files or dependencies at runtime.

> **Security**: add `out/` to `.gitignore`. Generated scripts contain API credentials in plaintext.
