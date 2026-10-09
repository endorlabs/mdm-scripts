# templates/vscode.sh
# Patches Microsoft VS Code Stable's product.json and installs update remediation.
# On macOS this runs only when the script was generated with ENDOR_VSCODE_MACOS_DAEMON=1. The
# worker then patches a clone of the app, re-signs it with a per-device identity and swaps the
# whole bundle into place, so Gatekeeper keeps accepting it (BUG-1862).

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
    --status) MODE="status" ;;
    --purge) MODE="purge" ;;
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

status_all() {
  local file
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if json_is_desired "$file"; then
      echo "[endor-vscode] configured: $file"
    else
      echo "[endor-vscode] not configured: $file"
    fi
  done < <(list_product_files)
}

# ── macOS: patch a clone, sign it with this Mac's identity, swap the whole app ──
#
# Microsoft's signature seals product.json, so an in-place edit makes Gatekeeper call a
# freshly updated VS Code "damaged". Instead the worker:
#   1. classifies the app in /Applications (read-only);
#   2. APFS-clones it into root-only staging and classifies the clone, which is authoritative
#      (users can write to the live bundle, but not to the clone);
#   3. patches product.json, signs only the outer bundle (no --deep) with a self-signed
#      identity kept in the System keychain, and verifies the result;
#   4. renames the live app aside and the signed clone into place. App Management blocks
#      writes inside a launched Microsoft app, but not renaming the whole bundle.
# The designated requirement accepts Microsoft's certificate or this Mac's, so ShipIt (VS Code's
# updater) keeps accepting Microsoft releases and the staged updates this worker pre-signs.
#
# States (classify_bundle):
#   A   Microsoft-signed, seal intact                       patch, sign, swap; keep the original
#   B   signed by this Mac and current                      nothing
#   C   signed by this Mac, but out of date                 patch if needed, re-sign, swap
#   D   Microsoft-signed, only Endor's product.json edit    patch, sign, swap (legacy installs)
#   D2  signed by this Mac, product.json changed since      patch, re-sign, swap
#   E   anything else                                       refuse and leave the app alone

PRODUCT_REL="Contents/Resources/app/product.json"
# Part of the fingerprint: bump it when a release changes what a current bundle looks like.
WORKER_VERSION=2
UPSTREAM_ANCHOR_DEFAULT='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = UBF8T346G9'
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PRISTINE_NAME="VSCode.bundle-pristine"
LIVE_CLASS=""
CERT_SHA1=""
RUN_TMP=""

