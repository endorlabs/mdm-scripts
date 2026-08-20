# templates/vscode.sh
# Patches Microsoft VS Code Stable's product.json and installs update remediation.

echo ""
echo "[endor] ── VS Code extension firewall ───────────────────────────────────────"

IFS= read -r -d '' _VSCODE_WORKER_CONTENT <<'ENDOR_VSCODE_WORKER' || true
#!/usr/bin/env bash
set -uo pipefail

FIREWALL_URL='{{VSCODE_SERVICE_URL}}'
DEFAULT_SERVICE_URL='https://marketplace.visualstudio.com/_apis/public/gallery'
DEFAULT_EXTENSION_URL_TEMPLATE='https://www.vscode-unpkg.net/_gallery/{publisher}/{name}/latest'
MODE="once"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --once) MODE="once" ;;
    --restore) MODE="restore" ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "[endor-vscode] ERROR: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

list_product_files() {
  if [[ -n "${ENDOR_VSCODE_PRODUCT_JSON:-}" ]]; then
    [[ -f "$ENDOR_VSCODE_PRODUCT_JSON" ]] && printf '%s\n' "$ENDOR_VSCODE_PRODUCT_JSON"
    return 0
  fi

  case "$(uname -s)" in
    Darwin)
      [[ -f "/Applications/Visual Studio Code.app/Contents/Resources/app/product.json" ]] \
        && printf '%s\n' "/Applications/Visual Studio Code.app/Contents/Resources/app/product.json"
      ;;
    Linux)
      local candidate
      for candidate in \
        "/usr/share/code/resources/app/product.json" \
        "/usr/lib/code/resources/app/product.json"; do
        [[ -f "$candidate" ]] && printf '%s\n' "$candidate"
      done
      ;;
  esac
}

jxa_json() {
  /usr/bin/osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('Foundation');

function readUtf8(path) {
  const error = Ref();
  const value = $.NSString.stringWithContentsOfFileEncodingError(
    path,
    $.NSUTF8StringEncoding,
    error
  );
  if (!value) {
    throw new Error(ObjC.unwrap(error[0].localizedDescription));
  }
  return ObjC.unwrap(value);
}

function writeUtf8(path, value) {
  const error = Ref();
  const ok = $(value).writeToFileAtomicallyEncodingError(
    path,
    true,
    $.NSUTF8StringEncoding,
    error
  );
  if (!ok) {
    throw new Error(ObjC.unwrap(error[0].localizedDescription));
  }
}

function run(argv) {
  const action = argv[0];
  const path = argv[1];
  const product = JSON.parse(readUtf8(path));
  const gallery = product.extensionsGallery;

  if (action === 'validate') {
    return 'ok';
  }
  if (action === 'service') {
    return gallery && typeof gallery.serviceUrl === 'string' ? gallery.serviceUrl : '';
  }
  if (action === 'template') {
    return gallery && typeof gallery.extensionUrlTemplate === 'string'
      ? gallery.extensionUrlTemplate
      : '';
  }
  if (action === 'has-template') {
    return gallery && Object.prototype.hasOwnProperty.call(gallery, 'extensionUrlTemplate')
      ? 'true'
      : 'false';
  }
  if (action === 'patch') {
    if (!gallery || typeof gallery !== 'object' || Array.isArray(gallery)) {
      product.extensionsGallery = {};
    }
    product.extensionsGallery.serviceUrl = argv[2];
    delete product.extensionsGallery.extensionUrlTemplate;
    writeUtf8(path, JSON.stringify(product, null, 2) + '\n');
    return 'ok';
  }
  if (action === 'restore') {
    if (!gallery || typeof gallery !== 'object' || Array.isArray(gallery)) {
      product.extensionsGallery = {};
    }
    product.extensionsGallery.serviceUrl = argv[2];
    product.extensionsGallery.extensionUrlTemplate = argv[3];
    writeUtf8(path, JSON.stringify(product, null, 2) + '\n');
    return 'ok';
  }
  throw new Error('unknown JSON action: ' + action);
}
JXA
}

json_validate() {
  local file="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    jxa_json validate "$file" >/dev/null 2>&1
  else
    command -v python3 >/dev/null 2>&1 || {
      echo "[endor-vscode] ERROR: python3 is required to patch product.json on Linux" >&2
      return 1
    }
    python3 - "$file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    json.load(handle)
PY
  fi
}

json_service_url() {
  local file="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    jxa_json service "$file" 2>/dev/null
  else
    python3 - "$file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle).get("extensionsGallery", {}).get("serviceUrl", "")
if isinstance(value, str):
    print(value)
PY
  fi
}

json_has_extension_template() {
  local file="$1" result
  if [[ "$(uname -s)" == "Darwin" ]]; then
    result=$(jxa_json has-template "$file" 2>/dev/null || true)
    [[ "$result" == "true" ]]
  else
    python3 - "$file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    gallery = json.load(handle).get("extensionsGallery", {})
sys.exit(0 if isinstance(gallery, dict) and "extensionUrlTemplate" in gallery else 1)
PY
  fi
}

