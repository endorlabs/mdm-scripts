#!/usr/bin/env bash
# macOS only. End-to-end test of VS Code's ExtensionGalleryServiceUrl policy, with Microsoft's
# real VS Code:
#   1. put the keys of the generated endor-vscode.mobileconfig where an MDM profile puts them,
#      /Library/Managed Preferences/com.microsoft.VSCode.plist, and check that endor-vscode.sh
#      reports the policy as set;
#   2. launch VS Code with trace logging, and check in its logs that it uses the Endor gallery
#      and, with no account signed in, keeps the Marketplace off;
#   3. check that endor-vscode-disable-policy.sh warns while the managed preference is there, and
#      not once it is gone.
#
# It writes to /Library/Managed Preferences and restarts cfprefsd, so it runs only on a
# GitHub-hosted runner, or with ENDOR_E2E_ALLOW_HOST_CHANGES=1 on a disposable Mac. It needs
# passwordless sudo and access to update.code.visualstudio.com. It uses a throwaway credential,
# which VS Code writes to its trace log.
#
#   ENDOR_E2E_VERSION    the VS Code release to use (default: the latest stable)
#   ENDOR_E2E_ARTIFACTS  where to keep logs: installer, disable script, VS Code
#
# Logs of root commands are redirected as the user running the test, so they stay readable.
# shellcheck disable=SC2024
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "skip: the VS Code macOS policy end-to-end test runs on macOS only"
  exit 0
fi
if [[ "${RUNNER_ENVIRONMENT:-}" != "github-hosted" && "${ENDOR_E2E_ALLOW_HOST_CHANGES:-0}" != "1" ]]; then
  echo "refusing to run: this test writes VS Code's managed preferences on this Mac." >&2
  echo "  Run it on a GitHub-hosted runner, or set ENDOR_E2E_ALLOW_HOST_CHANGES=1 on a disposable Mac." >&2
  exit 2
fi
if ! sudo -n true 2>/dev/null; then
  echo "this test needs passwordless sudo" >&2
  exit 2
fi
MANAGED_DIR="/Library/Managed Preferences"
MANAGED="$MANAGED_DIR/com.microsoft.VSCode.plist"
if [[ -e "$MANAGED" ]]; then
  echo "refusing to run: $MANAGED already exists, so an MDM manages VS Code on this Mac." >&2
  exit 2
fi

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
NAMESPACE="ci-e2e-policy"
OUT="$ROOT_DIR/package-firewall/bash/out/$NAMESPACE"
FIREWALL_PREFIX="https://factory.endorlabs.com/v1/namespaces/$NAMESPACE/firewall/vscode/_ak/"
WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vscode-policy-e2e.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
APP="$WORK/Visual Studio Code.app"
PROFILE="$WORK/profile"
ARTIFACTS="${ENDOR_E2E_ARTIFACTS:-${TMPDIR:-/tmp}/vscode-policy-e2e-artifacts}"
mkdir -p "$ARTIFACTS"
STEP=""
WAITED=0

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
  return 0
}
step() { STEP="$1"; printf '\n=== %s\n' "$1"; summary "" "**$1**" ""; }
pass() { printf 'PASS: %s\n' "$1"; summary "- ✅ $1"; }
fail() { printf 'FAIL: %s: %s\n' "$STEP" "$1" >&2; summary "- ❌ $1"; exit 1; }

# wait_until <seconds> <command...>: poll every 2s until the command succeeds; sets WAITED.
wait_until() {
  local limit="$1" start=$SECONDS
  shift
  until "$@"; do
    WAITED=$((SECONDS - start))
    if (( WAITED >= limit )); then
      return 1
    fi
    sleep 2
  done
  WAITED=$((SECONDS - start))
}