ts() { /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'; }
redact() { /usr/bin/sed -E 's#/_ak/[^/[:space:]"]+#/_ak/<redacted>#g'; }
log() { printf '%s [endor-vscode] %s\n' "$(ts)" "$*" | redact; }
warn() { printf '%s [endor-vscode] WARNING: %s\n' "$(ts)" "$*" | redact >&2; }
dry() { printf '[dry-run]   %s\n' "$*" | redact; }

# note_once <message>: log only when the message differs from the last one noted, so a
# persistent state (VS Code missing, an update waiting) is not repeated every minute.
note_once() {
  local f="$STATE_DIR/last-note"
  if [[ -f "$f" && "$(cat "$f" 2>/dev/null)" == "$*" ]]; then
    return 0
  fi
  log "$*"
  [[ "$DRY_RUN" == "1" ]] || printf '%s\n' "$*" > "$f" 2>/dev/null || true
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

info_value() { /usr/bin/plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null; }
plist_raw() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

valid_version() { [[ "$1" =~ ^[0-9][0-9A-Za-z.+-]*$ ]]; }

# version_gt <a> <b>: true when the dotted numeric version a is newer than b.
version_gt() {
  local a="$1" b="$2" x y
  while [[ -n "$a" || -n "$b" ]]; do
    x=${a%%.*}
    y=${b%%.*}
    if [[ "$a" == *.* ]]; then a=${a#*.}; else a=""; fi
    if [[ "$b" == *.* ]]; then b=${b#*.}; else b=""; fi
    x=${x:-0}
    y=${y:-0}
    is_uint "$x" && is_uint "$y" || return 1
    (( 10#$x > 10#$y )) && return 0
    (( 10#$x < 10#$y )) && return 1
  done
  return 1
}

discard() {
  [[ -n "$1" && "$1" != "/" ]] && /bin/rm -rf "$1"
  return 0
}

# in_dir <dir> <command...>: run a command from inside dir after checking that its physical
# path is dir itself. Used in users' ShipIt caches, so swapping a path component for a
# symlink can't redirect root's renames.
in_dir() {
  local dir="$1"
  shift
  ( cd "$dir" 2>/dev/null && [[ "$(pwd -P)" == "$dir" ]] && "$@" )
}

# move_into_place <src> <dest>: rename, but never into an existing directory.
move_into_place() {
  [[ ! -e "$2" && ! -L "$2" ]] && /bin/mv "$1" "$2"
}

prepare_dir() {
  /bin/mkdir -p "$STATE_DIR/$1" && /bin/chmod 700 "$STATE_DIR/$1"
}

fresh_stage() {
  discard "$STATE_DIR/stage"
  prepare_dir stage
}

# Physical path of the configured app. The app itself may not be a symlink.
resolve_app() {
  local parent
  parent=$(cd "$(dirname "$APP_PATH")" 2>/dev/null && pwd -P) || return 1
  APP="$parent/$(basename "$APP_PATH")"
}

app_present() { [[ -e "$APP" || -L "$APP" ]]; }

# proc_under <prefix>: a process whose executable path (argv[0]) starts with prefix is running.
proc_under() {
  /bin/ps -axo comm= 2>/dev/null \
    | P="$1" /usr/bin/awk 'index($0, ENVIRON["P"]) == 1 { found = 1 } END { exit !found }'
}
app_running() { proc_under "$APP/Contents/MacOS/"; }
# ShipIt waits while VS Code runs and installs once it quits; only the install is busy time.
shipit_installing() {
  proc_under "$APP/Contents/Frameworks/Squirrel.framework/Resources/ShipIt" && ! app_running
}

# bundle_complete <app>: the files the worker relies on exist and none of the path components
# it writes through is a symlink.
bundle_complete() {
  local app="$1" exe p
  for p in "$app" "$app/Contents" "$app/Contents/Resources" "$app/Contents/Resources/app"; do
    [[ -d "$p" && ! -L "$p" ]] || return 1
  done
  [[ -f "$app/Contents/Info.plist" && ! -L "$app/Contents/Info.plist" ]] || return 1
  exe=$(info_value "$app" CFBundleExecutable) || return 1
  [[ -n "$exe" && "$exe" != */* ]] || return 1
  [[ -f "$app/Contents/MacOS/$exe" && ! -L "$app/Contents/MacOS/$exe" ]] || return 1
  [[ -f "$app/$PRODUCT_REL" && ! -L "$app/$PRODUCT_REL" ]] || return 1
  [[ -f "$app/Contents/_CodeSignature/CodeResources" ]]
}

# bundle_stat <app>: cheap, stat-only identity of the files that change when the bundle does.
# Times are to the nanosecond: a same-size edit within the second of our own write would
# otherwise look unchanged.
bundle_stat() {
  local app="$1" exe f out=""
  exe=$(info_value "$app" CFBundleExecutable)
  for f in "$app" "$app/Contents" "$app/Contents/Info.plist" "$app/Contents/MacOS/${exe:-?}" \
      "$app/Contents/_CodeSignature/CodeResources" "$app/$PRODUCT_REL"; do
    out="$out$(/usr/bin/stat -f '%d:%i:%Fm:%Fc:%z' "$f" 2>/dev/null || echo -),"
  done
  printf '%s\n' "$out"
}

# bundle_fingerprint <app>: bundle_stat plus everything that decides what a current bundle
# looks like. Equal to last-good means nothing to do.
bundle_fingerprint() {
  printf '%s|%s|%s|%s\n' "$(bundle_stat "$1")" "$URL_HASH" "$CERT_SHA1" "$WORKER_VERSION"
}

# wait_for_quiescence: wait until ShipIt is not installing and the bundle's files stop changing.
# A bundle that is stable but incomplete is then classified, and refused.
wait_for_quiescence() {
  local deadline=$((SECONDS + SETTLE_TIMEOUT)) prev="" cur
  while :; do
    if ! shipit_installing; then
      app_present || return 0
      cur=$(bundle_stat "$APP")
      [[ "$cur" == "$prev" ]] && return 0
      # A first sample always gets a second look, whatever the timeout.
      if [[ -z "$prev" ]]; then
        prev=$cur
        /bin/sleep "$SETTLE_SECONDS"
        continue
      fi
      prev=$cur
    fi
    (( SECONDS >= deadline )) && return 1
    /bin/sleep "$SETTLE_SECONDS"
  done
}

jxa_plist() {
  /usr/bin/osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('Foundation');

function run(argv) {
  const dict = $.NSDictionary.dictionaryWithContentsOfFile(argv[1]);
  if (dict.isNil()) {
    throw new Error('cannot read plist: ' + argv[1]);
  }
  const plist = ObjC.deepUnwrap(dict);
  if (argv[0] === 'keys') {
    return Object.keys(plist).sort().join('\n');
  }
  if (argv[0] === 'nested') {
    // Nested code in a seal is a files2 entry that records a cdhash.
    const files = plist.files2 || {};
    return Object.keys(files).filter(function (key) {
      const value = files[key];
      return value !== null && typeof value === 'object'
        && Object.prototype.hasOwnProperty.call(value, 'cdhash');
    }).sort().join('\n');
  }
  throw new Error('unknown plist action: ' + argv[0]);
}
JXA
}

req_upstream() { printf 'identifier "%s" and (%s)' "$BUNDLE_ID" "$UPSTREAM_ANCHOR"; }
req_ours() { printf 'identifier "%s" and certificate leaf = H"%s"' "$BUNDLE_ID" "$1"; }
designated_requirement() {
  printf 'designated => identifier "%s" and ((%s) or certificate leaf = H"%s")' \
    "$BUNDLE_ID" "$UPSTREAM_ANCHOR" "$1"
}
designated_of() { /usr/bin/codesign -d -r- "$1" 2>&1 | /usr/bin/sed -n 's/^designated => //p'; }

# cs_verify <path> <requirement> [codesign flags...]: 0 ok, 1 invalid, 3 requirement not met.
cs_verify() {
  local path="$1" req="$2"
  shift 2
  /usr/bin/codesign --verify --strict "$@" -R "=$req" "$path" >/dev/null 2>&1
}

# dr_current <app>: the app's designated requirement is exactly the one this worker would embed.
dr_current() {
  local want
  want=$(/usr/bin/csreq -r "=$(designated_requirement "$CERT_SHA1")" -t 2>/dev/null \
    | /usr/bin/sed -n 's/^designated => //p')
  [[ -n "$want" && "$want" == "$(designated_of "$1")" ]]
}

# signer_class <app>: upstream, ours, previous or other. Resources are ignored here; the
# seal is checked separately so a modified product.json still identifies its signer.
signer_class() {
  local app="$1" sha1
  if cs_verify "$app" "$(req_upstream)" --ignore-resources; then
    echo upstream
    return 0
  fi
  if [[ -n "$CERT_SHA1" ]] && cs_verify "$app" "$(req_ours "$CERT_SHA1")" --ignore-resources; then
    echo ours
    return 0
  fi
  if [[ -f "$SIGNING_DIR/previous-certs" ]]; then
    while IFS= read -r sha1; do
      [[ "$sha1" =~ ^[0-9a-f]{40}$ ]] || continue
      if cs_verify "$app" "$(req_ours "$sha1")" --ignore-resources; then
        echo previous
        return 0
      fi
    done < "$SIGNING_DIR/previous-certs"
  fi
  echo other
}

# seal_status <app>: intact, product-only (product.json modified, plus at most stray temp files
# from the old in-place patcher) or broken. Any codesign output it does not recognise is broken.
seal_status() {
  local app="$1" out rc line product=0 extra=0 stray
  out=$(/usr/bin/codesign --verify --deep --strict -vvvv "$app" 2>&1)
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo intact
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      ""|--*) ;;
      "$app: a sealed resource is missing or invalid") ;;
      "file modified: $app/$PRODUCT_REL") product=1 ;;
      "file added: $app/$PRODUCT_REL.endor."*|"file added: $app/$PRODUCT_REL.endor-restore."*)
        stray=${line#file added: }
        [[ -f "$stray" && ! -L "$stray" ]] || extra=1
        ;;
      *) extra=1 ;;
    esac
  done <<EOF
$out
EOF
  if [[ "$rc" -eq 1 && "$product" -eq 1 && "$extra" -eq 0 ]]; then
    echo product-only
  else
    echo broken
  fi
}

strip_stray_temps() {
  local f
  for f in "$1/$PRODUCT_REL".endor.* "$1/$PRODUCT_REL".endor-restore.*; do
    if [[ -f "$f" && ! -L "$f" ]]; then
      /bin/rm -f "$f"
    fi
  done
}

# nested_all_upstream <app>: every nested code item the seal records is signed by Microsoft.
nested_all_upstream() {
  local app="$1" list rel
  list=$(jxa_plist nested "$app/Contents/_CodeSignature/CodeResources" 2>/dev/null) || return 1
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    case "$rel" in
      /*|..|../*|*/../*|*/..) return 1 ;;
    esac
    cs_verify "$app/Contents/$rel" "$UPSTREAM_ANCHOR" --deep || return 1
  done <<EOF
$list
EOF
}

entitlements_extract() {
  /usr/bin/codesign -d --entitlements - --xml "$1" > "$2" 2>/dev/null
  if [[ ! -s "$2" ]]; then
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0"><dict/></plist>' > "$2"
  fi
}

# entitlements_allowed <app>: the main executable's entitlements are all ones a self-signed app
# may carry. Restricted entitlements need a provisioning profile, and a re-signed app with
# them would not launch. Leaves the entitlements in $RUN_TMP/entitlements.plist.
entitlements_allowed() {
  local keys key
  ENT_BAD=""
  entitlements_extract "$1" "$RUN_TMP/entitlements.plist"
  keys=$(jxa_plist keys "$RUN_TMP/entitlements.plist" 2>/dev/null) || {
    ENT_BAD="unreadable"
    return 1
  }
  while IFS= read -r key; do
    case "$key" in
      ""|com.apple.security.cs.*|com.apple.security.device.*) ;;
      com.apple.security.personal-information.*|com.apple.security.automation.apple-events) ;;
      *) ENT_BAD="$ENT_BAD $key" ;;
    esac
  done <<EOF
$keys
EOF
  [[ -z "$ENT_BAD" ]]
}

has_quarantine() {
  [[ -n "$(/usr/bin/find "$1" -xattrname com.apple.quarantine -print -quit 2>/dev/null)" ]]
}

strip_xattr() {
  /usr/bin/find "$1" -xattrname "$2" -exec /usr/bin/xattr -d -s "$2" {} + 2>/dev/null
  [[ -z "$(/usr/bin/find "$1" -xattrname "$2" -print -quit 2>/dev/null)" ]]
}

# signature_options_current <app>: hardened runtime plus the library-validation exception.
# Our main executable must load Microsoft-signed frameworks, which library validation forbids.
# (Output is captured before matching: grep -q in a pipeline fails it under pipefail.)
signature_options_current() {
  local info
  info=$(/usr/bin/codesign -dv "$1" 2>&1)
  /usr/bin/grep -q '^CodeDirectory .*flags=0x[0-9a-f]*([^)]*runtime' <<< "$info" || return 1
  entitlements_extract "$1" "$RUN_TMP/current-entitlements.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' \
    "$RUN_TMP/current-entitlements.plist" 2>/dev/null)" == "true" ]]
}

# ── Signing identity ──────────────────────────────────────────────────────────
# A self-signed code-signing certificate, unique to this Mac, with a non-exportable key in the
# System keychain: the only keychain codesign finds from a LaunchDaemon without touching
# keychain search lists. Nothing trusts it; Gatekeeper doesn't assess non-quarantined apps
# that are validly signed but not notarized.

identity_load() {
  CERT_SHA1=""
  if [[ -s "$SIGNING_DIR/cert.sha1" ]]; then
    CERT_SHA1=$(/usr/bin/tr -d '[:space:]' < "$SIGNING_DIR/cert.sha1")
  fi
  [[ "$CERT_SHA1" =~ ^[0-9a-f]{40}$ ]] || CERT_SHA1=""
}

cert_fresh() {
  /usr/bin/openssl x509 -checkend $((RENEW_DAYS * 86400)) -noout \
    -in "$SIGNING_DIR/cert.pem" >/dev/null 2>&1
}

identity_in_keychain() {
  local ids
  ids=$(/usr/bin/security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null)
  /usr/bin/grep -qi -- "$1" <<< "$ids"
}

identity_usable() {
  [[ -n "$CERT_SHA1" ]] && cert_fresh && identity_in_keychain "$CERT_SHA1"
}

ensure_signing_identity() {
  identity_load
  identity_usable && return 0
  identity_create
}

identity_create() {
  local work cn p12pass sha1 old="$CERT_SHA1"
  prepare_dir signing || return 1
  work=$(/usr/bin/mktemp -d "$SIGNING_DIR/new.XXXXXX") || return 1
  cn="Endor Labs VS Code Firewall ($(/usr/bin/openssl rand -hex 4))"
  if ! (
    umask 077
    printf '%s\n' '[req]' 'distinguished_name=dn' 'x509_extensions=v3' 'prompt=no' \
      'string_mask=utf8only' '[dn]' "CN=$cn" 'O=Endor Labs' '[v3]' \
      'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
      'extendedKeyUsage=critical,codeSigning' 'subjectKeyIdentifier=hash' > "$work/req.cnf"
    /usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days "$CERT_DAYS" \
      -config "$work/req.cnf" -keyout "$work/key.pem" -out "$work/cert.pem"
  ) > "$work/openssl.log" 2>&1; then
    warn "could not create a signing certificate: $(/usr/bin/tr '\n' ' ' < "$work/openssl.log")"
    discard "$work"
    return 1
  fi
  p12pass=$(/usr/bin/openssl rand -hex 24)
  # LibreSSL's default PKCS#12 encryption is not accepted by security(1); use the legacy PBE.
  if ! P12PASS="$p12pass" /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" \
      -in "$work/cert.pem" -name "$cn" -passout env:P12PASS \
      -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -out "$work/id.p12" > "$work/openssl.log" 2>&1; then
    warn "could not package the signing identity: $(/usr/bin/tr '\n' ' ' < "$work/openssl.log")"
    discard "$work"
    return 1
  fi
  /bin/rm -f "$work/key.pem"
  if ! /usr/bin/security import "$work/id.p12" -k "$KEYCHAIN" -f pkcs12 -P "$p12pass" -x \
      -T /usr/bin/codesign > "$work/import.log" 2>&1; then
    warn "could not import the signing identity into $KEYCHAIN: $(/usr/bin/tr '\n' ' ' < "$work/import.log")"
    discard "$work"
    return 1
  fi
  /bin/rm -f "$work/id.p12"
  # Tests sign from a throwaway user keychain, where codesign needs a key partition list.
  if [[ -n "${ENDOR_VSCODE_KEYCHAIN_PASSWORD:-}" ]]; then
    /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s \
      -k "$ENDOR_VSCODE_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1
  fi
  sha1=$(/usr/bin/openssl x509 -in "$work/cert.pem" -noout -fingerprint -sha1 \
    | /usr/bin/sed 's/^.*=//; s/://g' | /usr/bin/tr 'A-F' 'a-f')
  if [[ ! "$sha1" =~ ^[0-9a-f]{40}$ ]] || ! identity_in_keychain "$sha1"; then
    warn "the imported signing identity is not usable from $KEYCHAIN"
    discard "$work"
    return 1
  fi

  /bin/mv -f "$work/cert.pem" "$SIGNING_DIR/cert.pem"
  printf '%s\n' "$cn" > "$SIGNING_DIR/cn"
  printf '%s\n' "$sha1" > "$SIGNING_DIR/cert.sha1.tmp" && /bin/mv -f "$SIGNING_DIR/cert.sha1.tmp" "$SIGNING_DIR/cert.sha1"
  discard "$work"
  if [[ -n "$old" && "$old" != "$sha1" ]]; then
    printf '%s\n' "$old" >> "$SIGNING_DIR/previous-certs"
    /usr/bin/security delete-certificate -Z "$old" -t "$KEYCHAIN" >/dev/null 2>&1 || true
    log "renewed the signing identity (previous certificate $old)"
  fi
  CERT_SHA1=$sha1
  log "created signing identity \"$cn\" ($sha1) in $KEYCHAIN"
}

# ── Classification ────────────────────────────────────────────────────────────

# classify_bundle <app>: sets CLASS (A B C D D2 E), CLASS_WHY, CLASS_SIGNER and CLASS_VERSION.
classify_bundle() {
  local app="$1" id seal
  CLASS=E
  CLASS_WHY=""
  CLASS_SIGNER=other
  CLASS_VERSION=""
  if ! bundle_complete "$app"; then
    CLASS_WHY="the bundle is incomplete or contains an unexpected symlink"
    return 0
  fi
  CLASS_VERSION=$(info_value "$app" CFBundleVersion)
  id=$(info_value "$app" CFBundleIdentifier)
  if [[ "$id" != "$BUNDLE_ID" ]]; then
    CLASS_WHY="bundle identifier is \"$id\""
    return 0
  fi
  if [[ -e "$app/Contents/embedded.provisionprofile" ]]; then
    CLASS_WHY="the bundle has a provisioning profile"
    return 0
  fi
  if ! json_validate "$app/$PRODUCT_REL"; then
    CLASS_WHY="product.json is not valid JSON"
    return 0
  fi
  CLASS_SIGNER=$(signer_class "$app")
  seal=$(seal_status "$app")
  case "$CLASS_SIGNER:$seal" in
    upstream:intact) CLASS=A ;;
    upstream:product-only)
      if json_is_managed "$app/$PRODUCT_REL"; then
        CLASS=D
      else
        CLASS_WHY="product.json was changed by something other than Endor"
        return 0
      fi
      ;;
    ours:intact|previous:intact) CLASS=C ;;
    ours:product-only|previous:product-only) CLASS=D2 ;;
    other:*)
      CLASS_WHY="the app is not signed by Microsoft or by this Mac"
      return 0
      ;;
    *)
      CLASS_WHY="the signature seal is broken by more than product.json"
      return 0
      ;;
  esac
  if ! nested_all_upstream "$app"; then
    CLASS=E
    CLASS_WHY="nested code is not signed by Microsoft"
    return 0
  fi
  if ! entitlements_allowed "$app"; then
    CLASS=E
    CLASS_WHY="unexpected entitlements:$ENT_BAD"
    return 0
  fi
  if [[ "$CLASS" == C ]] && bundle_current "$app"; then
    CLASS=B
  fi
}

