# templates/vscode.sh
# Patches Microsoft VS Code Stable's product.json and installs update remediation.
# On macOS this runs only when the script was generated with ENDOR_VSCODE_MACOS_DAEMON=1.

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

# ── macOS: classify the app before changing it ────────────────────────────────
#
# Microsoft's signature seals product.json, so an in-place edit makes Gatekeeper call a
# freshly updated VS Code "damaged". The fix is to patch a clone, sign it with an identity
# unique to this Mac and swap the whole app into place. Before changing anything, the worker
# must know what the app in /Applications is: classify_bundle decides without writing, and
# --status reports it. Until the swap is in place, --once still patches product.json in place.
#
# States (classify_bundle), and what the worker does with each once it swaps signed copies:
#   A   Microsoft-signed, seal intact                       patch, sign, swap; keep the original
#   B   signed by this Mac and current                      nothing
#   C   signed by this Mac, but out of date                 patch if needed, re-sign, swap
#   D   Microsoft-signed, only Endor's product.json edit    patch, sign, swap (legacy installs)
#   D2  signed by this Mac, product.json changed since      patch, re-sign, swap
#   E   anything else                                       refuse and leave the app alone

PRODUCT_REL="Contents/Resources/app/product.json"
UPSTREAM_ANCHOR_DEFAULT='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = UBF8T346G9'
CERT_SHA1=""
RUN_TMP=""

ts() { /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'; }
redact() { /usr/bin/sed -E 's#/_ak/[^/[:space:]"]+#/_ak/<redacted>#g'; }
log() { printf '%s [endor-vscode] %s\n' "$(ts)" "$*" | redact; }
warn() { printf '%s [endor-vscode] WARNING: %s\n' "$(ts)" "$*" | redact >&2; }

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

info_value() { /usr/bin/plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null; }

discard() {
  [[ -n "$1" && "$1" != "/" ]] && /bin/rm -rf "$1"
  return 0
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

# ── Status ────────────────────────────────────────────────────────────────────

darwin_status() {
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
  return 0
}

darwin_main() {
  local name
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin
  export LC_ALL=C
  APP_PATH="${ENDOR_VSCODE_APP:-/Applications/Visual Studio Code.app}"
  BUNDLE_ID="${ENDOR_VSCODE_BUNDLE_ID:-com.microsoft.VSCode}"
  UPSTREAM_ANCHOR="${ENDOR_VSCODE_UPSTREAM_ANCHOR:-$UPSTREAM_ANCHOR_DEFAULT}"
  KEYCHAIN="${ENDOR_VSCODE_KEYCHAIN:-/Library/Keychains/System.keychain}"
  RENEW_DAYS="${ENDOR_VSCODE_RENEW_DAYS:-30}"
  STATE_DIR="${ENDOR_VSCODE_STATE_DIR:-}"
  [[ -n "$STATE_DIR" ]] || STATE_DIR=$(cd "$(dirname "$0")" && pwd -P)
  SIGNING_DIR="$STATE_DIR/signing"

  if ! is_uint "$RENEW_DAYS"; then
    echo "[endor-vscode] ERROR: ENDOR_VSCODE_RENEW_DAYS must be a whole number" >&2
    return 2
  fi
  for name in ENDOR_VSCODE_APP ENDOR_VSCODE_BUNDLE_ID ENDOR_VSCODE_UPSTREAM_ANCHOR \
      ENDOR_VSCODE_KEYCHAIN; do
    if [[ -n "${!name:-}" ]]; then
      warn "$name is set; this is meant for tests only"
    fi
  done
  if ! resolve_app; then
    warn "cannot resolve $APP_PATH"
    return 1
  fi
  RUN_TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/endor-vscode.XXXXXX") || return 1
  trap 'discard "$RUN_TMP"' EXIT
  identity_load

  case "$MODE" in
    status) darwin_status ;;
  esac
}

# On macOS, --status reads the app bundle itself. Patching still edits product.json in place.
if [[ "$(uname -s)" == "Darwin" && -z "${ENDOR_VSCODE_PRODUCT_JSON:-}" && "$MODE" == status ]]; then
  darwin_main "$@"
  exit $?
fi

case "$MODE" in
  once) patch_all ;;
  restore) restore_all ;;
  status) status_all ;;
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

[[ "$_vscode_skip" == "1" ]] || echo "[endor] ✓ VS Code extension firewall done"
unset _vscode_os _VSCODE_STATE_DIR _VSCODE_WORKER_PATH _VSCODE_WORKER_CONTENT
unset _vscode_tmp_worker _vscode_plist _vscode_service _vscode_path _VSCODE_MACOS_DAEMON _vscode_skip