json_extension_template() {
  local file="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    jxa_json template "$file" 2>/dev/null
  else
    python3 - "$file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle).get("extensionsGallery", {}).get("extensionUrlTemplate", "")
if isinstance(value, str):
    print(value)
PY
  fi
}

json_is_desired() {
  local file="$1" current
  current=$(json_service_url "$file" 2>/dev/null || true)
  [[ "$current" == "$FIREWALL_URL" ]] && ! json_has_extension_template "$file"
}

json_is_managed() {
  local file="$1" current
  current=$(json_service_url "$file" 2>/dev/null || true)
  [[ "$current" == *"/firewall/vscode/_ak/"* ]]
}

json_is_restored() {
  local file="$1" service template
  service=$(json_service_url "$file" 2>/dev/null || true)
  template=$(json_extension_template "$file" 2>/dev/null || true)
  [[ "$service" == "$DEFAULT_SERVICE_URL" \
    && "$template" == "$DEFAULT_EXTENSION_URL_TEMPLATE" ]]
}

write_patched_json() {
  local file="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    jxa_json patch "$file" "$FIREWALL_URL" >/dev/null
  else
    python3 - "$file" "$FIREWALL_URL" <<'PY'
import json
import os
import sys

path, service_url = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    product = json.load(handle)
gallery = product.get("extensionsGallery")
if not isinstance(gallery, dict):
    gallery = {}
    product["extensionsGallery"] = gallery
gallery["serviceUrl"] = service_url
gallery.pop("extensionUrlTemplate", None)
with open(path, "w", encoding="utf-8", newline="\n") as handle:
    json.dump(product, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
  fi
}

write_restored_json() {
  local file="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    jxa_json restore "$file" "$DEFAULT_SERVICE_URL" "$DEFAULT_EXTENSION_URL_TEMPLATE" >/dev/null
  else
    python3 - "$file" "$DEFAULT_SERVICE_URL" "$DEFAULT_EXTENSION_URL_TEMPLATE" <<'PY'
import json
import sys

path, service_url, extension_url_template = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    product = json.load(handle)
gallery = product.get("extensionsGallery")
if not isinstance(gallery, dict):
    gallery = {}
    product["extensionsGallery"] = gallery
gallery["serviceUrl"] = service_url
gallery["extensionUrlTemplate"] = extension_url_template
with open(path, "w", encoding="utf-8", newline="\n") as handle:
    json.dump(product, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
  fi
}

patch_one() {
  local file="$1" tmp

  if ! json_validate "$file"; then
    echo "[endor-vscode] ERROR: refusing to modify invalid JSON: $file" >&2
    return 1
  fi
  if json_is_desired "$file"; then
    echo "[endor-vscode] already configured: $file"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run]   action : PATCH extensionsGallery.serviceUrl and REMOVE extensionUrlTemplate"
    echo "[dry-run]   file   : $file"
    echo "[dry-run]   URL    : $FIREWALL_URL"
    return 0
  fi

  tmp=$(mktemp "${file}.endor.XXXXXX")
  if ! cp -p "$file" "$tmp" \
      || ! write_patched_json "$tmp" \
      || ! json_validate "$tmp" \
      || ! json_is_desired "$tmp"; then
    rm -f "$tmp"
    echo "[endor-vscode] ERROR: failed to produce a valid patched product.json for $file" >&2
    return 1
  fi

  mv -f "$tmp" "$file"
  echo "[endor-vscode] configured: $file"
}

patch_all() {
  local files=() file status=0
  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(list_product_files)

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "[endor-vscode] Microsoft VS Code Stable not found; remediation remains ready for a later install."
    return 0
  fi

  for file in "${files[@]}"; do
    patch_one "$file" || status=1
  done
  return "$status"
}

restore_one() {
  local file="$1" tmp

  if ! json_validate "$file"; then
    echo "[endor-vscode] ERROR: refusing to modify invalid JSON: $file" >&2
    return 1
  fi
  if ! json_is_managed "$file"; then
    echo "[endor-vscode] skip restore (gallery is not Endor-managed): $file"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run]   action : RESTORE default VS Code gallery settings"
    echo "[dry-run]   file   : $file"
    return 0
  fi

  tmp=$(mktemp "${file}.endor-restore.XXXXXX")
  if ! cp -p "$file" "$tmp" \
      || ! write_restored_json "$tmp" \
      || ! json_validate "$tmp" \
      || ! json_is_restored "$tmp"; then
    rm -f "$tmp"
    echo "[endor-vscode] ERROR: failed to restore default gallery settings in $file" >&2
    return 1
  fi

  mv -f "$tmp" "$file"
  echo "[endor-vscode] restored default gallery settings: $file"
}

restore_all() {
  local files=() file status=0
  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(list_product_files)

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "[endor-vscode] Microsoft VS Code Stable not found; nothing to restore."
    return 0
  fi

  for file in "${files[@]}"; do
    restore_one "$file" || status=1
  done
  return "$status"
}

