#!/usr/bin/env bash
# macOS only. End-to-end test of the VS Code firewall daemon (ENDOR_VSCODE_MACOS_DAEMON=1) with
# Microsoft's real VS Code and VS Code's own updater:
#   1. deploy endor-vscode.sh over a running Microsoft copy (OLD), then relaunch the re-signed app;
#   2. stage NEW where VS Code's updater puts a downloaded update, let the daemon prepare it, then
#      quit VS Code and let ShipIt install it, as "Restart to Update" does;
#   3. replace the app with a fresh Microsoft copy and let the daemon migrate it;
#   4. run endor-remove.sh and check that Microsoft's original app is back.
#
# It changes the Mac it runs on: it replaces /Applications/Visual Studio Code.app, installs the
# LaunchDaemon and a signing identity in the System keychain, and runs endor-remove.sh. So it runs
# only on a GitHub-hosted runner, or with ENDOR_E2E_ALLOW_HOST_CHANGES=1 on a disposable Mac (on a
# self-hosted runner, set it in the runner's .env file). It needs passwordless sudo, a logged-in
# GUI session and access to update.code.visualstudio.com.
#
#   ENDOR_E2E_OLD_VERSION, ENDOR_E2E_NEW_VERSION  the VS Code releases to use. By default NEW is
#                            the latest stable release and OLD the newest one of the minor before.
#   ENDOR_E2E_VSCODE_BUILD   darwin-universal (default), darwin-arm64 or darwin (Intel)
#   ENDOR_E2E_ARTIFACTS      where to keep logs: worker, installer, ShipIt, VS Code, Gatekeeper
#
# Logs of root commands are redirected as the user running the test, so they stay readable.
# shellcheck disable=SC2024
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "skip: the VS Code macOS end-to-end test runs on macOS only"
  exit 0
fi
if [[ "${RUNNER_ENVIRONMENT:-}" != "github-hosted" && "${ENDOR_E2E_ALLOW_HOST_CHANGES:-0}" != "1" ]]; then
  echo "refusing to run: this test replaces VS Code and installs a LaunchDaemon on this Mac." >&2
  echo "  Run it on a GitHub-hosted runner, or set ENDOR_E2E_ALLOW_HOST_CHANGES=1 on a disposable Mac." >&2
  exit 2
fi
if ! sudo -n true 2>/dev/null; then
  echo "this test needs passwordless sudo" >&2
  exit 2
fi

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
GENERATOR="$ROOT_DIR/package-firewall/bash/generate.sh"
NAMESPACE="ci-e2e"
OUT="$ROOT_DIR/package-firewall/bash/out/$NAMESPACE"
FIREWALL_PREFIX="https://factory.endorlabs.com/v1/namespaces/$NAMESPACE/firewall/vscode/_ak/"

APP="/Applications/Visual Studio Code.app"
BUNDLE_ID="com.microsoft.VSCode"
PRODUCT_REL="Contents/Resources/app/product.json"
MS_REQ="identifier \"$BUNDLE_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = UBF8T346G9"
STATE_DIR="/Library/Application Support/Endor Labs/vscode-firewall"
WORKER="$STATE_DIR/worker.sh"
DAEMON_LABEL="com.endorlabs.vscode-firewall"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
WORKER_LOG="/Library/Logs/Endor Labs/vscode-firewall.log"
SHIPIT_DIR="$HOME/Library/Caches/$BUNDLE_ID.ShipIt"
SHIPIT_LABEL="$BUNDLE_ID.ShipIt"

BUILD="${ENDOR_E2E_VSCODE_BUILD:-darwin-universal}"
case "$BUILD" in
  darwin-universal|darwin-arm64|darwin) ;;
  *) echo "ENDOR_E2E_VSCODE_BUILD must be darwin-universal, darwin-arm64 or darwin" >&2; exit 2 ;;
esac

WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vscode-e2e.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
ARTIFACTS="${ENDOR_E2E_ARTIFACTS:-${TMPDIR:-/tmp}/vscode-e2e-artifacts}"
mkdir -p "$ARTIFACTS"
PROFILE="$WORK/profile"
START_TS=$(date '+%Y-%m-%d %H:%M:%S')
touch "$WORK/start"
STEP=""
WAITED=0
SHA1=""
OURS_REQ=""
STAGED=""

# ── Reporting ─────────────────────────────────────────────────────────────────

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
  return 0
}
step() { STEP="$1"; printf '\n=== %s\n' "$1"; summary "" "**$1**" ""; }
pass() { printf 'PASS: %s\n' "$1"; summary "- ✅ $1"; }
info() { printf 'INFO: %s\n' "$1"; summary "- ℹ️ $1"; }
fail() { printf 'FAIL: %s: %s\n' "$STEP" "$1" >&2; summary "- ❌ $1"; exit 1; }

# wait_until <seconds> <command...>: poll every 2s until the command succeeds; sets WAITED.
wait_until() {
  local limit="$1"
  shift
  WAITED=0
  until "$@"; do
    if (( WAITED >= limit )); then
      return 1
    fi
    sleep 2
    WAITED=$((WAITED + 2))
  done
}

# ── VS Code ───────────────────────────────────────────────────────────────────

info_value() { /usr/bin/plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null; }
cs_ok() { /usr/bin/codesign --verify --deep --strict -R "=$2" "$1" >/dev/null 2>&1; }
cdhash() { /usr/bin/codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
designated_of() { /usr/bin/codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
lower() { printf '%s' "$1" | tr 'A-F' 'a-f'; }

is_firewalled() {
  local url
  url=$(/usr/bin/plutil -extract extensionsGallery.serviceUrl raw -o - "$1/$PRODUCT_REL" 2>/dev/null) || return 1
  [[ "$url" == "$FIREWALL_PREFIX"* ]] \
    && ! /usr/bin/plutil -extract extensionsGallery.extensionUrlTemplate raw -o - "$1/$PRODUCT_REL" >/dev/null 2>&1
}

version_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1
  }'
}

resolve_versions() {
  local releases v
  NEW="${ENDOR_E2E_NEW_VERSION:-}"
  OLD="${ENDOR_E2E_OLD_VERSION:-}"
  if [[ -z "$NEW" || -z "$OLD" ]]; then
    releases=$(/usr/bin/curl -fsSL --retry 3 https://update.code.visualstudio.com/api/releases/stable \
      | tr -d '[]" ' | tr ',' '\n') || fail "could not list VS Code releases"
    [[ -n "$NEW" ]] || NEW=$(printf '%s\n' "$releases" | head -n 1)
    if [[ -z "$OLD" ]]; then
      OLD=$(printf '%s\n' "$releases" | awk -F. -v n="$NEW" \
        'BEGIN { split(n, v, ".") } $1 != v[1] || $2 != v[2] { print; exit }')
    fi
  fi
  for v in "$OLD" "$NEW"; do
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "not a VS Code version: \"$v\""
  done
  version_lt "$OLD" "$NEW" || fail "VS Code $OLD is not older than $NEW"
}

# fetch_vscode <version> <dest.app>: Microsoft's build, unpacked. curl sets no quarantine.
fetch_vscode() {
  local zip="$WORK/VSCode-$1.zip" tmp
  /usr/bin/curl -fL --retry 3 -sS -o "$zip" "https://update.code.visualstudio.com/$1/$BUILD/stable" \
    || fail "could not download VS Code $1 ($BUILD)"
  tmp=$(mktemp -d "$WORK/unzip.XXXXXX")
  /usr/bin/ditto -x -k "$zip" "$tmp" || fail "could not unpack VS Code $1"
  mv "$tmp/Visual Studio Code.app" "$2"
  rm -rf "$tmp" "$zip"
  cs_ok "$2" "$MS_REQ" || fail "VS Code $1 from Microsoft does not verify"
}

