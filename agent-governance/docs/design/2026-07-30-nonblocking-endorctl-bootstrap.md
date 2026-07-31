# Design: non-blocking `endorctl` bootstrap

Status: implemented
Date: 2026-07-30
Scope: `agent-governance/scripts/download_endorctl.sh` (POSIX only this pass)

## Problem

Every SessionStart hook runs `download_endorctl.sh` inline and the agent blocks
until it returns. On slow networks this stalls agent startup, sometimes for
many minutes.

Measured against `api.endorlabs.com` on 2026-07-30:

| | |
| --- | --- |
| `endorctl_macos_arm64` size | 305,440,226 bytes (291 MiB) |
| Compression on the wire | none — server ignores `Accept-Encoding: gzip` |
| Range requests | closed (`bytes=A-B`) honored with `206`; open-ended (`bytes=A-`) answered with the **whole body**. `Accept-Ranges` is not advertised |
| Version / `Last-Modified` at the time | `v1.7.1085` / previous day |
| `endorctl --version` locally | ~0.77 s |

291 MiB is roughly 24 s at 100 Mbps, 4 min at 10 Mbps, 20 min at 2 Mbps. The
binary appears to be rebuilt about daily, so this is not a first-run-only cost —
developers pay it on the first session of most days.

Five defects in the current script:

1. **No timeout ceiling.** Both curls (`download_endorctl.sh:10,23`) use
   `-fsSL --retry 5 --retry-connrefused --retry-all-errors` with no
   `--connect-timeout`, `--max-time`, or `--speed-limit`. curl has no default
   transfer timeout, so a slow-but-alive link or a captive portal hangs the hook
   indefinitely, and `--retry 5` multiplies it by up to 6. This is the direct
   cause of the startup-blocking complaints. (`download_endorctl.ps1` does set
   `-TimeoutSec 30`/`120` — the two paths disagree.)
2. **No resume.** A failure at 90% restarts from byte 0, up to five more times.
   The server does support ranges, but only the closed form — see the Resume
   note below for why the obvious `curl -C -` cannot be used here.
3. **Updates are on the critical path.** Even when a working binary is already
   installed, the session waits for a newer one.
4. **Nothing serializes concurrent sessions.** Claude Code, Cursor, and Codex —
   or three Claude windows — each download their own 291 MiB copy into their own
   `mktemp` file, competing for the same scarce bandwidth. There is no lock.
5. **Failure is fail-closed and loud.** Every error path is `exit 1`, and
   `render.sh:190` composes the session hook as `bootstrap \n audit`, so a
   network hiccup yields both no audit event and a hook error shown to the
   developer. The version check also runs every session even when there is
   nothing to do; there is no "checked recently" stamp.

## Decisions

- **Scope: this repo only.** Server-side fixes (gzip the download, ship a
  smaller binary) are the biggest single lever but belong to another team.
- **Background download is acceptable**, including on first run. One session
  (plus any starting during the download window) runs un-audited on a fresh
  machine.
- **Keep the updater inline** in the generated hook command rather than caching
  it as `$HOME/.endorctl/update.sh`. Inlining roughly doubles the bootstrap's
  size and makes the examples uglier, but the managed config stays the single
  source of truth — which is the whole tamper-resistance story. A cached script
  adds a refresh/staleness problem and hands the developer a file to neuter.
- **Update-check TTL: 24 h**, overridable by an env knob. Governance rules are
  server-side and fetched at run time, so binary freshness is not urgent.
- **POSIX first; Windows is a follow-up.** `download_endorctl.ps1` needs a
  different detach primitive and a different resume mechanism (see Follow-ups),
  and it is less acutely broken because it already has timeouts.
- **No explicit marker for un-audited sessions** for now. Absence of events from
  a device is the admin's signal. Revisit later.

## Target design

### Foreground (inside the hook, blocking)

```sh
BIN=$HOME/.endorctl/endorctl
if [ ! -x "$BIN" ]; then
    spawn_background_installer
    exit 0                 # nothing to audit with; hook succeeds, audit line never runs
fi
if check_due && [ -z "$ENDORCTL_SKIP_UPDATE" ]; then
    spawn_background_updater
fi
# fall through to the audit, using the binary already on disk
```

Steady-state foreground cost becomes one `[ -x ]` test plus one stamp-age test:
**zero network, zero binary spawn**, down from ~0.8 s plus an uncapped RTT.

