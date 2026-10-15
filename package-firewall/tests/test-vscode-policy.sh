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
    ENDOR_VSCODE_SKIP_WATCHER=1 "$OUT/endor-vscode.sh" 2>&1) || RC=$?
  case "$(uname -s)" in
    Darwin)
      expect_output "VS Code reads its policy from a configuration profile"
      ;;
    Linux)
      expect_rc 1
      expect_output "setting VS Code's policy must run as root"
      ;;
  esac
  generate
fi

echo "test: the installer and endor-remove.sh carry the same policy program"
extract() { sed -n "/^IFS= read -r -d '' _VSCODE_POLICY_PY <<'ENDOR_VSCODE_POLICY_PY'/,/^ENDOR_VSCODE_POLICY_PY\$/p" "$1"; }
installer_program=$(extract "$ROOT_DIR/package-firewall/bash/templates/vscode.sh")
remove_program=$(extract "$ROOT_DIR/package-firewall/bash/templates/remove.sh")
[[ -n "$installer_program" && "$installer_program" == "$remove_program" ]] \
  || fail "templates/vscode.sh and templates/remove.sh have different policy programs"

echo "VS Code policy Bash tests passed"
