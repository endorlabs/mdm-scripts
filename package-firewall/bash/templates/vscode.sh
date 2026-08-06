# templates/vscode.sh
# VS Code ecosystem — extension gallery
#
# Config target is product.json inside each VS Code install directory:
#   macOS  → /Applications/Visual Studio Code.app/Contents/Resources/app/product.json
#            (plus Insiders, plus ~/Applications copies)
#   Linux  → /usr/share/code/resources/app/product.json (and code-insiders, /opt)
#
# Block content is defined in shared/blocks/vscodegallery.txt.
#
# Three things make this ecosystem different from npm/pip/go/maven:
#
#   1. The file is JSON, so it can carry neither an Endor sentinel comment nor an
#      ${ENDOR_*} env-var reference. The managed marker is a top-level JSON key
#      that also stores the byte-exact original for restore.
#   2. product.json lives inside the application and is replaced wholesale by
#      every VS Code update, so a watcher re-applies the patch. Stable updates
#      monthly; Insiders nightly.
#   3. The credential is a URL path segment, so it lands in a world-readable file.
#      That is unavoidable — VS Code offers no indirection in product.json — and
#      is why VS Code should use its own revocable API key. See the READMEs.
#
# The {{VSCODE_GALLERY_URL}} token is filled here at install time (not at
# generation time) because the token embeds this machine's attribution label —
# same pattern as {{GO_PROXY_URL}} in templates/go.sh.

echo ""
echo "[endor-vscode] ── VS Code extensions ───────────────────────────────────────"

# ── Fill the attributed gallery URL into the block content ────────────────────
VSCODE_GALLERY_BLOCK=${VSCODE_GALLERY_BLOCK//'{{VSCODE_GALLERY_URL}}'/"$ENDOR_VSCODE_GALLERY_URL"}

if [[ "$VSCODE_GALLERY_BLOCK" == *'{{'* ]]; then
  echo "[endor-vscode] WARNING: unresolved {{...}} token in the VS Code gallery block." >&2
  echo "[endor-vscode]          Regenerate with generate.sh — do not hand-edit generated scripts." >&2
  _ENDOR_WARNED=1
fi

# ── Split the block into set-lines and delete-keys ────────────────────────────
# '-key' lines delete a key, '"key": value' lines set one, '#' lines are comments.
VSCODE_SET_LINES=""
VSCODE_DELETE_KEYS=""
while IFS= read -r _vsc_line; do
  _vsc_line="${_vsc_line#"${_vsc_line%%[![:space:]]*}"}"   # ltrim
  _vsc_line="${_vsc_line%"${_vsc_line##*[![:space:]]}"}"   # rtrim
  case "$_vsc_line" in
    ''|'#'*) continue ;;
    -*)      VSCODE_DELETE_KEYS="${VSCODE_DELETE_KEYS}${_vsc_line#-} " ;;
    *)       VSCODE_SET_LINES="${VSCODE_SET_LINES}${_vsc_line}"$'\n' ;;
  esac
done <<< "$VSCODE_GALLERY_BLOCK"
unset _vsc_line

VSCODE_SET_LINES="${VSCODE_SET_LINES%$'\n'}"
VSCODE_DELETE_KEYS="${VSCODE_DELETE_KEYS% }"

if [[ -z "$VSCODE_SET_LINES" ]]; then
  echo "[endor-vscode] ERROR: shared/blocks/vscodegallery.txt produced no keys to set." >&2
  _ENDOR_WARNED=1
fi

# ── Discover installs ─────────────────────────────────────────────────────────
VSCODE_PATHS_FILE=$(mktemp)
vscode_install_paths "$USER_HOME" > "$VSCODE_PATHS_FILE"

if [[ ! -s "$VSCODE_PATHS_FILE" ]]; then
  # Informational, not a warning — matches the "go binary not found" precedent in
  # templates/go.sh. A machine without VS Code is not a misconfigured machine.
  echo "[endor-vscode]   no VS Code installation found — nothing to do"
  echo "[endor-vscode]   (re-run this script after installing VS Code)"
  rm -f "$VSCODE_PATHS_FILE"
