#!/usr/bin/env bash
# Drives the ~/.bundle/config helpers from lib/common.sh against fixture files
# (the generated installer itself needs root + a console user), then checks
# the generator wires Ruby / Bundler in. When Bundler >= 2 is installed,
# `bundle config get --parseable` validates what Bundler actually resolves.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF_DIR="$(cd "$TEST_DIR/.." && pwd)"
MIRROR_URL="https://factory.endorlabs.com/v1/namespaces/ci-smoke/firewall/gem/"
HOST_KEY="FACTORY__ENDORLABS__COM"
CREDS="fakeuser:fakesecret"
CORP_URL="https://artifactory.example.com/api/gems/rubygems/"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
OWNER=$(id -un); GROUP=$(id -gn)

# Both are read by the sourced common.sh functions.
# shellcheck disable=SC2034
DRY_RUN=0
_ENDOR_WARNED=0
# shellcheck source=../bash/lib/common.sh
source "$PF_DIR/bash/lib/common.sh"

BLOCK=$(sed -e "s|{{GEM_MIRROR_URL}}|$MIRROR_URL|g" "$PF_DIR/shared/blocks/bundleconfig.txt")

HAVE_BUNDLE=0
if command -v bundle >/dev/null 2>&1; then
  major=$(bundle --version 2>/dev/null | sed -E 's/[^0-9]*([0-9]+).*/\1/')
  [[ "${major:-0}" -ge 2 ]] && HAVE_BUNDLE=1
fi

# Mirrors templates/ruby.sh and templates/remove.sh.
apply()  { upsert_bundle_config "$1" "$BLOCK" "$OWNER" "$GROUP"; }
remove() { remove_bundle_config "$1" "$MIRROR_URL" "$OWNER" "$GROUP"; }
warn()   { warn_if_bundle_mirror_conflict "$1" "$MIRROR_URL"; }

