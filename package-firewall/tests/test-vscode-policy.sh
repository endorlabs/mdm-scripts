#!/usr/bin/env bash
# The ExtensionGalleryServiceUrl policy in /etc/vscode/policy.json, set by endor-vscode.sh and
# removed by endor-remove.sh. ENDOR_VSCODE_POLICY_FILE puts the file in a temporary folder, so this
# runs on macOS too, as a normal user.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
GENERATOR="$ROOT_DIR/package-firewall/bash/generate.sh"
FIXTURE="$TEST_DIR/fixtures/vscode-product.json"
NAMESPACE="ci-smoke"
KEY_ID="ci-smoke-key-id"
SECRET="ci-smoke-secret"
OUT="$ROOT_DIR/package-firewall/bash/out/$NAMESPACE"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

service_url() {
  printf 'https://factory.endorlabs.com/v1/namespaces/%s/firewall/vscode/_ak/%s' "$NAMESPACE" \
    "$(printf '%s:%s' "$KEY_ID" "$1" | base64 | tr -d '\n=' | tr '+/' '-_')"
}
EXPECTED_URL=$(service_url "$SECRET")

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# PATCH, POLICY and AUTH set the flags; the policy is on and the patch off unless they say otherwise.
generate() {
  local secret="${1:-$SECRET}"
  ENDOR_NAMESPACE="$NAMESPACE" \
    ENDOR_API_KEY_ID="$KEY_ID" \
    ENDOR_API_SECRET="$secret" \
    ENDOR_VSCODE_ENABLE_PATCH="${PATCH:-0}" \
    ENDOR_VSCODE_ENABLE_POLICY="${POLICY:-1}" \
    ENDOR_VSCODE_POLICY_AUTH="${AUTH:-}" \
    bash "$GENERATOR" >/dev/null 2>"$TMP_DIR/generate.err" || { cat "$TMP_DIR/generate.err" >&2; return 1; }
}

# Each case gets a VS Code install, product.json state and policy file of its own.
new_case() {
  CASE="$TMP_DIR/$1"
  mkdir -p "$CASE/app" "$CASE/etc"
  cp "$FIXTURE" "$CASE/app/product.json"
  printf '{"name": "code", "version": "%s"}\n' "${2:-1.141.2}" > "$CASE/app/package.json"
  POLICY_FILE="$CASE/etc/vscode/policy.json"
  POLICY_STATE="$CASE/policy-state"
}

# install: runs endor-vscode.sh for the current case. Sets RC and OUTPUT.
install() {
  RC=0
  OUTPUT=$(ENDOR_VSCODE_PRODUCT_JSON="$CASE/app/product.json" \
    ENDOR_VSCODE_STATE_DIR="$CASE/state" \
    ENDOR_VSCODE_POLICY_FILE="$POLICY_FILE" \
    ENDOR_VSCODE_POLICY_STATE_DIR="$POLICY_STATE" \
    ENDOR_VSCODE_SKIP_WATCHER=1 \
    "$OUT/endor-vscode.sh" "$@" 2>&1) || RC=$?
}

# remove: runs only the VS Code section of endor-remove.sh, which needs no signed-in user and
# leaves this machine's own dotfiles alone. Sets RC and OUTPUT.
remove() {
  local section="$TMP_DIR/remove-section.sh"
  {
    echo 'set -euo pipefail'
    echo 'DRY_RUN="${ENDOR_TEST_DRY_RUN:-0}"; _ENDOR_WARNED=0'
    sed -n '/^# >>> endor-vscode-remove$/,/^# <<< endor-vscode-remove$/p' "$OUT/endor-remove.sh"
    echo 'exit "$_ENDOR_WARNED"'
  } > "$section"
  RC=0
  OUTPUT=$(ENDOR_VSCODE_PRODUCT_JSON="$CASE/app/product.json" \
    ENDOR_VSCODE_STATE_DIR="$CASE/state" \
    ENDOR_VSCODE_POLICY_FILE="$POLICY_FILE" \
    ENDOR_VSCODE_POLICY_STATE_DIR="$POLICY_STATE" \
    ENDOR_VSCODE_SKIP_WATCHER=1 \
    bash "$section" 2>&1) || RC=$?
}

