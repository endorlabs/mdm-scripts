#!/usr/bin/env bash
# macOS only. Exercises the VS Code worker's clone, sign and swap path on fake apps. Throwaway
# "upstream" (standing in for Microsoft) and "attacker" identities live in a throwaway keychain
# that is on the user's keychain search list only while the test runs. Needs no root.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "skip: VS Code code-signing tests run on macOS only"
  exit 0
fi

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
GENERATOR="$ROOT_DIR/package-firewall/bash/generate.sh"
FIXTURE="$TEST_DIR/fixtures/vscode-product.json"
NAMESPACE="ci-smoke"
KEY_ID="ci-smoke-key-id"
SECRET="ci-smoke-secret"
INSTALLER="$ROOT_DIR/package-firewall/bash/out/$NAMESPACE/endor-vscode.sh"
BUNDLE_ID="com.endorlabs.test.vscode-codesign"
DEFAULT_SERVICE_URL="https://marketplace.visualstudio.com/_apis/public/gallery"
DEFAULT_EXTENSION_URL_TEMPLATE="https://www.vscode-unpkg.net/_gallery/{publisher}/{name}/latest"

TMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
KC="$TMP_DIR/test.keychain-db"
KC_PASS=$(openssl rand -hex 16)
ORIG_KEYCHAINS=()
while IFS= read -r line; do
  line=$(printf '%s' "$line" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
  [[ -n "$line" ]] && ORIG_KEYCHAINS+=("$line")
done < <(security list-keychains -d user)
BACKGROUND=()

cleanup() {
  local pid
  for pid in ${BACKGROUND[@]+"${BACKGROUND[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  security list-keychains -d user -s ${ORIG_KEYCHAINS[@]+"${ORIG_KEYCHAINS[@]}"} || true
  security delete-keychain "$KC" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  if [[ -f "$TMP_DIR/worker.out" ]]; then
    echo "--- last worker output" >&2
    tail -n 20 "$TMP_DIR/worker.out" >&2
  fi
  exit 1
}

security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KC_PASS" "$KC"
security list-keychains -d user -s ${ORIG_KEYCHAINS[@]+"${ORIG_KEYCHAINS[@]}"} "$KC"

# make_identity <name>: a self-signed code-signing identity in the test keychain; prints its SHA-1.
make_identity() {
  local dir="$TMP_DIR/id-$1"
  mkdir -p "$dir"
  printf '%s\n' '[req]' 'distinguished_name=dn' 'x509_extensions=v3' 'prompt=no' '[dn]' \
    "CN=Endor test $1 $(openssl rand -hex 4)" '[v3]' 'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature' 'extendedKeyUsage=critical,codeSigning' > "$dir/req.cnf"
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 30 -config "$dir/req.cnf" \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" >/dev/null 2>&1
  P12PASS="test" openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "$1" \
    -passout env:P12PASS -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -out "$dir/id.p12"
  security import "$dir/id.p12" -k "$KC" -f pkcs12 -P test -x -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null 2>&1
  openssl x509 -in "$dir/cert.pem" -noout -fingerprint -sha1 | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f'
}

UP_SHA1=$(make_identity upstream)
BAD_SHA1=$(make_identity attacker)

export ENDOR_VSCODE_BUNDLE_ID="$BUNDLE_ID"
export ENDOR_VSCODE_UPSTREAM_ANCHOR="certificate leaf = H\"$UP_SHA1\""
export ENDOR_VSCODE_KEYCHAIN="$KC"
export ENDOR_VSCODE_KEYCHAIN_PASSWORD="$KC_PASS"
export ENDOR_VSCODE_USERS_DIR="$TMP_DIR/users"
export ENDOR_VSCODE_LOG="$TMP_DIR/worker.log"
export ENDOR_VSCODE_SETTLE_SECONDS=0
export ENDOR_VSCODE_SETTLE_TIMEOUT=0
export ENDOR_VSCODE_LOCK_WAIT=60
export ENDOR_VSCODE_SKIP_WATCHER=1

APP="$TMP_DIR/apps/Visual Studio Code.app"
mkdir -p "$TMP_DIR/apps" "$TMP_DIR/users"

firewall_url() {
  local token
  token=$(printf '%s:%s' "$KEY_ID" "$1" | base64 | tr '+/' '-_' | tr -d '=\n')
  printf 'https://factory.endorlabs.com/v1/namespaces/%s/firewall/vscode/_ak/%s' "$NAMESPACE" "$token"
}

generate() {
  local secret="${1:-$SECRET}"
  ENDOR_NAMESPACE="$NAMESPACE" ENDOR_API_KEY_ID="$KEY_ID" ENDOR_API_SECRET="$secret" \
    ENDOR_VSCODE_MACOS_DAEMON="${MACOS_DAEMON:-1}" bash "$GENERATOR" >/dev/null
  EXPECTED_URL=$(firewall_url "$secret")
}

# sign_with <identity sha1|-> <bundle> [codesign flags...]
sign_with() {
  local who="$1" bundle="$2"
  shift 2
  codesign --sign "$who" --keychain "$KC" --force --options runtime --timestamp=none "$@" "$bundle" \
    >/dev/null 2>&1
}

write_info_plist() {
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    "<key>CFBundleIdentifier</key><string>$2</string>" \
    "<key>CFBundleExecutable</key><string>$3</string>" \
    "<key>CFBundleVersion</key><string>$4</string>" \
    "<key>CFBundleShortVersionString</key><string>$4</string>" \
    '<key>CFBundlePackageType</key><string>APPL</string>' \
    '</dict></plist>' > "$1"
}

# build_app <dest> <version> [outer signer: sha1|adhoc|none] [helper signer sha1] [extra entitlement]
# A fake VS Code: a main executable, one nested helper app, and the fixture product.json.
build_app() {
  local app="$1" version="$2" signer="${3:-$UP_SHA1}" helper_signer="${4:-$UP_SHA1}" extra="${5:-}"
  local helper="$app/Contents/Frameworks/Code Helper.app" ent
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/app" "$helper/Contents/MacOS"
  write_info_plist "$app/Contents/Info.plist" "$BUNDLE_ID" Code "$version"
  write_info_plist "$helper/Contents/Info.plist" "$BUNDLE_ID.helper" "Code Helper" "$version"
  cp /usr/bin/true "$app/Contents/MacOS/Code"
  cp /usr/bin/true "$helper/Contents/MacOS/Code Helper"
  cp "$FIXTURE" "$app/Contents/Resources/app/product.json"
  sign_with "$helper_signer" "$helper" --identifier "$BUNDLE_ID.helper"
  ent="$TMP_DIR/entitlements.plist"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    '<key>com.apple.security.cs.allow-jit</key><true/>' \
    '<key>com.apple.security.device.camera</key><true/>' \
    "$extra" '</dict></plist>' > "$ent"
  case "$signer" in
    none) ;;
    adhoc) sign_with - "$app" --identifier "$BUNDLE_ID" --entitlements "$ent" ;;
    *) sign_with "$signer" "$app" --identifier "$BUNDLE_ID" --entitlements "$ent" ;;
  esac
}