`exit 0` — not `exit 1` — is what skips the audit cleanly. It behaves
identically in all three composed forms in `render.sh`, including Cursor's,
where the `EXIT` trap still removes `$T`.

### Background (detached subshell)

Today's logic, hardened:

- **Detach:** `( trap '' HUP; … ) >/dev/null 2>&1 </dev/null &`. The `trap` gives
  the `nohup` effect without depending on `nohup`; the redirections are what
  release the agent's stdout pipe. Verified 2026-07-30 that this returns the
  hook in 0 s even when the caller captures stdout through a pipe, and that the
  child outlives the parent. Reset any inherited `EXIT` trap inside the subshell
  (Cursor's wrapper sets one, and subshell trap inheritance varies by shell).
- **Lock:** `mkdir "$DIR/.update.lock"` (atomic) so N concurrent sessions perform
  one download instead of N × 291 MiB. Release via trap. Stale-break keyed on the
  **partial file's mtime**, which curl advances continuously — a reliable
  liveness signal that a fixed timeout is not.
- **Timeouts:** meta gets `--connect-timeout 5 --max-time 30`. The binary gets
  `--connect-timeout 10 --speed-limit 10240 --speed-time 60` (abort if
  throughput stays under 10 KB/s for a minute). Deliberately **no** `--max-time`
  on the binary: it is off the critical path now, so a genuinely slow link
  should be allowed to finish.
- **Resume, via an explicit closed range** into a stable partial at
  `$DIR/.endorctl.part`, replacing `--retry 5`'s restart-from-zero. **`curl -C -`
  does not work against this endpoint**: it sends an open-ended `Range: bytes=A-`,
  which the server answers with a `200` and the entire body, so curl aborts with
  `(33) HTTP server doesn't seem to support byte ranges`. A closed
  `bytes=A-B` gets a proper `206`, so the script probes the total length with a
  `HEAD` and asks for `-r <have>-<total-1>`, appending to the partial. The offset
  is recomputed per attempt, so an attempt that dies midway still leaves a
  correct prefix for the next one. Resume is also what makes a process-group kill
  survivable, so the design does not depend on bulletproof detachment.
- **SHA-pin the partial:** record the expected SHA beside it (`$DIR/.endorctl.sha`).
  The binary is rebuilt about daily, so a partial spanning two builds would fail
  verification forever; if the server's SHA moved, discard the partial and start
  fresh rather than retry into a permanent mismatch.
- **Discard a full-length partial that fails its digest.** A failed download
  keeps its partial for the next session, which is right for a genuine partial
  but wedges on a corrupt full-length one (two racing downloaders can produce
  it) — every session would re-request a range past the end and fail the same
  way for ever. The `HEAD` length makes this detectable: at or past full length
  with a bad digest, start over. The same check covers a server that ignores the
  range and resends the whole body, which would leave the partial over-long.
- **Stamp on success only** (`$DIR/.update-check`), so a failed check retries on
  the next session rather than being suppressed for the full TTL.

Verify SHA → `chmod +x` → atomic `mv` is unchanged from today.

### Preserved behavior

- `--skip-endorctl-update` keeps its current meaning: use the installed binary
  as-is, no per-session version check, install only when missing.
- The existing age-gated sweep of `endorctl-download-*` leftovers still has a
  job for pre-upgrade stragglers.
- SHA-256 verification before install is non-negotiable and unchanged.

## Out of scope

- Server-side compression or a smaller `endorctl`.
- MDM-side pre-provisioning of the binary (Jamf package / Intune Win32 app),
  which would take the download off the laptop entirely.
- Any change to `render.sh`'s composition of the hook commands, beyond
  regenerating output.

## Follow-ups

- **Windows parity.** `download_endorctl.ps1` needs `Start-Process powershell
  -EncodedCommand … -WindowStyle Hidden` (re-encoding the updater from a
  here-string) because `Start-Job` dies with its parent, plus a Range-header
  resume loop replacing `Invoke-WebRequest -OutFile`. Note also that
  `Invoke-WebRequest -TimeoutSec` is not a whole-transfer timeout, so today's
  `120` does not bound a 291 MiB download.
- Reconsider an explicit signal for un-audited sessions.

## Regeneration checklist

Changing `download_endorctl.sh` changes every generated artifact. Regenerate all
eight `examples/` files with the demo credentials (`PEPE` / `PAPA` / namespace
`spiderman`) and the placeholder profile UUIDs already checked in, per the
commands in `agent-governance/README.md`.
