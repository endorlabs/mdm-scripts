#!/usr/bin/env bash
# The vscode_* lifecycle in bash/lib/common.sh: discovery, the three-state machine,
# patch, restore, both writer paths, and the failure modes that must be loud.
#
# The lib is sourced in its *inlined* form — `grep -v '^# ' | sed '/^ *$/d'` — which
# is what generate.sh embeds in the scripts an MDM actually pushes. Testing the
# pristine file instead would not prove that nothing in the lib depends on a comment
# or a blank line surviving, and a heredoc body is exactly the shape that silently
# would.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_json_tool

NODE=$(command -v node || true)
T=$(mktemp -d)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

echo "== 0. strip, source, syntax =="
chk "pristine lib parses"  "$(bash -n "$LIB" 2>&1; echo rc=$?)" "rc=0"
strip_lib > "$T/stripped.sh"
chk "stripped lib parses"  "$(bash -n "$T/stripped.sh" 2>&1; echo rc=$?)" "rc=0"
# The one thing stripping can silently break is content inside a heredoc, because
# a stripped comment or blank line there changes data rather than code.
chk "no heredocs in the lib" "$(grep -c "<<'" "$T/stripped.sh")" "0"
source_stripped_lib "$T"
ok "sourced the stripped lib"

echo "== 1. encoding helpers =="
chk "endor_b64url substitutes + and / and strips padding" \
  "$(printf '\xfb\xff\xfe' | endor_b64url)" "-__-"
chk "endor_b64 round-trips through endor_b64d" \
  "$(printf 'userattr:jane@Mac' | endor_b64 | endor_b64d)" "userattr:jane@Mac"
chk "a realistic token comes out with no + / or =" \
  "$(printf 'someuser:somesecret+with/chars==' | endor_b64url | tr -dc '+/=' | wc -c | tr -d ' ')" "0"

echo "== 2. a writable fixture install, stable and Insiders =="
make_macos_app "$T/Applications" "Visual Studio Code.app"            "Visual Studio Code"            "$NODE"
make_macos_app "$T/Applications" "Visual Studio Code - Insiders.app" "Visual Studio Code - Insiders" "$NODE"
PJ="$T/Applications/Visual Studio Code.app/Contents/Resources/app/product.json"
PJI="$T/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/product.json"
MIN="$T/Applications/Visual Studio Code.app/Contents/Resources/app/min.json"
cp "$PJ" "$T/pristine.json"

chk "discovery finds both fixture editions" \
  "$(vscode_install_paths "$T" | grep -c "^$T/")" "2"
chk "edition label read from nameLong" "$(vscode_edition_label "$PJI")" "Visual Studio Code - Insiders"
chk "version read from the fixture" "$(endor_json_top_string "$PJ" version)" "$FIXTURE_VERSION"
chk "commit read from the fixture" "$(endor_json_top_string "$PJ" commit)" "$FIXTURE_COMMIT"
if [ -n "$NODE" ]; then
  # Never hardcode "Electron": stable's CFBundleExecutable is "Code" and Insiders
  # differs, so the name has to come out of Info.plist.
  chk "node bin resolved via CFBundleExecutable" "$(basename "$(vscode_node_bin "$PJ")")" "Code"
else
  skip "node bin (no node on PATH)"
fi
# Under root, [[ -w ]] returns true on a read-only mount, so read-only installs have
# to be recognised by path prefix or the script would fail deep inside the write.
chk "read-only detector: /snap path" \
  "$(vscode_is_readonly_install /snap/code/current/x/product.json && echo ro || echo rw)" "ro"
chk "read-only detector: /var/lib/flatpak path" \
  "$(vscode_is_readonly_install /var/lib/flatpak/app/x/product.json && echo ro || echo rw)" "ro"
chk "read-only detector: an ordinary path" \
  "$(vscode_is_readonly_install "$PJ" && echo ro || echo rw)" "rw"
chk "can_write says yes on a writable file" "$(vscode_can_write "$PJ" && echo y || echo n)" "y"
chk "can_write left the content alone" \
  "$(cmp -s "$PJ" "$T/pristine.json" && echo same || echo changed)" "same"

echo "== 3. state machine and patch =="
URL='https://factory.endorlabs.com/v1/namespaces/spiderman/firewall/vscode/_ak/dGVzdHVzZXI6dGVzdHNlY3JldA'
SET="\"serviceUrl\": \"$URL\""
DEL="extensionUrlTemplate"
FQDN=https://factory.endorlabs.com
chk "unmanaged before patching" "$(vscode_managed_state "$PJ" "$URL" "$DEL")" "unmanaged"

