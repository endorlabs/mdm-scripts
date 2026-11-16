#!/bin/sh
# cortexcode-merge.sh - merge Endor's rendered Cortex Code hooks into a user's
# existing hooks.json, keeping every hook and key that is not Endor's.
#
#   cortexcode-merge.sh EXISTING RENDERED OUT
#
# install-cortexcode.sh calls this with copies in a root-owned directory; it
# never touches the user's own file. No jq: the JSON work runs in JXA on macOS
# (osascript ships with every Mac) and in python3 on Linux. See
# cortexcode-merge.js and cortexcode-merge.py for the merge rules.
#
# Exit status. The caller writes OUT to the user's file only on 0.
#   0  OUT holds the merged file
#   2  EXISTING could not be merged (not JSON, an unknown shape, or the engine
#      failed). The user's file must stay as it is.
#   3  no JSON engine on this machine. The user's file must stay as it is.
set -eu

fail() { _code=$1; shift; echo "cortexcode-merge.sh: error: $*" >&2; exit "$_code"; }
[ $# -eq 3 ] || { echo "usage: cortexcode-merge.sh EXISTING RENDERED OUT" >&2; exit 64; }
existing=$1; rendered=$2; out=$3
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# These two cases need no parser, so a machine without one still gets them:
# a file that is already current, and an empty file, which holds nothing of the
# user's to keep.
if cmp -s "$existing" "$rendered" || ! grep -q '[^[:space:]]' "$existing"; then
  cat "$rendered" > "$out"
  exit 0
fi

# osascript first: on a Mac, python3 can be the Command Line Tools stub, which
# opens an install dialog instead of running.
if command -v osascript >/dev/null 2>&1; then
  set -- osascript -l JavaScript "$SCRIPT_DIR/cortexcode-merge.js"
elif command -v python3 >/dev/null 2>&1; then
  set -- python3 -I "$SCRIPT_DIR/cortexcode-merge.py"
else
  fail 3 "no JSON engine (osascript or python3); left the existing file as it is"
fi

rm -f "$out"
if "$@" "$existing" "$rendered" "$out" >/dev/null; then
  [ -f "$out" ] || fail 2 "the merge engine wrote no output; left the existing file as it is"
  exit 0
fi
rm -f "$out"
fail 2 "could not merge into the existing file (see the message above); left it as it is"
