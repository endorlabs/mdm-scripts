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
  for f in "$BOOT" "$AG/scripts/render.sh" "$AG/scripts/render-plist.sh" "$AG/scripts/runner.sh" \
           "$AG/scripts/install-cortexcode.sh" "$AG/scripts/cortexcode-merge.sh"; do
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

# --- download host ----------------------------------------------------------
# The stub curl answers any host; its log shows which one was asked.
installed() { for _ in $(seq 1 50); do [ -x "$H/.endorctl/endorctl" ] && break; sleep 0.2; done; settle; }
hosts() { sed -n 's|.*https://\([^/ ]*\)/.*|\1|p' "$H/curl.log" | sort -u | tr '\n' ' '; }
sec "endorctl is downloaded from the tenant's API host"
newhome; run >/dev/null; installed
chk "no API URL in the environment: production" "$(hosts)" "api.endorlabs.com "
newhome; ( export AGENT_HOOK_ENDOR_API=https://api.eu.endorlabs.com; run >/dev/null ); installed
chk "Claude's AGENT_HOOK_ENDOR_API is used for the digest and the binary" "$(hosts)" "api.eu.endorlabs.com "
chk "and the install completes from that host" "$(ver)" "endorctl version v1.7.1085"
newhome; ( export AGENT_HOOK_ENDOR_API=https://api.eu.endorlabs.com/; run >/dev/null ); installed
chk "a trailing slash on the URL is tolerated" \
  "$(grep -c 'https://api.eu.endorlabs.com/meta/version' "$H/curl.log")" "1"
newhome; ( export ENDORCTL_DOWNLOAD_API=https://api.example.test AGENT_HOOK_ENDOR_API=https://api.eu.endorlabs.com; run >/dev/null ); installed
chk "ENDORCTL_DOWNLOAD_API (what render.sh inlines) wins" "$(hosts)" "api.example.test "
newhome; ( export AGENT_HOOK_ENDOR_API=http://api.example.test; run >/dev/null ); installed
chk "a URL that is not https falls back to production" "$(hosts)" "api.endorlabs.com "

sec "render.sh hands a non-default API URL to the bootstrap"
rr() { "$AG/scripts/render.sh" --api-key k --api-secret s --namespace ns -o - "$@" 2>/dev/null; }
EU="https://api.eu.endorlabs.com"
for a in cursor codex copilot; do
  # Cursor's file writes "/" as "\/" (see js_cursor), so undo that before matching.
  chk "$a: --api-url is written in front of the bootstrap" \
    "$(rr --agent $a --api-url $EU | sed 's:\\/:/:g' | grep -c "ENDORCTL_DOWNLOAD_API='$EU'")" "1"
  # The bootstrap itself reads ${ENDORCTL_DOWNLOAD_API:-...}; only an assignment counts.
  chk "$a: the default URL adds nothing" "$(rr --agent $a | grep -c 'ENDORCTL_DOWNLOAD_API=')" "0"
done
chk "claude: nothing is inlined, the env block already carries the URL" \
  "$(rr --agent claude --api-url $EU | grep -c 'ENDORCTL_DOWNLOAD_API=')" "0"
chk "claude: the env block carries it" \
  "$(rr --agent claude --api-url $EU | grep -c "\"AGENT_HOOK_ENDOR_API\": \"$EU\"")" "1"
# End to end: the URL survives the JSON escaping and reaches curl.
if command -v python3 >/dev/null 2>&1; then
  newhome
  rr --agent copilot --api-url $EU | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["hooks"]["SessionStart"][0]["command"])' > "$H/session.cmd"
  ( export HOME="$H" PATH="$STUB:$PATH" CURL_LOG="$H/curl.log"; : > "$CURL_LOG"; /bin/sh -c "$(cat "$H/session.cmd")" </dev/null >/dev/null 2>&1 )
  installed
  chk "a rendered Copilot session hook downloads from --api-url" "$(hosts)" "api.eu.endorlabs.com "
fi

# --- examples ---------------------------------------------------------------
# The checked-in examples/ are generated output. Any change to a script must be
# reflected there, or the samples in the README silently drift from reality.
sec "checked-in examples are in sync with the scripts"
GEN="$WORK/gen"; mkdir -p "$GEN"/cursor "$GEN"/claude "$GEN"/codex "$GEN"/copilot "$GEN"/cortexcode
K=PEPE; S=PAPA; NS=spiderman     # demo credentials the samples were built with
r() { "$AG/scripts/render.sh" --api-key $K --api-secret $S --namespace $NS "$@"; }
{
  r --agent cursor -o "$GEN/cursor/hooks.json"
  r --agent claude -o "$GEN/claude/settings.json"
  r --agent codex  -o "$GEN/codex/requirements.toml"
  r --agent cursor --target-os windows -o "$GEN/cursor/hooks.windows.json"
  r --agent claude --target-os windows -o "$GEN/claude/settings.windows.json"
  r --agent codex  --target-os windows -o "$GEN/codex/requirements.windows.toml"
  r --agent copilot -o "$GEN/copilot/policy.json"
  r --agent copilot --target-os windows -o "$GEN/copilot/policy.windows.json"
  r --agent cortexcode -o "$GEN/cortexcode/hooks.json"
  r --agent cortexcode --target-os windows -o "$GEN/cortexcode/hooks.windows.json"
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
           codex/com.openai.codex.mobileconfig \
           copilot/policy.json copilot/policy.windows.json \
           cortexcode/hooks.json cortexcode/hooks.windows.json; do
  if [ ! -f "$GEN/$rel" ]; then echo "  (skipped $rel, needs plutil)"; continue; fi
  if cmp -s "$GEN/$rel" "$AG/examples/$rel"; then ok "examples/$rel"
  else bad "examples/$rel is stale - regenerate it (see README \"Examples\")"; fi
done

# The Cursor CLI reads hooks.json as JSONC and removes comments with a regex before
# parsing, inside strings too. One bare "//" in a command breaks the parse, and the
# CLI then runs no hooks from the file.
sec "the Cursor CLI can parse the rendered hooks.json"
if command -v python3 >/dev/null 2>&1; then
  # The values put both comment forms into the POSIX commands. "???" becomes "/" in
  # the Windows base64, which the demo credentials never produce.
  for os in macos linux windows; do
    f="$GEN/cursor/cli.$os.json"
    "$AG/scripts/render.sh" --agent cursor --target-os "$os" --api-key 'k//k' \
      --api-secret '???' --namespace 'a/*b*/c' -o "$f" >/dev/null 2>&1
    if why=$(python3 - "$f" "$os" 2>&1 <<'PY'
import base64, json, re, sys
raw = open(sys.argv[1]).read()
doc = json.loads(raw)
# What cursor-agent's parseJSONC does before JSON.parse.
cli = re.sub(r'/\*[\s\S]*?\*/', '', re.sub(r'//.*$', '', raw, flags=re.M))
try: seen = json.loads(cli)
except ValueError as e: sys.exit(f'the CLI cannot parse the file ({e})')
if seen != doc: sys.exit('the CLI reads a different document')
# The parse above only covers these inputs. No bare "/" covers every input.
if '/' in re.sub(r'\\.', '', raw): sys.exit('a bare "/" is left in the file')
if '\\/' not in raw: sys.exit('the file has no "/" at all, so nothing was tested')
for ev, hooks in doc['hooks'].items():
    cmd = hooks[0]['command']
    if sys.argv[2] == 'windows':
        cmd = base64.b64decode(cmd.split()[-1]).decode('utf-16-le')
    if 'https://' not in cmd: sys.exit(f'{ev}: the command lost its https:// URL')
PY
    ); then ok "cursor $os: parses to the same commands, no bare slash"
    else bad "cursor $os: $why"; fi
  done
else
  echo "  (skipped, needs python3)"
fi

sec "every embedded hook command is valid shell after JSON/TOML escaping"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$AG" "$WORK" <<'PY'
import json, subprocess, sys, os, plistlib, base64, shutil
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
d = json.load(open(f'{ag}/examples/copilot/policy.json'))
for ev, a in d['hooks'].items(): check(f'copilot:{ev}', a[0]['command'])
d = json.load(open(f'{ag}/examples/cortexcode/hooks.json'))
for ev, a in d['hooks'].items(): check(f'cortexcode:{ev}', a[0]['hooks'][0]['command'])
if tomllib:
    d = tomllib.load(open(f'{ag}/examples/codex/requirements.toml', 'rb'))
    for ev, arr in d['hooks'].items():
        for e in arr: check(f'codex:{ev}', e['hooks'][0]['command'])
# The Claude profile is read with plutil, not plistlib: plistlib's expat parser
# folds CRLF to LF as the XML spec says, so it would pass a CRLF-corrupted
# profile that macOS (which keeps the CR) then fails to run.
pf = f'{ag}/examples/claude/com.anthropic.claudecode.mobileconfig'
if os.path.exists(pf) and shutil.which('plutil'):
    events = plistlib.load(open(pf, 'rb'))['PayloadContent'][0]['hooks'].keys()
    for ev in events:
        kp = f'PayloadContent.0.hooks.{ev}.0.hooks.0.command'
        r = subprocess.run(['plutil', '-extract', kp, 'raw', '-o', '-', pf], capture_output=True, text=True)
        if r.returncode: bad.append((f'profile:{ev}', r.stderr.strip())); continue
        check(f'profile:{ev}', r.stdout)
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

# --- CRLF armor -------------------------------------------------------------
# The Claude profile stores the session command as literal newlines, and a
# profile that picks up CRLF between render and MDM (a Windows checkout, an
# editor, a paste into a web form) reaches the endpoint with the CRs intact:
# plutil -lint accepts it and macOS keeps the CR in the managed preference.
# render.sh wraps the command so it strips CRs from itself before the body is
# parsed. Prove the wrapper does that, on the bytes plutil hands back, under
# every shell an agent might use to run a hook.
sec "a CRLF-converted profile still runs its session hook"
chk "no checked-in example carries a CR" \
  "$(cat "$AG"/examples/*/* | tr -cd '\r' | wc -c | tr -d ' ')" "0"
# The bare bootstrap is what the wrapper protects; without it, CRLF is fatal.
chk "unarmored bootstrap fails to parse with CRLF (the defect the armor covers)" \
  "$({ cat "$BOOT"; echo 'echo AUDIT-RAN'; } | sed 's/$/\r/' | /bin/sh -n 2>/dev/null && echo parses || echo fails)" "fails"
if command -v plutil >/dev/null 2>&1; then
  CRLF="$WORK/crlf.mobileconfig"
  sed 's/$/\r/' "$GEN/claude/com.anthropic.claudecode.mobileconfig" > "$CRLF"
  chk "fixture is CRLF on every line" \
    "$(tr -cd '\r' < "$CRLF" | wc -c | tr -d ' ')" "$(wc -l < "$GEN/claude/com.anthropic.claudecode.mobileconfig" | tr -d ' ')"
  chk "plutil -lint accepts it (which is why the docs check cannot catch this)" \
    "$(plutil -lint "$CRLF" >/dev/null 2>&1 && echo ok || echo rejected)" "ok"
  KP='PayloadContent.0.hooks.SessionStart.0.hooks.0.command'
  plutil -extract "$KP" raw -o "$WORK/crlf.cmd" "$CRLF"
  chk "plutil keeps the CRs inside the command (as macOS does on install)" \
    "$([ "$(tr -cd '\r' < "$WORK/crlf.cmd" | wc -c)" -gt 0 ] && echo yes || echo no)" "yes"
  # Warm HOME with a fake endorctl that reports the audit ran, plus a fresh
  # stamp so the bootstrap takes its no-network path and hands off to the audit.
  H=$(mktemp -d "$WORK/home.XXXXXX"); mkdir -p "$H/.endorctl"; : > "$H/.endorctl/.update-check"
  printf '#!/bin/sh\nlast=; for a; do last=$a; done\nprintf "AUDIT-RAN %%s stdin=%%s\\n" "$last" "$(cat)"\n' > "$H/.endorctl/endorctl"
  chmod +x "$H/.endorctl/endorctl"
  for s in /bin/sh dash bash; do
    command -v "$s" >/dev/null || { echo "  (no $s, skipped)"; continue; }
    out=$(export HOME="$H" AGENT_HOOK_ENDOR_API=x AGENT_HOOK_ENDOR_NAMESPACE=x \
                 AGENT_HOOK_ENDOR_API_CREDENTIALS_KEY=x AGENT_HOOK_ENDOR_API_CREDENTIALS_SECRET=x
          printf '{"event":"SessionStart"}' | "$s" -c "$(cat "$WORK/crlf.cmd")" 2>&1)
    chk "$s -c runs the CRLF command through to the audit, stdin intact" \
      "$out" 'AUDIT-RAN claudecode stdin={"event":"SessionStart"}'
  done
else
  echo "  (profile cases skipped, need plutil)"
fi

# --- Cortex Code --------------------------------------------------------------
# Cortex Code reads hooks only from a file in the user's home, so its runner path
# renders, merges with the user's own hooks, and writes as the user. The checks
# below need python3 to read JSON; the install checks also run without it.
CC="$WORK/cc"; mkdir -p "$CC"
MERGE="$AG/scripts/cortexcode-merge.sh"
INSTALL="$AG/scripts/install-cortexcode.sh"
cc_render() { "$AG/scripts/render.sh" --agent cortexcode --namespace $NS "$@" 2>/dev/null; }
# jget FILE EXPR - print a Python expression over the parsed JSON in d.
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>&1; }

sec "cortexcode render: the five Claude-format events, on every OS"
if command -v python3 >/dev/null 2>&1; then
  for os in macos linux windows; do
    cc_render --api-key $K --api-secret $S --target-os $os -o "$CC/$os.json"
    chk "$os: valid JSON" "$(python3 -m json.tool "$CC/$os.json" >/dev/null 2>&1 && echo yes || echo no)" "yes"
    chk "$os: only the hooks key" "$(jget "$CC/$os.json" 'list(d)')" "['hooks']"
    chk "$os: exactly the five events, in order" "$(jget "$CC/$os.json" 'list(d["hooks"])')" \
      "['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'SessionEnd']"
    chk "$os: every event is one '*' group with one command hook" \
      "$(jget "$CC/$os.json" 'sorted({(len(a), a[0]["matcher"], len(a[0]["hooks"]), a[0]["hooks"][0]["type"], sorted(a[0].keys()) == ["hooks", "matcher"]) for a in d["hooks"].values()})')" \
      "[(1, '*', 1, 'command', True)]"
    chk "$os: every command names ai-audit cortexcode, or is encoded" \
      "$(jget "$CC/$os.json" 'sum(1 for a in d["hooks"].values() if "ai-audit cortexcode" in a[0]["hooks"][0]["command"] or a[0]["hooks"][0]["command"].startswith("powershell -NoProfile -EncodedCommand "))')" "5"
  done
  chk "per-event timeouts, POSIX" "$(jget "$CC/macos.json" '[a[0]["hooks"][0]["timeout"] for a in d["hooks"].values()]')" "[30, 30, 30, 30, 30]"
  chk "per-event timeouts, Windows (the session hook downloads inline)" \
    "$(jget "$CC/windows.json" '[a[0]["hooks"][0]["timeout"] for a in d["hooks"].values()]')" "[1800, 30, 30, 30, 30]"
  chk "macOS and Linux render the same file" "$(cmp -s "$CC/macos.json" "$CC/linux.json" && echo same || echo differ)" "same"
else
  echo "  (skipped, needs python3 to parse JSON)"
fi

sec "cortexcode render: hostile credentials reach endorctl intact"
# Each value carries a quote, a $, a backtick, a ;, a glob, and a space. Run the
# real hook commands under sh against a fake endorctl that prints its argv, one
# per line, and its stdin.
if command -v python3 >/dev/null 2>&1; then
  HK="it's \$HOME; \`id\` *"; HS='p"a\ss $(id)'; HN="ns 'x'"
  "$AG/scripts/render.sh" --agent cortexcode --api-key "$HK" --api-secret "$HS" --namespace "$HN" \
    --env 'ENDOR_X=a b'"'"'c' -o "$CC/hostile.json" 2>/dev/null
  H=$(mktemp -d "$WORK/home.XXXXXX"); mkdir -p "$H/.endorctl"; : > "$H/.endorctl/.update-check"
  printf '#!/bin/sh\nfor a; do printf "%%s\\n" "$a"; done\necho "ENDOR_X=$ENDOR_X"\necho "stdin=$(cat)"\n' > "$H/.endorctl/endorctl"
  chmod +x "$H/.endorctl/endorctl"
  want=$(printf '%s\n' --api https://api.endorlabs.com --namespace "$HN" --api-key "$HK" --api-secret "$HS" \
    ai-audit cortexcode "ENDOR_X=a b'c" 'stdin={"hook_event_name":"X"}')
  for ev in SessionStart UserPromptSubmit PreToolUse; do
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"][sys.argv[2]][0]["hooks"][0]["command"])' \
      "$CC/hostile.json" "$ev" > "$CC/cmd.sh"
    got=$(printf '{"hook_event_name":"X"}' | HOME="$H" /bin/sh "$CC/cmd.sh" 2>&1)
    chk "$ev: argv, --env, and stdin arrive exactly" "$got" "$want"
  done
  "$AG/scripts/render.sh" --agent cortexcode --target-os windows --api-key "$HK" --api-secret "$HS" \
    --namespace "$HN" -o "$CC/hostile.windows.json" 2>/dev/null
  dec=$(python3 -c 'import json,sys,base64; c=json.load(open(sys.argv[1]))["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]; print(base64.b64decode(c.split()[-1]).decode("utf-16-le"))' \
    "$CC/hostile.windows.json")
  chk "Windows: the key is PowerShell single-quoted" \
    "$(printf '%s' "$dec" | grep -cF -- "--api-key 'it''s \$HOME; \`id\` *'")" "1"
else
  echo "  (skipped, needs python3)"
fi

sec "cortexcode merge: Endor's entries are replaced, the user's are kept"
cc_render --api-key $K --api-secret $S -o "$CC/r.json"
cc_render --api-key OLDKEY --api-secret OLDSECRET -o "$CC/old.json"
# A user's file: their own hooks, one group that mixes theirs with a stale Endor
# hook, a hand-written Endor hook with extra spaces, an empty event, and keys
# this merge does not know.
cat > "$CC/foreign.json" <<'EOF'
{
  "theme": "dark",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "echo mine-pre" },
        { "type": "command", "command": "\"$HOME/.endorctl/endorctl\" --api-key 'OLDKEY' ai-audit cortexcode" } ] }
    ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "echo mine-stop" } ] } ],
    "SessionStart": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "endorctl ai-audit   cortexcode", "timeout": 30 } ] } ],
    "Notification": [],
    "PostToolUse": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "endorctl ai-audit claudecode" } ] } ]
  },
  "zz": { "n": 1.5, "s": "café ✓" }
}
EOF
# mrg EXISTING OUT - run the wrapper and echo its exit status.
mrg() { sh "$MERGE" "$1" "$CC/r.json" "$2" 2>"$CC/merge.err"; echo $?; }
if command -v python3 >/dev/null 2>&1 || command -v osascript >/dev/null 2>&1; then
  chk "a file with only Endor's (stale) hooks becomes the rendered file, byte for byte" \
    "$(mrg "$CC/old.json" "$CC/o1.json"):$(cmp -s "$CC/o1.json" "$CC/r.json" && echo same || echo differ)" "0:same"
  printf ' \n\t\n' > "$CC/blank.json"
  chk "an empty file becomes the rendered file" \
    "$(mrg "$CC/blank.json" "$CC/o2.json"):$(cmp -s "$CC/o2.json" "$CC/r.json" && echo same || echo differ)" "0:same"
  # A rendered file in another layout proves Endor-only output is the rendered
  # bytes, not a re-serialization that happens to match render.sh's layout.
  printf '{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"x ai-audit cortexcode"}]}]}}' > "$CC/compact.json"
  chk "Endor-only output is the rendered bytes, whatever their layout" \
    "$(sh "$MERGE" "$CC/old.json" "$CC/compact.json" "$CC/oc.json" 2>/dev/null; echo $?):$(cmp -s "$CC/oc.json" "$CC/compact.json" && echo same || echo differ)" "0:same"
  printf '{}' > "$CC/emptyobj.json"
  chk "an empty object becomes the rendered file" \
    "$(mrg "$CC/emptyobj.json" "$CC/o3.json"):$(cmp -s "$CC/o3.json" "$CC/r.json" && echo same || echo differ)" "0:same"
  chk "a foreign file merges" "$(mrg "$CC/foreign.json" "$CC/m1.json")" "0"
  if command -v python3 >/dev/null 2>&1; then
    chk "top-level keys kept, in place" "$(jget "$CC/m1.json" 'list(d)')" "['theme', 'hooks', 'zz']"
    chk "unknown values kept exactly" "$(jget "$CC/m1.json" 'd["zz"]')" "{'n': 1.5, 's': 'café ✓'}"
    chk "the user's events first, then Endor's new ones" "$(jget "$CC/m1.json" 'list(d["hooks"])')" \
      "['PreToolUse', 'Stop', 'Notification', 'PostToolUse', 'SessionStart', 'UserPromptSubmit', 'SessionEnd']"
    chk "the user's hooks all survive" \
      "$(jget "$CC/m1.json" '[h["command"] for a in d["hooks"].values() for g in a for h in g["hooks"] if "ai-audit cortexcode" not in h["command"]]')" \
      "['echo mine-pre', 'echo mine-stop', 'endorctl ai-audit claudecode']"
    chk "the mixed group keeps its matcher and loses only the Endor hook" \
      "$(jget "$CC/m1.json" 'd["hooks"]["PreToolUse"][0]')" \
      "{'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'echo mine-pre'}]}"
    chk "an event that was empty stays" "$(jget "$CC/m1.json" 'd["hooks"]["Notification"]')" "[]"
    chk "exactly one current Endor hook per event" \
      "$(jget "$CC/m1.json" 'sorted((e, sum(1 for g in a for h in g["hooks"] if "ai-audit" in h["command"] and "cortexcode" in h["command"])) for e, a in d["hooks"].items() if e in ("SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","SessionEnd"))')" \
      "[('PostToolUse', 1), ('PreToolUse', 1), ('SessionEnd', 1), ('SessionStart', 1), ('UserPromptSubmit', 1)]"
    chk "the Endor hooks are the rendered ones" \
      "$(python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))["hooks"]; r=json.load(open(sys.argv[2]))["hooks"]