# main_pids: VS Code main processes started from $APP, whichever bundle is there now.
main_pids() {
  /bin/ps -axo pid=,comm= \
    | P="$APP/Contents/MacOS/" awk '{ pid = $1; sub(/^ *[0-9]+ /, "") } index($0, ENVIRON["P"]) == 1 { print pid }'
}
vscode_running() { [[ -n "$(main_pids)" ]]; }
vscode_stopped() { ! vscode_running; }

# launch_vscode: open $APP with a throwaway profile, as a user would (through LaunchServices).
launch_vscode() {
  mkdir -p "$PROFILE/User" "$WORK/extensions"
  if [[ ! -f "$PROFILE/User/settings.json" ]]; then
    # update.mode none: VS Code's own updater must not stage a real update next to the test's.
    printf '%s\n' '{' '  "update.mode": "none",' '  "telemetry.telemetryLevel": "off",' \
      '  "workbench.startupEditor": "none",' '  "extensions.autoCheckUpdates": false' '}' \
      > "$PROFILE/User/settings.json"
  fi
  touch "$WORK/launched"
  sleep 1
  env -u ELECTRON_RUN_AS_NODE /usr/bin/open -n -g -a "$APP" --args \
    --user-data-dir "$PROFILE" --extensions-dir "$WORK/extensions" --use-mock-keychain \
    --skip-welcome --skip-release-notes --disable-workspace-trust || fail "could not open $APP"
}

extension_host_started() {
  [[ -n "$(find "$PROFILE/logs" -name exthost.log -newer "$WORK/launched" 2>/dev/null | head -n 1)" ]]
}

# check_launch <what>: the VS Code just launched runs a window and an extension host and stays up.
check_launch() {
  local procs
  wait_until 120 extension_host_started || fail "$1: the extension host did not start within 120s"
  sleep 5
  vscode_running || fail "$1: VS Code quit right after starting"
  procs=$(/bin/ps -axo comm=)
  [[ "$procs" == *"$APP/Contents/Frameworks/Code Helper (Renderer).app/"* ]] \
    || fail "$1: no renderer process is running"
  if [[ -n "$(find "$HOME/Library/Logs/DiagnosticReports" -name 'Code-*' -newer "$WORK/launched" 2>/dev/null)" ]]; then
    fail "$1: VS Code wrote a crash report"
  fi
  pass "$1 runs: its window and extension host started within ${WAITED}s"
}