case "$MODE" in
  once) patch_all ;;
  restore) restore_all ;;
esac
ENDOR_VSCODE_WORKER

_vscode_os=$(uname -s)
case "$_vscode_os" in
  Darwin)
    _VSCODE_STATE_DIR="${ENDOR_VSCODE_STATE_DIR:-/Library/Application Support/Endor Labs/vscode-firewall}"
    ;;
  Linux)
    _VSCODE_STATE_DIR="${ENDOR_VSCODE_STATE_DIR:-/var/lib/endor/vscode-firewall}"
    ;;
  *)
    echo "[endor] WARNING: VS Code firewall supports macOS and Linux only in this script." >&2
    _ENDOR_WARNED=1
    unset _vscode_os _VSCODE_WORKER_CONTENT
    return 0 2>/dev/null || true
    ;;
esac
_VSCODE_WORKER_PATH="$_VSCODE_STATE_DIR/worker.sh"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  _vscode_tmp_worker=$(mktemp)
  printf '%s\n' "$_VSCODE_WORKER_CONTENT" > "$_vscode_tmp_worker"
  chmod 700 "$_vscode_tmp_worker"
  ENDOR_VSCODE_STATE_DIR="$_VSCODE_STATE_DIR" \
    "$_vscode_tmp_worker" --once --dry-run || _ENDOR_WARNED=1
  rm -f "$_vscode_tmp_worker"
  echo "[dry-run]   action : INSTALL VS Code update remediation"
else
  if [[ "${EUID:-$(id -u)}" -ne 0 && "${ENDOR_VSCODE_SKIP_WATCHER:-0}" != "1" ]]; then
    echo "[endor] WARNING: VS Code firewall installation must run as root." >&2
    _ENDOR_WARNED=1
  else
    mkdir -p "$_VSCODE_STATE_DIR"
    chmod 700 "$_VSCODE_STATE_DIR"
    _vscode_tmp_worker="$_VSCODE_WORKER_PATH.tmp"
    printf '%s\n' "$_VSCODE_WORKER_CONTENT" > "$_vscode_tmp_worker"
    chmod 700 "$_vscode_tmp_worker"
    mv -f "$_vscode_tmp_worker" "$_VSCODE_WORKER_PATH"

    ENDOR_VSCODE_STATE_DIR="$_VSCODE_STATE_DIR" \
      "$_VSCODE_WORKER_PATH" --once || _ENDOR_WARNED=1

    if [[ "${ENDOR_VSCODE_SKIP_WATCHER:-0}" != "1" ]]; then
      if [[ "$_vscode_os" == "Darwin" ]]; then
        _vscode_plist="/Library/LaunchDaemons/com.endorlabs.vscode-firewall.plist"
        cat > "$_vscode_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.endorlabs.vscode-firewall</string>
  <key>ProgramArguments</key>
  <array>
    <string>$_VSCODE_WORKER_PATH</string>
    <string>--once</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>WatchPaths</key>
  <array>
    <string>/Applications</string>
  </array>
  <key>ThrottleInterval</key>
  <integer>10</integer>
</dict>
</plist>
PLIST
        chown root:wheel "$_vscode_plist"
        chmod 644 "$_vscode_plist"
        /bin/launchctl bootout system/com.endorlabs.vscode-firewall >/dev/null 2>&1 || true
        if ! /bin/launchctl bootstrap system "$_vscode_plist"; then
          echo "[endor] WARNING: could not load VS Code launchd remediation." >&2
          _ENDOR_WARNED=1
        fi
      else
        _vscode_service="/etc/systemd/system/endor-vscode-firewall.service"
        _vscode_path="/etc/systemd/system/endor-vscode-firewall.path"
        cat > "$_vscode_service" <<SERVICE
[Unit]
Description=Reapply Endor VS Code Extension Firewall

[Service]
Type=oneshot
ExecStart=$_VSCODE_WORKER_PATH --once
SERVICE
        cat > "$_vscode_path" <<PATHUNIT
[Unit]
Description=Watch Microsoft VS Code product.json for updates

[Path]
PathChanged=/usr/share/code/resources/app
PathChanged=/usr/lib/code/resources/app
Unit=endor-vscode-firewall.service

[Install]
WantedBy=multi-user.target
PATHUNIT
        chmod 644 "$_vscode_service" "$_vscode_path"
        if command -v systemctl >/dev/null 2>&1; then
          systemctl daemon-reload
          if ! systemctl enable --now endor-vscode-firewall.path; then
            echo "[endor] WARNING: could not enable VS Code systemd remediation." >&2
            _ENDOR_WARNED=1
          fi
        else
          echo "[endor] WARNING: systemd is required for VS Code update remediation on Linux." >&2
          _ENDOR_WARNED=1
        fi
      fi
    fi
  fi
fi

echo "[endor] ✓ VS Code extension firewall done"
unset _vscode_os _VSCODE_STATE_DIR _VSCODE_WORKER_PATH _VSCODE_WORKER_CONTENT
unset _vscode_tmp_worker _vscode_plist _vscode_service _vscode_path