print(all(m[e][-len(g):] == g for e, g in r.items()))' "$CC/m1.json" "$CC/r.json")" "True"
    chk "no stale credential left" "$(grep -c OLDKEY "$CC/m1.json")" "0"
  fi
  chk "a second run is byte-identical" \
    "$(mrg "$CC/m1.json" "$CC/m2.json"):$(cmp -s "$CC/m1.json" "$CC/m2.json" && echo same || echo differ)" "0:same"
  cc_render --api-key NEWKEY --api-secret $S -o "$CC/r2.json"
  sh "$MERGE" "$CC/m1.json" "$CC/r2.json" "$CC/m3.json" 2>/dev/null
  chk "a credential change replaces Endor's hooks, not duplicates them" \
    "$(grep -c 'ai-audit cortexcode' "$CC/m3.json"):$(grep -c NEWKEY "$CC/m3.json"):$(grep -c "'PEPE'" "$CC/m3.json")" "5:5:0"
  for bad in '{"hooks": ' '[1, 2]' '{"hooks": []}' '{"hooks": {"PreToolUse": {}}}' '{"hooks": {}, "x": NaN}'; do
    printf '%s' "$bad" > "$CC/bad.json"; rm -f "$CC/bad.out"
    chk "refused, nothing written: $bad" "$(mrg "$CC/bad.json" "$CC/bad.out"):$(have "$CC/bad.out")" "2:no"
  done
