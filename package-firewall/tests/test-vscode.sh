#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
GENERATOR="$ROOT_DIR/package-firewall/bash/generate.sh"
FIXTURE="$TEST_DIR/fixtures/vscode-product.json"
NAMESPACE="ci-smoke"
KEY_ID="ci-smoke-key-id"
SECRET="ci-smoke-secret"
EXPECTED_URL="https://factory.endorlabs.com/v1/namespaces/ci-smoke/firewall/vscode/_ak/Y2ktc21va2Uta2V5LWlkOmNpLXNtb2tlLXNlY3JldA"
DEFAULT_SERVICE_URL="https://marketplace.visualstudio.com/_apis/public/gallery"
DEFAULT_EXTENSION_URL_TEMPLATE="https://www.vscode-unpkg.net/_gallery/{publisher}/{name}/latest"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

OUT="$ROOT_DIR/package-firewall/bash/out/$NAMESPACE"

# PATCH and POLICY set the two method flags; the patch is on unless PATCH says otherwise.
generate() {
  local secret="${1:-$SECRET}"
  ENDOR_NAMESPACE="$NAMESPACE" \
    ENDOR_API_KEY_ID="$KEY_ID" \
    ENDOR_API_SECRET="$secret" \
    ENDOR_VSCODE_ENABLE_PATCH="${PATCH-1}" \
    ENDOR_VSCODE_ENABLE_POLICY="${POLICY:-0}" \
    bash "$GENERATOR" >/dev/null
}

# A leftover Endor deployment on this machine makes a script with a method turned off exit 1.
host_has_patch() {
  [[ -e /Library/LaunchDaemons/com.endorlabs.vscode-firewall.plist \
    || -e /etc/systemd/system/endor-vscode-firewall.path \
    || -e /etc/dpkg/dpkg.cfg.d/endor-vscode-firewall ]]
}

run_installer() {
  local product="$1" state="$2"
  ENDOR_VSCODE_PRODUCT_JSON="$product" \
    ENDOR_VSCODE_STATE_DIR="$state" \
    ENDOR_VSCODE_SKIP_WATCHER=1 \
    "$ROOT_DIR/package-firewall/bash/out/$NAMESPACE/endor-vscode.sh"
}

assert_patched() {
  local product="$1" expected_url="${2:-$EXPECTED_URL}"
  python3 - "$product" "$expected_url" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    product = json.load(handle)
gallery = product["extensionsGallery"]
assert gallery["serviceUrl"] == sys.argv[2]
assert "extensionUrlTemplate" not in gallery
assert gallery.get("controlUrl") == "https://main.vscode-cdn.net/extensions/marketplace.json"
assert product["unknownFixtureData"]["preserve"] is True
PY
}

assert_restored() {
  local product="$1"
  python3 - "$product" "$DEFAULT_SERVICE_URL" "$DEFAULT_EXTENSION_URL_TEMPLATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    product = json.load(handle)
gallery = product["extensionsGallery"]
assert gallery["serviceUrl"] == sys.argv[2]
assert gallery["extensionUrlTemplate"] == sys.argv[3]
assert product["unknownFixtureData"]["preserve"] is True
PY
}

echo "test: patches product.json, preserves fields, and is idempotent"
generate
product="$TMP_DIR/basic-product.json"
state="$TMP_DIR/basic-state"
cp "$FIXTURE" "$product"
run_installer "$product" "$state"
assert_patched "$product"
bash -n "$state/worker.sh"
before=$(shasum -a 256 "$product" 2>/dev/null | awk '{print $1}' || sha256sum "$product" | awk '{print $1}')
run_installer "$product" "$state" >/dev/null
after=$(shasum -a 256 "$product" 2>/dev/null | awk '{print $1}' || sha256sum "$product" | awk '{print $1}')
[[ "$before" == "$after" ]]
ENDOR_VSCODE_PRODUCT_JSON="$product" \
  ENDOR_VSCODE_STATE_DIR="$state" \
  "$state/worker.sh" --restore
assert_restored "$product"

echo "test: dry-run reports drift without writing"
product="$TMP_DIR/dry-product.json"
state="$TMP_DIR/dry-state"
cp "$FIXTURE" "$product"
before=$(shasum -a 256 "$product" 2>/dev/null | awk '{print $1}' || sha256sum "$product" | awk '{print $1}')
ENDOR_VSCODE_PRODUCT_JSON="$product" \
  ENDOR_VSCODE_STATE_DIR="$state" \
  ENDOR_VSCODE_SKIP_WATCHER=1 \
  "$ROOT_DIR/package-firewall/bash/out/$NAMESPACE/endor-vscode.sh" --dry-run >/dev/null
