#!/bin/sh
# runner-cowork.sh - paste this into your MDM as the script body (Jamf script,
# Kandji Custom Script, JumpCloud Command) to build the Claude Cowork plugin ZIP
# on one admin machine. On each run it fetches this repo at a pinned revision
# and rebuilds the plugin; the ZIP is replaced only when the plugin changed, and
# the output says when it needs uploading again.
#
# Scope it to the machine of the Claude organization Owner who uploads the
# plugin, not to the fleet: the ZIP holds the API key.
#
# The MDM must put credentials in the environment before this runs:
#   ENDOR_API_CREDENTIALS_KEY   ENDOR_API_CREDENTIALS_SECRET   ENDOR_NAMESPACE
#   Jamf:    prepend  export ENDOR_API_CREDENTIALS_KEY="$4" ENDOR_API_CREDENTIALS_SECRET="$5" ENDOR_NAMESPACE="$6"
#   Kandji / JumpCloud: prepend  export ENDOR_API_CREDENTIALS_KEY='...' ...  (single-quoted)
# Use a key with the AI Audit role only. Set ENDOR_API too if your tenant is not
# on https://api.endorlabs.com.
#
# Needs curl, tar and zip (all ship with macOS). See docs/deploy-claude-cowork.md.
set -eu

# --- settings: edit these ---------------------------------------------------
REF=main                                           # pin to a reviewed tag/commit, e.g. v1.0.0
EXTRA=                                              # extra render flags, e.g. --env ENDOR_AI_AUDIT_NO_BLOCKING=true
DEST=                                              # where the ZIP is written (must end in .zip); empty = OS default
ZIP_OWNER=                                         # user who uploads the ZIP; empty = leave it root-only
REPO_SLUG=endorlabs/mdm-scripts                    # owner/repo the tarball is fetched from
# -----------------------------------------------------------------------------

case "$(uname -s)" in
  Darwin) BASE="/Library/Application Support/EndorAIGovernance" ;;
  *)      BASE="/var/lib/endor-ai-governance" ;;
esac
REPO="$BASE/cowork-repo"
BUILT="$BASE/cowork-plugin"          # the last build, kept to tell whether anything changed
[ -n "$DEST" ] || DEST="$BASE/endor-cowork-governance.zip"
case "$DEST" in *.zip) ;; *) echo "runner-cowork.sh: DEST must end in .zip: $DEST" >&2; exit 2 ;; esac

# Everything written here holds the key or is run as root: owner-only.
umask 077
mkdir -p "$BASE" "$(dirname "$DEST")"

# Fetch the repo at the pinned ref (see runner.sh for why curl, not git).
rm -rf "$REPO"
mkdir -p "$REPO"
curl -fsSL --retry 5 --retry-connrefused --retry-all-errors \
  "https://codeload.github.com/$REPO_SLUG/tar.gz/$REF" \
  | tar -xz -C "$REPO" --strip-components=1
RENDER="$REPO/agent-governance/scripts/render.sh"

# A ZIP differs on every build (timestamps), so compare the plugin's files.
rm -rf "$BUILT.new"
# shellcheck disable=SC2086  # EXTRA is a list of flags
sh "$RENDER" --agent claude-cowork $EXTRA -o "$BUILT.new"
if [ -f "$DEST" ] && [ -d "$BUILT" ] && diff -rq "$BUILT.new" "$BUILT" >/dev/null 2>&1; then
  rm -rf "$BUILT.new"
  echo "runner-cowork.sh: plugin unchanged, nothing to upload ($DEST)"
else
  # shellcheck disable=SC2086
  sh "$RENDER" --agent claude-cowork $EXTRA -o "$DEST.new.zip"
  mv "$DEST.new.zip" "$DEST"
  rm -rf "$BUILT"
  mv "$BUILT.new" "$BUILT"
  [ -z "$ZIP_OWNER" ] || chown "$ZIP_OWNER" "$DEST"
  echo "runner-cowork.sh: plugin changed - upload $DEST in Claude's Organization settings > Plugins & skills"
fi
