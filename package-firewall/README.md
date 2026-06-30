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

---

## Shared config blocks

Both the bash and PowerShell generators read block content from `shared/blocks/`:

```
shared/blocks/
├── npmrc.txt          ← .npmrc content
├── yarnrc_classic.txt ← .yarnrc content  (yarn 1.x)
├── yarnrc.txt         ← .yarnrc.yml content  (yarn 2+)
├── pipconf.txt        ← pip.conf / pip.ini content
├── uvtoml.txt         ← uv.toml content
├── goenv.txt          ← go env file content  (GOPROXY)
└── mavensettings.txt  ← ~/.m2/settings.xml fragment  (Maven mirror + server)
```

Edit these files to customise what gets written to developer machines. The orchestration scripts (`templates/*.sh` / `templates/*.ps1`) control which files get written and in what order.

> **User attribution:** the `${ENDOR_*}` credential values referenced by these blocks (e.g. `${ENDOR_ATTR_USER}`, `${ENDOR_AUTH_B64}`) are computed **at install time** on each developer's machine — see `bash/templates/attribution.sh` and `powershell/templates/envvars.ps1`. This stamps `<console-user>@<machine>` onto each firewall request (shown as **User** in the log) without per-user API keys. `~/.config/endor/env.sh` is generated from those values by `bash/templates/envsh.sh`.

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
| `endor-remove.*` | Strip all Endor configuration from a machine |

Each generated script is fully self-contained — no external files or dependencies at runtime.

> **Security**: add `out/` to `.gitignore`. Generated scripts contain API credentials in plaintext.