# bundle_current <app>: a C bundle needs nothing. Otherwise CLASS_WHY says what is stale.
bundle_current() {
  local app="$1"
  if [[ "$CLASS_SIGNER" != ours ]] || ! identity_usable; then
    CLASS_WHY="the signing certificate is being replaced"
  elif ! json_is_desired "$app/$PRODUCT_REL"; then
    CLASS_WHY="product.json does not have the current firewall URL"
  elif ! dr_current "$app"; then
    CLASS_WHY="the designated requirement is out of date"
  elif ! signature_options_current "$app"; then
    CLASS_WHY="the runtime flag or entitlements are out of date"
  elif has_quarantine "$app"; then
    CLASS_WHY="the app is quarantined"
  else
    CLASS_WHY=""
    return 0
  fi
  return 1
}

describe_class() {
  case "$1" in
    A) echo "signed by Microsoft and unmodified" ;;
    B) echo "firewalled and signed by this Mac" ;;
    C) echo "signed by this Mac, needs updating: $CLASS_WHY" ;;
    D) echo "signed by Microsoft with product.json patched in place (legacy)" ;;
    D2) echo "signed by this Mac, but product.json changed since" ;;
    E) echo "refused: $CLASS_WHY" ;;
    *) echo "$1" ;;
  esac
}

