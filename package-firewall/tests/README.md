# package-firewall tests

Tests for the VS Code ecosystem — the JSON editing primitives, the patch/restore
lifecycle, the update watcher, and the generated scripts end to end.

```sh
cd package-firewall/tests
./run-all.sh                 # everything (adds the PowerShell suites when pwsh is present)
./run-all.sh --bash          # bash suites only
./run-all.sh lib watcher     # suites matching a name
./run-all.ps1                # PowerShell suites, from Windows without bash or WSL
```

Individual suites run standalone too: `bash bash/lib.sh`,
`pwsh -NoProfile -File powershell/lib.ps1`.

## Why VS Code has tests when the other ecosystems don't

The other ecosystems append a sentinel-delimited block to a config file that nothing
else rewrites. VS Code is different in three ways, and each one is a place to get
byte-level fidelity wrong:

1. **`product.json` is JSON**, so it can carry neither a `#` sentinel nor an
   `${ENDOR_*}` reference. The managed marker is a top-level JSON key that also stores
   the original `extensionsGallery` object verbatim, because that is what makes removal
   byte-exact. Nothing about that is checkable by eye.
2. **The file lives inside a signed application bundle** and is replaced wholesale by
   every VS Code update. Restore has to reproduce the original *exactly* — a stray
   trailing newline is a permanent diff against the vendor file.
3. **Two independent implementations** (awk and PowerShell, plus a node fallback on
   each side) write the same marker and the same patched lines into the same file. An
   admin may well run the bash script on Macs and the PowerShell one on Windows across
   one fleet. If the ports drift, one platform's output stops being readable by the
   other's state machine, and that surfaces as a mysterious re-patch loop rather than
   as an error.

The two `json-primitives` suites therefore mirror each other assertion for assertion.
That duplication is deliberate.

## Layout

| Path | |
|---|---|
| `run-all.sh`, `run-all.ps1` | runners; aggregate tallies, non-zero on any failure |
| `fixtures/product.json` | synthetic `product.json` — the target for almost everything |
| `bash/harness.sh`, `powershell/Harness.ps1` | paths, assertion helpers, fixture builders |
| `bash/json-primitives.sh` | the awk JSON primitives in isolation |
| `bash/lib.sh` | `vscode_*` lifecycle: discovery, state machine, both writers, failure modes |
| `bash/watcher.sh` | launchd plist, systemd units, cron fallback, sidecar telemetry |
| `bash/e2e.sh` | the generated scripts, against a sandboxed install |
| `powershell/json-primitives.ps1` | mirror of `bash/json-primitives.sh` |
| `powershell/lib.ps1` | mirror of `bash/lib.sh` |
| `powershell/e2e.ps1` | the generated PowerShell script bodies |

## The fixture, and why not a real install

`fixtures/product.json` is synthetic but shaped like the real thing: tab-indented,
LF line endings, **no final newline**, `extensionsGallery` at depth 1 with the same
keys in the same order, a 16-entry multi-line `accessSKUs` array, and a *nested*
`version` deeper in the file so "read the top-level key, not that one" stays a real
assertion.

Targeting an installed `product.json` instead would tie assertions like "16 SKUs" and
"74 lines" to one VS Code build, so the suites would start failing on an unrelated
schedule — VS Code's release schedule. The fixture makes those counts stable.

Its byte layout *is* the test data. `fixtures/.gitattributes` sets `-text` so no
checkout can normalise the line endings or add the final newline, and the missing final
newline is intentional — git will say `\ No newline at end of file`, which is correct.

Both `lib` suites additionally patch and restore whichever real `product.json` is
installed on the machine, if any, asserting nothing version-specific. That keeps a
real shipped file in the loop without coupling the suites to a version.

## What is not covered

- **Windows.** Scheduled Task registration and `%ProgramFiles%` / AppData discovery
  cannot run off-Windows and are reported as `skip`, never as a pass. The PowerShell
  header — console-user detection and the HKCU environment writes — is stubbed in
  `powershell/e2e.ps1` for the same reason. These need a Windows box.
- **A real update.** The suites simulate one by restoring the pristine file and running
  the repatch script. Nothing substitutes for letting an Insiders box take a real
  overnight update and checking `repatch_count`.
- **The firewall itself.** No network calls. Whether a blocked extension is actually
  absent from the gallery response is a factory-side question; see the verification
  steps in `../docs/vscode-enterprise-policy.md`.
- **App Management / TCC.** `bash/lib.sh` proves the EPERM path fails loudly with
  actionable text, using a read-only file. It cannot reproduce the macOS TCC denial
  itself, which needs a machine without the grant.

## Conventions

- No root, no network, no writes outside a `mktemp` directory. Both e2e suites verify
  their install-discovery redirect **before** executing anything, because without it
  they would patch the real VS Code on the machine running them.
- The generators write to `<generator dir>/out/<namespace>` with no override, so the
  e2e suites copy the working tree to a temp directory and generate there. The checkout
  stays clean, and no product code exists to accommodate the tests.
- `bash/lib.sh` and `bash/watcher.sh` source the lib in its **inlined** form
  (`grep -v '^# ' | sed '/^ *$/d'`), which is what `generate.sh` actually embeds.
  Testing the pristine file would not prove that nothing in the lib depends on a
  comment or a blank line surviving — and a heredoc body silently would.
- Suites keep going after a failure and print a tally, so one run reports every problem
  rather than the first.
- `python3` is required by the bash suites: several assertions are structural (key
  order, array lengths, sibling survival), not just "is it valid JSON". Deliberately
  not `node` — node is the lib's own fallback writer, so it is not an independent check.