quit_vscode() {
  local pid
  for pid in $(main_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  if ! wait_until 60 vscode_stopped; then
    for pid in $(main_pids); do kill -KILL "$pid" 2>/dev/null || true; done
    wait_until 20 vscode_stopped || fail "VS Code did not quit"
  fi
}

# ── The firewall ──────────────────────────────────────────────────────────────

generate() {
  ENDOR_NAMESPACE="$NAMESPACE" \
    ENDOR_API_KEY_ID="ci-e2e-key-id" \
    ENDOR_API_SECRET="ci-e2e-secret" \
    ENDOR_VSCODE_MACOS_DAEMON=1 \
    bash "$GENERATOR" >/dev/null
}

worker_status() { sudo /bin/bash "$WORKER" --status 2>/dev/null; }

# live_is <state> <version>: the worker classifies the installed app as this state and version.
live_is() {
  local s
  s=$(worker_status) || return 1
  grep -q "^state *: $1 " <<< "$s" && grep -q "^version *: $2\$" <<< "$s"
}

# check_signed <app> <what>: patched and signed by this Mac the way the worker signs.
check_signed() {
  local dr out
  cs_ok "$1" "$OURS_REQ" || fail "$2 does not verify (deep, strict) as signed by this Mac"
  dr=$(lower "$(designated_of "$1")")
  [[ "$dr" == *ubf8t346g9* && "$dr" == *"h\"$SHA1\""* ]] \
    || fail "$2 has an unexpected designated requirement: $dr"
  out=$(/usr/bin/codesign -dv "$1" 2>&1)
  [[ "$out" == *"(runtime)"* ]] || fail "$2 is not signed with the hardened runtime"
  out=$(/usr/bin/codesign -d --entitlements - "$1" 2>/dev/null)
  [[ "$out" == *com.apple.security.cs.disable-library-validation* ]] \
    || fail "$2 lacks the disable-library-validation entitlement"
  if /usr/bin/xattr -p com.apple.quarantine "$1" >/dev/null 2>&1; then
    fail "$2 is quarantined"
  fi
  is_firewalled "$1" || fail "$2: product.json does not point at the firewall"
  pass "$2 is patched and signed by this Mac; its requirement also accepts Microsoft's builds"
}

file_url() { printf 'file://%s/' "$(printf '%s' "$1" | sed 's/%/%25/g; s/ /%20/g')"; }

# stage_update: put Microsoft's NEW where VS Code's updater (Squirrel) leaves a downloaded update.
stage_update() {
  local upd
  mkdir -p "$SHIPIT_DIR"
  upd=$(mktemp -d "$SHIPIT_DIR/update.XXXXXXX")
  STAGED="$upd/Visual Studio Code.app"
  /usr/bin/ditto "$WORK/ms-new.app" "$STAGED"
  # Squirrel writes the state file last, once the update is unpacked and verified.
  printf '{"targetBundleURL":"%s","updateBundleURL":"%s","bundleIdentifier":"%s","launchAfterInstallation":false,"useUpdateBundleName":false}\n' \
    "$(file_url "$APP")" "$(file_url "$STAGED")" "$BUNDLE_ID" > "$SHIPIT_DIR/ShipItState.plist.tmp"
  mv "$SHIPIT_DIR/ShipItState.plist.tmp" "$SHIPIT_DIR/ShipItState.plist"
}

staged_prepared() { [[ -d "$STAGED" ]] && cs_ok "$STAGED" "$OURS_REQ" && is_firewalled "$STAGED"; }

# start_shipit: run the installed app's ShipIt as a launchd job in the user's GUI session, the
# way Squirrel does. It installs the staged update once VS Code quits.
start_shipit() {
  local shipit="$APP/Contents/Frameworks/Squirrel.framework/Resources/ShipIt" plist="$WORK/shipit-job.plist"
  [[ -x "$shipit" ]] || fail "there is no ShipIt in $APP"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$SHIPIT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$shipit</string>
    <string>$SHIPIT_LABEL</string>
    <string>$SHIPIT_DIR/ShipItState.plist</string>
  </array>
  <key>MachServices</key><dict><key>$SHIPIT_LABEL</key><true/></dict>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>RunAtLoad</key><true/>
  <key>ThrottleInterval</key><integer>2</integer>
  <key>StandardOutPath</key><string>$WORK/shipit.log</string>
  <key>StandardErrorPath</key><string>$WORK/shipit.log</string>
</dict>
</plist>
PLIST
  stop_shipit
  /bin/launchctl bootstrap "gui/$(id -u)" "$plist" || fail "could not start ShipIt as a launchd job"
}
stop_shipit() { /bin/launchctl bootout "gui/$(id -u)/$SHIPIT_LABEL" >/dev/null 2>&1 || true; }
shipit_finished() {
  grep -qE 'Installation completed successfully|aborting update|Too many attempts' "$WORK/shipit.log" 2>/dev/null
}

collect_artifacts() {
  sudo cat "$WORKER_LOG" > "$ARTIFACTS/worker.log" 2>/dev/null
  if sudo test -f "$WORKER"; then
    worker_status > "$ARTIFACTS/worker-status.txt"
  fi
  cp "$WORK/shipit.log" "$ARTIFACTS/" 2>/dev/null
  if [[ -d "$PROFILE/logs" ]]; then
    cp -R "$PROFILE/logs" "$ARTIFACTS/vscode-logs"
  fi
  find "$HOME/Library/Logs/DiagnosticReports" -name 'Code*' -newer "$WORK/start" \
    -exec cp {} "$ARTIFACTS/" \; 2>/dev/null
  /usr/bin/log show --start "$START_TS" --style compact \
    --predicate 'process == "syspolicyd" OR process == "amfid" OR subsystem BEGINSWITH "com.apple.syspolicy"' \
    > "$ARTIFACTS/gatekeeper.log" 2>&1
}

finish() {
  local rc=$? pid
  set +e
  stop_shipit
  for pid in $(main_pids); do kill -KILL "$pid" 2>/dev/null; done
  collect_artifacts
  # Leave a reusable Mac as it was found when a step failed halfway.
  if [[ -e "$DAEMON_PLIST" && -f "$OUT/endor-remove.sh" ]]; then
    sudo /bin/bash "$OUT/endor-remove.sh" >> "$ARTIFACTS/teardown.log" 2>&1
  fi
  rm -rf "$WORK"
  if [[ "$rc" -eq 0 ]]; then
    summary "" "All checks passed."
  fi
  echo "logs: $ARTIFACTS"
  exit "$rc"
}
trap finish EXIT

# ── The test ──────────────────────────────────────────────────────────────────

resolve_versions
summary "### VS Code end-to-end on macOS $(sw_vers -productVersion) ($(uname -m))"
step "Environment"
info "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
info "$(csrutil status 2>&1 | head -n 1)"
info "Gatekeeper: $(spctl --status 2>&1)"
info "VS Code $OLD, then $NEW ($BUILD)"

step "Install Microsoft's VS Code $OLD and open it"
if [[ -e "$DAEMON_PLIST" ]]; then
  fail "an Endor VS Code daemon is already installed on this Mac"
fi
fetch_vscode "$OLD" "$WORK/ms-old.app"
fetch_vscode "$NEW" "$WORK/ms-new.app"
OLD_BV=$(info_value "$WORK/ms-old.app" CFBundleVersion)
NEW_BV=$(info_value "$WORK/ms-new.app" CFBundleVersion)
if [[ -e "$APP" ]]; then
  info "replacing the VS Code that was already installed"
  sudo rm -rf "$APP"
fi
rm -rf "$SHIPIT_DIR"
/usr/bin/ditto "$WORK/ms-old.app" "$APP" || fail "could not install VS Code $OLD"
launch_vscode
check_launch "Microsoft's VS Code $OLD"

step "Deploy endor-vscode.sh while VS Code $OLD is running"
generate || fail "generate.sh failed"
running=$(main_pids | head -n 1)
if ! sudo /bin/bash "$OUT/endor-vscode.sh" > "$ARTIFACTS/install.log" 2>&1; then
  tail -n 30 "$ARTIFACTS/install.log" >&2
  fail "endor-vscode.sh exited non-zero"
fi
pass "endor-vscode.sh succeeded"
sudo /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1 || fail "the LaunchDaemon is not loaded"
pass "the LaunchDaemon is loaded"
SHA1=$(lower "$(sudo cat "$STATE_DIR/signing/cert.sha1" 2>/dev/null)")
[[ "$SHA1" =~ ^[0-9a-f]{40}$ ]] || fail "the worker recorded no signing identity"
OURS_REQ="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SHA1\""
live_is B "$OLD_BV" || fail "the worker does not report state B: $(worker_status | grep '^state')"
pass "the worker reports state B (patched, signed by this Mac, nothing left to do)"
check_signed "$APP" "VS Code $OLD"
sudo test -d "$STATE_DIR/pristine/$OLD_BV" || fail "Microsoft's original VS Code $OLD was not kept"
pass "Microsoft's original VS Code $OLD is kept for removal"
if kill -0 "$running" 2>/dev/null; then
  pass "the VS Code that was running during the swap is still running"
else
  fail "the VS Code that was running during the swap quit"
fi

step "Relaunch the re-signed VS Code $OLD"
quit_vscode
launch_vscode
check_launch "The re-signed VS Code $OLD"

step "Stage VS Code $NEW as a downloaded update"
stage_update
wait_until 240 staged_prepared || fail "the daemon did not prepare the staged update within 240s"
pass "the daemon patched and signed the staged update within ${WAITED}s"
cs_ok "$STAGED" "$(designated_of "$APP")" \
  || fail "the prepared update fails the installed app's designated requirement, so ShipIt would reject it"
pass "the prepared update meets the installed app's designated requirement, which is ShipIt's check"
sudo test -d "$STATE_DIR/pristine/$NEW_BV" || fail "Microsoft's original VS Code $NEW was not kept"
pass "Microsoft's original VS Code $NEW is kept for removal"

step "Restart to Update: ShipIt installs VS Code $NEW"
start_shipit
quit_vscode
wait_until 240 shipit_finished || fail "ShipIt did not finish within 240s"
grep -q 'Installation completed successfully' "$WORK/shipit.log" \
  || fail "ShipIt did not install the update: $(grep -iE 'error|abort' "$WORK/shipit.log" | tail -n 3)"
stop_shipit
[[ "$(info_value "$APP" CFBundleVersion)" == "$NEW_BV" ]] || fail "VS Code $NEW is not installed after ShipIt ran"
pass "ShipIt installed the prepared VS Code $NEW"
check_signed "$APP" "The updated VS Code $NEW"
wait_until 120 live_is B "$NEW_BV" || fail "the worker does not report state B after the update"
pass "the worker reports state B for VS Code $NEW"
launch_vscode
check_launch "The updated VS Code $NEW"
quit_vscode

step "Replace the app with a fresh Microsoft copy of VS Code $NEW"
sudo /bin/mv "$APP" "$WORK/replaced.app" || fail "could not move the installed app away"
/usr/bin/ditto "$WORK/ms-new.app" "$WORK/ms-new-copy.app"
sudo /bin/mv "$WORK/ms-new-copy.app" "$APP" || fail "could not put a fresh copy in place"
wait_until 240 live_is B "$NEW_BV" || fail "the daemon did not migrate the fresh copy within 240s"
pass "the daemon migrated the fresh copy within ${WAITED}s"
check_signed "$APP" "The migrated VS Code $NEW"
sudo rm -rf "$WORK/replaced.app"

step "Remove with endor-remove.sh"
if ! sudo /bin/bash "$OUT/endor-remove.sh" > "$ARTIFACTS/remove.log" 2>&1; then
  tail -n 30 "$ARTIFACTS/remove.log" >&2
  fail "endor-remove.sh exited non-zero"
fi
pass "endor-remove.sh succeeded"
cs_ok "$APP" "$MS_REQ" || fail "VS Code is not Microsoft-signed after removal"
[[ "$(cdhash "$APP")" == "$(cdhash "$WORK/ms-new.app")" ]] \
  || fail "the restored app is not Microsoft's original build"
cmp -s "$APP/$PRODUCT_REL" "$WORK/ms-new.app/$PRODUCT_REL" || fail "product.json differs from Microsoft's"
pass "Microsoft's original VS Code $NEW is back: same CDHash and product.json"
if sudo /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1 || [[ -e "$DAEMON_PLIST" ]]; then
  fail "the LaunchDaemon is still installed"
fi
if sudo test -e "$STATE_DIR"; then
  fail "$STATE_DIR is still there"
fi
certs=$(lower "$(security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null)")
[[ "$certs" != *"$SHA1"* ]] || fail "the signing certificate is still in the System keychain"
pass "the LaunchDaemon, its state and the signing identity are gone"
if [[ "$(spctl --status 2>&1)" == *enabled* ]]; then
  out=$(spctl -a -vv -t exec "$APP" 2>&1) || true
  [[ "$out" == *"Notarized Developer ID"* ]] || fail "Gatekeeper does not accept the restored app: $out"
  pass "Gatekeeper accepts the restored app as Notarized Developer ID"
else
  info "Gatekeeper assessments are off on this Mac, so spctl was not checked"
fi
launch_vscode
check_launch "The restored VS Code $NEW"
quit_vscode