tree_digest() {
  ( cd "$1" && { find . | LC_ALL=C sort; find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort; } ) \
    | shasum -a 256 | cut -d' ' -f1
}

inode() { stat -f %i "$1"; }

# run_worker <state> <args...>: run the installed worker against $APP.
run_worker() {
  local state="$1"
  shift
  ENDOR_VSCODE_APP="$APP" ENDOR_VSCODE_STATE_DIR="$state" \
    /bin/bash "$state/worker.sh" "$@" > "$TMP_DIR/worker.out" 2>&1
}

# install <state> [installer args...]: run the generated installer against $APP.
install() {
  local state="$1"
  shift
  ENDOR_VSCODE_APP="$APP" ENDOR_VSCODE_STATE_DIR="$state" bash "$INSTALLER" "$@" \
    > "$TMP_DIR/worker.out" 2>&1
}

cert_of() { tr -d '[:space:]' < "$1/signing/cert.sha1"; }

# status_of <state>: the state (A, B, C, D, D2 or E) that --status reports for $APP.
status_of() {
  run_worker "$1" --status || fail "--status failed"
  sed -n 's/^state *: \([A-E]2*\) .*/\1/p' "$TMP_DIR/worker.out"
}

signed_by() {
  codesign --verify --deep --strict -R "=identifier \"$BUNDLE_ID\" and certificate leaf = H\"$2\"" "$1" \
    >/dev/null 2>&1
}

