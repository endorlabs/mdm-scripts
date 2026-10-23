#!/usr/bin/env bash
# Drives the ~/.gemrc helpers from lib/common.sh against fixture home directories
# (the generated installer itself needs root + a console user), then checks the
# generator wires the gem section in. When `gem` is installed, `gem sources`
# (with HOME pointed at the fixture) validates what RubyGems actually resolves —
# on macOS runners Apple's /usr/bin/gem (RubyGems 3.0, Psych parser) is checked too.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF_DIR="$(cd "$TEST_DIR/.." && pwd)"
MIRROR_URL="https://factory.endorlabs.com/v1/namespaces/ci-smoke/firewall/gem/"
SOURCE_URL="https://fakeuser:fakesecret@factory.endorlabs.com/v1/namespaces/ci-smoke/firewall/gem/"
RUBYGEMS_URL="https://rubygems.org/"
CORP_URL="https://fakeuser:fakepassword@gems.corp.example.com/"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
OWNER=$(id -un); GROUP=$(id -gn)

# Both are read by the sourced common.sh functions.
# shellcheck disable=SC2034
DRY_RUN=0
_ENDOR_WARNED=0
# shellcheck source=../bash/lib/common.sh
source "$PF_DIR/bash/lib/common.sh"

BLOCK=$(sed -e "s|{{GEM_SOURCE_URL}}|$SOURCE_URL|g" "$PF_DIR/shared/blocks/gemrc.txt")

GEMS=()
command -v gem >/dev/null 2>&1 && GEMS+=("$(command -v gem)")
[[ -x /usr/bin/gem && "$(command -v gem)" != /usr/bin/gem ]] && GEMS+=(/usr/bin/gem)

# Mirrors templates/ruby.sh and templates/remove.sh. $h is the fixture home.
apply()  { upsert_gemrc "$h/.gemrc" "$h/.config/gem/gemrc" "$BLOCK" "$MIRROR_URL" "$OWNER" "$GROUP"; }
remove() { remove_gemrc "$h/.gemrc" "$MIRROR_URL" "$OWNER" "$GROUP"; }