# ── Stage, sign, swap ─────────────────────────────────────────────────────────

stage_clone() {
  /bin/cp -Rpc "$1" "$2" 2>/dev/null && return 0
  discard "$2"
  /usr/bin/ditto "$1" "$2"
}

# patch_product_json_in <app> <patch|restore>: rewrite product.json in place. The edit goes
# through a temp file outside the bundle and keeps the inode, so the bundle gains no files.
patch_product_json_in() {
  local pj="$1/$PRODUCT_REL" tmp="$RUN_TMP/product.json"
  [[ -f "$pj" && ! -L "$pj" ]] || return 1
  /bin/rm -f "$tmp"
  /bin/cp "$pj" "$tmp" || return 1
  if [[ "$2" == patch ]]; then
    write_patched_json "$tmp" && json_validate "$tmp" && json_is_desired "$tmp" || return 1
  else
    write_restored_json "$tmp" && json_validate "$tmp" && json_is_restored "$tmp" || return 1
  fi
  /bin/cat "$tmp" > "$pj"
}

# sign_bundle <app>: sign only the outer bundle; nested code keeps Microsoft's signatures.
sign_bundle() {
  local app="$1" owner
  owner=$(/usr/bin/stat -f '%u:%g' "$app") || return 1
  entitlements_allowed "$app" || { warn "unexpected entitlements:$ENT_BAD"; return 1; }
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.cs.disable-library-validation' \
    "$RUN_TMP/entitlements.plist" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' \
    "$RUN_TMP/entitlements.plist" >/dev/null || return 1
  # Microsoft's stapled notarization ticket names Microsoft's cdhash; it no longer applies.
  /bin/rm -f "$app/Contents/CodeResources"
  # codesign --strict refuses Finder metadata on signed files.
  strip_xattr "$app" com.apple.FinderInfo
  strip_xattr "$app" com.apple.ResourceFork
  if ! /usr/bin/codesign --sign "$CERT_SHA1" --keychain "$KEYCHAIN" --force \
      --identifier "$BUNDLE_ID" --options runtime --entitlements "$RUN_TMP/entitlements.plist" \
      --requirements "=$(designated_requirement "$CERT_SHA1")" --timestamp=none "$app" \
      > "$RUN_TMP/codesign.log" 2>&1; then
    warn "codesign failed: $(/usr/bin/tr '\n' ' ' < "$RUN_TMP/codesign.log")"
    return 1
  fi
  # codesign writes new files as root; give the bundle back to its owner.
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    /usr/sbin/chown -R "$owner" "$app"
  fi
  # A validly signed app that is not notarized is only assessed by Gatekeeper when quarantined.
  strip_xattr "$app" com.apple.quarantine
}

# verify_signed <app> <json predicate>: the signed copy is exactly what the worker intended.
verify_signed() {
  local app="$1" json_check="$2"
  if ! cs_verify "$app" "$(req_ours "$CERT_SHA1")" --deep; then
    warn "the signed copy does not verify"
  elif ! dr_current "$app"; then
    warn "the signed copy has an unexpected designated requirement"
  elif ! nested_all_upstream "$app"; then
    warn "the signed copy has nested code not signed by Microsoft"
  elif ! "$json_check" "$app/$PRODUCT_REL"; then
    warn "the signed copy has an unexpected product.json"
  elif ! signature_options_current "$app"; then
    warn "the signed copy lacks the runtime flag or the library-validation exception"
  elif has_quarantine "$app"; then
    warn "the signed copy is still quarantined"
  else
    return 0
  fi
  return 1
}

# swap_in <new.app> <outgoing>: rename the live app aside and the new bundle into its place.
swap_in() {
  local new="$1" out="$2"
  if [[ "$(/usr/bin/stat -f %d "$new")" != "$(/usr/bin/stat -f %d "$(dirname "$APP")")" ]]; then
    warn "the staging directory is not on the same volume as $APP"
    return 1
  fi
  [[ ! -e "$out" && ! -L "$out" ]] || return 1
  if ! /bin/mv "$APP" "$out"; then
    warn "could not move $APP aside"
    return 1
  fi
  if ! move_into_place "$new" "$APP"; then
    warn "could not move the new bundle into place; rolling back"
    move_into_place "$out" "$APP" || warn "rollback failed; the previous app is at $out"
    return 1
  fi
  # Tell LaunchServices about the new bundle now. A test app (ENDOR_VSCODE_APP) is not
  # registered, so it can't become the app that opens for this bundle identifier.
  if [[ -x "$LSREGISTER" && -z "${ENDOR_VSCODE_APP:-}" ]]; then
    "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
  fi
  return 0
}