else
  _VSCODE_TOUCHED=0
  while IFS= read -r _vsc_pj; do
    [[ -n "$_vsc_pj" ]] || continue
    # Generated scripts run under `set -e`, and vscode_patch returns 2 for
    # "already current" and 1 for a handled failure — both meaningful, neither
    # fatal. Collecting the status with `|| _vsc_rc=$?` keeps set -e from
    # aborting the run on an ordinary no-op.
    _vsc_rc=0
    vscode_patch \
      "$_vsc_pj" \
      "$ENDOR_VSCODE_GALLERY_URL" \
      "$VSCODE_SET_LINES" \
      "$VSCODE_DELETE_KEYS" \
      "{{NAMESPACE}}" \
      "{{FQDN}}" || _vsc_rc=$?
    case "$_vsc_rc" in
      0)
        _VSCODE_TOUCHED=1
        # In repatch mode a return of 0 means an update really did clobber
        # product.json since last time. Count it, so the race is visible in MDM
        # logs instead of invisible.
        if [[ "${_ENDOR_VSCODE_MODE:-install}" == "repatch" ]]; then
          _vsc_n=$(vscode_state_get repatch_count 2>/dev/null) || _vsc_n=0
          [[ -n "$_vsc_n" ]] || _vsc_n=0
          vscode_state_set repatch_count "$(( _vsc_n + 1 ))"
          vscode_state_set last_repatch "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          vscode_state_set last_app_version "$(endor_json_top_string "$_vsc_pj" version 2>/dev/null || echo unknown)"
        fi
        ;;
      2) _VSCODE_TOUCHED=1 ;;
      *) _ENDOR_WARNED=1 ;;
    esac
  done < "$VSCODE_PATHS_FILE"

  # ── Install the re-apply watcher (install mode only) ────────────────────────
  if [[ "${_ENDOR_VSCODE_MODE:-install}" == "install" ]]; then
    if [[ "$_VSCODE_TOUCHED" == "1" ]]; then
      VSCODE_STATE_DIR=$(endor_vscode_state_dir)
      VSCODE_REPATCH="${VSCODE_STATE_DIR}/endor-vscode-repatch.sh"

      # Record state whether or not the watcher is wanted, so re-enabling it later
      # (or running the repatch script by hand) needs no re-install.
      if [[ "${DRY_RUN:-0}" != "1" ]]; then
        mkdir -p "$VSCODE_STATE_DIR"
        chmod 700 "$VSCODE_STATE_DIR" 2>/dev/null || true

        # The watcher may fire from launchd at boot, before anyone has logged in,
        # so the repatch script cannot re-run console-user detection. Record the
        # already-rendered URL and home here instead; the state file is 0600 and
        # root-owned, which is strictly better than product.json's 0644.
        vscode_state_set gallery_url "$ENDOR_VSCODE_GALLERY_URL"
        vscode_state_set user_home "$USER_HOME"
      fi

      if [[ "${VSCODE_WATCHER:-1}" == "1" ]]; then
        if [[ "${DRY_RUN:-0}" != "1" ]]; then
          # The watcher must run from a stable path. Do NOT copy "$0": MDM tools
          # frequently pipe scripts to bash or exec them from an already-unlinked
          # temp file, so $0 is not reliably a readable path.
          printf '%s' "$_ENDOR_VSCODE_REPATCH_B64" | endor_b64d > "$VSCODE_REPATCH"
          chmod 700 "$VSCODE_REPATCH"
          chown root:wheel "$VSCODE_REPATCH" 2>/dev/null \
            || chown root:root "$VSCODE_REPATCH" 2>/dev/null || true
        fi
        vscode_install_watcher "$VSCODE_REPATCH" "$VSCODE_PATHS_FILE" || true
        vscode_state_report
      else
        # An explicit opt-out is an admin decision, so it is stated loudly but does
        # NOT set _ENDOR_WARNED — failing every MDM check-in for a chosen setting
        # is alert fatigue, and alert fatigue is how real warnings get ignored.
        echo "[endor-vscode]       update watcher skipped (--no-vscode-watcher)"
        echo "[endor-vscode]       NOTE: the patch is lost whenever VS Code updates — monthly for"
        echo "[endor-vscode]             stable, nightly for Insiders. Re-push this script on every"
        echo "[endor-vscode]             MDM check-in, or accept unfiltered windows in between."
      fi
    fi
  fi

  rm -f "$VSCODE_PATHS_FILE"

  echo "[endor-vscode]   covers: Extensions view search, install and auto-update, plus"
  echo "[endor-vscode]           'code --install-extension' (the CLI reads product.json too)"
  echo "[endor-vscode]   gallery: {{FQDN}}/v1/namespaces/{{NAMESPACE}}/firewall/vscode/_ak/<token>"
  echo "[endor-vscode]   note: extension downloads still come from Microsoft's CDN by design —"
  echo "[endor-vscode]         blocked versions are filtered out of the gallery response, so"
  echo "[endor-vscode]         they are never offered. Keep *.vsassets.io / *.vscode-unpkg.net"
  echo "[endor-vscode]         reachable through any egress proxy."
  echo "[endor-vscode] ✓ VS Code done"
fi
