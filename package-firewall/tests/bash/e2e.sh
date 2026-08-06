#!/usr/bin/env bash
# End-to-end, using the scripts generate.sh actually produces: the inlined lib, the
# credentials block, the embedded repatch payload, the watcher, and remove.sh.
#
# The generators write to <generator dir>/out/<namespace> with no override, so the
# working tree is copied into a sandbox and the generator is run there. That keeps
# the checkout clean and lets the rotation case regenerate with different
# credentials for free.
#
# Install discovery is redirected into the sandbox by rewriting the absolute install
# roots in the generated scripts. That is a safety requirement, not a convenience:
# without it this suite would patch the real VS Code on the machine running it. The
# redirect is verified before anything executes.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_json_tool

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

export ENDOR_VSCODE_STATE_DIR="$SB/state"
export ENDOR_VSCODE_LAUNCHD_DIR="$SB/LaunchDaemons"
export ENDOR_VSCODE_SYSTEMD_DIR="$SB/systemd"
export ENDOR_VSCODE_CRON_DIR="$SB/cron.hourly"
export ENDOR_VSCODE_LOG="$SB/endor.log"
mkdir -p "$ENDOR_VSCODE_LAUNCHD_DIR" "$ENDOR_VSCODE_SYSTEMD_DIR" "$ENDOR_VSCODE_CRON_DIR" \
         "$SB/home" "$SB/bin"

# Loading a real system daemon needs root and would touch the host. The unit files
# themselves are still written, and watcher.sh lints them.
for stub in launchctl systemctl; do
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/$stub"; chmod +x "$SB/bin/$stub"
done
export PATH="$SB/bin:$PATH"

echo "== 0. generate from the working tree, in a sandbox =="
copy_package_firewall "$SB/pf"
gen() {
  ENDOR_NAMESPACE=spiderman ENDOR_API_KEY_ID=TESTKEYID ENDOR_API_SECRET="$1" \
    "$SB/pf/bash/generate.sh" >"$SB/gen.log" 2>&1
}
if gen TESTSECRET; then ok "generate.sh succeeded"; else bad "generate.sh failed: $(cat "$SB/gen.log")"; fi
OUT="$SB/pf/bash/out/spiderman"
for f in endor-vscode.sh endor-vscode-repatch.sh endor-remove.sh; do
  [ -f "$OUT/$f" ] && ok "generated $f" || bad "missing $f"
done
bash -n "$OUT/endor-vscode.sh" && ok "endor-vscode.sh parses" || bad "endor-vscode.sh has a syntax error"

echo "== 1. build fixture installs and redirect discovery into the sandbox =="
if [ "$(uname -s)" = "Darwin" ]; then
  make_macos_app "$SB/Applications" "Visual Studio Code.app"            "Visual Studio Code"
  make_macos_app "$SB/Applications" "Visual Studio Code - Insiders.app" "Visual Studio Code - Insiders"
  PJ="$SB/Applications/Visual Studio Code.app/Contents/Resources/app/product.json"
  PJI="$SB/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/product.json"
else
  mkdir -p "$SB/usr/share/code/resources/app" "$SB/usr/share/code-insiders/resources/app"
  set_name_long "$FIXTURE" "$SB/usr/share/code/resources/app/product.json"          "Visual Studio Code"
  set_name_long "$FIXTURE" "$SB/usr/share/code-insiders/resources/app/product.json" "Visual Studio Code - Insiders"
  PJ="$SB/usr/share/code/resources/app/product.json"
  PJI="$SB/usr/share/code-insiders/resources/app/product.json"
fi
cp "$PJ" "$SB/pristine-stable.json"
cp "$PJI" "$SB/pristine-insiders.json"