product_value() {
  plutil -extract "extensionsGallery.$2" raw -o - "$1/Contents/Resources/app/product.json" 2>/dev/null
}

assert_firewalled() {
  local app="$1" state="$2" out
  signed_by "$app" "$(cert_of "$state")" || fail "$app is not signed by this Mac's identity"
  [[ "$(product_value "$app" serviceUrl)" == "$EXPECTED_URL" ]] || fail "serviceUrl is not the firewall URL"
  ! product_value "$app" extensionUrlTemplate >/dev/null || fail "extensionUrlTemplate is still present"
  [[ "$(plutil -extract unknownFixtureData.preserve raw -o - "$app/Contents/Resources/app/product.json")" == "true" ]] \
    || fail "unrelated product.json fields were not preserved"
  # Output is captured first: grep -q ends a pipeline early, which fails it under pipefail.
  out=$(codesign -dv "$app" 2>&1)
  grep -q 'flags=0x[0-9a-f]*([^)]*runtime' <<< "$out" || fail "hardened runtime is missing"
  out=$(codesign -d --entitlements - --xml "$app" 2>/dev/null)
  grep -q 'com.apple.security.cs.disable-library-validation' <<< "$out" \
    || fail "the library-validation exception is missing"
  out=$(codesign -d -r- "$app" 2>&1)
  grep -qi "H\"$UP_SHA1\"" <<< "$out" || fail "the designated requirement does not accept upstream"
  [[ -z "$(find "$app" -xattrname com.apple.quarantine -print -quit)" ]] || fail "the app is still quarantined"
}

assert_restored() {
  [[ "$(product_value "$1" serviceUrl)" == "$DEFAULT_SERVICE_URL" ]] || fail "serviceUrl was not restored"
  [[ "$(product_value "$1" extensionUrlTemplate)" == "$DEFAULT_EXTENSION_URL_TEMPLATE" ]] \
    || fail "extensionUrlTemplate was not restored"
}

assert_identity_gone() {
  local ids
  ids=$(security find-identity -p codesigning "$KC")
  ! grep -qi "$1" <<< "$ids" || fail "identity $1 is still in the keychain"
}