after=$(shasum -a 256 "$product" 2>/dev/null | awk '{print $1}' || sha256sum "$product" | awk '{print $1}')
[[ "$before" == "$after" ]]
[[ ! -e "$state" ]]

echo "test: Jamf's volume, computer and user arguments are accepted"
product="$TMP_DIR/jamf-product.json"
state="$TMP_DIR/jamf-state"
cp "$FIXTURE" "$product"
before=$(shasum -a 256 "$product" 2>/dev/null | awk '{print $1}' || sha256sum "$product" | awk '{print $1}')
ENDOR_VSCODE_PRODUCT_JSON="$product" \
  ENDOR_VSCODE_STATE_DIR="$state" \
  ENDOR_VSCODE_SKIP_WATCHER=1 \
  "$ROOT_DIR/package-firewall/bash/out/$NAMESPACE/endor-vscode.sh" / test-mac test-user --dry-run "" >/dev/null
after=$(shasum -a 256 "$product" 2>/dev/null | awk '{print $1}' || sha256sum "$product" | awk '{print $1}')
[[ "$before" == "$after" ]]
[[ ! -e "$state" ]]
ENDOR_VSCODE_PRODUCT_JSON="$product" \
  ENDOR_VSCODE_STATE_DIR="$state" \
  ENDOR_VSCODE_SKIP_WATCHER=1 \
  "$ROOT_DIR/package-firewall/bash/out/$NAMESPACE/endor-vscode.sh" / test-mac test-user "" "" >/dev/null
assert_patched "$product"
if "$ROOT_DIR/package-firewall/bash/out/$NAMESPACE/endor-vscode.sh" --bogus >/dev/null 2>&1; then
  echo "expected an unknown argument to be rejected" >&2
  exit 1
fi

echo "test: an unsupported OS is skipped with a warning"
fake_bin="$TMP_DIR/fake-bin"
mkdir -p "$fake_bin"
printf '#!/bin/sh\necho FreeBSD\n' > "$fake_bin/uname"
chmod 755 "$fake_bin/uname"
set +e
output=$(PATH="$fake_bin:$PATH" ENDOR_VSCODE_SKIP_WATCHER=1 \
  "$ROOT_DIR/package-firewall/bash/out/$NAMESPACE/endor-vscode.sh" 2>&1)
status=$?
set -e
[[ "$status" == "1" ]]
grep -q "supports macOS and Linux only" <<<"$output"
if grep -q "unbound variable" <<<"$output"; then
  echo "an unsupported OS hit an unset variable" >&2
  exit 1
fi

echo "test: the worker's python3 ignores modules in the current directory"
product="$TMP_DIR/isolated-product.json"
state="$TMP_DIR/isolated-state"
planted="$TMP_DIR/planted"
mkdir -p "$planted"
printf 'open("%s", "w").close()\nfrom json import *\n' "$TMP_DIR/planted-imported" > "$planted/json.py"
cp "$FIXTURE" "$product"
(cd "$planted" && run_installer "$product" "$state" >/dev/null)
assert_patched "$product"
[[ ! -e "$TMP_DIR/planted-imported" ]]

# dpkg unpacks a new VS Code as product.json.dpkg-new and renames it at the end; rpm uses
# product.json;<hex>. A run started meanwhile must patch the new file, not the old one.
for temp_name in "product.json.dpkg-new" "product.json;5f3e2a1b"; do
  echo "test: a run waits for the package manager to put $temp_name in place, then patches it"
  dir="$TMP_DIR/unpack-$RANDOM"
  mkdir -p "$dir"
  product="$dir/product.json"
  state="$dir-state"
  cp "$FIXTURE" "$product"
  sed 's/fixture-v1/fixture-v2/' "$FIXTURE" > "$dir/$temp_name"
  run_installer "$product" "$state" > "$dir.out" 2>&1 &
  pid=$!
  sleep 3
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "the run did not wait for the package manager" >&2
    cat "$dir.out" >&2
    exit 1
  fi
  mv -f "$dir/$temp_name" "$product"
  wait "$pid"
  assert_patched "$product"
  grep -q '"fixture-v2"' "$product"
  grep -q "waited for the package manager" "$dir.out"