else
  echo "  (skipped, needs python3 or osascript)"
fi
# No engine: the shortcuts still work, anything else is refused.
NOENG="$WORK/noeng"; mkdir -p "$NOENG"
for t in sh cat cmp grep rm dirname; do ln -sf "$(command -v $t)" "$NOENG/$t"; done
chk "no JSON engine: a foreign file is refused with its own status" \
  "$(PATH="$NOENG" sh "$MERGE" "$CC/foreign.json" "$CC/r.json" "$CC/ne.out" 2>/dev/null; echo $?):$(have "$CC/ne.out")" "3:no"
chk "no JSON engine: an already-current file still passes" \
  "$(PATH="$NOENG" sh "$MERGE" "$CC/r.json" "$CC/r.json" "$CC/ne2.out" 2>/dev/null; echo $?)" "0"

sec "cortexcode merge: the macOS engine agrees with the Linux engine"
# cortexcode-merge.js runs under JXA on a Mac. Its merge function is plain
# JavaScript, so node runs it here on the same inputs.
if command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  for f in old foreign m1 emptyobj; do
    node -e 'const fs=require("fs"); const [js, e, r] = process.argv.slice(1);
      const merge = new Function(fs.readFileSync(js, "utf8") + "; return mergeCortexHooks;")();
      process.stdout.write(merge(fs.readFileSync(e, "utf8"), fs.readFileSync(r, "utf8")));' \
      "$AG/scripts/cortexcode-merge.js" "$CC/$f.json" "$CC/r.json" > "$CC/$f.node.json" 2>&1
    python3 -I "$AG/scripts/cortexcode-merge.py" "$CC/$f.json" "$CC/r.json" "$CC/$f.py.json"
    chk "$f: same bytes from both engines" "$(cmp -s "$CC/$f.node.json" "$CC/$f.py.json" && echo same || echo differ)" "same"
  done
  for bad in '{"hooks": ' '[1, 2]' '{"hooks": []}' '{"hooks": {"PreToolUse": {}}}'; do
    printf '%s' "$bad" > "$CC/bad.json"
    chk "node refuses too: $bad" "$(node -e 'const fs=require("fs"); const [js, e, r] = process.argv.slice(1);
      const merge = new Function(fs.readFileSync(js, "utf8") + "; return mergeCortexHooks;")();
      try { merge(fs.readFileSync(e, "utf8"), fs.readFileSync(r, "utf8")); console.log("merged"); } catch (x) { console.log("refused"); }' \
      "$AG/scripts/cortexcode-merge.js" "$CC/bad.json" "$CC/r.json")" "refused"
  done