# fake_process <executable path>: a process whose argv[0] is that path, as ps reports VS Code.
fake_process() {
  bash -c 'exec -a "$1" sleep 120' _ "$1" &
  BACKGROUND+=("$!")
  sleep 0.3
}
stop_fakes() {
  local pid
  for pid in ${BACKGROUND[@]+"${BACKGROUND[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  BACKGROUND=()
}

url_encode_path() { printf 'file://%s/' "$(printf '%s' "$1" | sed 's/%/%25/g; s/ /%20/g')"; }

# stage_update <user> <version> [signer]: a downloaded update as Squirrel leaves it.
stage_update() {
  local cache="$TMP_DIR/users/$1/Library/Caches/$BUNDLE_ID.ShipIt"
  rm -rf "$cache"
  mkdir -p "$cache/update.Ab12Cd3"
  STAGED="$cache/update.Ab12Cd3/Visual Studio Code.app"
  build_app "$STAGED" "$2" "${3:-$UP_SHA1}"
  printf '{"bundleIdentifier":"%s","launchAfterInstallation":true,"targetBundleURL":"%s","updateBundleURL":"%s","useUpdateBundleName":false}\n' \
    "$BUNDLE_ID" "$(url_encode_path "$APP")" "$(url_encode_path "$STAGED")" > "$cache/ShipItState.plist"
}

echo "test: without ENDOR_VSCODE_MACOS_DAEMON=1 the installer leaves the app alone"
MACOS_DAEMON=0 generate
state="$TMP_DIR/state-opt-out"
build_app "$APP" 1.0.0
digest=$(tree_digest "$APP")
install "$state" || [[ -f /Library/LaunchDaemons/com.endorlabs.vscode-firewall.plist ]] || fail "installer failed"
grep -qF 'ENDOR_VSCODE_MACOS_DAEMON=1' "$TMP_DIR/worker.out" || fail "the installer did not say how to opt in"
[[ "$(tree_digest "$APP")" == "$digest" && ! -e "$state" ]] || fail "the installer changed something without the flag"

generate

echo "test: --status reports an upstream app as pristine and a legacy in-place patch, read-only"
state="$TMP_DIR/state-status"
EMPTY="$TMP_DIR/no-app"
mkdir -p "$EMPTY"
APP="$EMPTY/Visual Studio Code.app" install "$state" || fail "installer failed without an app"
build_app "$APP" 1.0.0
digest=$(tree_digest "$APP")
[[ "$(status_of "$state")" == A ]] || fail "an upstream app is not reported as A"
[[ "$(tree_digest "$APP")" == "$digest" ]] || fail "--status modified the app"
plutil -replace extensionsGallery.serviceUrl -string "$(firewall_url old-secret)" "$APP/Contents/Resources/app/product.json"
printf '{}\n' > "$APP/Contents/Resources/app/product.json.endor.Q1w2E3"
digest=$(tree_digest "$APP")
[[ "$(status_of "$state")" == D ]] || fail "a legacy in-place patch is not reported as D"
[[ "$(tree_digest "$APP")" == "$digest" ]] || fail "--status modified the app"
[[ ! -e "$state/signing" ]] || fail "--status created a signing identity"

echo "test: a pristine app is patched, signed by this Mac, swapped in, and its original kept"
state="$TMP_DIR/state-pristine"
build_app "$APP" 1.0.0
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$APP"
original=$(tree_digest "$APP")
before=$(inode "$APP")
install "$state" || fail "installer failed"
[[ "$(inode "$APP")" != "$before" ]] || fail "the app was not swapped"
assert_firewalled "$APP" "$state"
[[ "$(status_of "$state")" == B ]] || fail "--status does not report the swapped-in app as B"
pristine="$state/pristine/1.0.0/VSCode.bundle-pristine"
[[ "$(tree_digest "$pristine")" == "$original" ]] || fail "the kept original differs from the app"
[[ ! -e "$state/stage/Visual Studio Code.app" ]] || fail "the staging copy was left behind"
live_dr=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
build_app "$TMP_DIR/apps/next-upstream.app" 1.1.0 "$UP_SHA1"
codesign --verify --deep --strict -R "=$live_dr" "$TMP_DIR/apps/next-upstream.app" >/dev/null 2>&1 \
  || fail "an upstream-signed update does not satisfy the designated requirement"
build_app "$TMP_DIR/apps/next-attacker.app" 1.1.0 "$BAD_SHA1"
rc=0
codesign --verify --deep --strict -R "=$live_dr" "$TMP_DIR/apps/next-attacker.app" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 3 ]] || fail "an attacker-signed update was not rejected by the requirement (rc $rc)"

echo "test: a second run changes nothing"
before=$(inode "$APP")
digest=$(tree_digest "$APP")
run_worker "$state" --once || fail "second run failed"
[[ "$(inode "$APP")" == "$before" && "$(tree_digest "$APP")" == "$digest" ]] || fail "second run modified the app"

echo "test: credential rotation re-patches and re-signs with the same identity"
cert=$(cert_of "$state")
generate "ci-smoke-rotated-secret"
install "$state" || fail "installer failed after rotation"
assert_firewalled "$APP" "$state"
[[ "$(cert_of "$state")" == "$cert" ]] || fail "rotation replaced the signing identity"
generate
install "$state" || fail "installer failed rotating back"

echo "test: certificate renewal re-signs and retires the old identity"
ENDOR_VSCODE_RENEW_DAYS=4000 run_worker "$state" --once || fail "renewal run failed"
[[ "$(cert_of "$state")" != "$cert" ]] || fail "the certificate was not renewed"
grep -qx "$cert" "$state/signing/previous-certs" || fail "the old certificate is not in previous-certs"
assert_identity_gone "$cert"
assert_firewalled "$APP" "$state"

