#!/bin/bash
# Tests for the agent-governance scripts.
#
#   tests/run-tests.sh                 offline: bootstrap behavior + example sync
#   tests/run-tests.sh --network       also assert the download endpoint's contract
#   tests/run-tests.sh --network-full  also do a real resume + install (~300 MB)
#
# The offline suite is the one to run in CI: it needs no network and finishes in
# seconds. It drives download_endorctl.sh under a throwaway HOME with a stubbed
# curl, so every branch - including ones that only happen on a bad network - is
# reachable without waiting on a ~300 MB transfer.
#
# bash rather than POSIX sh: this runs on a maintainer's machine, not on a
# managed endpoint, so the portability rules the shipped scripts follow (see
# README "Prerequisites") do not apply here. The scripts under test are still
# checked with sh -n and dash -n.
set -u

AG=$(cd "$(dirname "$0")/.." && pwd)
BOOT="$AG/scripts/download_endorctl.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/agov-tests.XXXXXX")
STUB="$WORK/stub"
trap 'rm -rf "$WORK"' EXIT

want_network=0; want_full=0
for a in "$@"; do
  case "$a" in
    --network)      want_network=1 ;;
    --network-full) want_network=1; want_full=1 ;;
    -h|--help)      sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
sec() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# --- fixtures ---------------------------------------------------------------
# Stand-in "endorctl" binaries that answer --version the way the real one does.
mkdir -p "$STUB"
mkfake() { printf '#!/bin/sh\necho "endorctl version %s"\n' "$1" > "$2"; chmod +x "$2"; }
mkfake v1.7.1085 "$WORK/new-bin"; NEWSHA=$(shasum -a 256 "$WORK/new-bin" | awk '{print $1}')
mkfake v1.7.1000 "$WORK/old-bin"

