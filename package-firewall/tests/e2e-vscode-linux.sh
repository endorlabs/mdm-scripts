#!/usr/bin/env bash
# Linux (Debian/Ubuntu with systemd) only. End-to-end test of the VS Code firewall's update
# remediation with Microsoft's real .deb packages:
#   1. install OLD with apt, deploy endor-vscode.sh with both methods, and check the path unit,
#      timer and dpkg hook, and /etc/vscode/policy.json;
#   2. upgrade to NEW with apt, and downgrade to OLD with dpkg -i: each is patched by the time the
#      command returns (the dpkg hook);
#   3. without the dpkg hook, dpkg -i NEW is patched within 15 seconds (the path unit, whose run
#      waits for dpkg to rename the new files into place);
#   4. with the path unit stopped, a reset product.json is patched within 75 seconds (the timer);
#   5. remove, and check Microsoft's gallery settings are back and the units, hook and policy are
#      gone.
#
# It changes the machine it runs on: it installs VS Code, systemd units and a dpkg hook. So it
# runs only on a GitHub-hosted runner, or with ENDOR_E2E_ALLOW_HOST_CHANGES=1 on a disposable
# machine. It needs passwordless sudo, systemd and access to update.code.visualstudio.com.
#
#   ENDOR_E2E_OLD_VERSION, ENDOR_E2E_NEW_VERSION  the VS Code releases to use. By default NEW is
#                            the latest stable release and OLD the newest one of the minor before.
#   ENDOR_E2E_ARTIFACTS      where to keep logs: installer, journal, removal
#
# Logs of root commands are redirected as the user running the test, so they stay readable.
# shellcheck disable=SC2024
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "skip: the VS Code Linux end-to-end test runs on Linux only"
  exit 0
fi
if [[ "${RUNNER_ENVIRONMENT:-}" != "github-hosted" && "${ENDOR_E2E_ALLOW_HOST_CHANGES:-0}" != "1" ]]; then
  echo "refusing to run: this test installs VS Code, systemd units and a dpkg hook on this machine." >&2
  echo "  Run it on a GitHub-hosted runner, or set ENDOR_E2E_ALLOW_HOST_CHANGES=1 on a disposable machine." >&2
  exit 2
fi
if ! sudo -n true 2>/dev/null; then
  echo "this test needs passwordless sudo" >&2
  exit 2
fi
if [[ ! -d /run/systemd/system || ! -d /etc/dpkg/dpkg.cfg.d ]]; then
  echo "this test needs systemd and dpkg" >&2
  exit 2
fi

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
NAMESPACE="ci-e2e"
OUT="$ROOT_DIR/package-firewall/bash/out/$NAMESPACE"
FIREWALL_PREFIX="https://factory.endorlabs.com/v1/namespaces/$NAMESPACE/firewall/vscode/_ak/"
DEFAULT_SERVICE_URL="https://marketplace.visualstudio.com/_apis/public/gallery"
DEFAULT_EXTENSION_URL_TEMPLATE="https://www.vscode-unpkg.net/_gallery/{publisher}/{name}/latest"
APP_DIR="/usr/share/code/resources/app"
PRODUCT="$APP_DIR/product.json"
STATE_DIR="/var/lib/endor/vscode-firewall"
DPKG_HOOK="/etc/dpkg/dpkg.cfg.d/endor-vscode-firewall"
POLICY_FILE="/etc/vscode/policy.json"
POLICY_STATE_DIR="/var/lib/endor/vscode-policy"
UNITS=(endor-vscode-firewall.path endor-vscode-firewall.timer endor-vscode-firewall.service)
ARTIFACTS="${ENDOR_E2E_ARTIFACTS:-${TMPDIR:-/tmp}/vscode-e2e-artifacts}"
WORK=$(mktemp -d)
STARTED_AT=$(date '+%Y-%m-%d %H:%M:%S')
mkdir -p "$ARTIFACTS"
export DEBIAN_FRONTEND=noninteractive

info() { echo "[e2e] $*"; }
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

finish() {
  local status=$?
  sudo journalctl --no-pager --since "$STARTED_AT" -u 'endor-vscode-firewall*' > "$ARTIFACTS/journal.log" 2>&1 || true
  [[ -f "$DPKG_HOOK" ]] && cp "$DPKG_HOOK" "$ARTIFACTS/dpkg-hook.cfg" 2>/dev/null
  rm -rf "$WORK"
  exit "$status"
}
trap finish EXIT