done

echo "test: a package manager that never finishes delays the patch by ENDOR_VSCODE_SETTLE_TIMEOUT at most"
dir="$TMP_DIR/stuck-unpack"
mkdir -p "$dir"
product="$dir/product.json"
cp "$FIXTURE" "$product"
cp "$FIXTURE" "$product.dpkg-new"
started=$SECONDS
ENDOR_VSCODE_SETTLE_TIMEOUT=2 run_installer "$product" "$dir-state" >/dev/null 2>&1
(( SECONDS - started <= 8 ))
assert_patched "$product"
[[ -e "$product.dpkg-new" ]]

if command -v flock >/dev/null 2>&1; then
  echo "test: runs that overlap take turns"
  dir="$TMP_DIR/overlap"
  mkdir -p "$dir"
  product="$dir/product.json"
  state="$dir-state"
  cp "$FIXTURE" "$product"
  run_installer "$product" "$state" >/dev/null
  cp "$FIXTURE" "$product"
  sed 's/fixture-v1/fixture-v2/' "$FIXTURE" > "$product.dpkg-new"
  ENDOR_VSCODE_PRODUCT_JSON="$product" "$state/worker.sh" --once >/dev/null 2>&1 &
  first=$!
  sleep 1
  ENDOR_VSCODE_PRODUCT_JSON="$product" "$state/worker.sh" --once >/dev/null 2>&1 &
  second=$!
  sleep 2
  mv -f "$product.dpkg-new" "$product"
  wait "$first"
  wait "$second"
  assert_patched "$product"
  grep -q '"fixture-v2"' "$product"
  for leftover in "$dir"/*.endor.*; do
    if [[ -e "$leftover" ]]; then
      echo "overlapping runs left a temporary file behind: $leftover" >&2
      exit 1
    fi
  done
fi

echo "test: credential rotation preserves valid product.json modifications"
product="$TMP_DIR/rotation-product.json"
state="$TMP_DIR/rotation-state"
cp "$FIXTURE" "$product"
generate
run_installer "$product" "$state" >/dev/null
python3 - "$product" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    product = json.load(handle)
product["unknownFixtureData"]["adminModification"] = "keep-me"
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(product, handle, indent=2)
    handle.write("\n")
PY
generate "ci-smoke-rotated-secret"
run_installer "$product" "$state" >/dev/null
python3 - "$product" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    product = json.load(handle)
assert product["unknownFixtureData"]["adminModification"] == "keep-me"
PY
ENDOR_VSCODE_PRODUCT_JSON="$product" \
  ENDOR_VSCODE_STATE_DIR="$state" \
  "$state/worker.sh" --restore >/dev/null
assert_restored "$product"
python3 - "$product" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    product = json.load(handle)
assert product["unknownFixtureData"]["adminModification"] == "keep-me"
PY

echo "test: an updater overwrite is patched without losing new product data"
product="$TMP_DIR/update-product.json"
updated="$TMP_DIR/update-upstream.json"
state="$TMP_DIR/update-state"
generate
cp "$FIXTURE" "$product"
run_installer "$product" "$state" >/dev/null
python3 - "$FIXTURE" "$updated" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    product = json.load(handle)
product["commit"] = "fixture-v2"
product["extensionsGallery"]["serviceUrl"] = "https://new-upstream.example/gallery"
product["extensionsGallery"]["controlUrl"] = "https://new-upstream.example/control"
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(product, handle, indent=2)
    handle.write("\n")
PY
cp "$updated" "$product"
run_installer "$product" "$state" >/dev/null
ENDOR_VSCODE_PRODUCT_JSON="$product" \
  ENDOR_VSCODE_STATE_DIR="$state" \
  "$state/worker.sh" --restore >/dev/null
assert_restored "$product"
python3 - "$product" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    product = json.load(handle)
assert product["commit"] == "fixture-v2"
assert product["extensionsGallery"]["controlUrl"] == "https://new-upstream.example/control"
PY

echo "test: missing gallery is created structurally"
product="$TMP_DIR/no-gallery-product.json"
state="$TMP_DIR/no-gallery-state"
printf '%s\n' '{"nameShort":"Code","unknownFixtureData":{"preserve":true},"extensionsGallery":{"controlUrl":"https://main.vscode-cdn.net/extensions/marketplace.json"}}' > "$product"
run_installer "$product" "$state" >/dev/null
assert_patched "$product"

echo "test: malformed JSON fails without mutation"
product="$TMP_DIR/malformed-product.json"
state="$TMP_DIR/malformed-state"
printf '%s\n' '{"extensionsGallery":' > "$product"
cp "$product" "$TMP_DIR/malformed-original.json"
if run_installer "$product" "$state" >/dev/null 2>&1; then
  echo "expected malformed product.json to fail" >&2
  exit 1
fi
cmp -s "$product" "$TMP_DIR/malformed-original.json"

echo "test: the VS Code flags take true, false, 1 and 0 in any case, and nothing else"
for value in true TRUE True 1; do
  PATCH="$value" generate
  grep -qxF "_VSCODE_ENABLE_PATCH='1'" "$OUT/endor-vscode.sh"
done
for value in false FALSE 0 ""; do
  PATCH="$value" POLICY=true generate
  grep -qxF "_VSCODE_ENABLE_PATCH='0'" "$OUT/endor-vscode.sh"
  grep -qxF "_VSCODE_ENABLE_POLICY='1'" "$OUT/endor-vscode.sh"
done
for value in yes on 2 " true"; do
  if PATCH="$value" generate 2>/dev/null; then
    echo "expected ENDOR_VSCODE_ENABLE_PATCH='$value' to be rejected" >&2
    exit 1
  fi
  if POLICY="$value" generate 2>/dev/null; then
    echo "expected ENDOR_VSCODE_ENABLE_POLICY='$value' to be rejected" >&2
    exit 1
  fi
done

echo "test: ENDOR_VSCODE_POLICY_AUTH is github or microsoft, and only with the policy"
POLICY=1 ENDOR_VSCODE_POLICY_AUTH=Microsoft generate
grep -qxF "_VSCODE_POLICY_AUTH='microsoft'" "$OUT/endor-vscode.sh"
POLICY=1 generate
grep -qxF "_VSCODE_POLICY_AUTH=''" "$OUT/endor-vscode.sh"
if POLICY=1 ENDOR_VSCODE_POLICY_AUTH=okta generate 2>/dev/null; then
  echo "expected ENDOR_VSCODE_POLICY_AUTH=okta to be rejected" >&2
  exit 1
fi
if ENDOR_VSCODE_POLICY_AUTH=github generate 2>/dev/null; then
  echo "expected ENDOR_VSCODE_POLICY_AUTH without the policy to be rejected" >&2
  exit 1
fi

echo "test: ENDOR_VSCODE_MACOS_DAEMON is a deprecated alias for ENDOR_VSCODE_ENABLE_PATCH"
output=$(PATCH="" ENDOR_VSCODE_MACOS_DAEMON=1 generate 2>&1)
grep -q "ENDOR_VSCODE_MACOS_DAEMON is deprecated" <<<"$output"
grep -qxF "_VSCODE_ENABLE_PATCH='1'" "$OUT/endor-vscode.sh"
PATCH=true ENDOR_VSCODE_MACOS_DAEMON=1 generate 2>/dev/null
output=$(PATCH="" ENDOR_VSCODE_MACOS_DAEMON=0 generate 2>&1)
grep -q "no longer patches Linux either" <<<"$output"
if PATCH=0 ENDOR_VSCODE_MACOS_DAEMON=1 generate 2>/dev/null; then
  echo "expected ENDOR_VSCODE_MACOS_DAEMON=1 with ENDOR_VSCODE_ENABLE_PATCH=0 to be rejected" >&2
  exit 1
fi
if PATCH="" ENDOR_VSCODE_MACOS_DAEMON=yes generate 2>/dev/null; then
  echo "expected ENDOR_VSCODE_MACOS_DAEMON=yes to be rejected" >&2
  exit 1
fi

echo "test: with neither method enabled, VS Code is left alone"
output=$(PATCH=0 generate 2>&1)
grep -q "no method enabled" <<<"$output"
grep -q "VS Code: not enabled" "$OUT/endor-all.sh"
product="$TMP_DIR/neither-product.json"
state="$TMP_DIR/neither-state"
cp "$FIXTURE" "$product"
rc=0
output=$(run_installer "$product" "$state" 2>&1) || rc=$?
cmp -s "$product" "$FIXTURE"
[[ ! -e "$state" ]]
grep -q "no VS Code method is enabled" <<<"$output"
if grep -q "VS Code extension firewall done" <<<"$output"; then
  echo "a script with no method enabled said VS Code was done" >&2
  exit 1
fi
if host_has_patch; then [[ "$rc" -eq 1 ]]; else [[ "$rc" -eq 0 ]]; fi

echo "test: a patch left by an earlier deployment is reported, and left in place"
generate
product="$TMP_DIR/leftover-product.json"
state="$TMP_DIR/leftover-state"
cp "$FIXTURE" "$product"
run_installer "$product" "$state" >/dev/null
PATCH=0 generate 2>/dev/null
rc=0
output=$(run_installer "$product" "$state" 2>&1) || rc=$?
[[ "$rc" -eq 1 ]]
grep -q "patch from an earlier deployment is still installed" <<<"$output"
assert_patched "$product"
[[ -x "$state/worker.sh" ]]
# The patched product.json alone is enough to report it.
rm -rf "$state"
rc=0
output=$(run_installer "$product" "$state" 2>&1) || rc=$?
[[ "$rc" -eq 1 ]]
grep -qF "still installed ($product)" <<<"$output"

# The docs-site generator fetches these templates and fills in only the placeholders it knows.
# A script with the method placeholders left in place must behave as scripts did before them.
echo "test: a script from a generator that predates the method flags behaves as before"
PATCH=1 POLICY=1 generate
legacy="$TMP_DIR/legacy-vscode.sh"
for daemon in "{{VSCODE_MACOS_DAEMON}}" 1; do
  sed -e "s/^_VSCODE_ENABLE_PATCH='1'\$/_VSCODE_ENABLE_PATCH='{{VSCODE_ENABLE_PATCH}}'/" \
    -e "s/^_VSCODE_ENABLE_POLICY='1'\$/_VSCODE_ENABLE_POLICY='{{VSCODE_ENABLE_POLICY}}'/" \
    -e "s/^_VSCODE_POLICY_AUTH=''\$/_VSCODE_POLICY_AUTH='{{VSCODE_POLICY_AUTH}}'/" \
    -e "s/^_VSCODE_MACOS_DAEMON='1'\$/_VSCODE_MACOS_DAEMON='$daemon'/" \
    "$OUT/endor-vscode.sh" > "$legacy"
  chmod 700 "$legacy"
  [[ "$(grep -c '{{VSCODE_' "$legacy")" -ge 3 ]]
  product="$TMP_DIR/legacy-product.json"
  state="$TMP_DIR/legacy-state-$RANDOM"
  policy="$TMP_DIR/legacy-policy/policy.json"
  mkdir -p "$(dirname "$policy")"
  # An Endor policy is already there; a script that predates the policy says nothing about it.
  printf '{"ExtensionGalleryServiceUrl": "%s"}\n' "$EXPECTED_URL" > "$policy"
  cp "$policy" "$TMP_DIR/legacy-policy-before.json"
  cp "$FIXTURE" "$product"
  # Such scripts looked only for the macOS daemon's plist, not for a stray worker.
  mkdir -p "$state"
  printf '#!/bin/sh\n' > "$state/worker.sh"
  rc=0
  output=$(ENDOR_VSCODE_PRODUCT_JSON="$product" ENDOR_VSCODE_STATE_DIR="$state" \
    ENDOR_VSCODE_POLICY_FILE="$policy" ENDOR_VSCODE_POLICY_STATE_DIR="$TMP_DIR/legacy-policy-state" \
    ENDOR_VSCODE_SKIP_WATCHER=1 "$legacy" 2>&1) || rc=$?
  cmp -s "$policy" "$TMP_DIR/legacy-policy-before.json"
  [[ ! -e "$TMP_DIR/legacy-policy-state" ]]
  if grep -qi "policy" <<<"$output"; then
    echo "a script from an older generator mentioned the policy:" >&2
    echo "$output" >&2
    exit 1
  fi
  if [[ "$(uname -s)" == "Darwin" && "$daemon" != "1" ]]; then
    cmp -s "$product" "$FIXTURE"
    grep -qF 'ENDOR_VSCODE_MACOS_DAEMON=1' <<<"$output"
    if host_has_patch; then [[ "$rc" -eq 1 ]]; else [[ "$rc" -eq 0 ]]; fi
  else
    [[ "$rc" -eq 0 ]]
    assert_patched "$product"
  fi
done
generate

echo "VS Code Bash tests passed"