# Stub curl. Reproduces the endpoint's actual range behavior, which the resume
# logic depends on: a closed range (bytes=A-B) is honored with a 206, but an
# open-ended one (bytes=A-) is answered with the whole body - which is why
# `curl -C -` cannot be used here. Body goes to stdout; the caller appends.
cat > "$STUB/curl" <<'STUBEOF'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
url=""; head=0; cont=0; range=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -r) range="$2"; shift 2 ;;
    -C) cont=1; shift 2 ;;
    --connect-timeout|--max-time|--speed-limit|--speed-time) shift 2 ;;
    -*I|-I) head=1; shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */meta/version)
    [ "${STUB_META_FAIL:-}" = 1 ] && exit 7
    printf '{"ClientVersion":"%s","ClientChecksums":{"ARCH_TYPE_MACOS_ARM64":"%s","ARCH_TYPE_MACOS_AMD64":"%s","ARCH_TYPE_LINUX_ARM64":"%s","ARCH_TYPE_LINUX_AMD64":"%s"}}\n' \
      "$STUB_LATEST" "$STUB_SHA" "$STUB_SHA" "$STUB_SHA" "$STUB_SHA"
    ;;
  */download/latest/*)
    total=$(wc -c < "$STUB_DL_BODY" | tr -d ' ')
    if [ "$head" = 1 ]; then printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$total"; exit 0; fi
    [ "${STUB_DL_FAIL:-}" = 1 ] && exit 28
    [ -n "${STUB_DL_SLEEP:-}" ] && sleep "$STUB_DL_SLEEP"
    [ "$cont" = 1 ] && exit 33          # open-ended range: what -C - sends, unusable here
    if [ -n "$range" ]; then
      start=${range%-*}; end=${range#*-}
      if [ -z "$end" ]; then cat "$STUB_DL_BODY"
      else dd if="$STUB_DL_BODY" bs=1 skip="$start" count=$((end - start + 1)) 2>/dev/null; fi
    else
      cat "$STUB_DL_BODY"
    fi
    ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/curl"

# Compose bootstrap + audit exactly as render.sh does, then run it.
run() {
  CURL_LOG="$H/curl.log"; export CURL_LOG
  : > "$CURL_LOG"
  { cat "$BOOT"; echo 'echo AUDIT-RAN'; } > "$H/composed.sh"
  ( export HOME="$H" PATH="$STUB:$PATH"; /bin/sh "$H/composed.sh" ) 2>"$H/stderr"
}
newhome() {
  H=$(mktemp -d "$WORK/home.XXXXXX")
  export STUB_LATEST=v1.7.1085 STUB_SHA="$NEWSHA" STUB_DL_BODY="$WORK/new-bin"
  unset STUB_META_FAIL STUB_DL_FAIL STUB_DL_SLEEP
}
settle() { for _ in $(seq 1 60); do [ -d "$H/.endorctl/.update.lock" ] || break; sleep 0.2; done; sleep 0.4; }
have()   { [ -e "$1" ] && echo yes || echo no; }
# A `case` inside $(...) confuses bash's parser, so wrap it.
isnum()  { case "${1:-}" in ''|*[!0-9]*) echo no ;; *) echo yes ;; esac; }
ver()    { "$H/.endorctl/endorctl" --version 2>/dev/null; }
calls()  { c=$(grep -c "$1" "$H/curl.log" 2>/dev/null); echo "${c:-0}"; }
# Body GETs only - the length probe uses -I against the same URL.
gets()   { c=$(grep 'download/latest' "$H/curl.log" 2>/dev/null | grep -vc 'fsSLI'); echo "${c:-0}"; }

sec "syntax"
for s in sh bash dash; do
  command -v "$s" >/dev/null || { echo "  (no $s, skipped)"; continue; }
  for f in "$BOOT" "$AG/scripts/render.sh" "$AG/scripts/render-plist.sh" "$AG/scripts/runner.sh"; do
    if $s -n "$f" 2>/dev/null; then ok "$s -n $(basename "$f")"; else bad "$s -n $(basename "$f")"; fi
  done
done

sec "cold machine: no binary, so the session is not audited and the install is backgrounded"
newhome
out=$(run)
chk "audit did not run this session" "$(echo "$out" | grep -c AUDIT-RAN)" "0"
chk "hook returned before the binary existed" "$(have "$H/.endorctl/endorctl")" "no"
settle
chk "background job installed it" "$(ver)" "endorctl version v1.7.1085"
chk "check stamp written" "$(have "$H/.endorctl/.update-check")" "yes"
chk "lock released" "$(have "$H/.endorctl/.update.lock")" "no"
chk "partial cleaned up" "$(have "$H/.endorctl/.endorctl.part")" "no"
chk "digest pin cleaned up" "$(have "$H/.endorctl/.endorctl.sha")" "no"

sec "warm machine: a fresh stamp means no network at all"
out=$(run); settle
chk "audit ran" "$(echo "$out" | grep -c AUDIT-RAN)" "1"
chk "zero curl invocations" "$(wc -l < "$H/curl.log" | tr -d ' ')" "0"

sec "stamp expired but already current: metadata only"
touch -t 202001010000 "$H/.endorctl/.update-check"
out=$(run); settle
chk "audit ran" "$(echo "$out" | grep -c AUDIT-RAN)" "1"
chk "metadata fetched once" "$(calls meta/version)" "1"
chk "no download" "$(gets)" "0"
chk "stamp refreshed" "$(find "$H/.endorctl/.update-check" -mmin +1 | wc -l | tr -d ' ')" "0"

sec "update available: the session audits now, the upgrade lands after"
cp "$WORK/old-bin" "$H/.endorctl/endorctl"
touch -t 202001010000 "$H/.endorctl/.update-check"
out=$(run)
chk "audit ran without waiting" "$(echo "$out" | grep -c AUDIT-RAN)" "1"
chk "old binary still in place when the hook returned" "$(ver)" "endorctl version v1.7.1000"
settle
chk "upgraded in the background" "$(ver)" "endorctl version v1.7.1085"

sec "ENDORCTL_SKIP_UPDATE: no check even with an expired stamp"
cp "$WORK/old-bin" "$H/.endorctl/endorctl"
touch -t 202001010000 "$H/.endorctl/.update-check"
out=$(ENDORCTL_SKIP_UPDATE=1 run); settle
chk "audit ran" "$(echo "$out" | grep -c AUDIT-RAN)" "1"
chk "zero curl invocations" "$(wc -l < "$H/curl.log" | tr -d ' ')" "0"
chk "binary untouched" "$(ver)" "endorctl version v1.7.1000"

sec "custom TTL is honored"
newhome
mkdir -p "$H/.endorctl"; cp "$WORK/old-bin" "$H/.endorctl/endorctl"
touch -t 202001010000 "$H/.endorctl/.update-check"
( export ENDORCTL_UPDATE_TTL_MINUTES=999999999; run >/dev/null ); settle
chk "a TTL longer than the stamp's age suppresses the check" "$(wc -l < "$H/curl.log" | tr -d ' ')" "0"
run >/dev/null; settle
chk "the default TTL does not" "$(calls meta/version)" "1"

sec "digest mismatch: nothing is installed"
newhome
export STUB_DL_BODY="$WORK/old-bin"        # body that does not match the advertised digest
run; settle
chk "binary not installed" "$(have "$H/.endorctl/endorctl")" "no"
chk "bad partial discarded" "$(have "$H/.endorctl/.endorctl.part")" "no"
chk "stamp not written, so the next session retries" "$(have "$H/.endorctl/.update-check")" "no"
chk "lock released" "$(have "$H/.endorctl/.update.lock")" "no"

sec "complete partial from a killed run installs without refetching"
newhome
mkdir -p "$H/.endorctl"
cp "$WORK/new-bin" "$H/.endorctl/.endorctl.part"
printf '%s\n' "$NEWSHA" > "$H/.endorctl/.endorctl.sha"
run; settle
chk "installed" "$(ver)" "endorctl version v1.7.1085"
chk "no download issued" "$(gets)" "0"

sec "short partial is resumed with a closed range, not restarted"
newhome
mkdir -p "$H/.endorctl"
head -c 20 "$WORK/new-bin" > "$H/.endorctl/.endorctl.part"
printf '%s\n' "$NEWSHA" > "$H/.endorctl/.endorctl.sha"
run; settle
chk "one GET" "$(gets)" "1"
chk "it carried a closed range starting at the partial's length" "$(calls ' -r 20-')" "1"
chk "assembled binary is correct" "$(ver)" "endorctl version v1.7.1085"

sec "digest moved while the partial sat on disk: start over"
newhome
mkdir -p "$H/.endorctl"
cp "$WORK/old-bin" "$H/.endorctl/.endorctl.part"
printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$H/.endorctl/.endorctl.sha"
run; settle
chk "refetched from scratch" "$(gets)" "1"
chk "correct binary installed" "$(ver)" "endorctl version v1.7.1085"

sec "full-length corrupt partial self-heals instead of wedging"
# Regression: a full-length partial that fails its digest (two racing downloaders
# can produce one) would otherwise re-request a range past the end every session,
# fail, keep the partial, and never install.
newhome
mkdir -p "$H/.endorctl"
tr 'a-z' 'A-Z' < "$WORK/new-bin" > "$H/.endorctl/.endorctl.part"
printf '%s\n' "$NEWSHA" > "$H/.endorctl/.endorctl.sha"
chk "fixture is exactly full length" \
  "$(wc -c < "$H/.endorctl/.endorctl.part" | tr -d ' ')" "$(wc -c < "$WORK/new-bin" | tr -d ' ')"
run; settle
chk "recovered and installed" "$(ver)" "endorctl version v1.7.1085"
chk "lock released" "$(have "$H/.endorctl/.update.lock")" "no"

sec "metadata unreachable: the session still audits, nothing is installed"
newhome
mkdir -p "$H/.endorctl"; cp "$WORK/old-bin" "$H/.endorctl/endorctl"
export STUB_META_FAIL=1
out=$(run); settle
chk "audit ran" "$(echo "$out" | grep -c AUDIT-RAN)" "1"
chk "binary untouched" "$(ver)" "endorctl version v1.7.1000"
chk "stamp not written, so the next session retries" "$(have "$H/.endorctl/.update-check")" "no"

sec "a live lock makes a concurrent session stand down"
newhome
mkdir -p "$H/.endorctl/.update.lock"; echo 99999 > "$H/.endorctl/.update.lock/owner"
run; settle
chk "stood down without touching the network" "$(wc -l < "$H/curl.log" | tr -d ' ')" "0"
chk "the other session's lock survived" "$(have "$H/.endorctl/.update.lock")" "yes"

sec "a slow download does not block the hook"
newhome
export STUB_DL_SLEEP=6
s=$(date +%s); run >/dev/null; e=$(date +%s)
chk "hook returned immediately" "$([ $((e-s)) -le 2 ] && echo fast || echo "blocked $((e-s))s")" "fast"
settle
chk "binary arrived afterwards" "$(have "$H/.endorctl/endorctl")" "yes"

sec "SIGTERM mid-download drains cleanly and the next session finishes"
# A trap does not fire until the running command returns, so a signalled job
# holds its lock until curl drains - correct, curl still owns the partial. What
# matters is that it then cleans up and leaves resumable state behind.
newhome
export STUB_DL_SLEEP=5
run >/dev/null
sleep 1
pid=$(pgrep -f "$H/composed.sh" | head -1)
chk "background job is running" "$([ -n "$pid" ] && echo yes || echo no)" "yes"
chk "lock held while downloading" "$(have "$H/.endorctl/.update.lock")" "yes"
[ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
for _ in $(seq 1 40); do [ -d "$H/.endorctl/.update.lock" ] || break; sleep 0.5; done
chk "lock released once curl drained" "$(have "$H/.endorctl/.update.lock")" "no"
chk "install aborted by the signal" "$(have "$H/.endorctl/endorctl")" "no"
chk "digest pin kept" "$(have "$H/.endorctl/.endorctl.sha")" "yes"
chk "downloaded bytes kept" "$(have "$H/.endorctl/.endorctl.part")" "yes"
unset STUB_DL_SLEEP
run >/dev/null; settle
chk "next session completes the install" "$(ver)" "endorctl version v1.7.1085"
chk "without re-downloading" "$(gets)" "0"

# --- examples ---------------------------------------------------------------
# The checked-in examples/ are generated output. Any change to a script must be
# reflected there, or the samples in the README silently drift from reality.
sec "checked-in examples are in sync with the scripts"
GEN="$WORK/gen"; mkdir -p "$GEN"/cursor "$GEN"/claude "$GEN"/codex
K=PEPE; S=PAPA; NS=spiderman     # demo credentials the samples were built with
r() { "$AG/scripts/render.sh" --api-key $K --api-secret $S --namespace $NS "$@"; }
{
  r --agent cursor -o "$GEN/cursor/hooks.json"
  r --agent claude -o "$GEN/claude/settings.json"
  r --agent codex  -o "$GEN/codex/requirements.toml"
  r --agent cursor --target-os windows -o "$GEN/cursor/hooks.windows.json"
  r --agent claude --target-os windows -o "$GEN/claude/settings.windows.json"
  r --agent codex  --target-os windows -o "$GEN/codex/requirements.windows.toml"
} >/dev/null 2>&1
if command -v plutil >/dev/null 2>&1; then
  # Placeholder UUIDs, so a regenerated profile stays byte-identical.
  r --agent claude -o - 2>/dev/null | "$AG/scripts/render-plist.sh" \
    --identifier com.endorlabs.ai-governance.claudecode --organization "Endor Labs" \
    --name "Claude Code - Endor AI Governance" \
    --profile-uuid 00000000-0000-0000-0000-AAAAAAAAAAAA \
    --content-uuid 00000000-0000-0000-0000-BBBBBBBBBBBB \
    -o "$GEN/claude/com.anthropic.claudecode.mobileconfig" 2>/dev/null
  r --agent codex -o - 2>/dev/null | "$AG/scripts/render-plist.sh" --style mcx \
    --identifier com.endorlabs.ai-governance.codex --organization "Endor Labs" \
    --name "Codex - Endor AI Governance" \
    --profile-uuid 00000000-0000-0000-0000-CCCCCCCCCCCC \
    --content-uuid 00000000-0000-0000-0000-DDDDDDDDDDDD \
    -o "$GEN/codex/com.openai.codex.mobileconfig" 2>/dev/null
fi
for rel in cursor/hooks.json cursor/hooks.windows.json \
           claude/settings.json claude/settings.windows.json \
           claude/com.anthropic.claudecode.mobileconfig \
           codex/requirements.toml codex/requirements.windows.toml \
           codex/com.openai.codex.mobileconfig; do
  if [ ! -f "$GEN/$rel" ]; then echo "  (skipped $rel, needs plutil)"; continue; fi
  if cmp -s "$GEN/$rel" "$AG/examples/$rel"; then ok "examples/$rel"
  else bad "examples/$rel is stale - regenerate it (see README \"Examples\")"; fi
done

sec "every embedded hook command is valid shell after JSON/TOML escaping"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$AG" "$WORK" <<'PY'
import json, subprocess, sys, os, plistlib, base64
ag, work = sys.argv[1], sys.argv[2]
try: import tomllib
except ImportError: tomllib = None
n = 0; bad = []
def check(label, cmd):
    global n; n += 1
    p = os.path.join(work, 'cmd.sh')
    open(p, 'w').write(cmd)
    r = subprocess.run(['sh', '-n', p], capture_output=True, text=True)
    if r.returncode: bad.append((label, r.stderr.strip()))
d = json.load(open(f'{ag}/examples/claude/settings.json'))
for ev, a in d['hooks'].items(): check(f'claude:{ev}', a[0]['hooks'][0]['command'])
d = json.load(open(f'{ag}/examples/cursor/hooks.json'))
for ev, a in d['hooks'].items(): check(f'cursor:{ev}', a[0]['command'])
if tomllib:
    d = tomllib.load(open(f'{ag}/examples/codex/requirements.toml', 'rb'))
    for ev, arr in d['hooks'].items():
        for e in arr: check(f'codex:{ev}', e['hooks'][0]['command'])
pf = f'{ag}/examples/claude/com.anthropic.claudecode.mobileconfig'
if os.path.exists(pf):
    pl = plistlib.load(open(pf, 'rb'))
    for ev, a in pl['PayloadContent'][0]['hooks'].items():
        check(f'profile:{ev}', a[0]['hooks'][0]['command'])
pf = f'{ag}/examples/codex/com.openai.codex.mobileconfig'
if os.path.exists(pf) and tomllib:
    pl = plistlib.load(open(pf, 'rb'))
    b = base64.b64decode(pl['PayloadContent'][0]['PayloadContent']['com.openai.codex']
                         ['Forced'][0]['mcx_preference_settings']['requirements_toml_base64']).decode()
    for ev, arr in tomllib.loads(b)['hooks'].items():
        for e in arr: check(f'mcx:{ev}', e['hooks'][0]['command'])
    same = b.rstrip() == open(f'{ag}/examples/codex/requirements.toml').read().rstrip()
    if not same: bad.append(('mcx payload', 'does not match requirements.toml'))
for label, err in bad: print(f'  \033[31mFAIL\033[0m {label}: {err}')
print(f'  \033[32mPASS\033[0m {n} embedded hook commands parsed and syntax-checked')
sys.exit(1 if bad else 0)
PY
  if [ $? -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
else
  echo "  (skipped, needs python3 to parse JSON/TOML/plist)"
fi

# --- network ----------------------------------------------------------------
if [ "$want_network" = 1 ]; then
  sec "download endpoint contract (network)"
  U=https://api.endorlabs.com/download/latest/endorctl_macos_arm64
  meta=$(curl -fsSL --connect-timeout 5 --max-time 30 https://api.endorlabs.com/meta/version)
  latest=$(echo "$meta" | sed -n 's/.*"ClientVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  sha=$(echo "$meta" | sed -n 's/.*"ARCH_TYPE_MACOS_ARM64"[[:space:]]*:[[:space:]]*"\([a-f0-9]*\)".*/\1/p')
  chk "meta advertises a version" "$([ -n "$latest" ] && echo yes || echo no)" "yes"
  chk "meta advertises a 64-hex digest" "${#sha}" "64"
  total=$(curl -fsSLI --connect-timeout 5 --max-time 30 "$U" 2>/dev/null \
    | tr -d '\r' | sed -n 's/^[Cc]ontent-[Ll]ength: *//p' | tail -1)
  chk "HEAD yields a numeric length" "$(isnum "$total")" "yes"
  code=$(curl -sS -r 0-99 -o /dev/null -w '%{http_code}' --max-time 30 "$U")
  chk "closed range is honored (resume depends on this)" "$code" "206"
  # If this ever becomes 206, `curl -C -` would work and the closed-range dance
  # in download_endorctl.sh could be simplified.
  code=$(curl -sS -r "$((total - 1000))-" -o /dev/null -w '%{http_code}' --max-time 60 "$U")
  chk "open-ended range still returns the whole body, so -C - stays unusable" "$code" "200"