else
  echo "  (skipped, needs node and python3)"
fi

sec "cortexcode merge: a second run is byte-identical when a user event is empty"
# An empty array for one of Endor's events used to stay in place on the first
# run and move to the end on the second, so every run rewrote the file.
if command -v python3 >/dev/null 2>&1 || command -v osascript >/dev/null 2>&1; then
  have_node=$(command -v node >/dev/null 2>&1 && echo yes || echo no)
  G='[{"hooks": [{"type": "command", "command": "echo mine-stop"}]}]'
  for ev in SessionStart UserPromptSubmit PreToolUse PostToolUse SessionEnd Notification Stop; do
    i=0
    for shape in "{\"hooks\": {\"$ev\": []}}" "{\"hooks\": {\"$ev\": [], \"Stop\": $G}}" "{\"hooks\": {\"Stop\": $G, \"$ev\": []}}"; do
      i=$((i + 1))
      printf '%s\n' "$shape" > "$CC/st.json"
      sh "$MERGE" "$CC/st.json" "$CC/r.json" "$CC/st1.json" 2>/dev/null
      sh "$MERGE" "$CC/st1.json" "$CC/r.json" "$CC/st2.json" 2>/dev/null
      got=$(cmp -s "$CC/st1.json" "$CC/st2.json" && echo stable || echo rewritten)
      if [ "$have_node" = yes ]; then
        node -e 'const fs=require("fs"); const [js, e, r, o1, o2] = process.argv.slice(1);
          const merge = new Function(fs.readFileSync(js, "utf8") + "; return mergeCortexHooks;")();
          const r1 = merge(fs.readFileSync(e, "utf8"), fs.readFileSync(r, "utf8"));
          fs.writeFileSync(o1, r1); fs.writeFileSync(o2, merge(r1, fs.readFileSync(r, "utf8")));' \
          "$AG/scripts/cortexcode-merge.js" "$CC/st.json" "$CC/r.json" "$CC/stn1.json" "$CC/stn2.json" 2>/dev/null
        if cmp -s "$CC/stn1.json" "$CC/st1.json" && cmp -s "$CC/stn2.json" "$CC/st2.json"; then
          got="$got:engines-agree"
        else
          got="$got:engines-differ"
        fi
      else
        got="$got:engines-agree"
      fi
      chk "$ev, shape $i: run 2 == run 1, and node == python on both runs" "$got" "stable:engines-agree"
    done
  done