sha()     { shasum -a 256 "$1" | awk '{print $1}'; }
markers() { grep -cF "$ENDOR_BLOCK_START" "$1" || true; }
mode()    { if stat --version >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
# assert_sources <home> <url>... — the sources every available gem resolves from that home (skipped without gem)
assert_sources() {
  local home="$1" g got expected; shift
  expected=$(printf '%s\n' "$@" | sort | tr '\n' ' ')
  for g in ${GEMS[@]+"${GEMS[@]}"}; do
    got=$( cd "$TMP_DIR" && env -u GEMRC HOME="$home" "$g" sources -l 2>/dev/null | grep '^http' | sort | tr '\n' ' ' )
    [[ "$got" == "$expected" ]] || { echo "$g resolves '$got', expected '$expected' (HOME=$home)"; return 1; }
  done
}
new_home() { h="$TMP_DIR/$1"; mkdir -p "$h"; }
new_gemrc() { cat > "$h/.gemrc"; cp "$h/.gemrc" "$h/.gemrc.orig"; }

echo "test: fresh machine — created, idempotent, dry-run inert, no backup, removal deletes (gem: ${#GEMS[@]} binar$([[ ${#GEMS[@]} == 1 ]] && echo y || echo ies))"
new_home fresh
apply; f="$h/.gemrc"
[[ "$(head -1 "$f")" == "---" ]]; [[ "$(markers "$f")" == "1" ]]; [[ "$(mode "$f")" == "600" ]]
grep -qxF ":sources:" "$f"; grep -qxF -- "- $SOURCE_URL" "$f"; [[ ! -e "$f.endor-bak" ]]
assert_sources "$h" "$SOURCE_URL"
before=$(sha "$f"); apply; [[ "$(sha "$f")" == "$before" ]]
DRY_RUN=1 apply >/dev/null; [[ "$(sha "$f")" == "$before" ]]
out=$(DRY_RUN=1 remove); [[ "$out" == *'DELETE'* && -f "$f" ]]
out=$(remove); [[ "$out" == *'deleted (Endor-made)'* && ! -f "$f" ]]
out=$(remove); [[ "$out" == *'skip (not found)'* ]]
apply; [[ "$(markers "$f")" == "1" ]]                          # re-install after removal

echo "test: existing ~/.gemrc — backed up once, sources replaced, other keys kept, private source warns, restored byte-for-byte"
new_home existing; new_gemrc <<EOF
---
gem: --no-document
# keep me
:sources:
- $RUBYGEMS_URL
- $CORP_URL
:verbose: true
EOF
f="$h/.gemrc"
out=$(DRY_RUN=1 apply); [[ "$out" == *'backup'* && "$out" == *'gems.corp.example.com'* && "$out" != *'fakepassword'* ]]; cmp -s "$f" "$f.orig"
_ENDOR_WARNED=0; apply > "$h/apply.out" 2>&1; out=$(cat "$h/apply.out"); [[ "$_ENDOR_WARNED" == "1" ]]   # private server disabled → warn
[[ "$out" == *'backed up'* && "$out" == *'***@gems.corp'* && "$out" != *'fakepassword'* ]]
cmp -s "$f.endor-bak" "$f.orig"; [[ "$(mode "$f.endor-bak")" == "600" ]]
grep -qxF "gem: --no-document" "$f"; grep -qxF "# keep me" "$f"; grep -qxF ":verbose: true" "$f"
! grep -qF "$RUBYGEMS_URL" "$f"; ! grep -qF "gems.corp" "$f"; [[ "$(grep -c '^:sources:' "$f")" == "1" ]]
assert_sources "$h" "$SOURCE_URL"
before=$(sha "$f"); bbefore=$(sha "$f.endor-bak"); _ENDOR_WARNED=0; apply > "$h/apply.out" 2>&1; out=$(cat "$h/apply.out")
[[ "$(sha "$f")" == "$before" && "$(sha "$f.endor-bak")" == "$bbefore" && "$_ENDOR_WARNED" == "0" && "$out" != *'NOTE'* ]]   # idempotent, no second backup
out=$(DRY_RUN=1 remove); [[ "$out" == *'RESTORE'* ]]; [[ -e "$f.endor-bak" ]]
out=$(remove); [[ "$out" == *'original restored'* ]]; cmp -s "$f" "$f.orig"; [[ ! -e "$f.endor-bak" ]]
assert_sources "$h" "$RUBYGEMS_URL" "$CORP_URL"
out=$(remove); [[ "$out" == *'skip (no Endor block)'* ]]; cmp -s "$f" "$f.orig"

echo "test: only the XDG file exists — ~/.gemrc built from it, XDG untouched; removal deletes ~/.gemrc"
new_home xdg; mkdir -p "$h/.config/gem"
printf -- 'gem: --no-document\n:sources:\n- %s\n' "$RUBYGEMS_URL" > "$h/.config/gem/gemrc"; cp "$h/.config/gem/gemrc" "$h/xdg.orig"
out=$(DRY_RUN=1 apply); [[ "$out" == *'BUILD'* && ! -e "$h/.gemrc" ]]
apply; f="$h/.gemrc"
[[ -f "$f" && ! -e "$f.endor-bak" ]]; grep -qxF "gem: --no-document" "$f"; ! grep -qF "$RUBYGEMS_URL" "$f"; [[ "$(markers "$f")" == "1" ]]
cmp -s "$h/.config/gem/gemrc" "$h/xdg.orig"
assert_sources "$h" "$SOURCE_URL"
remove >/dev/null; [[ ! -e "$f" ]]; cmp -s "$h/.config/gem/gemrc" "$h/xdg.orig"

echo "test: both files exist — XDG ignored and untouched, ~/.gemrc handled like an existing file"
new_home both; mkdir -p "$h/.config/gem"; printf -- ':sources:\n- %s\n' "$CORP_URL" > "$h/.config/gem/gemrc"; cp "$h/.config/gem/gemrc" "$h/xdg.orig"
new_gemrc <<EOF
:sources:
- $RUBYGEMS_URL
EOF
f="$h/.gemrc"; _ENDOR_WARNED=0; apply >/dev/null; [[ "$_ENDOR_WARNED" == "0" ]]        # rubygems.org alone: no warning
cmp -s "$f.endor-bak" "$f.orig"; cmp -s "$h/.config/gem/gemrc" "$h/xdg.orig"; assert_sources "$h" "$SOURCE_URL"
remove >/dev/null; cmp -s "$f" "$f.orig"; cmp -s "$h/.config/gem/gemrc" "$h/xdg.orig"

echo "test: file rewritten by 'gem sources' (canonical dump, no sentinels, rubygems.org re-added) — re-run leaves ours only"
new_home rewritten; new_gemrc <<EOF
---
:backtrace: "true"
:sources:
- "$SOURCE_URL"
- "$RUBYGEMS_URL"
:update_sources: "true"
gem: "--no-document"
EOF
f="$h/.gemrc"; _ENDOR_WARNED=0; apply > "$h/apply.out" 2>&1; out=$(cat "$h/apply.out")
[[ ! -e "$f.endor-bak" ]]                                        # a file that is already ours is never backed up
[[ "$out" == *"$RUBYGEMS_URL"* && "$out" != *'***@factory'* && "$_ENDOR_WARNED" == "0" ]]   # note lists rubygems.org, not ours
[[ "$(markers "$f")" == "1" && "$(grep -c '^:sources:' "$f")" == "1" && "$(grep -c 'firewall/gem/' "$f")" == "1" ]]
grep -qxF ':backtrace: "true"' "$f"; grep -qxF ':update_sources: "true"' "$f"; grep -qxF 'gem: "--no-document"' "$f"
assert_sources "$h" "$SOURCE_URL"
cp "$f.orig" "$f"; out=$(remove); [[ "$out" == *'deleted (Endor-made)'* && ! -e "$f" ]]   # recognised by url even without sentinels
new_gemrc <<EOF
:sources:
- $RUBYGEMS_URL
EOF
apply >/dev/null; printf -- '---\n:sources:\n- "%s"\n- "%s"\n' "$SOURCE_URL" "$RUBYGEMS_URL" > "$f"   # dev ran gem sources --add after install
out=$(remove); [[ "$out" == *'original restored'* ]]; cmp -s "$f" "$f.orig"                        # the backup still wins

echo "test: flow-style :sources: [a, b] (breaks both parsers) — replaced by the block form"
new_home flow; new_gemrc <<EOF
:sources: [$RUBYGEMS_URL, $CORP_URL]
EOF
f="$h/.gemrc"; _ENDOR_WARNED=0; apply >/dev/null 2>&1; [[ "$_ENDOR_WARNED" == "1" ]]
! grep -q '\[' "$f"; assert_sources "$h" "$SOURCE_URL"
remove >/dev/null; cmp -s "$f" "$f.orig"

echo "test: command defaults carrying --source / -s / --clear-sources warn; harmless ones don't; Endor block ignored"
new_home warn
for line in 'gem: --no-document --source https://other.example.com/' 'install: -s https://other.example.com/' 'update: --clear-sources --source https://x/'; do
  printf '%s\n' "$line" > "$h/sys-gemrc"; _ENDOR_WARNED=0; warn_if_gemrc_source_override "$h/sys-gemrc" 2>/dev/null
  [[ "$_ENDOR_WARNED" == "1" ]] || { echo "no warning for: $line"; exit 1; }
done
for line in 'gem: --no-document' ':sources:' '- https://other.example.com/' 'install: --user-install --no-document'; do
  printf '%s\n' "$line" > "$h/sys-gemrc"; _ENDOR_WARNED=0; warn_if_gemrc_source_override "$h/sys-gemrc"
  [[ "$_ENDOR_WARNED" == "0" ]] || { echo "false warning for: $line"; exit 1; }
done
printf '%s\n%s\n%s\n' "$ENDOR_BLOCK_START" 'gem: --source https://x/' "$ENDOR_BLOCK_END" > "$h/sys-gemrc"
_ENDOR_WARNED=0; warn_if_gemrc_source_override "$h/sys-gemrc" "$h/does-not-exist"; [[ "$_ENDOR_WARNED" == "0" ]]

echo "test: generator emits the gem section into endor-ruby.sh / endor-all.sh / endor-remove.sh"
ENDOR_NAMESPACE=ci-smoke ENDOR_API_KEY_ID=ci-smoke-key-id ENDOR_API_SECRET=ci-smoke-secret bash "$PF_DIR/bash/generate.sh" >/dev/null
out="$PF_DIR/bash/out/ci-smoke"
bash -n "$out/endor-ruby.sh"
grep -qF 'ENDOR_GEM_SOURCE_URL="https://' "$out/endor-ruby.sh"
grep -qF '@factory.endorlabs.com/v1/namespaces/ci-smoke/firewall/gem/"' "$out/endor-ruby.sh"
grep -qF -- '- {{GEM_SOURCE_URL}}' "$out/endor-ruby.sh"                 # filled at install time, not generation
grep -qF "GEMRC_BLOCK=\${GEMRC_BLOCK//'{{GEM_SOURCE_URL}}'" "$out/endor-ruby.sh"
grep -qF "upsert_gemrc \"\$GEMRC\" \"\$GEMRC_XDG\" \"\$GEMRC_BLOCK\" \"$MIRROR_URL\"" "$out/endor-ruby.sh"
grep -qF "upsert_gemrc \"\$_ROOT_HOME/.gemrc\"" "$out/endor-ruby.sh"
grep -qF "upsert_gemrc \"\$GEMRC\"" "$out/endor-all.sh"
grep -qF "remove_gemrc \"\$USER_HOME/.gemrc\" \"$MIRROR_URL\"" "$out/endor-remove.sh"
grep -qF "remove_gemrc \"\$_ROOT_HOME/.gemrc\"" "$out/endor-remove.sh"
! grep -qE '\{\{(GEM_MIRROR_URL|BUNDLE_HOST_KEY)\}\}' "$out/endor-ruby.sh" "$out/endor-remove.sh" "$out/endor-all.sh"

echo "ok: gem tests passed (gem validation: $([[ ${#GEMS[@]} -gt 0 ]] && echo "on — ${GEMS[*]}" || echo skipped))"