service_url() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["extensionsGallery"].get("serviceUrl", ""))' "$PRODUCT"; }
installed_version() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$APP_DIR/package.json"; }
patched() { [[ "$(service_url 2>/dev/null)" == "$FIREWALL_PREFIX"* ]]; }

# wait_until <seconds> <command...>: wall-clock seconds; WAITED holds how long it took.
wait_until() {
  local limit="$1" start=$SECONDS
  shift
  while ! "$@"; do
    (( SECONDS - start >= limit )) && { WAITED=$((SECONDS - start)); return 1; }
    sleep 1
  done
  WAITED=$((SECONDS - start))
}

download() {
  local deb="$WORK/code_$1.deb"
  curl -fL --retry 3 -sS -o "$deb" "https://update.code.visualstudio.com/$1/linux-deb-x64/stable" \
    || fail "could not download VS Code $1"
  echo "$deb"
}

releases=$(curl -fsSL --retry 3 https://update.code.visualstudio.com/api/releases/stable \
  | tr -d '[]" ' | tr ',' '\n') || fail "could not list VS Code releases"
NEW="${ENDOR_E2E_NEW_VERSION:-$(printf '%s\n' "$releases" | head -n 1)}"
OLD="${ENDOR_E2E_OLD_VERSION:-$(printf '%s\n' "$releases" | awk -F. -v n="$NEW" \
  'BEGIN { split(n, v, ".") } $1 != v[1] || $2 != v[2] { print; exit }')}"
info "VS Code $OLD -> $NEW"
OLD_DEB=$(download "$OLD")
NEW_DEB=$(download "$NEW")

info "1. install $OLD with apt and deploy"
sudo -E apt-get install -y -q "$OLD_DEB" > "$ARTIFACTS/apt-old.log" 2>&1 || fail "apt could not install $OLD"
[[ "$(installed_version)" == "$OLD" ]] || fail "expected $OLD, found $(installed_version)"
patched && fail "a fresh install is already patched"
# Removal deletes /etc/vscode only if the installer created it.
POLICY_DIR_EXISTED=0
[[ ! -e /etc/vscode ]] || POLICY_DIR_EXISTED=1
ENDOR_NAMESPACE="$NAMESPACE" ENDOR_API_KEY_ID="ci-e2e-key-id" ENDOR_API_SECRET="ci-e2e-secret" \
  ENDOR_VSCODE_ENABLE_PATCH=1 ENDOR_VSCODE_ENABLE_POLICY=1 bash "$ROOT_DIR/package-firewall/bash/generate.sh" >/dev/null
sudo bash "$OUT/endor-vscode.sh" > "$ARTIFACTS/install.log" 2>&1 || fail "endor-vscode.sh failed (see install.log)"
patched || fail "the installer did not patch $PRODUCT"
for unit in endor-vscode-firewall.path endor-vscode-firewall.timer; do
  systemctl is-active --quiet "$unit" || fail "$unit is not active"
  systemctl is-enabled --quiet "$unit" || fail "$unit is not enabled"
done
[[ -f "$DPKG_HOOK" ]] || fail "the dpkg hook is missing"
grep -q '^PathChanged=/usr/share/code/resources/app$' /etc/systemd/system/endor-vscode-firewall.path \
  || fail "the path unit doesn't watch $APP_DIR"
[[ "$(stat -c '%U:%G %a' "$POLICY_FILE" 2>/dev/null)" == "root:root 644" ]] \
  || fail "$POLICY_FILE is missing, or not root's with mode 644"
python3 -I -c 'import json, sys; assert json.load(open(sys.argv[1]))["ExtensionGalleryServiceUrl"].startswith(sys.argv[2])' \
  "$POLICY_FILE" "$FIREWALL_PREFIX" || fail "$POLICY_FILE doesn't set the Endor ExtensionGalleryServiceUrl"
# VS Code reads policy.json from 1.106.
if [[ "$(printf '%s\n' 1.106.0 "$OLD" | sort -V | head -n 1)" == "1.106.0" ]] \
    && grep -q "doesn't read $POLICY_FILE" "$ARTIFACTS/install.log"; then
  fail "the installer says VS Code $OLD is too old for the policy"
fi
pass "deployed: patched and the policy set, with the path unit, the timer and the dpkg hook"