# recover_outgoing: a run that died between its two renames left the app in outgoing/.
recover_outgoing() {
  local b
  for b in "$STATE_DIR/outgoing"/*.bundle-outgoing.*; do
    [[ -d "$b" && ! -L "$b" ]] || continue
    if ! app_present && move_into_place "$b" "$APP"; then
      log "moved back the app an interrupted run had moved aside: $APP"
    else
      discard "$b"
    fi
  done
}

outgoing_path() {
  prepare_dir outgoing || return 1
  printf '%s/outgoing/%s.bundle-outgoing.%s\n' "$STATE_DIR" "$(basename "$APP" .app)" "$$"
}

# retain_pristine <bundle> <version>: keep Microsoft's original bytes for removal, under a
# non-.app name so LaunchServices doesn't register it.
retain_pristine() {
  local src="$1" v="$2" dest
  if ! valid_version "$v"; then
    discard "$src"
    return 0
  fi
  dest="$STATE_DIR/pristine/$v"
  prepare_dir pristine || return 1
  discard "$dest.new"
  /bin/mkdir -m 700 "$dest.new" || return 1
  if ! /bin/mv "$src" "$dest.new/$PRISTINE_NAME"; then
    discard "$dest.new"
    return 1
  fi
  discard "$dest"
  /bin/mv "$dest.new" "$dest"
}

pristine_ok() {
  [[ -d "$1" && ! -L "$1" ]] \
    && [[ "$(info_value "$1" CFBundleVersion)" == "$2" ]] \
    && [[ "$(info_value "$1" CFBundleIdentifier)" == "$BUNDLE_ID" ]] \
    && cs_verify "$1" "$(req_upstream)" --deep
}

# prune_pristine: keep originals only for the installed version and pending updates.
prune_pristine() {
  local keep d v list owner upd
  [[ "$DRY_RUN" != "1" && -d "$STATE_DIR/pristine" ]] || return 0
  keep=" $(info_value "$APP" CFBundleVersion) "
  list=$(list_staged_updates)
  while IFS=$'\t' read -r owner upd <&3; do
    [[ -n "$upd" ]] && keep="$keep$(info_value "$upd" CFBundleVersion) "
  done 3<<EOF
$list
EOF
  for d in "$STATE_DIR/pristine"/*; do
    [[ -d "$d" ]] || continue
    v=$(basename "$d")
    case "$keep" in
      *" $v "*) ;;
      *) discard "$d" ;;
    esac
  done
}

record_good() { [[ "$DRY_RUN" == "1" ]] || printf '%s\n' "$1" > "$STATE_DIR/last-good"; }
record_refused() { [[ "$DRY_RUN" == "1" ]] || printf '%s %s\n' "$(/bin/date +%s)" "$1" > "$STATE_DIR/last-refused"; }

fast_path_ok() {
  [[ -f "$STATE_DIR/last-good" && "$(cat "$STATE_DIR/last-good" 2>/dev/null)" == "$1" ]] && cert_fresh
}

# refused_recently <fingerprint>: the same bundle was refused or failed within the last hour.
refused_recently() {
  local f="$STATE_DIR/last-refused" t fp
  [[ -f "$f" ]] || return 1
  read -r t fp < "$f" || return 1
  is_uint "$t" && [[ "$fp" == "$1" ]] && (( $(/bin/date +%s) - t < 3600 ))
}

# ── Live app ──────────────────────────────────────────────────────────────────

process_live() {
  local fp
  LIVE_CLASS=""
  if ! app_present; then
    note_once "Microsoft VS Code Stable not found at $APP; remediation remains ready for a later install."
    return 0
  fi
  fp=$(bundle_fingerprint "$APP")
  if fast_path_ok "$fp"; then
    LIVE_CLASS=B
    [[ "$DRY_RUN" == "1" ]] && log "already configured: $APP"
    return 0
  fi
  refused_recently "$fp" && return 1
  if ! wait_for_quiescence; then
    note_once "deferred: VS Code is being updated or its files are still changing"
    return 0
  fi
  app_present || return 0
  fp=$(bundle_fingerprint "$APP")
  classify_bundle "$APP"
  LIVE_CLASS=$CLASS
  case "$CLASS" in
    B)
      record_good "$fp"
      note_once "VS Code $CLASS_VERSION is firewalled and signed by this Mac"
      return 0
      ;;
    E)
      warn "refusing to modify $APP: $CLASS_WHY"
      record_refused "$fp"
      return 1
      ;;
  esac
  if migrate_live "$fp"; then
    return 0
  fi
  record_refused "$fp"
  return 1
}

# migrate_live <fingerprint>: bring an A, C, D or D2 app to B.
migrate_live() {
  local fp="$1" from="$CLASS" why="$CLASS_WHY" version="$CLASS_VERSION" clone out desc
  desc=$(describe_class "$from")
  if [[ "$DRY_RUN" == "1" ]]; then
    dry "action : CLONE, PATCH product.json, SIGN with this Mac's identity, SWAP the app"
    dry "app    : $APP (VS Code $version, $desc)"
    [[ -n "$CERT_SHA1" ]] || dry "action : CREATE a code-signing identity in $KEYCHAIN"
    dry "URL    : $FIREWALL_URL"
    return 0
  fi
  ensure_signing_identity || return 1
  fresh_stage || return 1
  clone="$STATE_DIR/stage/$(basename "$APP")"
  if ! stage_clone "$APP" "$clone"; then
    warn "could not copy $APP into $STATE_DIR/stage"
    discard "$clone"
    return 1
  fi
  if [[ "$(bundle_stat "$APP")" != "${fp%%|*}" ]]; then
    discard "$clone"
    log "deferred: VS Code changed while it was being copied"
    LIVE_CLASS=""
    return 0
  fi
  strip_stray_temps "$clone"
  classify_bundle "$clone"
  if [[ "$CLASS" != "$from" ]]; then
    discard "$clone"
    log "deferred: the copy classified as $CLASS ($CLASS_WHY), the app as $from"
    LIVE_CLASS=""
    return 0
  fi
  if ! json_is_desired "$clone/$PRODUCT_REL" && ! patch_product_json_in "$clone" patch; then
    warn "could not patch product.json in the copy of $APP"
    discard "$clone"
    return 1
  fi
  if ! sign_bundle "$clone" || ! verify_signed "$clone" json_is_desired; then
    discard "$clone"
    return 1
  fi
  if [[ "$(bundle_stat "$APP")" != "${fp%%|*}" ]] || shipit_installing; then
    discard "$clone"
    log "deferred: VS Code changed while the copy was being signed"
    LIVE_CLASS=""
    return 0
  fi
  out=$(outgoing_path) || return 1
  if ! swap_in "$clone" "$out"; then
    discard "$clone"
    return 1
  fi
  if [[ "$from" == A ]]; then
    retain_pristine "$out" "$version" || warn "could not keep Microsoft's original VS Code $version"
  else
    discard "$out"
  fi
  LIVE_CLASS=B
  record_good "$(bundle_fingerprint "$APP")"
  case "$from" in
    A) log "VS Code $version: patched, signed by this Mac and swapped in; Microsoft's original is kept for removal" ;;
    D) log "VS Code $version: repaired a product.json patched in place; signed by this Mac and swapped in" ;;
    *) log "VS Code $version: re-signed and swapped in ($why)" ;;
  esac
  if app_running; then
    log "VS Code is running; it uses the firewall from its next start"
  fi
  return 0
}

# ── Staged updates ────────────────────────────────────────────────────────────
# Squirrel unpacks each update into ~/Library/Caches/<bundle id>.ShipIt/update.XXXX/, records it
# in ShipItState.plist and installs it once VS Code quits, relaunching about 1.7 s later: too
# soon to patch afterwards. Once the live app is ours, ShipIt checks updates against our
# designated requirement, so a copy patched and signed by this Mac installs already firewalled.

# file_url_path <file:///...>: percent-decoded path without a trailing slash.
file_url_path() {
  local url="$1"
  case "$url" in
    file:///*) ;;
    *) return 1 ;;
  esac
  url=${url#file://}
  case "$url" in
    *%*) url=$(printf '%b' "${url//%/\\x}") ;;
  esac
  printf '%s\n' "${url%/}"
}

# list_staged_updates: "<owner uid>\t<update app>" for each user's pending update of this app.
list_staged_updates() {
  local dir state owner target upd base
  for dir in "$USERS_DIR"/*/Library/Caches/"$BUNDLE_ID".ShipIt; do
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    dir=$(cd "$dir" 2>/dev/null && pwd -P) || continue
    state="$dir/ShipItState.plist"
    [[ -f "$state" && ! -L "$state" ]] || continue
    owner=$(/usr/bin/stat -f %u "$dir")
    [[ "$(/usr/bin/stat -f %u "$state")" == "$owner" ]] || continue
    [[ "$(plist_raw "$state" bundleIdentifier)" == "$BUNDLE_ID" ]] || continue
    target=$(file_url_path "$(plist_raw "$state" targetBundleURL)") || continue
    [[ "$target" == "$APP" ]] || continue
    upd=$(file_url_path "$(plist_raw "$state" updateBundleURL)") || continue
    case "$upd" in
      */../*|*/./*|*/..|*/.) continue ;;
      *.app) ;;
      *) continue ;;
    esac
    base=$(dirname "$upd")
    [[ "$(dirname "$base")" == "$dir" ]] || continue
    case "$(basename "$base")" in
      update.*) ;;
      *) continue ;;
    esac
    [[ -d "$base" && ! -L "$base" ]] || continue
    [[ "$(/usr/bin/stat -f %u "$base")" == "$owner" ]] || continue
    printf '%s\t%s\n' "$owner" "$upd"
  done
}