# policy_value <key>: the key's value in the case's policy file, or <none>.
policy_value() {
  python3 -I - "$POLICY_FILE" "$1" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get(sys.argv[2], "<none>"))
PY
}

file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# plist_value <file> <dotted.path>: a value from a property list, or <none>.
plist_value() {
  python3 -I - "$1" "$2" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    value = plistlib.load(handle)
for part in sys.argv[2].split("."):
    if isinstance(value, list):
        value = value[int(part)]
    elif isinstance(value, dict) and part in value:
        value = value[part]
    else:
        value = "<none>"
        break
print(value)
PY
}

# managed_prefs <file> <url> [provider]: what an MDM profile leaves in /Library/Managed Preferences.
managed_prefs() {
  python3 -I - "$1" "$2" "${3:-}" <<'PY'
import os
import plistlib
import sys
path, url, provider = sys.argv[1:4]
os.makedirs(os.path.dirname(path), exist_ok=True)
value = {"ExtensionGalleryServiceUrl": url}
if provider:
    value["ExtensionGalleryAuthProvider"] = provider
with open(path, "wb") as handle:
    plistlib.dump(value, handle)
PY
}
digest() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }

expect_rc() {
  if [[ "$RC" -ne "$1" ]]; then
    echo "$OUTPUT" >&2
    fail "expected exit $1, got $RC"
  fi
}

expect_output() {
  if ! grep -qF -- "$1" <<<"$OUTPUT"; then
    echo "$OUTPUT" >&2
    fail "expected the output to contain: $1"
  fi
}

echo "test: the policy goes into a new policy.json, once"
generate
new_case create
install
expect_rc 0
[[ "$(policy_value ExtensionGalleryServiceUrl)" == "$EXPECTED_URL" ]] || fail "the URL is not set"
[[ "$(policy_value ExtensionGalleryAuthProvider)" == "<none>" ]] || fail "the auth provider was set without AUTH"
[[ "$(file_mode "$POLICY_FILE")" == "644" ]] || fail "policy.json is not mode 644"
[[ "$(file_mode "$POLICY_STATE/record.json")" == "600" ]] || fail "the record is not mode 600"
if grep -qF "/_ak/" "$POLICY_STATE/record.json"; then fail "the record contains the URL"; fi
expect_output "Copilot Business or Enterprise"
cmp -s "$CASE/app/product.json" "$FIXTURE" || fail "the policy alone changed product.json"
[[ ! -e "$CASE/state" ]] || fail "the policy alone installed the patch"
before=$(digest "$POLICY_FILE")
install
expect_rc 0
expect_output "policy already set"
[[ "$(digest "$POLICY_FILE")" == "$before" ]] || fail "a second run changed policy.json"

echo "test: other policies stay, and a rotated credential replaces the URL"
new_case merge
mkdir -p "$(dirname "$POLICY_FILE")"
printf '{\n  "UpdateMode": "none",\n  "ExtensionGalleryServiceUrl": ""\n}\n' > "$POLICY_FILE"
install
expect_rc 0
[[ "$(policy_value UpdateMode)" == "none" ]] || fail "another policy was lost"
[[ "$(policy_value ExtensionGalleryServiceUrl)" == "$EXPECTED_URL" ]] || fail "an empty URL was not replaced"
generate "ci-smoke-rotated-secret"
install
expect_rc 0
[[ "$(policy_value ExtensionGalleryServiceUrl)" == "$(service_url ci-smoke-rotated-secret)" ]] \
  || fail "the rotated URL was not written"
[[ "$(policy_value UpdateMode)" == "none" ]] || fail "rotation lost another policy"
generate
# A file that was already there keeps its mode.
chmod 640 "$POLICY_FILE"
install
expect_rc 0
[[ "$(file_mode "$POLICY_FILE")" == "640" ]] || fail "rewriting policy.json changed its mode"

echo "test: a gallery that isn't Endor's is left alone"
new_case foreign
mkdir -p "$(dirname "$POLICY_FILE")"
printf '{"ExtensionGalleryServiceUrl": "https://gallery.example.invalid/_apis/public/gallery"}\n' > "$POLICY_FILE"
cp "$POLICY_FILE" "$CASE/before.json"
install
expect_rc 1
expect_output "sets ExtensionGalleryServiceUrl to another gallery"
cmp -s "$POLICY_FILE" "$CASE/before.json" || fail "a foreign gallery was changed"