out=$(vscode_patch "$PJ" "$URL" "$SET" "$DEL" spiderman "$FQDN"); rc=$?
chk "patch returns 0" "$rc" "0"
if json_ok "$PJ"; then ok "patched product.json is valid JSON"; else bad "INVALID JSON: $out"; fi
chk "state is now current" "$(vscode_managed_state "$PJ" "$URL" "$DEL")" "current"
chk "marker records via=awk" "$(vscode_marker_field "$PJ" via)" "awk"
chk "marker records appVersion" "$(vscode_marker_field "$PJ" appVersion)" "$FIXTURE_VERSION"
chk "final newline still absent, as the source had none" \
  "$(endor_file_has_final_newline "$PJ" && echo y || echo n)" "n"
chk "serviceUrl set; unpkg fallback gone; controlUrl, resourceUrlTemplate, SKUs kept" \
  "$(jget "$PJ" "d['extensionsGallery']['serviceUrl'].endswith('/_ak/dGVzdHVzZXI6dGVzdHNlY3JldA') and 'extensionUrlTemplate' not in d['extensionsGallery'] and d['extensionsGallery']['controlUrl'].startswith('https://main.vscode-cdn.net') and d['extensionsGallery']['resourceUrlTemplate'].startswith('https://{publisher}') and len(d['extensionsGallery']['accessSKUs'])==$FIXTURE_SKUS")" "true"

echo "== 4. idempotency: a re-run must not write =="
cp "$PJ" "$T/before.json"
out=$(vscode_patch "$PJ" "$URL" "$SET" "$DEL" spiderman "$FQDN"); rc=$?
chk "re-patch returns 2 (already current)" "$rc" "2"
if cmp -s "$T/before.json" "$PJ"; then ok "no bytes changed"; else bad "the file changed on re-patch"; fi

echo "== 5. credential rotation: stale -> restore, then patch =="
# Never patch on top of a patch. Restoring first is what lets credentials rotate
# indefinitely without the captured original drifting.
URL2="${URL}rotated"
chk "rotation is detected as stale" "$(vscode_managed_state "$PJ" "$URL2" "$DEL")" "stale"
out=$(vscode_patch "$PJ" "$URL2" "\"serviceUrl\": \"$URL2\"" "$DEL" spiderman "$FQDN"); rc=$?
chk "patch after rotation returns 0" "$rc" "0"
chk "current at the new URL" "$(vscode_managed_state "$PJ" "$URL2" "$DEL")" "current"
chk "exactly one marker, no accumulation" "$(grep -cF '_endorPackageFirewall' "$PJ")" "1"
if json_ok "$PJ"; then ok "still valid JSON"; else bad "INVALID after rotation"; fi

echo "== 6. unpatch restores pristine bytes =="
out=$(vscode_unpatch "$PJ"); rc=$?
chk "unpatch returns 0" "$rc" "0"
if cmp -s "$T/pristine.json" "$PJ"; then ok "byte-identical to pristine, after two patch cycles"
else bad "differs: $(diff "$T/pristine.json" "$PJ" | head -4)"; fi
out=$(vscode_unpatch "$PJ"); rc=$?
chk "unpatch on an unmanaged file is a no-op success" "$rc" "0"

echo "== 7. the node writer, on a minified product.json =="
if [ -n "$NODE" ]; then
  python3 -c "import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2],'w'))" \
    "$T/pristine.json" "$MIN"
  chk "extract fails on minified input (the fallback trigger)" \
    "$(endor_json_extract_top_object "$MIN" extensionsGallery >/dev/null 2>&1; echo $?)" "1"
  out=$(vscode_patch "$MIN" "$URL" "$SET" "$DEL" spiderman "$FQDN"); rc=$?
  chk "patch succeeds via the node writer" "$rc" "0"
  case "$out" in *"bundled node writer"*) ok "reported which writer ran" ;;
                 *) bad "did not report the fallback: $out" ;; esac
  if json_ok "$MIN"; then ok "node-written file is valid JSON"; else bad "node-written file INVALID"; fi
  # The node writer pretty-prints, so the marker spans several lines. This is the
  # assertion that catches a marker reader which only handles the single-line form.
  chk "marker records via=node" "$(vscode_marker_field "$MIN" via)" "node"
  chk "the node path applied the same two edits" \
    "$(jget "$MIN" "d['extensionsGallery']['serviceUrl'].endswith('/_ak/dGVzdHVzZXI6dGVzdHNlY3JldA') and 'extensionUrlTemplate' not in d['extensionsGallery'] and len(d['extensionsGallery']['accessSKUs'])==$FIXTURE_SKUS")" "true"
  out=$(vscode_unpatch "$MIN"); rc=$?
  chk "node unpatch returns 0" "$rc" "0"
  chk "node restore reinstated the original gallery, extensionUrlTemplate included" \
    "$(jget "$MIN" "'_endorPackageFirewall' not in d and d['extensionsGallery']['serviceUrl']=='https://marketplace.visualstudio.com/_apis/public/gallery' and d['extensionsGallery']['extensionUrlTemplate'].startswith('https://www.vscode-unpkg.net')")" "true"
else
  skip "node writer fallback (no node on PATH)"