staged_seen() {
  [[ -f "$STATE_DIR/staged-seen" ]] && /usr/bin/grep -qxF -- "$1" "$STATE_DIR/staged-seen"
}

staged_mark() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  {
    /usr/bin/tail -n 19 "$STATE_DIR/staged-seen" 2>/dev/null
    printf '%s\n' "$1"
  } > "$STATE_DIR/staged-seen.tmp" && /bin/mv -f "$STATE_DIR/staged-seen.tmp" "$STATE_DIR/staged-seen"
}

# release_hold <update dir> <name>: put a held update back where ShipIt expects it.
release_hold() {
  in_dir "$1" move_into_place "$2.endor-hold" "$2"
}

process_staged() {
  local list owner upd status=0
  list=$(list_staged_updates)
  [[ -n "$list" ]] || return 0
  while IFS=$'\t' read -r owner upd <&3; do
    [[ -n "$upd" ]] || continue
    prepatch_staged "$owner" "$upd" || status=1
  done 3<<EOF
$list
EOF
  return "$status"
}

prepatch_staged() {
  local upd="$2" updir name fp version live_version live_dr clone
  updir=$(dirname "$upd")
  name=$(basename "$upd")
  if [[ "$DRY_RUN" != "1" && ! -e "$upd" && -d "$upd.endor-hold" ]] && release_hold "$updir" "$name"; then
    log "released an update held by an interrupted run: $upd"
  fi
  [[ "$LIVE_CLASS" == B && -d "$upd" && ! -L "$upd" ]] || return 0
  bundle_complete "$upd" || return 0
  fp=$(bundle_fingerprint "$upd")
  staged_seen "$fp" && return 0
  # ShipIt waits for VS Code to quit; with VS Code gone it may be installing right now.
  if ! app_running; then
    note_once "an update is staged at $upd; it is prepared while VS Code is running"
    return 0
  fi
  version=$(info_value "$upd" CFBundleVersion)
  live_version=$(info_value "$APP" CFBundleVersion)
  if [[ "$(info_value "$upd" CFBundleIdentifier)" != "$BUNDLE_ID" ]] || ! version_gt "$version" "$live_version"; then
    log "leaving the staged update at $upd alone: not a newer VS Code (staged $version, installed $live_version)"
    staged_mark "$fp"
    return 0
  fi
  live_dr=$(designated_of "$APP")
  if [[ "$(signer_class "$upd")" == ours ]] && cs_verify "$upd" "$live_dr" --deep; then
    staged_mark "$fp"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    dry "action : HOLD, PATCH and SIGN the staged VS Code $version update"
    dry "update : $upd"
    return 0
  fi
  ensure_signing_identity || return 1

  # Hold the update under another name while it is prepared. If VS Code restarts meanwhile,
  # ShipIt can't find it, retries and then relaunches the installed, firewalled app.
  if ! in_dir "$updir" /bin/mv "$name" "$name.endor-hold"; then
    warn "could not hold the staged update at $upd"
    return 1
  fi
  clone="$STATE_DIR/stage/$name"
  if build_staged_copy "$updir" "$name" "$clone" "$live_dr" \
      && in_dir "$updir" move_into_place "$clone" "$name"; then
    in_dir "$updir" retain_pristine "$name.endor-hold" "$version" \
      || warn "could not keep Microsoft's original VS Code $version"
    staged_mark "$(bundle_fingerprint "$upd")"
    log "prepared the staged VS Code $version update: patched and signed by this Mac, so it installs already firewalled"
    return 0
  fi
  discard "$clone"
  release_hold "$updir" "$name" || warn "could not release the held update at $upd"
  # Don't retry this update every minute; once installed, the live app is migrated as usual.
  staged_mark "$fp"
  return 1
}

# build_staged_copy <update dir> <name> <clone> <live DR>
build_staged_copy() {
  fresh_stage || return 1
  if ! in_dir "$1" stage_clone "$2.endor-hold" "$3"; then
    warn "could not copy the staged update $1/$2"
    return 1
  fi
  classify_bundle "$3"
  if [[ "$CLASS" != A ]]; then
    warn "refusing the staged update $1/$2: $(describe_class "$CLASS")"
    return 1
  fi
  if ! patch_product_json_in "$3" patch; then
    warn "could not patch product.json in the staged update $1/$2"
    return 1
  fi
  sign_bundle "$3" && verify_signed "$3" json_is_desired || return 1
  # ShipIt's own check: the update must satisfy the installed app's designated requirement.
  if ! cs_verify "$3" "$4" --deep; then
    warn "the prepared update would not satisfy the installed app's designated requirement"
    return 1
  fi
}

# ── Restore, purge, status ────────────────────────────────────────────────────

restore_staged() {
  local list owner upd updir name v p status=0
  list=$(list_staged_updates)
  while IFS=$'\t' read -r owner upd <&3; do
    [[ -n "$upd" ]] || continue
    updir=$(dirname "$upd")
    name=$(basename "$upd")
    if [[ "$DRY_RUN" != "1" && ! -e "$upd" && -d "$upd.endor-hold" ]]; then
      release_hold "$updir" "$name"
    fi
    [[ -d "$upd" && ! -L "$upd" ]] || continue
    case "$(signer_class "$upd")" in
      ours|previous) ;;
      *) continue ;;
    esac
    v=$(info_value "$upd" CFBundleVersion)
    p="$STATE_DIR/pristine/$v/$PRISTINE_NAME"
    if [[ "$DRY_RUN" == "1" ]]; then
      dry "action : RESTORE Microsoft's staged VS Code $v update at $upd"
      continue
    fi
    if ! in_dir "$updir" /bin/mv "$name" "$name.endor-restore"; then
      warn "could not move the prepared update at $upd aside"
      status=1
      continue
    fi
    if valid_version "$v" && pristine_ok "$p" "$v" && in_dir "$updir" move_into_place "$p" "$name"; then
      log "restored Microsoft's staged VS Code $v update at $upd"
    else
      log "removed the prepared VS Code $v update at $upd; VS Code downloads it again"
    fi
    in_dir "$updir" /bin/rm -rf "$name.endor-restore"
  done 3<<EOF
$list
EOF
  return "$status"
}

