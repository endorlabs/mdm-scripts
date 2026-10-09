#!/usr/bin/env bash
# macOS only. Exercises how the VS Code worker classifies fake apps. Throwaway
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

TMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
KC="$TMP_DIR/test.keychain-db"
KC_PASS=$(openssl rand -hex 16)
ORIG_KEYCHAINS=()
while IFS= read -r line; do
  line=$(printf '%s' "$line" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
  [[ -n "$line" ]] && ORIG_KEYCHAINS+=("$line")
done < <(security list-keychains -d user)

cleanup() {
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
export ENDOR_VSCODE_SKIP_WATCHER=1

APP="$TMP_DIR/apps/Visual Studio Code.app"
mkdir -p "$TMP_DIR/apps"

firewall_url() {
  local token
  token=$(printf '%s:%s' "$KEY_ID" "$1" | base64 | tr '+/' '-_' | tr -d '=\n')
  printf 'https://factory.endorlabs.com/v1/namespaces/%s/firewall/vscode/_ak/%s' "$NAMESPACE" "$token"
}

generate() {
  ENDOR_NAMESPACE="$NAMESPACE" ENDOR_API_KEY_ID="$KEY_ID" ENDOR_API_SECRET="$SECRET" \
    ENDOR_VSCODE_MACOS_DAEMON="${MACOS_DAEMON:-1}" bash "$GENERATOR" >/dev/null
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

# run_worker <state> <args...>: run the installed worker against $APP.
run_worker() {
  local state="$1"
  shift
  ENDOR_VSCODE_APP="$APP" ENDOR_VSCODE_STATE_DIR="$state" \
    /bin/bash "$state/worker.sh" "$@" > "$TMP_DIR/worker.out" 2>&1
}

# install <state> [installer args...]: run the generated installer. Its --once still patches
# product.json in place, so point that at a scratch copy rather than at an app.
install() {
  local state="$1"
  shift
  cp "$FIXTURE" "$TMP_DIR/scratch-product.json"
  ENDOR_VSCODE_PRODUCT_JSON="$TMP_DIR/scratch-product.json" ENDOR_VSCODE_STATE_DIR="$state" \
    bash "$INSTALLER" "$@" > "$TMP_DIR/worker.out" 2>&1
}

# status_of <state>: the state (A, B, C, D, D2 or E) that --status reports for $APP.
status_of() {
  run_worker "$1" --status || fail "--status failed"
  sed -n 's/^state *: \([A-E]2*\) .*/\1/p' "$TMP_DIR/worker.out"
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

echo "test: apps the worker can't vouch for are refused and left byte-for-byte unchanged"
state="$TMP_DIR/state-refuse"
APP="$EMPTY/Visual Studio Code.app" install "$state" || fail "installer failed without an app"
refuse_case() {
  local name="$1" digest
  digest=$(tree_digest "$APP")
  [[ "$(status_of "$state")" == E ]] || fail "$name: --status does not report it as refused"
  [[ "$(tree_digest "$APP")" == "$digest" ]] || fail "$name: the app was modified"
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

echo "VS Code code-signing tests passed"