else
  echo "  (skipped, needs python3 or osascript)"
fi

sec "cortexcode install: who the targets are"
# Stubs stand in for the OS tools the installer asks: uname, stat (macOS console
# owner), dscl, loginctl, who, getent, and id for users this machine lacks.
CS="$WORK/ccstub"; mkdir -p "$CS"
REAL_ID=$(command -v id)
cat > "$CS/uname" <<'EOF'
#!/bin/sh
echo "$STUB_OS"
EOF
cat > "$CS/stat" <<'EOF'
#!/bin/sh
echo "$STUB_CONSOLE"
EOF
cat > "$CS/dscl" <<'EOF'
#!/bin/sh
case "$3" in
  /Users/alice) echo "NFSHomeDirectory: $STUB_HOMES/alice" ;;
  /Users/carol) printf 'NFSHomeDirectory:\n %s\n' "$STUB_HOMES/Carol Smith" ;;
esac
EOF
cat > "$CS/loginctl" <<'EOF'
#!/bin/sh
[ -n "${STUB_NO_LOGIND:-}" ] && { echo "Failed to connect to bus" >&2; exit 1; }
printf '%s\n' "  3 1001 alice seat0 tty2" "  4  120 gdm   seat0 tty1" "  5 1002 bob         pts/1" \
              "  6 1001 alice       pts/2" "  7    0 root        pts/3"
EOF
cat > "$CS/who" <<'EOF'
#!/bin/sh
printf '%s\n' "dave     pts/0        2026-11-15 10:00" "root     pts/1        2026-11-15 10:01"
EOF
cat > "$CS/getent" <<'EOF'
#!/bin/sh
case "$2" in
  alice) echo "alice:x:1001:1001::$STUB_HOMES/alice:/bin/bash" ;;
  bob)   echo "bob:x:1002:1002::$STUB_HOMES/bob:/bin/bash" ;;
  dave)  echo "dave:x:1003:1003::$STUB_HOMES/dave:/bin/sh" ;;
  gdm)   echo "gdm:x:120:125::/var/lib/gdm3:/bin/false" ;;
  root)  echo "root:x:0:0::/root:/bin/sh" ;;
  *) exit 2 ;;
esac
EOF
cat > "$CS/id" <<EOF
#!/bin/sh
if [ "\$1" = -u ] && [ \$# -eq 2 ]; then
  case "\$2" in alice) echo 1001; exit ;; bob) echo 1002; exit ;; carol) echo 1004; exit ;; dave) echo 1003; exit ;; esac