restore_live() {
  local p out clone
  if ! app_present; then
    log "Microsoft VS Code Stable not found at $APP; nothing to restore."
    return 0
  fi
  if ! wait_for_quiescence; then
    warn "VS Code is being updated; run the restore again"
    return 1
  fi
  classify_bundle "$APP"
  case "$CLASS" in
    A)
      log "VS Code $CLASS_VERSION is Microsoft's unmodified build; nothing to restore."
      return 0
      ;;
    E)
      if bundle_complete "$APP" && json_is_managed "$APP/$PRODUCT_REL"; then
        warn "cannot restore $APP: $CLASS_WHY"
        return 1
      fi
      log "VS Code at $APP is not managed by Endor; nothing to restore."
      return 0
      ;;
  esac

  p="$STATE_DIR/pristine/$CLASS_VERSION/$PRISTINE_NAME"
  if [[ "$CLASS" != D ]] && valid_version "$CLASS_VERSION" && pristine_ok "$p" "$CLASS_VERSION"; then
    if [[ "$DRY_RUN" == "1" ]]; then
      dry "action : SWAP BACK Microsoft's original VS Code $CLASS_VERSION"
      return 0
    fi
    out=$(outgoing_path) || return 1
    swap_in "$p" "$out" || return 1
    discard "$out"
    log "restored Microsoft's original VS Code $CLASS_VERSION"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    dry "action : RESTORE the default gallery in a copy of $APP and SWAP it in"
    return 0
  fi
  # Without Microsoft's original: restore product.json in a copy. A copy we signed is signed
  # again, so it stays valid until VS Code's next update replaces it with Microsoft's build.
  [[ "$CLASS" == D ]] || ensure_signing_identity || return 1
  fresh_stage || return 1
  clone="$STATE_DIR/stage/$(basename "$APP")"
  if ! stage_clone "$APP" "$clone"; then
    discard "$clone"
    return 1
  fi
  strip_stray_temps "$clone"
  if ! patch_product_json_in "$clone" restore; then
    warn "could not restore product.json in the copy of $APP"
    discard "$clone"
    return 1
  fi
  if [[ "$CLASS" != D ]] && { ! sign_bundle "$clone" || ! verify_signed "$clone" json_is_restored; }; then
    discard "$clone"
    return 1
  fi
  out=$(outgoing_path) || return 1
  if ! swap_in "$clone" "$out"; then
    discard "$clone"
    return 1
  fi
  discard "$out"
  if [[ "$CLASS" == D ]]; then
    log "restored the default gallery in VS Code $CLASS_VERSION"
  else
    log "restored the default gallery in VS Code $CLASS_VERSION; it stays signed by this Mac until its next update"
  fi
}

darwin_purge() {
  local sha1
  if [[ "$DRY_RUN" == "1" ]]; then
    dry "action : DELETE the signing identity from $KEYCHAIN and the worker's staging state"
    return 0
  fi
  if [[ -d "$SIGNING_DIR" ]]; then
    for sha1 in $(/bin/cat "$SIGNING_DIR/cert.sha1" "$SIGNING_DIR/previous-certs" 2>/dev/null); do
      [[ "$sha1" =~ ^[0-9a-f]{40}$ ]] || continue
      if /usr/bin/security delete-certificate -Z "$sha1" -t "$KEYCHAIN" >/dev/null 2>&1; then
        log "deleted signing identity $sha1 from $KEYCHAIN"
      fi
    done
  fi
  discard "$STATE_DIR/signing"
  discard "$STATE_DIR/stage"
  discard "$STATE_DIR/outgoing"
  discard "$STATE_DIR/pristine"
  /bin/rm -f "$STATE_DIR/last-good" "$STATE_DIR/last-refused" "$STATE_DIR/last-note" \
    "$STATE_DIR/staged-seen"
}

