#!/bin/sh
# runner.sh - paste this into your MDM as the script body (Jamf script, Kandji
# Custom Script, JumpCloud Command) to keep an agent's hook config current on
# macOS/Linux. On each run it fetches this repo at a pinned revision, renders the
# config, and places it - atomically, and only when the result changed. Run it on
# a recurring schedule and repo, credential, and flag changes all take effect.
#
# The MDM must put credentials in the environment before this runs:
#   ENDOR_API_CREDENTIALS_KEY   ENDOR_API_CREDENTIALS_SECRET   ENDOR_NAMESPACE
#   Jamf:    prepend  export ENDOR_API_CREDENTIALS_KEY="$4" ENDOR_API_CREDENTIALS_SECRET="$5" ENDOR_NAMESPACE="$6"
#   Kandji / JumpCloud: prepend  export ENDOR_API_CREDENTIALS_KEY='...' ...  (single-quoted)
# Use an audit-only / least-privilege credential.
#
# Endpoint needs git + jq. Windows doesn't use this - pre-generate and push via
# Intune (see docs/deploy-windows-intune.md).
set -eu

# --- settings: edit these ---------------------------------------------------
AGENT=cursor                                       # cursor | claude | codex
REF=main                                           # pin to a reviewed tag/commit, e.g. v1.0.0
EXTRA=                                              # extra render flags, e.g. --env ENDOR_AI_AUDIT_NO_BLOCKING=true
DEST=                                              # override install path; empty = OS default
REPO_URL=https://github.com/endorlabs/mdm-scripts
# -----------------------------------------------------------------------------

os=$(uname -s)
case "$os" in
  Darwin) REPO="/Library/Application Support/EndorAIGovernance/repo" ;;
  *)      REPO="/var/lib/endor-ai-governance/repo" ;;
esac

# Default install path per (agent, OS). macOS Claude is profile-delivered (see
# docs/deploy-claude-profile.md), so set DEST yourself if you really want a file.
if [ -z "$DEST" ]; then
  case "$AGENT:$os" in
    cursor:Darwin) DEST="/Library/Application Support/Cursor/hooks.json" ;;
    cursor:Linux)  DEST="/etc/cursor/hooks.json" ;;
    claude:Linux)  DEST="/etc/claude-code/managed-settings.json" ;;
    # Codex reads a managed requirements.toml at /etc/codex on both macOS and
    # Linux; hooks from this source are auto-trusted. On macOS the tamper-resistant
    # alternative is an MDM profile (see docs/deploy-codex-profile.md) - deliver
    # that through your MDM instead of running this on the endpoint.
    codex:Darwin|codex:Linux) DEST="/etc/codex/requirements.toml" ;;
    *) echo "runner.sh: set DEST for agent '$AGENT' on $os" >&2; exit 2 ;;
  esac
fi

mkdir -p "$(dirname "$REPO")" "$(dirname "$DEST")"

# Fetch this repo at the pinned ref - one clone, into a root-owned path (never
# /tmp). Checking out an explicit ref means the device runs a reviewed revision.
if [ ! -d "$REPO/.git" ]; then
  git init -q "$REPO"
  git -C "$REPO" remote add origin "$REPO_URL"
fi
git -C "$REPO" fetch --depth 1 origin "$REF"
git -C "$REPO" -c advice.detachedHead=false checkout -f FETCH_HEAD

# Render the config and swap it in only if it changed. Comparing the output (not
# the repo revision) means credential and flag changes take effect too.
sh "$REPO/agent-governance/scripts/render.sh" --agent "$AGENT" $EXTRA -o "$DEST.tmp"
if [ -f "$DEST" ] && cmp -s "$DEST.tmp" "$DEST"; then
  rm -f "$DEST.tmp"
else
  mv "$DEST.tmp" "$DEST"
fi