echo "test: a policy.json that isn't a JSON object is left alone"
for content in '{"ExtensionGalleryServiceUrl": ' '["ExtensionGalleryServiceUrl"]'; do
  new_case "invalid-$RANDOM"
  mkdir -p "$(dirname "$POLICY_FILE")"
  printf '%s\n' "$content" > "$POLICY_FILE"
  cp "$POLICY_FILE" "$CASE/before.json"
  install
  expect_rc 1
  expect_output "VS Code ignores every policy in it"
  cmp -s "$POLICY_FILE" "$CASE/before.json" || fail "an invalid policy.json was changed"
done

echo "test: a symbolic link is left alone"
new_case symlink
mkdir -p "$(dirname "$POLICY_FILE")"
printf '{}\n' > "$CASE/target.json"
ln -s "$CASE/target.json" "$POLICY_FILE"
install
expect_rc 1
expect_output "is a symbolic link"
[[ "$(cat "$CASE/target.json")" == "{}" ]] || fail "the link's target was changed"

echo "test: the sign-in provider is set, changed and cleared, and someone else's is kept"
new_case auth
AUTH=microsoft generate
install
expect_rc 0
[[ "$(policy_value ExtensionGalleryAuthProvider)" == "microsoft" ]] || fail "AUTH=microsoft was not set"
expect_output "Microsoft Entra ID work or school account"
AUTH=github generate
install
expect_rc 0
[[ "$(policy_value ExtensionGalleryAuthProvider)" == "github" ]] || fail "AUTH was not changed to github"
generate
install
expect_rc 0
[[ "$(policy_value ExtensionGalleryAuthProvider)" == "<none>" ]] || fail "an unset AUTH did not clear the value it wrote"
new_case auth-foreign
mkdir -p "$(dirname "$POLICY_FILE")"
printf '{"ExtensionGalleryAuthProvider": "github"}\n' > "$POLICY_FILE"
AUTH=microsoft generate
install
expect_rc 1
expect_output "sets ExtensionGalleryAuthProvider to 'github'"
[[ "$(policy_value ExtensionGalleryAuthProvider)" == "github" ]] || fail "someone else's provider was changed"
[[ "$(policy_value ExtensionGalleryServiceUrl)" == "$EXPECTED_URL" ]] || fail "the URL was not set"
generate
install
expect_rc 0
[[ "$(policy_value ExtensionGalleryAuthProvider)" == "github" ]] || fail "someone else's provider was removed"

echo "test: a dry run changes nothing"
new_case dry-run
install --dry-run
expect_rc 0
expect_output "[dry-run]   action : SET ExtensionGalleryServiceUrl"
[[ ! -e "$POLICY_FILE" && ! -e "$POLICY_STATE" ]] || fail "a dry run wrote something"

echo "test: a VS Code too old for the policy is reported"
new_case old-vscode 1.100.3
install
expect_rc 1
expect_output "VS Code 1.100.3 doesn't read $POLICY_FILE; 1.106 and later do."
PATCH=1 generate
new_case old-vscode-patched 1.100.3
install
expect_rc 0
expect_output "the patch covers it until it's updated"
AUTH=microsoft generate
new_case old-vscode-auth 1.120.0
install
expect_rc 1
expect_output "VS Code 1.120.0 ignores ExtensionGalleryAuthProvider"
generate