darwin_status() {
  local list owner upd d
  echo "app        : $APP"
  if app_present; then
    classify_bundle "$APP"
    echo "version    : ${CLASS_VERSION:-unknown}"
    echo "state      : $CLASS ($(describe_class "$CLASS"))"
    echo "signer     : $CLASS_SIGNER"
  else
    echo "state      : not installed"
  fi
  if app_running; then echo "running    : yes"; else echo "running    : no"; fi
  if [[ -n "$CERT_SHA1" ]]; then
    echo "identity   : $(cat "$SIGNING_DIR/cn" 2>/dev/null) ($CERT_SHA1)"
    echo "expires    : $(/usr/bin/openssl x509 -enddate -noout -in "$SIGNING_DIR/cert.pem" 2>/dev/null | /usr/bin/sed 's/^notAfter=//')"
    if identity_in_keychain "$CERT_SHA1"; then echo "keychain   : $KEYCHAIN"; else echo "keychain   : MISSING from $KEYCHAIN"; fi
  else
    echo "identity   : none yet"
  fi
  for d in "$STATE_DIR/pristine"/*; do
    [[ -d "$d" ]] && echo "original   : VS Code $(basename "$d") kept for removal"
  done
  list=$(list_staged_updates)
  while IFS=$'\t' read -r owner upd <&3; do
    [[ -n "$upd" ]] || continue
    if [[ -d "$upd" ]]; then
      echo "staged     : VS Code $(info_value "$upd" CFBundleVersion), signer $(signer_class "$upd"): $upd"
    elif [[ -d "$upd.endor-hold" ]]; then
      echo "staged     : held: $upd"
    fi
  done 3<<EOF
$list
EOF
  if [[ -f "$STATE_DIR/last-refused" ]]; then
    echo "refused    : $(/bin/date -r "$(cut -d' ' -f1 "$STATE_DIR/last-refused")" 2>/dev/null)"
  fi
  return 0
}

rotate_log() {
  local size
  [[ -f "$LOG_FILE" ]] || return 0
  size=$(/usr/bin/stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)
  if (( size > 1048576 )); then
    /bin/mv -f "$LOG_FILE" "$LOG_FILE.1" && : > "$LOG_FILE" && /bin/chmod 600 "$LOG_FILE"
  fi
  return 0
}

darwin_main() {
  local name rc status=0
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin
  export LC_ALL=C
  APP_PATH="${ENDOR_VSCODE_APP:-/Applications/Visual Studio Code.app}"
  BUNDLE_ID="${ENDOR_VSCODE_BUNDLE_ID:-com.microsoft.VSCode}"
  UPSTREAM_ANCHOR="${ENDOR_VSCODE_UPSTREAM_ANCHOR:-$UPSTREAM_ANCHOR_DEFAULT}"
  KEYCHAIN="${ENDOR_VSCODE_KEYCHAIN:-/Library/Keychains/System.keychain}"
  USERS_DIR="${ENDOR_VSCODE_USERS_DIR:-/Users}"
  LOG_FILE="${ENDOR_VSCODE_LOG:-/Library/Logs/Endor Labs/vscode-firewall.log}"
  LOCK_WAIT="${ENDOR_VSCODE_LOCK_WAIT:-120}"
  SETTLE_SECONDS="${ENDOR_VSCODE_SETTLE_SECONDS:-2}"
  SETTLE_TIMEOUT="${ENDOR_VSCODE_SETTLE_TIMEOUT:-30}"
  CERT_DAYS="${ENDOR_VSCODE_CERT_DAYS:-3650}"
  RENEW_DAYS="${ENDOR_VSCODE_RENEW_DAYS:-30}"
  STATE_DIR="${ENDOR_VSCODE_STATE_DIR:-}"
  [[ -n "$STATE_DIR" ]] || STATE_DIR=$(cd "$(dirname "$0")" && pwd -P)
  SIGNING_DIR="$STATE_DIR/signing"

  for name in LOCK_WAIT SETTLE_SECONDS SETTLE_TIMEOUT CERT_DAYS RENEW_DAYS; do
    if ! is_uint "${!name}"; then
      echo "[endor-vscode] ERROR: ENDOR_VSCODE_$name must be a whole number" >&2
      return 2
    fi
  done
  # One run at a time: the installer, the LaunchDaemon and removal all go through this lock.
  if [[ "$MODE" != status && "$DRY_RUN" != "1" && "${ENDOR_VSCODE_LOCK_HELD:-0}" != "1" ]]; then
    /bin/mkdir -p "$STATE_DIR" && /bin/chmod 700 "$STATE_DIR" || return 1
    ENDOR_VSCODE_LOCK_HELD=1 /usr/bin/lockf -k -s -t "$LOCK_WAIT" "$STATE_DIR/.lock" \
      /bin/bash "$0" "$@"
    rc=$?
    if [[ "$rc" -eq 75 ]]; then
      if [[ "$MODE" == once ]]; then
        log "another run of the worker is still busy; leaving this trigger to it"
        return 0
      fi
      warn "another run of the worker held the lock for ${LOCK_WAIT}s"
    fi
    return "$rc"
  fi

  for name in ENDOR_VSCODE_APP ENDOR_VSCODE_BUNDLE_ID ENDOR_VSCODE_UPSTREAM_ANCHOR \
      ENDOR_VSCODE_KEYCHAIN ENDOR_VSCODE_USERS_DIR; do
    if [[ -n "${!name:-}" ]]; then
      warn "$name is set; this is meant for tests only"
    fi
  done
  # codesign reports physical paths, and seal_status matches them against these.
  if [[ -d "$STATE_DIR" ]]; then
    STATE_DIR=$(cd "$STATE_DIR" && pwd -P)
    SIGNING_DIR="$STATE_DIR/signing"
  fi
  if ! resolve_app; then
    warn "cannot resolve $APP_PATH"
    return 1
  fi
  URL_HASH=$(printf '%s' "$FIREWALL_URL" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-16)
  RUN_TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/endor-vscode.XXXXXX") || return 1
  trap 'discard "$RUN_TMP"' EXIT
  identity_load

  if [[ "$DRY_RUN" != "1" ]] && [[ "$MODE" == once || "$MODE" == restore ]]; then
    recover_outgoing
  fi
  case "$MODE" in
    once)
      [[ "$DRY_RUN" == "1" ]] || rotate_log
      process_live || status=1
      process_staged || status=1
      [[ "$LIVE_CLASS" == B ]] && prune_pristine
      ;;
    restore)
      restore_staged || status=1
      restore_live || status=1
      ;;
    purge) darwin_purge || status=1 ;;
    status) darwin_status ;;
  esac
  return "$status"
}

if [[ "$(uname -s)" == "Darwin" && -z "${ENDOR_VSCODE_PRODUCT_JSON:-}" ]]; then
  darwin_main "$@"
  exit $?
fi

case "$MODE" in
  once) patch_all ;;
  restore) restore_all ;;
  status) status_all ;;
  purge) : ;;
esac
ENDOR_VSCODE_WORKER

# Changing VS Code on macOS has costs that each customer weighs (see bash/README.md), so the
# macOS daemon is opt-in: ENDOR_VSCODE_MACOS_DAEMON=1 when the script is generated.
_VSCODE_MACOS_DAEMON='{{VSCODE_MACOS_DAEMON}}'
_vscode_skip=0
_vscode_os=$(uname -s)
case "$_vscode_os" in
  Darwin)
    _VSCODE_STATE_DIR="${ENDOR_VSCODE_STATE_DIR:-/Library/Application Support/Endor Labs/vscode-firewall}"
    _VSCODE_LOG_DIR="/Library/Logs/Endor Labs"
    [[ "$_VSCODE_MACOS_DAEMON" == "1" ]] || _vscode_skip=1
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

# The worker runs under /bin/bash on macOS: Bash 3.2, whatever PATH the MDM agent has.
_vscode_run_worker() {
  if [[ "$_vscode_os" == "Darwin" ]]; then
    /bin/bash "$@"
  else
    "$@"
  fi
}

_vscode_xml() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

if [[ "$_vscode_skip" == "1" ]]; then
  echo "[endor] skip: the VS Code firewall is not enabled for macOS in this script."
  echo "[endor]   To enable it, regenerate with ENDOR_VSCODE_MACOS_DAEMON=1 (see bash/README.md)."
  # An earlier version of this script installed the daemon unconditionally. Leave it running,
  # because removing it would turn the firewall off, but make the admin decide.
  if [[ -f /Library/LaunchDaemons/com.endorlabs.vscode-firewall.plist ]]; then
    echo "[endor] WARNING: a VS Code firewall daemon from an earlier deployment is still installed." >&2
    echo "[endor]   Regenerate with ENDOR_VSCODE_MACOS_DAEMON=1 to keep it, or run endor-remove.sh to remove it." >&2
    _ENDOR_WARNED=1
  fi
elif [[ "${DRY_RUN:-0}" == "1" ]]; then
  _vscode_tmp_worker=$(mktemp)
  printf '%s\n' "$_VSCODE_WORKER_CONTENT" > "$_vscode_tmp_worker"
  chmod 700 "$_vscode_tmp_worker"
  ENDOR_VSCODE_STATE_DIR="$_VSCODE_STATE_DIR" \
    _vscode_run_worker "$_vscode_tmp_worker" --once --dry-run || _ENDOR_WARNED=1
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

    # Stop a previous daemon first: older workers edited the app in place.
    if [[ "$_vscode_os" == "Darwin" && "${ENDOR_VSCODE_SKIP_WATCHER:-0}" != "1" ]]; then
      /bin/launchctl bootout system/com.endorlabs.vscode-firewall >/dev/null 2>&1 || true
    fi
    # Report the current state again, and re-evaluate an app refused earlier.
    rm -f "$_VSCODE_STATE_DIR/last-note" "$_VSCODE_STATE_DIR/last-refused"

    ENDOR_VSCODE_STATE_DIR="$_VSCODE_STATE_DIR" ENDOR_VSCODE_LOCK_WAIT="${ENDOR_VSCODE_LOCK_WAIT:-600}" \
      _vscode_run_worker "$_VSCODE_WORKER_PATH" --once || _ENDOR_WARNED=1

    if [[ "${ENDOR_VSCODE_SKIP_WATCHER:-0}" != "1" ]]; then
      if [[ "$_vscode_os" == "Darwin" ]]; then
        _vscode_plist="/Library/LaunchDaemons/com.endorlabs.vscode-firewall.plist"
        _vscode_log="$_VSCODE_LOG_DIR/vscode-firewall.log"
        mkdir -p "$_VSCODE_LOG_DIR"
        touch "$_vscode_log"
        chmod 600 "$_vscode_log"
        # Watch /Applications for updater replacements and each user's ShipIt cache for staged
        # updates. A user who has never updated VS Code has no ShipIt cache yet, so watch their
        # Caches folder instead; StartInterval covers anything the watches miss.
        _vscode_watch="    <string>/Applications</string>"
        for _vscode_caches in /Users/*/Library/Caches; do
          [[ -d "$_vscode_caches" && ! -L "$_vscode_caches" ]] || continue
          if [[ -d "$_vscode_caches/com.microsoft.VSCode.ShipIt" ]]; then
            _vscode_caches="$_vscode_caches/com.microsoft.VSCode.ShipIt"
          fi
          _vscode_watch="$_vscode_watch
    <string>$(_vscode_xml "$_vscode_caches")</string>"
        done
        cat > "$_vscode_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.endorlabs.vscode-firewall</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(_vscode_xml "$_VSCODE_WORKER_PATH")</string>
    <string>--once</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>WatchPaths</key>
  <array>
$_vscode_watch
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>ThrottleInterval</key>
  <integer>2</integer>
  <key>StandardOutPath</key>
  <string>$(_vscode_xml "$_vscode_log")</string>
  <key>StandardErrorPath</key>
  <string>$(_vscode_xml "$_vscode_log")</string>
</dict>
</plist>
PLIST
        chown root:wheel "$_vscode_plist"
        chmod 644 "$_vscode_plist"
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

[[ "$_vscode_skip" == "1" ]] || echo "[endor] ✓ VS Code extension firewall done"
unset -f _vscode_run_worker _vscode_xml
unset _vscode_os _VSCODE_STATE_DIR _VSCODE_WORKER_PATH _VSCODE_WORKER_CONTENT _VSCODE_LOG_DIR
unset _vscode_tmp_worker _vscode_plist _vscode_service _vscode_path _vscode_log _vscode_watch
unset _vscode_caches _VSCODE_MACOS_DAEMON _vscode_skip
