#!/usr/bin/env bash
# The update watcher: launchd on macOS, systemd or cron on Linux, plus the sidecar
# telemetry that makes the update race countable.
#
# VS Code replaces product.json on every update — monthly for stable, nightly for
# Insiders — on a schedule uncorrelated with MDM check-in, so the watcher is what
# keeps the patch applied. It is also the only part of this ecosystem that installs
# a persistent daemon, so its unit files are linted rather than assumed.
#
# The daemon is never actually loaded (that needs root and would touch the host), so
# launchctl and systemctl are stubbed. What is genuinely under test is the content
# of the files the lib writes.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# Every writable location the watcher code touches is overridable precisely so this
# suite can run without root.
export ENDOR_VSCODE_LAUNCHD_DIR="$W/LaunchDaemons"
export ENDOR_VSCODE_SYSTEMD_DIR="$W/systemd"
export ENDOR_VSCODE_CRON_DIR="$W/cron.hourly"
export ENDOR_VSCODE_LOG="$W/endor.log"
export ENDOR_VSCODE_STATE_DIR="$W/state"
mkdir -p "$ENDOR_VSCODE_LAUNCHD_DIR" "$ENDOR_VSCODE_SYSTEMD_DIR" "$ENDOR_VSCODE_CRON_DIR" "$W/bin"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/launchctl"; chmod +x "$W/bin/launchctl"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/systemctl"; chmod +x "$W/bin/systemctl"

source_stripped_lib "$W"

# Both editions, because the watcher has to cover more than one install.
printf '%s\n%s\n' \
  "/Applications/Visual Studio Code.app/Contents/Resources/app/product.json" \
  "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/product.json" > "$W/paths"

echo "== launchd plist =="
if [ "$(uname -s)" = "Darwin" ]; then
  PATH="$W/bin:$PATH" _vscode_watcher_launchd "$W/repatch.sh" "$W/paths" >/dev/null 2>&1
  PLIST="$ENDOR_VSCODE_LAUNCHD_DIR/com.endorlabs.pkgfirewall.vscode.plist"
  [ -f "$PLIST" ] && ok "plist written" || bad "plist missing"
  plutil -lint "$PLIST" >/dev/null 2>&1 && ok "plutil -lint passes" \
    || bad "plutil -lint FAILED: $(plutil -lint "$PLIST" 2>&1)"
  # Squirrel replaces the whole bundle rather than editing product.json in place, so
  # a watch on the file alone goes stale on the vnode that no longer exists. Both
  # the files and their parent directories have to be watched.
  n=$(/usr/libexec/PlistBuddy -c 'Print :WatchPaths' "$PLIST" 2>/dev/null | grep -c 'product.json\|/app$')
  chk "watches both files and both parent directories" "$n" "4"
  chk "hourly backstop present" \
    "$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$PLIST" 2>/dev/null)" "3600"
  chk "label correct" \
    "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST" 2>/dev/null)" "com.endorlabs.pkgfirewall.vscode"
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" 2>/dev/null | grep -q 'repatch.sh' \
    && ok "invokes the repatch script" || bad "repatch script not referenced"
  # launchd refuses to load a plist that is group- or world-writable.
  chk "plist mode is 644" "$(stat -f '%Lp' "$PLIST")" "644"
else
  skip "launchd plist (needs macOS for plutil/PlistBuddy)"
fi

echo "== systemd units =="
PATH="$W/bin:$PATH" _vscode_watcher_linux "$W/repatch.sh" "$W/paths" >/dev/null 2>&1
for u in service path timer; do
  [ -f "$ENDOR_VSCODE_SYSTEMD_DIR/endor-vscode-firewall.$u" ] && ok "$u unit written" || bad "$u unit missing"
done
chk "4 PathModified entries (both files, both parent dirs)" \
  "$(grep -c '^PathModified=' "$ENDOR_VSCODE_SYSTEMD_DIR/endor-vscode-firewall.path")" "4"
grep -q '^OnUnitActiveSec=1h' "$ENDOR_VSCODE_SYSTEMD_DIR/endor-vscode-firewall.timer" \
  && ok "hourly timer backstop" || bad "timer interval missing"
grep -q '^Type=oneshot' "$ENDOR_VSCODE_SYSTEMD_DIR/endor-vscode-firewall.service" \
  && ok "service is oneshot" || bad "service type wrong"

echo "== cron fallback, for a Linux box without systemd =="
rm -rf "$ENDOR_VSCODE_SYSTEMD_DIR" "$W/bin/systemctl"
_vscode_watcher_linux "$W/repatch.sh" "$W/paths" >/dev/null 2>&1
C="$ENDOR_VSCODE_CRON_DIR/endor-vscode-firewall"
[ -f "$C" ] && ok "cron job written" || bad "cron job missing"
[ -x "$C" ] && ok "cron job is executable" || bad "cron job not executable"
# run-parts skips any name containing a dot, so an extension here would mean the
# job is installed and never runs — a failure that looks like success.
case "$(basename "$C")" in
  *.*) bad "basename has an extension; run-parts would silently skip it" ;;
  *)   ok "basename has no extension (run-parts safe)" ;;
esac
grep -q 'repatch.sh' "$C" && ok "cron job invokes the repatch script" || bad "cron job does not reference repatch"

echo "== sidecar telemetry =="
# The update race cannot be closed — if a developer relaunches VS Code before the
# watcher fires, that session talks to the public marketplace. Counting re-applies
# is what turns it from invisible into visible in an MDM log.
vscode_state_set repatch_count 4
vscode_state_set last_repatch 2026-08-04T12:00:00Z
chk "state round-trips" "$(vscode_state_get repatch_count)" "4"
vscode_state_set repatch_count 5
chk "a key is replaced, not appended" "$(vscode_state_get repatch_count)" "5"
chk "exactly one repatch_count line after the update" \
  "$(grep -c '^repatch_count=' "$ENDOR_VSCODE_STATE_DIR/state")" "1"
vscode_state_report | grep -q '5×' && ok "report surfaces the count for MDM logs" || bad "report empty"
chk "state file is not world-readable" "$(stat -f '%Lp' "$ENDOR_VSCODE_STATE_DIR/state" 2>/dev/null \
  || stat -c '%a' "$ENDOR_VSCODE_STATE_DIR/state")" "600"

summarize