echo "test: endor-remove.sh removes only Endor's policy"
new_case remove-created
AUTH=microsoft generate
install
expect_rc 0
remove
expect_rc 0
[[ ! -e "$POLICY_FILE" && ! -e "$(dirname "$POLICY_FILE")" ]] || fail "removal left the file it created"
[[ ! -e "$POLICY_STATE" ]] || fail "removal left the record"
generate
new_case remove-shared
mkdir -p "$(dirname "$POLICY_FILE")"
printf '{"UpdateMode": "none", "ExtensionGalleryAuthProvider": "github"}\n' > "$POLICY_FILE"
install
expect_rc 0
remove
expect_rc 0
[[ "$(policy_value ExtensionGalleryServiceUrl)" == "<none>" ]] || fail "removal left the URL"
[[ "$(policy_value UpdateMode)" == "none" ]] || fail "removal took another policy"
[[ "$(policy_value ExtensionGalleryAuthProvider)" == "github" ]] || fail "removal took someone else's provider"
new_case remove-unrecorded
mkdir -p "$(dirname "$POLICY_FILE")"
printf '{"ExtensionGalleryServiceUrl": "%s"}\n' "$EXPECTED_URL" > "$POLICY_FILE"
ENDOR_TEST_DRY_RUN=1 remove
expect_rc 0
expect_output "[dry-run]   action : REMOVE the Endor ExtensionGalleryServiceUrl policy"
[[ "$(policy_value ExtensionGalleryServiceUrl)" == "$EXPECTED_URL" ]] || fail "a dry run removed the policy"
remove
expect_rc 0
expect_output "no record of setting ExtensionGalleryServiceUrl"
[[ -f "$POLICY_FILE" && "$(policy_value ExtensionGalleryServiceUrl)" == "<none>" ]] \
  || fail "removal deleted a file it has no record of creating, or left the URL"
new_case remove-nothing
remove
expect_rc 0
expect_output "skip (no VS Code policy file)"
# A record folder without a record goes too.
mkdir -p "$POLICY_STATE"
remove
expect_rc 0
[[ ! -e "$POLICY_STATE" ]] || fail "removal left an empty record folder"

echo "test: a policy left by an earlier deployment is reported, and left in place"
new_case leftover
install
expect_rc 0
PATCH=1 POLICY=0 generate
install
expect_rc 1
expect_output "policy from an earlier deployment is still set in $POLICY_FILE"
[[ "$(policy_value ExtensionGalleryServiceUrl)" == "$EXPECTED_URL" ]] || fail "the policy was removed"
generate

# As root on Linux this would write the real /etc/vscode/policy.json, so it runs only otherwise.
if [[ "$(uname -s)" == "Darwin" || "$(id -u)" -ne 0 ]]; then
  echo "test: without the test override, the policy goes where the OS keeps it"
  new_case real-location
  PATCH=1 generate
  RC=0
  OUTPUT=$(ENDOR_VSCODE_PRODUCT_JSON="$CASE/app/product.json" ENDOR_VSCODE_STATE_DIR="$CASE/state" \
    ENDOR_VSCODE_MANAGED_PREFS="$CASE/managed" ENDOR_VSCODE_SKIP_WATCHER=1 "$OUT/endor-vscode.sh" 2>&1) || RC=$?
  case "$(uname -s)" in
    Darwin)
      expect_rc 0
      expect_output "no configuration profile sets VS Code's policy yet"
      ;;
    Linux)
      expect_rc 1
      expect_output "setting VS Code's policy must run as root"
      ;;
  esac
  generate
fi

echo "test: with the policy, the generator writes a macOS profile and property list"
UUID_RE='^[0-9A-F]{8}-[0-9A-F]{4}-5[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$'
PROFILE="$OUT/endor-vscode.mobileconfig"
PREFS="$OUT/endor-vscode-policy.plist"
generate
for file in "$PROFILE" "$PREFS"; do
  [[ -f "$file" ]] || fail "$file was not generated"
  [[ "$(file_mode "$file")" == "600" ]] || fail "$file is not mode 600"
  if grep -qE '\{\{|<!--' "$file"; then fail "$file has a placeholder or the template's comment"; fi
  if command -v xmllint >/dev/null 2>&1; then xmllint --noout "$file" || fail "$file is not well-formed XML"; fi
  if [[ -x /usr/bin/plutil ]]; then /usr/bin/plutil -lint -s "$file" || fail "$file is not a valid property list"; fi
done
[[ "$(plist_value "$PROFILE" PayloadType)" == "Configuration" ]] || fail "the profile is not a Configuration"
[[ "$(plist_value "$PROFILE" PayloadIdentifier)" == "com.endorlabs.package-firewall.vscode" ]] \
  || fail "the profile's identifier is not stable"
[[ "$(plist_value "$PROFILE" TargetDeviceType)" == "5" ]] || fail "the profile does not target macOS"
[[ "$(plist_value "$PROFILE" PayloadContent.0.PayloadType)" == "com.microsoft.VSCode" ]] \
  || fail "the payload is not for com.microsoft.VSCode"