main_pids() {
  /bin/ps -axo pid=,comm= \
    | P="$APP/Contents/MacOS/" awk '{ pid = $1; sub(/^ *[0-9]+ /, "") } index($0, ENVIRON["P"]) == 1 { print pid }'
}
vscode_stopped() { [[ -z "$(main_pids)" ]]; }
quit_vscode() {
  local pid
  for pid in $(main_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  if ! wait_until 60 vscode_stopped; then
    for pid in $(main_pids); do kill -KILL "$pid" 2>/dev/null || true; done
  fi
}

# Managed preferences are cached by cfprefsd; restart it so changes to the file take effect.
reload_preferences() { sudo /usr/bin/killall cfprefsd >/dev/null 2>&1 || true; }

cleanup() {
  quit_vscode
  sudo /bin/rm -f "$MANAGED"
  reload_preferences
  if [[ -d "$PROFILE/logs" ]]; then
    cp -R "$PROFILE/logs" "$ARTIFACTS/vscode-logs"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# logs_say <text>: some VS Code log written since the launch contains the text.
logs_say() { grep -rqF -- "$1" "$PROFILE/logs" 2>/dev/null; }
signed_out_logged() {
  logs_say "[Marketplace] Enterprise marketplace configured but user not signed in" \
    || logs_say "[Marketplace] User signed out"
}

step "Download VS Code"
VERSION="${ENDOR_E2E_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION=$(/usr/bin/curl -fsSL --retry 3 https://update.code.visualstudio.com/api/releases/stable \
    | tr -d '[]" ' | tr ',' '\n' | head -n 1) || fail "could not list VS Code releases"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "not a VS Code version: \"$VERSION\""
/usr/bin/curl -fL --retry 3 -sS -o "$WORK/vscode.zip" "https://update.code.visualstudio.com/$VERSION/darwin-universal/stable" \
  || fail "could not download VS Code $VERSION"
/usr/bin/ditto -x -k "$WORK/vscode.zip" "$WORK" || fail "could not unpack VS Code $VERSION"
[[ -d "$APP" ]] || fail "the download has no Visual Studio Code.app"
pass "VS Code $VERSION"

step "Install the policy the way an MDM profile does"
ENDOR_NAMESPACE="$NAMESPACE" ENDOR_API_KEY_ID="ci-e2e-key-id" ENDOR_API_SECRET="ci-e2e-secret" \
  ENDOR_VSCODE_ENABLE_POLICY=1 bash "$ROOT_DIR/package-firewall/bash/generate.sh" >/dev/null
/usr/bin/plutil -lint -s "$OUT/endor-vscode.mobileconfig" || fail "the generated profile is not a valid property list"
# macOS writes a profile's payload, without its Payload* keys, to managed preferences.
/usr/bin/plutil -extract PayloadContent.0 xml1 -o "$WORK/payload.plist" "$OUT/endor-vscode.mobileconfig" \
  || fail "the profile has no payload"
[[ "$(/usr/bin/plutil -extract PayloadType raw -o - "$WORK/payload.plist")" == "com.microsoft.VSCode" ]] \
  || fail "the payload is not for com.microsoft.VSCode"
for key in PayloadDisplayName PayloadIdentifier PayloadType PayloadUUID PayloadVersion; do
  /usr/bin/plutil -remove "$key" "$WORK/payload.plist"
done
sudo /bin/mkdir -p "$MANAGED_DIR"
sudo /usr/bin/install -m 0644 -o root -g wheel "$WORK/payload.plist" "$MANAGED"
reload_preferences
sudo env ENDOR_VSCODE_APP="$APP" bash "$OUT/endor-vscode.sh" > "$ARTIFACTS/install.log" 2>&1 \
  || fail "endor-vscode.sh exited non-zero (see install.log)"
grep -qF "VS Code's policy is set by a configuration profile." "$ARTIFACTS/install.log" \
  || fail "endor-vscode.sh did not find the policy (see install.log)"
if grep -q "doesn't read" "$ARTIFACTS/install.log"; then
  fail "endor-vscode.sh says VS Code $VERSION is too old for the policy"
fi
pass "endor-vscode.sh reports the policy as set by a configuration profile"

step "Launch VS Code"
mkdir -p "$PROFILE/User" "$WORK/extensions"
printf '%s\n' '{' '  "update.mode": "none",' '  "telemetry.telemetryLevel": "off",' \
  '  "workbench.startupEditor": "none"' '}' > "$PROFILE/User/settings.json"
env -u ELECTRON_RUN_AS_NODE /usr/bin/open -n -g -a "$APP" --args \
  --user-data-dir "$PROFILE" --extensions-dir "$WORK/extensions" --use-mock-keychain \
  --skip-welcome --skip-release-notes --disable-workspace-trust --log trace || fail "could not open VS Code"
wait_until 180 logs_say "[Marketplace] Private marketplace configured" \
  || fail "VS Code did not log that a private marketplace is configured within 180s"
pass "VS Code uses the policy's gallery ${WAITED}s after launch"
if ! grep -rqF -- "$FIREWALL_PREFIX" "$PROFILE/logs"; then
  fail "VS Code's logs don't show the Endor gallery URL"
fi
wait_until 60 signed_out_logged \
  || fail "VS Code did not log that the Marketplace needs a sign-in within 60s"
pass "with no account signed in, VS Code keeps the Marketplace off"
quit_vscode

step "Turn the policy off"
if sudo bash "$OUT/endor-vscode-disable-policy.sh" > "$ARTIFACTS/disable-policy.log" 2>&1; then
  fail "endor-vscode-disable-policy.sh exited 0 while a profile sets the policy"
fi
grep -qF "Remove the profile in your MDM" "$ARTIFACTS/disable-policy.log" \
  || fail "endor-vscode-disable-policy.sh did not say to remove the profile (see disable-policy.log)"
pass "endor-vscode-disable-policy.sh warns while the profile is installed"
sudo /bin/rm -f "$MANAGED"
reload_preferences
sudo bash "$OUT/endor-vscode-disable-policy.sh" >> "$ARTIFACTS/disable-policy.log" 2>&1 \
  || fail "endor-vscode-disable-policy.sh exited non-zero once the profile was gone (see disable-policy.log)"
pass "endor-vscode-disable-policy.sh is clean once the profile is gone"
echo "VS Code macOS policy end-to-end test passed"