# sandbox <src> <dst> — rewrite the absolute install roots and USER_HOME so nothing
# outside the sandbox is reachable. USER_HOME matters because remove.sh strips
# env.sh and shell-rc lines, and a test must never reach into a real home directory.
sandbox() {
  sed -e "s#\"/Applications/Visual Studio Code#\"$SB/Applications/Visual Studio Code#g" \
      -e "s#\"/usr/share/code#\"$SB/usr/share/code#g" \
      -e "s#\"/opt/visual-studio-code#\"$SB/opt/visual-studio-code#g" \
      -e "s#\"/usr/lib/code#\"$SB/usr/lib/code#g" \
      -e "s#\"/snap/code#\"$SB/snap/code#g" \
      -e "s#^USER_HOME=.*#USER_HOME=\"$SB/home\"#" \
      "$1" > "$2"
  chmod 700 "$2"
}
sandbox "$OUT/endor-vscode.sh" "$SB/vscode.sh"
sandbox "$OUT/endor-remove.sh" "$SB/remove.sh"

# Refuse to run if any real install root survived the rewrite.
leaked=$(grep -c -e '"/Applications/Visual Studio Code' -e '"/usr/share/code' -e '"/opt/visual-studio-code' \
                 "$SB/vscode.sh" "$SB/remove.sh" | awk -F: '{ s += $2 } END { print s+0 }')
if [ "$leaked" -eq 0 ]; then
  ok "no real install root reachable from the sandboxed scripts"
else
  bad "$leaked unsandboxed install path(s) remain — refusing to run"
  summarize; exit 1
fi

echo "== 2. install patches both editions =="
out=$("$SB/vscode.sh" 2>&1); rc=$?
chk "exit 0" "$rc" "0"
if json_ok "$PJ" && json_ok "$PJI"; then ok "both product.json valid"; else bad "invalid JSON: $out"; fi
grep -qF '/firewall/vscode/_ak/' "$PJ"  && ok "stable points at the firewall"   || bad "stable not patched"
grep -qF '/firewall/vscode/_ak/' "$PJI" && ok "Insiders points at the firewall" || bad "Insiders not patched"
# The security-relevant half of the patch: with extensionUrlTemplate present, a
# firewall 5xx resolves versions straight from www.vscode-unpkg.net.
grep -qF '"extensionUrlTemplate"' "$PJ" && bad "unpkg fallback survived" || ok "unpkg fallback removed"
grep -qF 'main.vscode-cdn.net' "$PJ" && ok "controlUrl (Microsoft's revocation list) preserved" \
  || bad "controlUrl lost"
case "$out" in *"Visual Studio Code - Insiders"*) ok "Insiders reported by name" ;;
               *) bad "Insiders not named in the output" ;; esac
chk "token is attributed to the console user" \
  "$(jget "$PJ" "d['_endorPackageFirewall']['namespace']")" "spiderman"

echo "== 3. watcher and sidecar =="
REPATCH="$ENDOR_VSCODE_STATE_DIR/endor-vscode-repatch.sh"
[ -x "$REPATCH" ] && ok "repatch payload decoded and executable" || bad "repatch payload missing"
# Not `cp "$0"`: MDM tools routinely pipe the script to bash or exec it from a temp
# file that is already unlinked by the time the watcher fires.
chk "repatch payload mode is 700" "$(stat -f '%Lp' "$REPATCH" 2>/dev/null || stat -c '%a' "$REPATCH")" "700"
bash -n "$REPATCH" && ok "repatch payload parses" || bad "repatch payload is broken"
if cmp -s "$REPATCH" "$OUT/endor-vscode-repatch.sh"; then
  ok "payload is byte-identical to the standalone generated copy"
else
  bad "payload differs from out/endor-vscode-repatch.sh"
fi
chk "state file mode is 600" \
  "$(stat -f '%Lp' "$ENDOR_VSCODE_STATE_DIR/state" 2>/dev/null || stat -c '%a' "$ENDOR_VSCODE_STATE_DIR/state")" "600"
grep -qF '/firewall/vscode/_ak/' "$ENDOR_VSCODE_STATE_DIR/state" \
  && ok "gallery_url recorded for the watcher to reuse" || bad "no gallery_url in the sidecar"