[[ "$(plist_value "$PROFILE" PayloadContent.0.ExtensionGalleryServiceUrl)" == "$EXPECTED_URL" ]] \
  || fail "the profile does not carry the URL"
[[ "$(plist_value "$PROFILE" PayloadContent.0.ExtensionGalleryAuthProvider)" == "<none>" ]] \
  || fail "the profile sets a provider without AUTH"
[[ "$(plist_value "$PREFS" ExtensionGalleryServiceUrl)" == "$EXPECTED_URL" ]] || fail "the plist does not carry the URL"
profile_uuid=$(plist_value "$PROFILE" PayloadUUID)
payload_uuid=$(plist_value "$PROFILE" PayloadContent.0.PayloadUUID)
[[ "$profile_uuid" =~ $UUID_RE && "$payload_uuid" =~ $UUID_RE && "$profile_uuid" != "$payload_uuid" ]] \
  || fail "the profile's UUIDs are malformed: $profile_uuid $payload_uuid"
cp "$PROFILE" "$TMP_DIR/profile-before"
generate
cmp -s "$PROFILE" "$TMP_DIR/profile-before" || fail "regenerating the same profile changed it"
AUTH=microsoft generate
[[ "$(plist_value "$PROFILE" PayloadContent.0.ExtensionGalleryAuthProvider)" == "microsoft" ]] \
  || fail "the profile does not set AUTH"
[[ "$(plist_value "$PREFS" ExtensionGalleryAuthProvider)" == "microsoft" ]] || fail "the plist does not set AUTH"
[[ "$(plist_value "$PROFILE" PayloadUUID)" != "$profile_uuid" ]] || fail "a different profile kept its UUID"
PATCH=1 POLICY=0 generate
[[ ! -e "$PROFILE" && ! -e "$PREFS" ]] || fail "the profile was left behind with the policy off"
generate

if [[ "$(uname -s)" == "Darwin" ]]; then
  # install_mac: runs endor-vscode.sh for the current case without the policy file override, so
  # it checks managed preferences. The patch is on, so a daemon on this Mac doesn't count as a
  # leftover. Sets RC and OUTPUT.
  install_mac() {
    RC=0
    OUTPUT=$(ENDOR_VSCODE_PRODUCT_JSON="$CASE/app/product.json" \
      ENDOR_VSCODE_STATE_DIR="$CASE/state" \
      ENDOR_VSCODE_APP="$CASE/Visual Studio Code.app" \
      ENDOR_VSCODE_MANAGED_PREFS="$CASE/managed" \
      ENDOR_VSCODE_SKIP_WATCHER=1 \
      "$OUT/endor-vscode.sh" 2>&1) || RC=$?
  }
  new_mac_case() {
    new_case "$1"
    mkdir -p "$CASE/managed" "$CASE/Visual Studio Code.app/Contents"
    python3 -I -c 'import plistlib, sys; plistlib.dump({"CFBundleShortVersionString": sys.argv[2]}, open(sys.argv[1], "wb"))' \
      "$CASE/Visual Studio Code.app/Contents/Info.plist" "${2:-1.141.2}"
  }

  echo "test: macOS: the installer reports the profile that sets the policy"
  PATCH=1 generate
  new_mac_case mac-none
  install_mac
  expect_rc 0
  expect_output "no configuration profile sets VS Code's policy yet"
  # The generated profile, as macOS installs it.
  new_mac_case mac-generated
  python3 -I - "$PROFILE" "$CASE/managed/com.microsoft.VSCode.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    payload = plistlib.load(handle)["PayloadContent"][0]
with open(sys.argv[2], "wb") as handle:
    plistlib.dump({k: v for k, v in payload.items() if not k.startswith("Payload")}, handle)