fi

echo "== 8. validation refuses a corrupt candidate =="
printf 'not json at all' > "$T/bad.json"
chk "rejects non-JSON" "$(endor_json_validate "$T/bad.json" && echo y || echo n)" "n"
printf '{\n\t"a": 1,\n}\n' > "$T/tc.json"
chk "rejects a trailing comma with no node binary" \
  "$(endor_json_validate "$T/tc.json" && echo y || echo n)" "n"
if [ -n "$NODE" ]; then
  chk "rejects a trailing comma with node too" \
    "$(endor_json_validate "$T/tc.json" "$(vscode_node_bin "$PJ")" && echo y || echo n)" "n"
else
  skip "node validation path (no node on PATH)"
fi

echo "== 9. EPERM, which on macOS means the App Management grant is missing =="
cp "$T/pristine.json" "$T/ro.json"; chmod 444 "$T/ro.json"
if [ "$(id -u)" = "0" ]; then
  skip "EPERM path (running as root, chmod cannot simulate it)"
else
  out=$(vscode_patch "$T/ro.json" "$URL" "$SET" "$DEL" ns https://f 2>&1); rc=$?
  chk "patch fails on an unwritable product.json" "$rc" "1"
  # A silent no-op here would look exactly like success in an MDM log, which is the
  # whole reason this path is asserted on.
  case "$out" in *"App Management"*) ok "surfaced the App Management/TCC cause" ;;
                 *) bad "no TCC guidance in: $out" ;; esac
  if cmp -s "$T/pristine.json" "$T/ro.json"; then ok "left the file untouched"
  else bad "modified a file it could not write cleanly"; fi
fi

echo "== 10. a read-only install is refused with something actionable =="
out=$(vscode_patch /snap/code/current/product.json "$URL" "$SET" "$DEL" ns https://f 2>&1); rc=$?
chk "snap install refused" "$rc" "1"
case "$out" in *"read-only"*) ok "explained the snap/flatpak situation" ;; *) bad "unclear message: $out" ;; esac

echo "== 11. dry-run writes nothing and does not print the credential =="
cp "$T/pristine.json" "$T/dry.json"
DRY_RUN=1
out=$(vscode_patch "$T/dry.json" "$URL" "$SET" "$DEL" spiderman "$FQDN"); rc=$?
DRY_RUN=0
chk "dry-run returns 0" "$rc" "0"
if cmp -s "$T/pristine.json" "$T/dry.json"; then ok "no bytes written"; else bad "dry-run modified the file"; fi
# The token is a bearer credential in a URL path, and MDM logs are read by more
# people than product.json is.
case "$out" in
  *"dGVzdHVzZXI6dGVzdHNlY3JldA"*) bad "dry-run leaked the token" ;;
  *"_ak/<redacted>"*)             ok "token redacted in dry-run output" ;;
  *)                              bad "unexpected dry-run output: $out" ;;
esac

echo "== 12. cross-check against the real installed product.json, if there is one =="
# The fixture mirrors a shipped product.json but is not one. This checks the round
# trip against whatever VS Code is actually installed here, without asserting
# anything version-specific — so it keeps working across VS Code updates.
REAL=""
for c in "/Applications/Visual Studio Code.app/Contents/Resources/app/product.json" \
         "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/product.json" \
         "/usr/share/code/resources/app/product.json" \
         "/opt/visual-studio-code/resources/app/product.json"; do
  [ -f "$c" ] && { REAL="$c"; break; }
done
if [ -z "$REAL" ]; then
  skip "real-install round-trip (no VS Code installation found)"
else
  echo "  (using $REAL)"
  cp "$REAL" "$T/real.json"; cp "$REAL" "$T/real-pristine.json"
  out=$(vscode_patch "$T/real.json" "$URL" "$SET" "$DEL" spiderman "$FQDN"); rc=$?
  chk "patch of the real file returns 0" "$rc" "0"
  if json_ok "$T/real.json"; then ok "real file still valid JSON"; else bad "real file INVALID: $out"; fi
  chk "real file: serviceUrl set and the unpkg fallback removed" \
    "$(jget "$T/real.json" "d['extensionsGallery']['serviceUrl'].startswith('https://factory') and 'extensionUrlTemplate' not in d['extensionsGallery']")" "true"
  # 3 lines for the two key edits, plus 1 for the inserted marker.
  chk "real file: diff is the 2 key edits plus the marker, nothing else" \
    "$(diff "$T/real-pristine.json" "$T/real.json" | grep -c '^[<>]')" "4"
  out=$(vscode_unpatch "$T/real.json"); rc=$?
  chk "unpatch of the real file returns 0" "$rc" "0"
  if cmp -s "$T/real-pristine.json" "$T/real.json"; then ok "real file restored byte-for-byte"
  else bad "real file differs: $(diff "$T/real-pristine.json" "$T/real.json" | head -4)"; fi
fi

summarize