fi

if [ "$want_full" = 1 ]; then
  sec "real resume and install (network, ~300 MB)"
  H="$WORK/real"; mkdir -p "$H/.endorctl"
  U=https://api.endorlabs.com/download/latest/endorctl_macos_arm64
  meta=$(curl -fsSL --connect-timeout 5 --max-time 30 https://api.endorlabs.com/meta/version)
  sha=$(echo "$meta" | sed -n 's/.*"ARCH_TYPE_MACOS_ARM64"[[:space:]]*:[[:space:]]*"\([a-f0-9]*\)".*/\1/p')
  curl -fsSL -r 0-104857599 -o "$H/.endorctl/.endorctl.part" "$U"
  printf '%s\n' "$sha" > "$H/.endorctl/.endorctl.sha"
  chk "seeded a 100 MB partial" "$(wc -c < "$H/.endorctl/.endorctl.part" | tr -d ' ')" "104857600"
  { cat "$BOOT"; echo 'echo AUDIT-RAN'; } > "$H/composed.sh"
  s=$(date +%s); ( export HOME="$H"; /bin/sh "$H/composed.sh" ) >/dev/null; e=$(date +%s)
  chk "hook returned immediately" "$([ $((e-s)) -le 2 ] && echo fast || echo "blocked $((e-s))s")" "fast"
  for _ in $(seq 1 900); do [ -d "$H/.endorctl/.update.lock" ] || break; sleep 1; done
  got=$(shasum -a 256 "$H/.endorctl/endorctl" 2>/dev/null | awk '{print $1}')
  chk "resumed and installed a digest-matching binary" "$got" "$sha"
  chk "partial cleaned up" "$(have "$H/.endorctl/.endorctl.part")" "no"
  chk "lock released" "$(have "$H/.endorctl/.update.lock")" "no"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