fi
exec "$REAL_ID" "\$@"
EOF
chmod +x "$CS"/*
export STUB_HOMES="$WORK/homes"
mkdir -p "$STUB_HOMES/alice" "$STUB_HOMES/bob" "$STUB_HOMES/dave" "$STUB_HOMES/Carol Smith"
inst() { PATH="$CS:$PATH" sh "$INSTALL" "$@" "$CC/r.json"; }
chk "macOS: the console user, home from dscl" \
  "$(STUB_OS=Darwin STUB_CONSOLE=alice inst --dry-run 2>/dev/null)" "alice $STUB_HOMES/alice/.snowflake/cortex/hooks.json"
chk "macOS: a home path with a space (dscl wraps it)" \
  "$(STUB_OS=Darwin STUB_CONSOLE=carol inst --dry-run 2>/dev/null)" "carol $STUB_HOMES/Carol Smith/.snowflake/cortex/hooks.json"
for c in loginwindow root _mbsetupuser ''; do
  out=$(STUB_OS=Darwin STUB_CONSOLE=$c inst --dry-run 2>&1; echo "rc=$?")
  chk "macOS: console '$c' is no one, exit 0 with a message" \
    "$(printf '%s' "$out" | grep -c 'no logged-in user'):$(printf '%s' "$out" | tail -1)" "1:rc=0"
done
chk "Linux: each session user once, system and root sessions skipped" \
  "$(STUB_OS=Linux inst --dry-run 2>/dev/null | tr '\n' '|')" \
  "alice $STUB_HOMES/alice/.snowflake/cortex/hooks.json|bob $STUB_HOMES/bob/.snowflake/cortex/hooks.json|"
chk "Linux without logind: utmp users" \
  "$(STUB_OS=Linux STUB_NO_LOGIND=1 inst --dry-run 2>/dev/null)" "dave $STUB_HOMES/dave/.snowflake/cortex/hooks.json"
chk "TARGET_USER overrides detection" \
  "$(STUB_OS=Linux inst --dry-run --users "bob" 2>/dev/null)" "bob $STUB_HOMES/bob/.snowflake/cortex/hooks.json"
chk "a ~/ DEST is the target user's home" \
  "$(STUB_OS=Linux inst --dry-run --users "bob" --dest '~/.cortex/hooks.json' 2>/dev/null)" "bob $STUB_HOMES/bob/.cortex/hooks.json"
chk "an absolute DEST is used as is" \
  "$(STUB_OS=Linux inst --dry-run --users "bob" --dest /srv/x/hooks.json 2>/dev/null)" "bob /srv/x/hooks.json"
chk "a relative DEST is refused" \
  "$(STUB_OS=Linux inst --dry-run --users bob --dest rel/hooks.json >/dev/null 2>&1; echo $?)" "1"
chk "a missing home is skipped, not an error" \
  "$(STUB_OS=Linux STUB_HOMES=/nonexistent inst --dry-run --users bob 2>&1; echo "rc=$?")" \
  "install-cortexcode.sh: skipped bob: home /nonexistent/bob does not exist
rc=0"

sec "cortexcode install: the file lands as the user, mode 600, merged"
# The target is the user running the tests, so no privilege change is needed.
ME=$(id -un)
U1="$WORK/u1"; mkdir -p "$U1"; D1="$U1/.snowflake/cortex/hooks.json"
ins() { sh "$INSTALL" --users "$ME" --dest "$1" "$2" 2>"$CC/install.err"; echo $?; }
modeof() { ls -ld "$1" | awk '{print $1}'; }
chk "absent: installed" "$(ins "$D1" "$CC/r.json")" "0"
chk "content is the rendered file" "$(cmp -s "$D1" "$CC/r.json" && echo same || echo differ)" "same"
chk "file mode 600" "$(modeof "$D1")" "-rw-------"
chk "created directories are private" "$(modeof "$U1/.snowflake"):$(modeof "$U1/.snowflake/cortex")" "drwx------:drwx------"
chk "owned by the target user" "$(ls -ln "$D1" | awk '{print $3}')" "$(id -u)"
ino=$(ls -i "$D1" | awk '{print $1}')
chk "unchanged: second run exits 0" "$(ins "$D1" "$CC/r.json")" "0"
chk "unchanged: the file is not replaced" "$(ls -i "$D1" | awk '{print $1}')" "$ino"
chk "no temp files left" "$(ls -A "$U1/.snowflake/cortex" | tr '\n' ' ')" "hooks.json "
if command -v python3 >/dev/null 2>&1 || command -v osascript >/dev/null 2>&1; then
  cp "$CC/foreign.json" "$D1"
  chk "foreign: merged in place" "$(ins "$D1" "$CC/r.json")" "0"
  chk "foreign: the result is the merge" "$(cmp -s "$D1" "$CC/m1.json" && echo same || echo differ)" "same"
fi
printf '{"hooks": {"PreToolUse": [ broken' > "$D1"; cp "$D1" "$CC/broken.copy"
chk "malformed: exit non-zero" "$(ins "$D1" "$CC/r.json")" "1"
chk "malformed: the file is untouched" "$(cmp -s "$D1" "$CC/broken.copy" && echo same || echo differ)" "same"
chk "malformed: the error names the user and the file" "$(grep -c "error: $ME: did not update $D1" "$CC/install.err")" "1"
# The target is valid JSON, so only the symlink check can stop the write.
printf '{"victim": 1}\n' > "$WORK/victim"; rm -f "$D1"; ln -s "$WORK/victim" "$D1"
chk "symlink at the file: exit non-zero" "$(ins "$D1" "$CC/r.json")" "1"
chk "symlink at the file: its target is untouched" "$(cat "$WORK/victim")" '{"victim": 1}'
chk "symlink at the file: the link is left as it is" "$([ -L "$D1" ] && echo link || echo replaced)" "link"
rm -f "$D1"; mkdir "$D1"
chk "a directory at the file: exit non-zero" "$(ins "$D1" "$CC/r.json")" "1"
rmdir "$D1"
# The user edits the file while the merge runs: a stub sh appends to it just
# before the merge starts. The edit must survive, and the run is not a failure.
if command -v python3 >/dev/null 2>&1 || command -v osascript >/dev/null 2>&1; then
  RS="$WORK/racestub"; mkdir -p "$RS"
  printf '#!/bin/sh
case "$1" in *cortexcode-merge.sh) printf " " >> "$RACE_FILE" ;; esac
exec /bin/sh "$@"
' > "$RS/sh"
  chmod +x "$RS/sh"
  cp "$CC/foreign.json" "$D1"; printf ' ' > "$CC/space"; cat "$CC/foreign.json" "$CC/space" > "$CC/edited.json"
  chk "changed during the run: exit 0" \
    "$(RACE_FILE="$D1" PATH="$RS:$PATH" sh "$INSTALL" --users "$ME" --dest "$D1" "$CC/r.json" 2>"$CC/install.err"; echo $?)" "0"
  chk "changed during the run: the user's edit is kept, nothing written" \
    "$(cmp -s "$D1" "$CC/edited.json" && echo kept || echo overwritten)" "kept"
  chk "changed during the run: says the next run retries" "$(grep -c 'changed during this run' "$CC/install.err")" "1"
  chk "the next run merges the edit" "$(ins "$D1" "$CC/r.json"):$(grep -c 'echo mine-pre' "$D1")" "0:1"
  rm -f "$D1"
fi
chk "an unknown user is skipped and the other is still written" \
  "$(sh "$INSTALL" --users "$ME no-such-user-xyz" --dest "$U1/two.json" "$CC/r.json" 2>/dev/null; echo $?):$(have "$U1/two.json")" "0:yes"

sec "cortexcode install: a hostile user cannot stall the run or feed it unbounded input"
# alice and bob are stub names for the user running the tests, each with their
# own home, so a two-user run needs no root. alice's file is the hostile one;
# bob must still get his file, and the run must report alice as failed.
LS="$WORK/twostub"; mkdir -p "$LS"; LH="$WORK/twohomes"
printf '#!/bin/sh\necho Linux\n' > "$LS/uname"
cat > "$LS/getent" <<EOF
#!/bin/sh
case "\$2" in alice|bob) echo "\$2:x:$(id -u):$(id -g)::$LH/\$2:/bin/sh" ;; *) exit 2 ;; esac
EOF
cat > "$LS/id" <<EOF
#!/bin/sh
if [ "\$1" = -u ] && [ \$# -eq 2 ]; then case "\$2" in alice|bob) echo $(id -u); exit ;; esac; fi
exec "$REAL_ID" "\$@"
EOF
chmod +x "$LS"/*
AF="$LH/alice/.snowflake/cortex/hooks.json"; BF="$LH/bob/.snowflake/cortex/hooks.json"
two() {  # two - fresh homes; set up alice's file before calling run_two
  rm -rf "$LH"; mkdir -p "$LH/alice/.snowflake/cortex" "$LH/bob"
}
run_two() {  # prints "<exit>:<seconds>"; stderr to install.err
  _s=$(date +%s)
  PATH="$LS:$PATH" sh "$INSTALL" --users "alice bob" --timeout 2 "$CC/r.json" 2>"$CC/install.err"
  echo "$?:$(( $(date +%s) - _s ))"
}
fast() { case "$1" in 1:[0-9]) echo "failed, bounded" ;; *) echo "got $1" ;; esac; }

two; mkfifo "$AF"
chk "FIFO: alice fails without blocking" "$(fast "$(run_two)")" "failed, bounded"
chk "FIFO: refused as not a regular file" "$(grep -c 'alice: could not read' "$CC/install.err"):$(grep -c 'is not a regular file' "$CC/install.err")" "1:1"
chk "FIFO: bob still gets his file" "$(cmp -s "$BF" "$CC/r.json" && echo same || echo missing)" "same"
chk "FIFO: alice's FIFO is left as it is" "$([ -p "$AF" ] && echo fifo || echo replaced)" "fifo"

two; { printf '{"hooks": {}, "pad": "'; head -c 1048576 /dev/zero | tr '\0' x; printf '"}\n'; } > "$AF"
cp "$AF" "$CC/big.copy"
chk "over 1 MiB: alice fails" "$(run_two | cut -d: -f1)" "1"
chk "over 1 MiB: says so" "$(grep -c 'alice: .* is larger than 1048576 bytes' "$CC/install.err")" "1"
chk "over 1 MiB: alice's file is untouched" "$(cmp -s "$AF" "$CC/big.copy" && echo same || echo changed)" "same"
chk "over 1 MiB: bob still gets his file" "$(cmp -s "$BF" "$CC/r.json" && echo same || echo missing)" "same"

# A write lease is a hang any user can cause on their own file: another open()
# of it blocks until the holder lets go, up to /proc/sys/fs/lease-break-time
# (45s by default). The holder ignores the break signal, as an attacker would.
# lease FILE - start a holder in the background and wait until it holds.
lease() {
  python3 -c 'import fcntl, os, signal, sys, time
signal.signal(signal.SIGIO, signal.SIG_IGN)
fd = os.open(sys.argv[1], os.O_WRONLY)
fcntl.fcntl(fd, 1024, fcntl.F_WRLCK)  # F_SETLEASE
print("held", flush=True)
time.sleep(60)' "$1" > "$CC/lease.out" 2>&1 &
  holder=$!
  for _ in $(seq 1 50); do [ -s "$CC/lease.out" ] && break; sleep 0.1; done
  [ "$(cat "$CC/lease.out")" = held ]
}
if [ "$(uname -s)" = Linux ] && command -v python3 >/dev/null 2>&1; then
  two; cp "$CC/foreign.json" "$AF"
  if lease "$AF"; then
    out=$(run_two)
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    chk "blocked reader: alice fails within the time limit" "$(fast "$out")" "failed, bounded"
    chk "blocked reader: says it timed out" "$(grep -c 'alice: reading .* took longer than 2s' "$CC/install.err")" "1"
    chk "blocked reader: alice's file is untouched" "$(cmp -s "$AF" "$CC/foreign.json" && echo same || echo changed)" "same"
    chk "blocked reader: bob still gets his file" "$(cmp -s "$BF" "$CC/r.json" && echo same || echo missing)" "same"
    # The lease holds the open of the file long enough to SIGSTOP the step, as a
    # user can do to their own process. A stopped process ignores TERM, so
    # only the KILL that follows ends the step.
    two; cp "$CC/foreign.json" "$AF"
    if lease "$AF"; then
      ( for _ in $(seq 1 40); do
          p=$(pgrep -u "$(id -u)" -f 'endor-step-[0-9]' | head -1)
          [ -n "$p" ] && { kill -STOP "$p"; echo "$p" > "$CC/stopped"; break; }
          sleep 0.05
        done ) &
      stopper=$!; rm -f "$CC/stopped"
      out=$(run_two)
      wait "$stopper"; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
      chk "stopped reader: it was stopped" "$(have "$CC/stopped")" "yes"
      chk "stopped reader: alice fails within the time limit" "$(fast "$out")" "failed, bounded"
      chk "stopped reader: bob still gets his file" "$(cmp -s "$BF" "$CC/r.json" && echo same || echo missing)" "same"
    else
      kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    fi
  else
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    echo "  (blocked-reader cases skipped, this filesystem does not grant leases: $(cat "$CC/lease.out"))"
  fi
else
  echo "  (blocked-reader cases skipped, need Linux leases and python3)"
fi

sec "cortexcode install as root: a planted symlink reaches only what the user can"
# Needs root and a way to act as another user. The target is 'nobody', with a
# home under a directory that nobody can only traverse.
if [ "$(id -u)" = 0 ] && id -u nobody >/dev/null 2>&1 && \
   { command -v runuser >/dev/null 2>&1 || command -v sudo >/dev/null 2>&1; }; then
  chmod 711 "$WORK"
  NBH="$WORK/nbhome"; mkdir -p "$NBH"; chown nobody "$NBH"
  chk "written as nobody" "$(sh "$INSTALL" --users nobody --dest "$NBH/.snowflake/cortex/hooks.json" "$CC/r.json" 2>/dev/null; echo $?)" "0"
  chk "owner nobody, mode 600" \
    "$(ls -ln "$NBH/.snowflake/cortex/hooks.json" | awk '{print $3}'):$(modeof "$NBH/.snowflake/cortex/hooks.json")" \
    "$(id -u nobody):-rw-------"
  chk "directories owned by nobody" \
    "$(ls -lnd "$NBH/.snowflake" "$NBH/.snowflake/cortex" | awk '{print $3}' | sort -u)" "$(id -u nobody)"
  # nobody points its .snowflake at a directory only root can write.
  ROOTDIR="$WORK/rootonly"; mkdir -p "$ROOTDIR"; chmod 755 "$ROOTDIR"
  NBH2="$WORK/nbhome2"; mkdir -p "$NBH2"; chown nobody "$NBH2"
  ln -s "$ROOTDIR" "$NBH2/.snowflake"; chown -h nobody "$NBH2/.snowflake"
  chk "symlinked directory to a root-only place: refused" \
    "$(sh "$INSTALL" --users nobody --dest "$NBH2/.snowflake/cortex/hooks.json" "$CC/r.json" 2>/dev/null; echo $?)" "1"
  chk "nothing was created in the root-only directory" "$(ls -A "$ROOTDIR" | wc -l | tr -d ' ')" "0"
  mkdir -p "$ROOTDIR/cortex"; printf '{"root": true}\n' > "$ROOTDIR/cortex/hooks.json"
  chk "a root-owned file behind the symlinked directory: refused" \
    "$(sh "$INSTALL" --users nobody --dest "$NBH2/.snowflake/cortex/hooks.json" "$CC/r.json" 2>/dev/null; echo $?)" "1"
  chk "and it is untouched, with no temp file beside it" \
    "$(cat "$ROOTDIR/cortex/hooks.json"):$(ls -A "$ROOTDIR/cortex" | wc -l | tr -d ' ')" '{"root": true}:1'
  # The same hang through runuser or sudo: a TERM alone does not end them while
  # their child waits, so the KILL that follows must.
  NBH3="$WORK/nbhome3"; mkdir -p "$NBH3"; cp "$CC/foreign.json" "$NBH3/hooks.json"; chown -R nobody "$NBH3"
  if command -v python3 >/dev/null 2>&1 && lease "$NBH3/hooks.json"; then
    s=$(date +%s)
    rc=$(sh "$INSTALL" --users nobody --timeout 2 --dest "$NBH3/hooks.json" "$CC/r.json" 2>"$CC/install.err"; echo $?)
    e=$(date +%s); kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    chk "blocked reader as nobody: fails within the time limit" "$rc:$([ $((e - s)) -le 9 ] && echo bounded || echo "took $((e - s))s")" "1:bounded"
    chk "blocked reader as nobody: file untouched" "$(cmp -s "$NBH3/hooks.json" "$CC/foreign.json" && echo same || echo changed)" "same"
    if lease "$NBH3/hooks.json"; then
      ( for _ in $(seq 1 40); do
          p=$(pgrep -u nobody -f 'endor-step-[0-9]' | head -1)
          [ -n "$p" ] && { kill -STOP "$p"; echo "$p" > "$CC/stopped"; break; }
          sleep 0.05
        done ) &
      stopper=$!; rm -f "$CC/stopped"
      s=$(date +%s)
      rc=$(sh "$INSTALL" --users nobody --timeout 2 --dest "$NBH3/hooks.json" "$CC/r.json" 2>/dev/null; echo $?)
      e=$(date +%s); wait "$stopper"; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
      chk "stopped reader as nobody: stopped, and the run still ends in time" \
        "$(have "$CC/stopped"):$rc:$([ $((e - s)) -le 9 ] && echo bounded || echo "took $((e - s))s")" "yes:1:bounded"
    fi
    # An MDM reads the installer's output to EOF, so that output must close when
    # the installer exits, even when the user keeps a step stopped. Through each
    # wrapper: sudo is the one used when runuser is not on PATH.
    NOSBIN=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v sbin | paste -sd: -)
    for wrap in runuser sudo; do
      WP=$PATH; [ "$wrap" = sudo ] && WP=$NOSBIN
      if ! PATH=$WP command -v "$wrap" >/dev/null 2>&1 || { [ "$wrap" = sudo ] && PATH=$WP command -v runuser >/dev/null 2>&1; }; then
        echo "  ($wrap case skipped, cannot select it)"; continue
      fi
      cp "$CC/foreign.json" "$NBH3/hooks.json"; chown nobody "$NBH3/hooks.json"
      lease "$NBH3/hooks.json" || { kill "$holder" 2>/dev/null; continue; }
      rm -f "$CC/stopped" "$CC/piped.done"
      ( for _ in $(seq 1 40); do
          p=$(pgrep -u nobody -f 'endor-step-[0-9]' | head -1)
          [ -n "$p" ] && { kill -STOP "$p"; echo "$p" > "$CC/stopped"; break; }
          sleep 0.05
        done ) &
      stopper=$!
      ( PATH=$WP sh "$INSTALL" --users nobody --timeout 2 --dest "$NBH3/hooks.json" "$CC/r.json" 2>&1 \
          | cat > "$CC/piped.out"; : > "$CC/piped.done" ) &
      piper=$!
      for _ in $(seq 1 60); do [ -f "$CC/piped.done" ] && break; sleep 0.25; done
      wait "$stopper"; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
      sp=$(cat "$CC/stopped" 2>/dev/null)
      chk "$wrap: a step was stopped" "$([ -n "$sp" ] && echo yes || echo no)" "yes"
      chk "$wrap: the output closes once the installer exits" "$(have "$CC/piped.done")" "yes"
      # Dead but not yet reaped (a zombie) counts as gone.
      for _ in $(seq 1 20); do case "$(ps -o stat= -p "$sp" 2>/dev/null)" in ''|Z*) break ;; esac; sleep 0.1; done
      chk "$wrap: the stopped step is gone" "$(case "$(ps -o stat= -p "$sp" 2>/dev/null)" in ''|Z*) echo gone ;; *) echo alive ;; esac)" "gone"
      chk "$wrap: no process of any step is left" "$(ps -u nobody -o args= | grep -c 'endor-step-[0-9]')" "0"
      chk "$wrap: the failure is in the output" "$(grep -c 'error: nobody: reading .* took longer than 2s' "$CC/piped.out")" "1"
      # Leave nothing behind for the rest of the suite if this failed.
      pkill -CONT -u nobody -f 'endor-step-[0-9]' 2>/dev/null; pkill -KILL -u nobody -f 'endor-step-[0-9]' 2>/dev/null
      [ -n "$sp" ] && { kill -CONT "$sp"; kill -KILL "$sp"; } 2>/dev/null
      kill "$piper" 2>/dev/null; wait "$piper" 2>/dev/null
    done
    # dash ends a subshell under errexit when kill names a PID that is gone. The
    # user can arrange that: stop the step, then keep spawning short-lived
    # processes that carry its tag, so the watchdog lists PIDs that vanish
    # before the signal. The watchdog must still kill the step.
    if command -v dash >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
      cp "$CC/foreign.json" "$NBH3/hooks.json"; chown nobody "$NBH3/hooks.json"
      if lease "$NBH3/hooks.json"; then
        rm -f "$CC/stopped" "$CC/flood.done"
        ( dash "$INSTALL" --users nobody --timeout 2 --dest "$NBH3/hooks.json" "$CC/r.json" >/dev/null 2>&1
          : > "$CC/flood.done" ) &
        runner_pid=$!
        sp=""
        for _ in $(seq 1 40); do
          sp=$(pgrep -u nobody -f 'endor-step-[0-9]' | head -1)
          [ -n "$sp" ] && { kill -STOP "$sp"; break; }
          sleep 0.05
        done
        tag=$(ps -o args= -p "$sp" 2>/dev/null | grep -o 'endor-step-[0-9]*-[0-9]*' | head -1)
        # Each lives ~50ms, long enough for ps to list it. Three loops spawn them
        # back to back, so some listed ones are gone before the signal on nearly
        # every pass.
        runuser -u nobody -- env T="$tag" /bin/sh -c 'for i in 1 2 3; do
          ( while :; do sh -c "sleep 0.05" "$T" & done ) &
        done; wait' >/dev/null 2>&1 &
        flooder=$!
        s=$(date +%s)
        for _ in $(seq 1 48); do [ -f "$CC/flood.done" ] && break; sleep 0.25; done
        e=$(date +%s)
        kill -KILL "$flooder" 2>/dev/null; pkill -KILL -u nobody -f 'while :; do sh -c' 2>/dev/null; sleep 0.3
        kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
        for _ in $(seq 1 20); do case "$(ps -o stat= -p "$sp" 2>/dev/null)" in ''|Z*) break ;; esac; sleep 0.1; done
        chk "dash, tag flood: the step was stopped and its tag found" "$([ -n "$sp" ] && [ -n "$tag" ] && echo yes || echo no)" "yes"
        chk "dash, tag flood: the run still ends within the limit" \
          "$([ -f "$CC/flood.done" ] && echo "ended" || echo "still running after $((e - s))s")" "ended"
        chk "dash, tag flood: the stopped step is gone" \
          "$(case "$(ps -o stat= -p "$sp" 2>/dev/null)" in ''|Z*) echo gone ;; *) echo alive ;; esac)" "gone"
        # Leave nothing behind for the rest of the suite if this failed.
        pkill -CONT -u nobody -f 'endor-step-[0-9]' 2>/dev/null; pkill -KILL -u nobody -f 'endor-step-[0-9]' 2>/dev/null
        kill "$runner_pid" 2>/dev/null; pkill -KILL -f "dash $INSTALL" 2>/dev/null; wait "$runner_pid" 2>/dev/null
      else
        kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
      fi
    else
      echo "  (dash tag-flood case skipped, needs dash and runuser)"
    fi
  else
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    echo "  (blocked-reader case skipped, no lease)"
  fi
  chmod 700 "$WORK"
else
  echo "  (skipped, needs root and runuser or sudo)"
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
