#!/usr/bin/env bash
# Shared harness for the bash suites. Sourced, never run.
#
# No `set` options here on purpose: each suite sets its own, and the assertion
# helpers deliberately keep going after a failure so one run reports every
# problem rather than the first.

# ─── Paths ────────────────────────────────────────────────────────────────────
# Everything is derived from this file's location, so the suites run from any cwd
# and from a checkout at any path.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PF_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_DIR="$(cd "$PF_DIR/.." && pwd)"
BASH_DIR="$PF_DIR/bash"
LIB="$BASH_DIR/lib/common.sh"
FIXTURE="$TESTS_DIR/fixtures/product.json"

# Facts about the fixture that several suites assert against. Kept here so a
# deliberate fixture edit is a one-line update instead of a scavenger hunt.
FIXTURE_LINES=74           # real lines; `wc -l` reports 73 as the last has no newline
FIXTURE_GALLERY_LINES=28   # extensionsGallery incl. its opening and closing lines
FIXTURE_GALLERY_KEYS=9     # keys inside extensionsGallery
FIXTURE_SKUS=16
FIXTURE_VERSION="1.999.0"
FIXTURE_COMMIT="0123456789abcdef0123456789abcdef01234567"

# ─── Counters ─────────────────────────────────────────────────────────────────
pass=0; fail=0; skipped=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  skip %s\n' "$1"; skipped=$((skipped+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got [$2] want [$3])"; fi; }

# summarize — print the tally and set the exit status. Last line of every suite.
summarize() {
  echo
  if [ "$skipped" -gt 0 ]; then
    printf 'passed %d, failed %d, skipped %d\n' "$pass" "$fail" "$skipped"
  else
    printf 'passed %d, failed %d\n' "$pass" "$fail"
  fi
  [ "$fail" -eq 0 ]
}

# ─── Independent JSON parser ──────────────────────────────────────────────────
# Checking the lib's output with the lib's own validator would be circular, so an
# outside parser is required. python3 rather than node, because several assertions
# are about structure (key order, array lengths, sibling survival) and not merely
# validity — and because node is the lib's own fallback writer, so it is not
# independent of the code under test.
require_json_tool() {
  command -v python3 >/dev/null 2>&1 && return 0
  echo "ERROR: these suites need python3 to parse JSON independently of the code" >&2
  echo "       under test. Install python3 and re-run." >&2
  exit 2
}

# json_ok <file> — true when <file> parses as JSON.
json_ok() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }

# jget <file> <python-expr> — evaluate an expression against the parsed document,
# available as `d`, and print the result. Used for structural assertions that a
# grep cannot make honestly (key order, array lengths, sibling survival).
jget() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = eval(sys.argv[2])
print("" if v is None else ("true" if v is True else ("false" if v is False else v)))
' "$1" "$2" 2>/dev/null
}

# ─── The lib, in the form that actually ships ─────────────────────────────────
# inline_common() in generate.sh strips `^# ` comment lines and blank lines, so
# the pristine file is not what runs on a managed machine. Testing the stripped
# form is what proves nothing in the lib depends on a comment or a blank line
# surviving — which a heredoc body silently would.
strip_lib() { grep -v '^# ' "$LIB" | sed '/^[[:space:]]*$/d'; }

# source_stripped_lib <workdir> — write the stripped lib into <workdir> and source
# it, then set the two globals the lib expects its host script to have defined.
source_stripped_lib() {
  strip_lib > "$1/stripped.sh"
  # shellcheck disable=SC1090
  . "$1/stripped.sh"
  DRY_RUN=0
  _ENDOR_WARNED=0
}

# ─── Fixture installs ─────────────────────────────────────────────────────────
# make_macos_app <parent> <bundle name> <nameLong> [node bin]
# Builds a macOS-shaped bundle around a copy of the fixture. The Info.plist and
# the CFBundleExecutable shim exist so vscode_node_bin has something real to
# resolve — the fallback writer's whole point is using VS Code's own Electron as
# node, and hardcoding "Electron" there would be wrong (stable ships "Code").
make_macos_app() {
  local parent="$1" bundle="$2" long="$3" node="${4:-}" d
  d="$parent/$bundle/Contents"
  mkdir -p "$d/Resources/app" "$d/MacOS"
  set_name_long "$FIXTURE" "$d/Resources/app/product.json" "$long"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Code</string></dict></plist>\n' \
    > "$d/Info.plist"
  if [ -n "$node" ]; then
    # ELECTRON_RUN_AS_NODE is simply ignored by real node, so a shim is enough.
    printf '#!/bin/sh\nexec %s "$@"\n' "$node" > "$d/MacOS/Code"
    chmod +x "$d/MacOS/Code"
  fi
}

# set_name_long <src> <dst> <nameLong> — copy <src> to <dst> with nameLong
# replaced, which is how the two editions are told apart. GNU sed preserves a
# missing final newline and BSD sed adds one, so the source's final-newline state
# is restored explicitly: the fixture deliberately has none, and every
# byte-exactness assertion downstream depends on that surviving.
set_name_long() {
  local src="$1" dst="$2" long="$3" tmp="$2.tmp$$"
  sed "s#\"nameLong\"[[:space:]]*:[[:space:]]*\"[^\"]*\"#\"nameLong\": \"$long\"#" "$src" > "$tmp"
  # A capture of the last byte is empty exactly when that byte is a newline.
  if [ -n "$(tail -c 1 "$src")" ] && [ -z "$(tail -c 1 "$tmp")" ]; then
    head -c "$(( $(wc -c < "$tmp") - 1 ))" "$tmp" > "$dst"
    rm -f "$tmp"
  else
    mv "$tmp" "$dst"
  fi
}

# ─── Working-tree copy, for the end-to-end suite ──────────────────────────────
# The generators write to <generator dir>/out/<namespace>, with no override. The
# e2e suite needs to generate with throwaway credentials — and to regenerate with
# rotated ones — so it copies the working tree into a sandbox and runs the
# generator there. That keeps the checkout clean, and means no product code has to
# change to accommodate the tests.
copy_package_firewall() {
  local dest="$1"
  mkdir -p "$dest"
  ( cd "$PF_DIR" && tar -cf - --exclude out . ) | ( cd "$dest" && tar -xf - )
}