echo "test: removal swaps Microsoft's original back and purge deletes the identity"
cert=$(cert_of "$state")
run_worker "$state" --restore || fail "restore failed"
[[ "$(tree_digest "$APP")" == "$original" ]] || fail "the restored app differs from the original"
codesign --verify --deep --strict -R "=identifier \"$BUNDLE_ID\" and certificate leaf = H\"$UP_SHA1\"" "$APP" \
  >/dev/null 2>&1 || fail "the restored app is not upstream-signed"
run_worker "$state" --purge || fail "purge failed"
assert_identity_gone "$cert"
[[ ! -e "$state/signing" && ! -e "$state/pristine" ]] || fail "purge left signing state behind"

echo "test: a legacy app patched in place is repaired, including a stray temp file"
state="$TMP_DIR/state-legacy"
build_app "$APP" 1.0.0
plutil -replace extensionsGallery.serviceUrl -string "$(firewall_url old-secret)" "$APP/Contents/Resources/app/product.json"
printf '{}\n' > "$APP/Contents/Resources/app/product.json.endor.Q1w2E3"
install "$state" || fail "installer failed on a legacy app"
assert_firewalled "$APP" "$state"
[[ ! -e "$APP/Contents/Resources/app/product.json.endor.Q1w2E3" ]] || fail "the stray temp file survived"
[[ ! -e "$state/pristine" ]] || fail "a modified app was kept as an original"

echo "test: removal without an original restores product.json and keeps a valid signature"
cert=$(cert_of "$state")
run_worker "$state" --restore || fail "restore without an original failed"
assert_restored "$APP"
signed_by "$APP" "$cert" || fail "the restored app is not validly signed"
run_worker "$state" --purge || fail "purge failed"
assert_identity_gone "$cert"

echo "test: apps the worker can't vouch for are refused and left byte-for-byte unchanged"
state="$TMP_DIR/state-refuse"
APP="$EMPTY/Visual Studio Code.app" install "$state" || fail "installer failed without an app"
refuse_case() {
  local name="$1" digest
  digest=$(tree_digest "$APP")
  [[ "$(status_of "$state")" == E ]] || fail "$name: --status does not report it as refused"
  if run_worker "$state" --once; then
    fail "$name: the worker did not refuse"
  fi
  [[ "$(tree_digest "$APP")" == "$digest" ]] || fail "$name: the app was modified"
  rm -f "$state/last-refused"
}
build_app "$APP" 1.0.0 "$BAD_SHA1"
refuse_case "attacker-signed app"
build_app "$APP" 1.0.0 adhoc
refuse_case "ad-hoc signed app"
build_app "$APP" 1.0.0 none
refuse_case "unsigned app"
build_app "$APP" 1.0.0
printf 'extra\n' > "$APP/Contents/Resources/app/extra.js"
refuse_case "a file added to an upstream app"
build_app "$APP" 1.0.0 "$UP_SHA1" "$BAD_SHA1"
refuse_case "an attacker-signed helper sealed by upstream"
build_app "$APP" 1.0.0
sign_with "$BAD_SHA1" "$APP/Contents/Frameworks/Code Helper.app" --identifier "$BUNDLE_ID.helper"
refuse_case "a helper swapped after upstream signed"
build_app "$APP" 1.0.0
printf '{"extensionsGallery":\n' > "$APP/Contents/Resources/app/product.json"
refuse_case "invalid product.json"
build_app "$APP" 1.0.0
plutil -replace extensionsGallery.serviceUrl -string "https://gallery.example.com" "$APP/Contents/Resources/app/product.json"
refuse_case "product.json changed by someone else"
build_app "$APP" 1.0.0 "$UP_SHA1" "$UP_SHA1" '<key>com.apple.application-identifier</key><string>X.Y</string>'
refuse_case "a restricted entitlement"
[[ ! -e "$state/signing" ]] || fail "a refusal created a signing identity"