PY
  install_mac
  expect_rc 0
  expect_output "VS Code's policy is set by a configuration profile."
  new_mac_case mac-user
  managed_prefs "$CASE/managed/alice/com.microsoft.VSCode.plist" "$EXPECTED_URL"
  install_mac
  expect_rc 0
  expect_output "VS Code's policy is set by a configuration profile."

  echo "test: macOS: an old credential, another gallery or another provider in a profile is a warning"
  new_mac_case mac-stale
  managed_prefs "$CASE/managed/com.microsoft.VSCode.plist" "$(service_url old-secret)"
  install_mac
  expect_rc 1
  expect_output "with other credentials or for another namespace"
  new_mac_case mac-foreign
  managed_prefs "$CASE/managed/com.microsoft.VSCode.plist" "https://gallery.example.invalid/_apis/public/gallery"
  install_mac
  expect_rc 1
  expect_output "sets ExtensionGalleryServiceUrl to another gallery"
  PATCH=1 AUTH=microsoft generate
  new_mac_case mac-auth
  managed_prefs "$CASE/managed/com.microsoft.VSCode.plist" "$EXPECTED_URL"
  install_mac
  expect_rc 1
  expect_output "sets ExtensionGalleryAuthProvider to 'github, the default', not 'microsoft'"
  managed_prefs "$CASE/managed/com.microsoft.VSCode.plist" "$EXPECTED_URL" microsoft
  install_mac
  expect_rc 0

  echo "test: macOS: a VS Code too old for the policy is reported"
  PATCH=1 generate
  new_mac_case mac-old 1.98.0
  managed_prefs "$CASE/managed/com.microsoft.VSCode.plist" "$EXPECTED_URL"
  install_mac
  expect_rc 0
  expect_output "VS Code 1.98.0 doesn't read the ExtensionGalleryServiceUrl policy (1.99 and later do); the patch covers it"

  echo "test: macOS: a profile left by an earlier deployment is reported"
  PATCH=1 POLICY=0 generate
  new_mac_case mac-leftover
  managed_prefs "$CASE/managed/com.microsoft.VSCode.plist" "$EXPECTED_URL"
  install_mac
  expect_rc 1
  expect_output "a configuration profile still sets VS Code's ExtensionGalleryServiceUrl"

  echo "test: macOS: endor-remove.sh reports a profile it can't remove"
  generate
  section="$TMP_DIR/remove-section-mac.sh"
  {
    echo 'set -euo pipefail'
    echo 'DRY_RUN=0; _ENDOR_WARNED=0'
    sed -n '/^# >>> endor-vscode-remove$/,/^# <<< endor-vscode-remove$/p' "$OUT/endor-remove.sh"
    echo 'exit "$_ENDOR_WARNED"'
  } > "$section"
  RC=0
  OUTPUT=$(ENDOR_VSCODE_STATE_DIR="$CASE/state" ENDOR_VSCODE_MANAGED_PREFS="$CASE/managed" \
    ENDOR_VSCODE_SKIP_WATCHER=1 bash "$section" 2>&1) || RC=$?
  expect_rc 1
  expect_output "Remove the profile in your MDM"
  new_mac_case mac-remove-none
  RC=0
  OUTPUT=$(ENDOR_VSCODE_STATE_DIR="$CASE/state" ENDOR_VSCODE_MANAGED_PREFS="$CASE/managed" \
    ENDOR_VSCODE_SKIP_WATCHER=1 bash "$section" 2>&1) || RC=$?
  expect_rc 0
  expect_output "skip (no VS Code configuration profile)"
  generate
fi

# product_url: the serviceUrl in the case's product.json.
product_url() {
  python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["extensionsGallery"]["serviceUrl"])' \
    "$CASE/app/product.json"
}

# disable <patch|policy> [--dry-run]: runs endor-vscode-disable-<method>.sh for the current case.
# Sets RC and OUTPUT.
disable() {
  local method="$1"
  shift
  RC=0
  OUTPUT=$(ENDOR_VSCODE_PRODUCT_JSON="$CASE/app/product.json" \
    ENDOR_VSCODE_STATE_DIR="$CASE/state" \
    ENDOR_VSCODE_POLICY_FILE="$POLICY_FILE" \
    ENDOR_VSCODE_POLICY_STATE_DIR="$POLICY_STATE" \
    ENDOR_VSCODE_SKIP_WATCHER=1 \
    "$OUT/endor-vscode-disable-$method.sh" "$@" 2>&1) || RC=$?
}

echo "test: each disable script turns off its own method, and leaves the other"
PATCH=1 generate
for method in patch policy; do
  [[ -x "$OUT/endor-vscode-disable-$method.sh" ]] || fail "endor-vscode-disable-$method.sh was not generated"
  /bin/bash -n "$OUT/endor-vscode-disable-$method.sh"
