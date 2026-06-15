#!/bin/sh
# runner.sh — MDM-run script that keeps an agent's hook config current.
#
# IT sets this up once in the MDM (see docs/). On every check-in it fetches this
# public repo (a pinned --ref, or the default-branch tip if unpinned), re-renders
# the agent's config from that source + the current credentials/flags, and swaps
# it in atomically only when the result changes. Endpoint needs: git + /bin/sh + jq.
#
# Usage:
#   runner.sh --agent <name> [--ref <tag|commit>] [--dest <path>] [extra render.sh args...]
#
# --ref pins the repo to a reviewed tag, branch, or commit, so each device runs a
# known revision instead of whatever is at the branch tip. Omit it to track the
# default branch.
#
# Credentials are read from the environment by render.sh (see its header):
#   ENDOR_API_CREDENTIALS_KEY / ENDOR_API_CREDENTIALS_SECRET / ENDOR_NAMESPACE
# The MDM script exports them before invoking this runner — Jamf from its $4-$6
# parameters, Kandji/JumpCloud hard-coded in the script (see docs/).
#
# Extra args pass straight through to render.sh, e.g. monitor-only:
#   runner.sh --agent cursor --env ENDOR_AI_AUDIT_NO_BLOCKING=true
#
# macOS and Linux only. Windows endpoints have no git/sh/jq — pre-generate with
# `render.sh --target-os windows` and push via Intune (see docs/deploy-windows-intune.md).
set -eu

REPO_URL="https://github.com/endorlabs/mdm-scripts"
RENDER_REL="agent-governance/scripts/render.sh"   # path to render.sh within the repo
os=$(uname -s)
case "$os" in
  Darwin) REPO="/Library/Application Support/EndorAIGovernance/repo" ;;
  *)      REPO="/var/lib/endor-ai-governance/repo" ;;
esac

{ [ "${1:-}" = "--agent" ] && [ $# -ge 2 ]; } || { echo "usage: runner.sh --agent <name> [--ref <tag|commit>] [--dest <path>] [render args...]" >&2; exit 2; }
agent="$2"; shift 2

dest=""; ref=""
while :; do
  case "${1:-}" in
    --ref)  [ $# -ge 2 ] || { echo "runner.sh: --ref requires a value" >&2; exit 2; }; ref="$2"; shift 2 ;;
    --dest) [ $# -ge 2 ] || { echo "runner.sh: --dest requires a value" >&2; exit 2; }; dest="$2"; shift 2 ;;
    *) break ;;
  esac
done

# Default install location per (agent, OS); override with --dest. Add new here.
# (macOS Claude is normally profile-delivered — see docs/deploy-claude-profile.md —
# so it has no runner default; pass --dest if you really want a file there.)
if [ -z "$dest" ]; then
  case "$agent:$os" in
    cursor:Darwin) dest="/Library/Application Support/Cursor/hooks.json" ;;
    cursor:Linux)  dest="/etc/cursor/hooks.json" ;;
    claude:Linux)  dest="/etc/claude-code/managed-settings.json" ;;
    *) echo "runner.sh: no default --dest for agent '$agent' on $os; pass --dest" >&2; exit 2 ;;
  esac
fi

# Clean machines may not have these directories yet.
mkdir -p "$(dirname "$REPO")" "$(dirname "$dest")"

# 1. Fetch the source at the pinned ref (or the default-branch tip if unpinned)
#    and check it out, so the device runs exactly that reviewed revision.
if [ ! -d "$REPO/.git" ]; then
  git init -q "$REPO"
  git -C "$REPO" remote add origin "$REPO_URL"
fi
git -C "$REPO" fetch --depth 1 origin "${ref:-HEAD}"
git -C "$REPO" -c advice.detachedHead=false checkout -f FETCH_HEAD

# 2. Render the config (the session hook also installs/updates endorctl) and swap
#    it in atomically only if it actually changed. Comparing the rendered output
#    — not just the repo SHA — means credential rotations and flag changes from
#    the MDM take effect too, not only repo commits.
sh "$REPO/$RENDER_REL" --agent "$agent" "$@" -o "$dest.tmp"
if [ -f "$dest" ] && cmp -s "$dest.tmp" "$dest"; then
  rm -f "$dest.tmp"
else
  mv "$dest.tmp" "$dest"
fi