sha()      { shasum -a 256 "$1" | awk '{print $1}'; }
markers()  { grep -cF "$ENDOR_BLOCK_START" "$1" || true; }
keycount() { grep -cF "$2: " "$1" || true; }            # lines setting <key>
# GNU stat (Linux) takes -c; BSD stat (macOS) takes -f. GNU `stat -f` is "file system" mode and
# would print fs info to stdout while failing, so detect the flavour instead of falling through.
mode()     { if stat --version >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
# bundle_get <file> <setting> — what Bundler resolves with <file> as its global config
bundle_get() {
  ( cd "$TMP_DIR" && BUNDLE_USER_CONFIG="$1" BUNDLE_DISABLE_VERSION_CHECK=1 HOME="$TMP_DIR" \
      bundle config get "$2" --parseable 2>/dev/null | sed -n "s|^$2=||p" )
}
# assert_bundle <file> <setting> <expected> — skipped without bundler
assert_bundle() {
  [[ "$HAVE_BUNDLE" == "1" ]] || return 0
  local got; got=$(bundle_get "$1" "$2")
  [[ "$got" == "$3" ]] || { echo "bundle resolves $2 to '$got', expected '$3'"; return 1; }
}
new_fixture() { f="$TMP_DIR/$1/.bundle/config"; mkdir -p "$(dirname "$f")"; cat > "$f"; cp "$f" "$f.orig"; }

echo "test: fresh machine — created, idempotent, dry-run inert, no secret in the file, removal deletes"
f="$TMP_DIR/fresh/.bundle/config"
apply "$f"
[[ "$(head -1 "$f")" == "---" ]]; [[ "$(markers "$f")" == "1" ]]; [[ "$(mode "$f")" == "600" ]]
[[ "$(keycount "$f" 'BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/')" == "1" ]]
[[ "$(keycount "$f" 'BUNDLE_MIRROR__RUBYGEMS__ORG')" == "1" ]]
! grep -q "BUNDLE_$HOST_KEY" "$f"                               # credential is env.sh's job
assert_bundle "$f" 'mirror.https://rubygems.org/' "$MIRROR_URL"
assert_bundle "$f" 'mirror.rubygems.org' "$MIRROR_URL"
before=$(sha "$f"); apply "$f"; [[ "$(sha "$f")" == "$before" ]]
DRY_RUN=1 apply "$f" >/dev/null; [[ "$(sha "$f")" == "$before" ]]
out=$(remove "$f"); [[ "$out" == *'deleted (was empty)'* && ! -f "$f" ]]
out=$(remove "$f"); [[ "$out" == *'skip (not found)'* ]]
apply "$f"; [[ "$(markers "$f")" == "1" ]]                      # re-install after removal

echo "test: credential via environment (the env.sh model) is what Bundler applies to the firewall host (bundler: $([[ "$HAVE_BUNDLE" == "1" ]] && echo on || echo skipped))"
if [[ "$HAVE_BUNDLE" == "1" ]]; then
  got=$( cd "$TMP_DIR" && env "BUNDLE_$HOST_KEY=$CREDS" BUNDLE_USER_CONFIG="$f" BUNDLE_DISABLE_VERSION_CHECK=1 HOME="$TMP_DIR" \
           bundle config get factory.endorlabs.com --parseable 2>/dev/null | sed -n 's|^factory.endorlabs.com=||p' )
  [[ "$got" == "$CREDS" ]]
fi

echo "test: existing config — other keys preserved, removal restores the original byte-for-byte"
new_fixture existing <<'EOF'
---
BUNDLE_JOBS: "4"
BUNDLE_PATH: "vendor/bundle"
EOF
apply "$f"; [[ "$(markers "$f")" == "1" ]]
grep -qxF 'BUNDLE_JOBS: "4"' "$f"; grep -qxF 'BUNDLE_PATH: "vendor/bundle"' "$f"
assert_bundle "$f" 'mirror.https://rubygems.org/' "$MIRROR_URL"; assert_bundle "$f" 'jobs' "4"
out=$(remove "$f"); [[ "$out" == *'block removed'* ]]; cmp -s "$f" "$f.orig"
out=$(remove "$f"); [[ "$out" == *'skip (no Endor block)'* ]]

echo "test: existing file without a trailing newline — block starts on its own line"
f="$TMP_DIR/nonl/.bundle/config"; mkdir -p "$(dirname "$f")"; printf -- '---\nBUNDLE_JOBS: "4"' > "$f"
apply "$f"; grep -qxF 'BUNDLE_JOBS: "4"' "$f"; grep -qxF "$ENDOR_BLOCK_START" "$f"

echo "test: file rewritten by 'bundle config' (keys kept, sentinels gone) — one copy of each key after re-run"
new_fixture rewritten <<EOF
---
BUNDLE_JOBS: "4"
BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: "$MIRROR_URL"
BUNDLE_MIRROR__RUBYGEMS__ORG: "$MIRROR_URL"
EOF
out=$(DRY_RUN=1 apply "$f"); [[ "$out" == *'2 stale Endor line(s)'* ]]; cmp -s "$f" "$f.orig"
out=$(apply "$f"); [[ "$out" == *'2 stale Endor line(s)'* ]]
[[ "$(markers "$f")" == "1" ]]
[[ "$(keycount "$f" 'BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/')" == "1" ]]
[[ "$(keycount "$f" 'BUNDLE_MIRROR__RUBYGEMS__ORG')" == "1" ]]
assert_bundle "$f" 'mirror.https://rubygems.org/' "$MIRROR_URL"
cp "$f.orig" "$f"                                              # removal with no sentinels at all
out=$(remove "$f"); [[ "$out" == *'block removed'* ]]
[[ "$(keycount "$f" 'BUNDLE_MIRROR__RUBYGEMS__ORG')" == "0" ]]; grep -qxF 'BUNDLE_JOBS: "4"' "$f"

echo "test: real 'bundle config set --global' rewrite, then re-run (bundler: $([[ "$HAVE_BUNDLE" == "1" ]] && echo on || echo skipped))"
if [[ "$HAVE_BUNDLE" == "1" ]]; then
  f="$TMP_DIR/real/.bundle/config"; apply "$f"
  ( cd "$TMP_DIR" && BUNDLE_USER_CONFIG="$f" BUNDLE_DISABLE_VERSION_CHECK=1 HOME="$TMP_DIR" \
      bundle config set --global timeout 20 ) >/dev/null 2>&1
  [[ "$(markers "$f")" == "0" ]]                                 # Bundler dropped the sentinels
  apply "$f" >/dev/null; [[ "$(markers "$f")" == "1" ]]
  [[ "$(keycount "$f" 'BUNDLE_MIRROR__RUBYGEMS__ORG')" == "1" ]]; grep -qxF 'BUNDLE_TIMEOUT: "20"' "$f"
  assert_bundle "$f" 'mirror.https://rubygems.org/' "$MIRROR_URL"; assert_bundle "$f" 'timeout' "20"
  remove "$f" >/dev/null; grep -qxF 'BUNDLE_TIMEOUT: "20"' "$f"; [[ "$(markers "$f")" == "0" ]]
fi

echo "test: pre-existing rubygems.org mirror (registry) — warning fires, Endor key wins, restored on removal"
new_fixture registry <<EOF
---
BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: "$CORP_URL"
EOF
_ENDOR_WARNED=0; warn "$f" 2>/dev/null; [[ "$_ENDOR_WARNED" == "1" ]]
apply "$f"; grep -qF "$CORP_URL" "$f"                            # user's line kept
assert_bundle "$f" 'mirror.https://rubygems.org/' "$MIRROR_URL"  # last key wins
_ENDOR_WARNED=0; warn "$f" 2>/dev/null; [[ "$_ENDOR_WARNED" == "1" ]]   # persists on re-run
_ENDOR_WARNED=0
remove "$f" >/dev/null; cmp -s "$f" "$f.orig"
assert_bundle "$f" 'mirror.https://rubygems.org/' "$CORP_URL"

echo "test: mirror.all — warning names it; the user's key is kept"
new_fixture all <<EOF
---
BUNDLE_MIRROR__ALL: "$CORP_URL"
EOF
_ENDOR_WARNED=0; warn "$f" 2> "$TMP_DIR/warn.out"; [[ "$_ENDOR_WARNED" == "1" ]]; grep -q 'mirror.all' "$TMP_DIR/warn.out"
_ENDOR_WARNED=0
apply "$f"; grep -qF 'BUNDLE_MIRROR__ALL' "$f"
remove "$f" >/dev/null; cmp -s "$f" "$f.orig"

echo "test: our own keys and unrelated keys raise no warning"
new_fixture clean <<EOF
---
BUNDLE_JOBS: "4"
BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: "$MIRROR_URL"
EOF
_ENDOR_WARNED=0; warn "$f"; [[ "$_ENDOR_WARNED" == "0" ]]

echo "test: user fallback_timeout for rubygems.org — pinned to 0 inside the block, restored on removal"
new_fixture fallback <<'EOF'
---
BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/__FALLBACK_TIMEOUT: "3"
EOF
out=$(DRY_RUN=1 apply "$f"); [[ "$out" == *'fallback_timeout'* ]]; cmp -s "$f" "$f.orig"
out=$(apply "$f"); [[ "$out" == *'fallback_timeout'* ]]
grep -qxF 'BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/__FALLBACK_TIMEOUT: "0"' "$f"
grep -qxF 'BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/__FALLBACK_TIMEOUT: "3"' "$f"   # user's line kept
assert_bundle "$f" 'mirror.https://rubygems.org/.fallback_timeout' "0"
before=$(sha "$f"); apply "$f" >/dev/null; [[ "$(sha "$f")" == "$before" ]]       # idempotent
remove "$f" >/dev/null; cmp -s "$f" "$f.orig"

echo "test: Endor-only file left by a rewrite — removal deletes it; a user credential line is not ours"
new_fixture only <<EOF
---
BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: "$MIRROR_URL"
BUNDLE_MIRROR__RUBYGEMS__ORG: "$MIRROR_URL"
EOF
out=$(DRY_RUN=1 remove "$f"); [[ "$out" == *'DELETE file'* ]]; cmp -s "$f" "$f.orig"
out=$(remove "$f"); [[ "$out" == *'deleted (was empty)'* && ! -f "$f" ]]
new_fixture usercred <<EOF
---
BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: "$MIRROR_URL"
BUNDLE_$HOST_KEY: "$CREDS"
EOF
remove "$f" >/dev/null; grep -qxF "BUNDLE_$HOST_KEY: \"$CREDS\"" "$f"

echo "test: generator emits endor-ruby.sh, exports the credential from env.sh, wires Ruby into endor-all.sh / endor-remove.sh"
ENDOR_NAMESPACE=ci-smoke ENDOR_API_KEY_ID=ci-smoke-key-id ENDOR_API_SECRET=ci-smoke-secret bash "$PF_DIR/bash/generate.sh" >/dev/null
out="$PF_DIR/bash/out/ci-smoke"
bash -n "$out/endor-ruby.sh"
grep -qF "$MIRROR_URL" "$out/endor-ruby.sh"; grep -qF "$MIRROR_URL" "$out/endor-all.sh"
! grep -qF "BUNDLE_$HOST_KEY: " "$out/endor-ruby.sh"             # no credential in the bundle block
grep -qF "export BUNDLE_$HOST_KEY=\"{{BUNDLE_CREDS}}\"" "$out/endor-ruby.sh"   # env.sh block; filled at install time
grep -qF "export BUNDLE_$HOST_KEY=\"{{BUNDLE_CREDS}}\"" "$out/endor-js.sh"     # env.sh is shared by every script
grep -qF "ENVSH_BLOCK=\${ENVSH_BLOCK//'{{BUNDLE_CREDS}}'" "$out/endor-ruby.sh"
grep -qF 'ENDOR_BUNDLE_CREDS=' "$out/endor-ruby.sh"
grep -qF "remove_bundle_config \"\$USER_HOME/.bundle/config\" \"$MIRROR_URL\" \"\$CONSOLE_USER\"" "$out/endor-remove.sh"
! grep -qE '\{\{(GEM_MIRROR_URL|BUNDLE_HOST_KEY)\}\}' "$out/endor-ruby.sh" "$out/endor-remove.sh" "$out/endor-all.sh"

echo "test: credential variable follows Bundler's host mapping (EU host with port, dashed host)"
ENDOR_NAMESPACE=ci-smoke-eu ENDOR_FQDN=https://factory.eu.endorlabs.com:8443 ENDOR_API_KEY_ID=fake-key-id ENDOR_API_SECRET=fake-secret \
  bash "$PF_DIR/bash/generate.sh" >/dev/null
grep -qF 'export BUNDLE_FACTORY__EU__ENDORLABS__COM="' "$PF_DIR/bash/out/ci-smoke-eu/endor-ruby.sh"
grep -qF 'https://factory.eu.endorlabs.com:8443/v1/namespaces/ci-smoke-eu/firewall/gem/' "$PF_DIR/bash/out/ci-smoke-eu/endor-ruby.sh"
ENDOR_NAMESPACE=ci-smoke-dash ENDOR_FQDN=https://fw-test.example.com ENDOR_API_KEY_ID=fake-key-id ENDOR_API_SECRET=fake-secret \
  bash "$PF_DIR/bash/generate.sh" >/dev/null
grep -qF 'export BUNDLE_FW___TEST__EXAMPLE__COM="' "$PF_DIR/bash/out/ci-smoke-dash/endor-ruby.sh"
rm -rf "$PF_DIR/bash/out/ci-smoke-eu" "$PF_DIR/bash/out/ci-smoke-dash"

echo "ok: bundler tests passed (bundler validation: $([[ "$HAVE_BUNDLE" == "1" ]] && echo on || echo skipped))"