done
new_case disable
install
expect_rc 0
[[ "$(product_url)" == "$EXPECTED_URL" && "$(policy_value ExtensionGalleryServiceUrl)" == "$EXPECTED_URL" ]] \
  || fail "the installer did not apply both methods"
disable policy --dry-run
expect_rc 0
expect_output "Dry run complete"
[[ "$(policy_value ExtensionGalleryServiceUrl)" == "$EXPECTED_URL" ]] || fail "a dry run removed the policy"
disable policy
expect_rc 0
expect_output "The VS Code ExtensionGalleryServiceUrl policy is off."
[[ ! -e "$POLICY_FILE" ]] || fail "disable-policy left the policy file it created"
[[ "$(product_url)" == "$EXPECTED_URL" && -x "$CASE/state/worker.sh" ]] || fail "disable-policy touched the patch"
install
expect_rc 0
disable patch
expect_rc 0
expect_output "The VS Code product.json patch is off."
[[ "$(product_url)" == "https://marketplace.visualstudio.com/_apis/public/gallery" ]] \
  || fail "disable-patch did not restore product.json"
[[ ! -e "$CASE/state" ]] || fail "disable-patch left the patch's state"
[[ "$(policy_value ExtensionGalleryServiceUrl)" == "$EXPECTED_URL" ]] || fail "disable-patch touched the policy"
# With one method off, the installer generated for the other stops warning, unless this machine
# has a patch of its own.
POLICY=1 PATCH=0 generate
install
if [[ ! -e /Library/LaunchDaemons/com.endorlabs.vscode-firewall.plist \
    && ! -e /etc/systemd/system/endor-vscode-firewall.path && ! -e /etc/dpkg/dpkg.cfg.d/endor-vscode-firewall ]]; then
  expect_rc 0
fi
generate

echo "test: the VS Code section of endor-remove.sh doesn't use the console user"
for script in "$OUT/endor-vscode-disable-patch.sh" "$OUT/endor-vscode-disable-policy.sh"; do
  if grep -nE 'CONSOLE_USER|USER_HOME|USER_GROUP' "$script"; then
    fail "$script uses the console user"
  fi
done

echo "test: the generator refuses a remove template without exactly one marked VS Code section"
copy="$TMP_DIR/generator-copy"
mkdir -p "$copy/package-firewall"
cp -R "$ROOT_DIR/package-firewall/bash" "$ROOT_DIR/package-firewall/shared" "$copy/package-firewall/"
for broken in missing-end two-starts; do
  template="$copy/package-firewall/bash/templates/remove.sh"
  cp "$ROOT_DIR/package-firewall/bash/templates/remove.sh" "$template"
  case "$broken" in
    missing-end) sed -i.bak '/^# <<< endor-vscode-remove$/d' "$template" ;;
    two-starts) printf '# >>> endor-vscode-remove\n' >> "$template" ;;
  esac
  if ENDOR_NAMESPACE="$NAMESPACE" ENDOR_API_KEY_ID="$KEY_ID" ENDOR_API_SECRET="$SECRET" \
      bash "$copy/package-firewall/bash/generate.sh" >/dev/null 2>"$TMP_DIR/broken.err"; then
    fail "the generator accepted a remove template with $broken"
  fi
  grep -q "must mark one non-empty VS Code section" "$TMP_DIR/broken.err" \
    || fail "the generator gave the wrong error for $broken"
done

echo "test: the installer and endor-remove.sh carry the same policy program"
extract() { sed -n "/^IFS= read -r -d '' _VSCODE_POLICY_PY <<'ENDOR_VSCODE_POLICY_PY'/,/^ENDOR_VSCODE_POLICY_PY\$/p" "$1"; }
installer_program=$(extract "$ROOT_DIR/package-firewall/bash/templates/vscode.sh")
remove_program=$(extract "$ROOT_DIR/package-firewall/bash/templates/remove.sh")
[[ -n "$installer_program" && "$installer_program" == "$remove_program" ]] \
  || fail "templates/vscode.sh and templates/remove.sh have different policy programs"

echo "VS Code policy Bash tests passed"