echo "test: a helper swapped after this Mac signed is refused"
state="$TMP_DIR/state-tamper"
build_app "$APP" 1.0.0
install "$state" || fail "installer failed"
sign_with "$BAD_SHA1" "$APP/Contents/Frameworks/Code Helper.app" --identifier "$BUNDLE_ID.helper"
touch "$APP/Contents/Resources/app/product.json"
refuse_case "a helper swapped after signing"

echo "test: the worker waits while ShipIt installs an update"
state="$TMP_DIR/state-shipit"
build_app "$APP" 1.0.0
APP="$EMPTY/Visual Studio Code.app" install "$state" || fail "installer failed without an app"
digest=$(tree_digest "$APP")
fake_process "$APP/Contents/Frameworks/Squirrel.framework/Resources/ShipIt"
run_worker "$state" --once || fail "a deferred run failed"
[[ "$(tree_digest "$APP")" == "$digest" ]] || fail "the app was modified while ShipIt was installing"
stop_fakes
run_worker "$state" --once || fail "the run after ShipIt finished failed"
assert_firewalled "$APP" "$state"

echo "test: dry-run reports without signing or writing"
state="$TMP_DIR/state-dry"
build_app "$APP" 1.0.0
digest=$(tree_digest "$APP")
install "$state" --dry-run || fail "dry-run failed"
grep -q 'SIGN with this Mac' "$TMP_DIR/worker.out" || fail "dry-run did not report the signing action"
[[ "$(tree_digest "$APP")" == "$digest" ]] || fail "dry-run modified the app"
[[ ! -e "$state" ]] || fail "dry-run created state"

echo "test: a staged update is pre-patched only while VS Code runs, and restored on removal"
state="$TMP_DIR/state-staged"
build_app "$APP" 1.0.0
install "$state" || fail "installer failed"
stage_update alice 1.1.0
staged_original=$(tree_digest "$STAGED")
run_worker "$state" --once || fail "run with a staged update failed"
[[ "$(tree_digest "$STAGED")" == "$staged_original" ]] || fail "the update was touched while VS Code was not running"
fake_process "$APP/Contents/MacOS/Code"
run_worker "$state" --once || fail "pre-patch run failed"
assert_firewalled "$STAGED" "$state"
codesign --verify --deep --strict -R "=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')" "$STAGED" \
  >/dev/null 2>&1 || fail "the prepared update does not satisfy the installed app's requirement"
[[ ! -e "$STAGED.endor-hold" ]] || fail "the held update was left behind"
[[ -d "$state/pristine/1.1.0/VSCode.bundle-pristine" && -d "$state/pristine/1.0.0/VSCode.bundle-pristine" ]] \
  || fail "the originals of the installed and staged versions were not both kept"
before=$(inode "$STAGED")
run_worker "$state" --once || fail "repeat run failed"
[[ "$(inode "$STAGED")" == "$before" ]] || fail "a prepared update was prepared again"
run_worker "$state" --restore || fail "restore with a prepared update failed"
[[ "$(tree_digest "$STAGED")" == "$staged_original" ]] || fail "the staged update was not restored to upstream's"
run_worker "$state" --purge || fail "purge failed"
stop_fakes

echo "test: staged downgrades, attacker builds, and updates for an app that isn't ours are left alone"
state="$TMP_DIR/state-staged-refuse"
build_app "$APP" 1.0.0
install "$state" || fail "installer failed"
fake_process "$APP/Contents/MacOS/Code"
for spec in "0.9.0 $UP_SHA1" "1.0.0 $UP_SHA1" "1.2.0 $BAD_SHA1"; do
  # shellcheck disable=SC2086
  stage_update bob $spec
  digest=$(tree_digest "$STAGED")
  run_worker "$state" --once || true
  [[ "$(tree_digest "$STAGED")" == "$digest" && ! -e "$STAGED.endor-hold" ]] \
    || fail "staged update ($spec) was modified"
done
build_app "$APP" 1.0.0 "$BAD_SHA1"
stage_update bob 1.1.0
digest=$(tree_digest "$STAGED")
run_worker "$state" --once || true
[[ "$(tree_digest "$STAGED")" == "$digest" ]] || fail "an update for an app that isn't ours was modified"
stop_fakes
run_worker "$state" --purge || fail "purge failed"

echo "VS Code code-signing tests passed"