if [ "$(uname -s)" = "Darwin" ]; then
  PLIST="$ENDOR_VSCODE_LAUNCHD_DIR/com.endorlabs.pkgfirewall.vscode.plist"
  [ -f "$PLIST" ] && ok "launchd plist written" || bad "plist missing"
  plutil -lint "$PLIST" >/dev/null 2>&1 && ok "plist lints clean" || bad "plist invalid"
  n=$(/usr/libexec/PlistBuddy -c 'Print :WatchPaths' "$PLIST" 2>/dev/null | grep -c "$SB")
  chk "watches both files and both parent dirs" "$n" "4"
else
  [ -f "$ENDOR_VSCODE_SYSTEMD_DIR/endor-vscode-firewall.path" ] \
    && ok "systemd path unit written" || bad "systemd path unit missing"
fi

echo "== 4. idempotency: a re-run writes nothing =="
cp "$PJ" "$SB/before.json"
out=$("$SB/vscode.sh" 2>&1); rc=$?
chk "exit 0" "$rc" "0"
if cmp -s "$SB/before.json" "$PJ"; then ok "no bytes changed"; else bad "the re-run modified product.json"; fi
case "$out" in *"already current"*) ok "reported already-current" ;; *) bad "did not report a no-op" ;; esac

echo "== 5. simulate a VS Code update, then let the watcher's repatch script run =="
cp "$SB/pristine-stable.json"   "$PJ"     # the updater replaced product.json
cp "$SB/pristine-insiders.json" "$PJI"
grep -qF '_ak/' "$PJ" && bad "sanity: should be pristine now" || ok "product.json clobbered (update simulated)"
sandbox "$REPATCH" "$SB/repatch-sandboxed.sh"
out=$("$SB/repatch-sandboxed.sh" 2>&1); rc=$?
chk "repatch exit 0" "$rc" "0"
grep -qF '/firewall/vscode/_ak/' "$PJ"  && ok "stable re-patched after the update"   || bad "repatch did not re-apply: $out"
grep -qF '/firewall/vscode/_ak/' "$PJI" && ok "Insiders re-patched after the update" || bad "Insiders not re-patched"
# The repatch script must not recompute attribution: the watcher can fire at boot
# with nobody logged in, and it would then mint a token attributed to no user.
case "$out" in *"user attribution"*) bad "repatch recomputed attribution" ;;
               *) ok "repatch reused the URL recorded at install time" ;; esac
chk "repatch_count incremented to 2, one per edition" \
  "$(sed -n 's/^repatch_count=//p' "$ENDOR_VSCODE_STATE_DIR/state")" "2"
grep -q '^last_repatch=' "$ENDOR_VSCODE_STATE_DIR/state" && ok "last_repatch stamped" || bad "no last_repatch"

echo "== 6. the next install run surfaces the count to MDM logs =="
out=$("$SB/vscode.sh" 2>&1)
case "$out" in *"re-applied the patch 2×"*) ok "the update race is visible in the output" ;;
               *) bad "repatch count not surfaced: $(printf '%s' "$out" | tail -3)" ;; esac

echo "== 7. --dry-run writes nothing and does not print the credential =="
# Against an already-current file the dry-run would just report a no-op, so start
# from pristine to make it actually describe the edit it would apply — that is the
# output the redaction has to hold for.
TOKEN=$(sed -n 's#.*/_ak/\([A-Za-z0-9_-]*\).*#\1#p' "$PJ" | head -1)
[ -n "$TOKEN" ] && ok "recovered the installed token to check against" || bad "could not read the token"
cp "$SB/pristine-stable.json" "$PJ"
out=$("$SB/vscode.sh" --dry-run 2>&1); rc=$?
chk "exit 0" "$rc" "0"
if cmp -s "$SB/pristine-stable.json" "$PJ"; then ok "no bytes written"; else bad "--dry-run modified product.json"; fi
case "$out" in
  *"$TOKEN"*)         bad "--dry-run leaked the token" ;;
  *"_ak/<redacted>"*) ok "token redacted in --dry-run output" ;;
  *)                  bad "unexpected --dry-run output: $(printf '%s' "$out" | tail -5)" ;;
