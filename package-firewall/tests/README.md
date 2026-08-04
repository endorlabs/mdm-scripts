# package-firewall tests

Tests for the VS Code ecosystem.

```sh
cd package-firewall/tests
./run-all.sh                 # every suite
./run-all.sh --bash          # bash suites only
./run-all.sh json            # suites matching a name
```

Suites are discovered by glob (`bash/*.sh`, `powershell/*.ps1`, minus the harness), so
adding one needs no edit to the runner. Individual suites run standalone too:
`bash bash/json-primitives.sh`.

## Why VS Code has tests when the other ecosystems don't

The other ecosystems append a sentinel-delimited block to a config file that nothing
else rewrites. VS Code is different in three ways, and each one is a place to get
byte-level fidelity wrong:

1. **`product.json` is JSON**, so it can carry neither a `#` sentinel nor an
   `${ENDOR_*}` reference. The managed marker has to be a top-level JSON key, and it
   stores the original `extensionsGallery` object verbatim, because that is what makes
   removal byte-exact. Nothing about that is checkable by eye.
2. **The file lives inside a signed application bundle** and is replaced wholesale by
   every VS Code update. Restore has to reproduce the original *exactly* — a stray
   trailing newline is a permanent diff against the vendor file.
3. **Two independent implementations** (awk and PowerShell, plus a node fallback on
   each side) write the same marker and the same patched lines into the same file. An
   admin may well run the bash script on Macs and the PowerShell one on Windows across
   one fleet. If the ports drift, one platform's output stops being readable by the
   other's state machine, and that surfaces as a mysterious re-patch loop rather than
   as an error.

## Layout

| Path | |
|---|---|
| `run-all.sh` | runner; aggregates tallies, non-zero on any failure |
| `fixtures/product.json` | synthetic `product.json` — the target for almost everything |
| `bash/harness.sh` | paths, assertion helpers, the stripped-lib loader |
| `bash/json-primitives.sh` | the awk JSON editing primitives in isolation |

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

Individual suites may additionally exercise a real installed `product.json` when one is
present, asserting nothing version-specific.

## Conventions

- No root, no network, no writes outside a `mktemp` directory.
- Suites source the lib in its **inlined** form (`grep -v '^# ' | sed '/^ *$/d'`), which
  is what `generate.sh` actually embeds. Testing the pristine file would not prove that
  nothing in the lib depends on a comment or a blank line surviving — and a heredoc body
  silently would.
- Suites keep going after a failure and print a tally, so one run reports every problem
  rather than the first.
- `python3` is required by the bash suites: several assertions are structural (key
  order, array lengths, sibling survival), not just "is it valid JSON". Deliberately
  not `node` — node is the lib's own fallback writer, so it is not an independent check.