info "2. upgrade with apt, then downgrade with dpkg -i"
sudo -E apt-get install -y -q "$NEW_DEB" > "$ARTIFACTS/apt-new.log" 2>&1 || fail "apt could not install $NEW"
[[ "$(installed_version)" == "$NEW" ]] || fail "expected $NEW after the upgrade"
patched || fail "apt returned before the upgraded product.json was patched"
pass "apt upgrade to $NEW: patched by the time apt returned"
sudo dpkg -i "$OLD_DEB" > "$ARTIFACTS/dpkg-old.log" 2>&1 || fail "dpkg could not install $OLD"
[[ "$(installed_version)" == "$OLD" ]] || fail "expected $OLD after the downgrade"
patched || fail "dpkg returned before the downgraded product.json was patched"
pass "dpkg -i $OLD: patched by the time dpkg returned"

info "3. without the dpkg hook, the path unit patches"
sudo mv "$DPKG_HOOK" "$WORK/dpkg-hook"
sudo dpkg -i "$NEW_DEB" > "$ARTIFACTS/dpkg-new.log" 2>&1 || fail "dpkg could not install $NEW"
[[ "$(installed_version)" == "$NEW" ]] || fail "expected $NEW"
wait_until 15 patched || fail "the path unit did not patch the new product.json within 15s"
pass "dpkg -i $NEW without the hook: the path unit patched it within ${WAITED}s"
sudo mv "$WORK/dpkg-hook" "$DPKG_HOOK"

info "4. with the path unit stopped, the timer patches"
sudo systemctl stop endor-vscode-firewall.path
sudo python3 -I - "$PRODUCT" "$DEFAULT_SERVICE_URL" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    product = json.load(handle)
product["extensionsGallery"]["serviceUrl"] = sys.argv[2]
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(product, handle, indent=2)
PY
patched && fail "could not reset product.json"
wait_until 75 patched || fail "the timer did not patch product.json within 75s"
pass "the timer patched a reset product.json within ${WAITED}s"
sudo systemctl start endor-vscode-firewall.path

info "5. remove"
if sudo bash "$OUT/endor-remove.sh" > "$ARTIFACTS/remove.log" 2>&1; then
  :
elif grep -q "could not detect console user" "$ARTIFACTS/remove.log"; then
  # endor-remove.sh needs a signed-in user for the other ecosystems. Its VS Code section doesn't,
  # so run only that.
  echo "::notice::no signed-in user on this runner; running only the VS Code section of endor-remove.sh"
  {
    echo 'set -euo pipefail'
    echo 'DRY_RUN=0; _ENDOR_WARNED=0'
    sed -n '/^# >>> endor-vscode-remove$/,/^# <<< endor-vscode-remove$/p' "$OUT/endor-remove.sh"
    echo 'exit "$_ENDOR_WARNED"'
  } > "$WORK/remove-vscode.sh"
  sudo bash "$WORK/remove-vscode.sh" >> "$ARTIFACTS/remove.log" 2>&1 \
    || fail "the VS Code section of endor-remove.sh failed (see remove.log)"
else
  fail "endor-remove.sh failed (see remove.log)"
fi
[[ "$(service_url)" == "$DEFAULT_SERVICE_URL" ]] || fail "removal did not restore serviceUrl"
python3 -I -c 'import json, sys; assert json.load(open(sys.argv[1]))["extensionsGallery"]["extensionUrlTemplate"] == sys.argv[2]' \
  "$PRODUCT" "$DEFAULT_EXTENSION_URL_TEMPLATE" || fail "removal did not restore extensionUrlTemplate"
[[ ! -e "$DPKG_HOOK" ]] || fail "the dpkg hook is still there"
for unit in "${UNITS[@]}"; do
  [[ ! -e "/etc/systemd/system/$unit" ]] || fail "$unit is still there"
done
[[ ! -e "$STATE_DIR" ]] || fail "the state folder is still there"
[[ ! -e "$POLICY_FILE" ]] || fail "removal left $POLICY_FILE, which the installer created"
[[ "$POLICY_DIR_EXISTED" == "1" || ! -e /etc/vscode ]] || fail "removal left /etc/vscode, which the installer created"
[[ ! -e "$POLICY_STATE_DIR" ]] || fail "removal left the policy record"
sudo dpkg -i "$OLD_DEB" > "$ARTIFACTS/dpkg-after-removal.log" 2>&1 || fail "dpkg could not install $OLD"
patched && fail "VS Code was patched after removal"
pass "removal restored the gallery settings and removed the units, the dpkg hook and the policy"
echo "VS Code Linux end-to-end test passed"