esac
out=$("$SB/vscode.sh" 2>&1)   # re-apply, so the rotation case below starts managed

echo "== 8. credential rotation is detected and re-applied =="
gen ROTATEDSECRET || bad "regenerate failed"
sandbox "$OUT/endor-vscode.sh" "$SB/vscode2.sh"
out=$("$SB/vscode2.sh" 2>&1); rc=$?
chk "exit 0" "$rc" "0"
chk "exactly one marker, no accumulation" "$(grep -cF '_endorPackageFirewall' "$PJ")" "1"
if json_ok "$PJ"; then ok "valid JSON after rotation"; else bad "invalid after rotation"; fi
case "$out" in *"out of date"*) ok "reported stale and restored before re-patching" ;;
               *) bad "did not report the stale state" ;; esac

echo "== 9. --no-vscode-watcher is loud but not a failure =="
cp "$SB/pristine-stable.json"   "$PJ"
cp "$SB/pristine-insiders.json" "$PJI"
# Clear the artifacts an earlier step installed, or this would assert against those
# rather than against what this run did.
rm -rf "$ENDOR_VSCODE_STATE_DIR"
rm -f "$ENDOR_VSCODE_LAUNCHD_DIR/com.endorlabs.pkgfirewall.vscode.plist" \
      "$ENDOR_VSCODE_SYSTEMD_DIR"/endor-vscode-firewall.* \
      "$ENDOR_VSCODE_CRON_DIR/endor-vscode-firewall"
out=$("$SB/vscode2.sh" --no-vscode-watcher 2>&1); rc=$?
# Failing every check-in over a deliberate setting is alert fatigue, and alert
# fatigue is how real warnings end up ignored.
chk "exit 0 despite the opt-out" "$rc" "0"
case "$out" in *"watcher skipped"*) ok "stated the opt-out" ;; *) bad "no opt-out message" ;; esac
grep -qF '/firewall/vscode/_ak/' "$ENDOR_VSCODE_STATE_DIR/state" \
  && ok "state still recorded, so the watcher can be enabled later" || bad "no state written"
[ -f "$ENDOR_VSCODE_LAUNCHD_DIR/com.endorlabs.pkgfirewall.vscode.plist" ] \
  && bad "watcher installed despite --no-vscode-watcher" || ok "no watcher installed"

echo "== 10. removal restores pristine bytes and tears the watcher down =="
out=$("$SB/vscode2.sh" 2>&1)   # reinstate the watcher so removal has something to remove
out=$("$SB/remove.sh" 2>&1); rc=$?
chk "exit 0" "$rc" "0"
if cmp -s "$SB/pristine-stable.json" "$PJ"; then ok "stable byte-identical to pristine"
else bad "stable differs: $(diff "$SB/pristine-stable.json" "$PJ" | head -3)"; fi
if cmp -s "$SB/pristine-insiders.json" "$PJI"; then ok "Insiders byte-identical to pristine"
else bad "Insiders differs"; fi
if [ "$(uname -s)" = "Darwin" ]; then
  [ -f "$ENDOR_VSCODE_LAUNCHD_DIR/com.endorlabs.pkgfirewall.vscode.plist" ] \
    && bad "watcher plist survived removal" || ok "watcher plist removed"
fi
[ -d "$ENDOR_VSCODE_STATE_DIR" ] && bad "sidecar survived removal" || ok "sidecar state removed"
case "$out" in *"Restart VS Code"*) ok "told the admin to restart VS Code" ;; *) bad "no restart hint" ;; esac

echo "== 11. removal is idempotent =="
out=$("$SB/remove.sh" 2>&1); rc=$?
chk "exit 0 on a second run" "$rc" "0"
case "$out" in *"not managed by Endor"*) ok "skipped cleanly" ;; *) bad "unexpected output: $out" ;; esac

summarize
