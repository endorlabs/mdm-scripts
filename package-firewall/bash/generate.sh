#!/usr/bin/env bash
# generate.sh — Endor Package Firewall MDM Script Generator
#
# Produces self-contained, MDM-deployable scripts that configure developer
# machines to route package installations through the Endor Package Firewall.
#
# Usage:
#   ENDOR_NAMESPACE=my-team \
#   ENDOR_API_KEY_ID=key-id \
#   ENDOR_API_SECRET=key-secret \
#   ./generate.sh
#
# Or with a .env file:
#   set -a; source .env; set +a; ./generate.sh
#
# Environment variables:
#   ENDOR_NAMESPACE    Required. Your Endor namespace (e.g. my-team)
#   ENDOR_API_KEY_ID   Required. API key ID (Basic Auth username)
#   ENDOR_API_SECRET   Required. API secret  (Basic Auth password)
#   ENDOR_FQDN         Optional. Base URL (default: https://factory.endorlabs.com)
#
# To customise config blocks, edit shared/blocks/*.txt directly.
# To customise orchestration logic, edit templates/*.sh directly.
#
# Output (out/<namespace>/):
#   endor-js.sh       — JavaScript: npm · pnpm · yarn classic · yarn 2+ · bun
#   endor-python.sh   — Python:     pip · uv · poetry
#   endor-go.sh       — Go:         go modules (GOPROXY → ~/.config/go/env)
#   endor-maven.sh    — Maven:      Maven (settings.xml → ~/.m2/settings.xml)
#   endor-all.sh      — All of the above (single-script MDM deploy)
#   endor-remove.sh   — Offboarding: strips Endor config from all files
#
# All scripts accept --dry-run: prints what would change without writing anything.
# All scripts are idempotent — safe to re-push on MDM check-in cycles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
TMPL_DIR="$SCRIPT_DIR/templates"
SHARED_BLOCKS_DIR="$SCRIPT_DIR/../shared/blocks"

# ─── Validate required env vars ───────────────────────────────────────────────
: "${ENDOR_NAMESPACE:?ENDOR_NAMESPACE is required}"
: "${ENDOR_API_KEY_ID:?ENDOR_API_KEY_ID is required}"
: "${ENDOR_API_SECRET:?ENDOR_API_SECRET is required}"

# Reject credential characters that would corrupt generated scripts/URLs.
case "${ENDOR_API_KEY_ID}${ENDOR_API_SECRET}" in
  *[!A-Za-z0-9+/=_.-]*)
    echo "ERROR: ENDOR_API_KEY_ID / ENDOR_API_SECRET contain unsupported characters" >&2
    exit 1 ;;
esac

# ─── Resolve FQDN ─────────────────────────────────────────────────────────────
FQDN="${ENDOR_FQDN:-https://factory.endorlabs.com}"

# ─── Compute derived values ────────────────────────────────────────────────────
# Only machine-independent values are derived here. Attribution values
# (<console-user>@<machine>) are computed at install time — see credentials_block.
FQDN_HOST="${FQDN#https://}"
FQDN_HOST="${FQDN_HOST#http://}"
TRUSTED_HOST="${FQDN_HOST%%:*}"

NPM_REGISTRY_URL="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/npm/"
NPM_REGISTRY_HOST="${FQDN_HOST}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/npm/"
PYPI_URL="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/pypi/simple/"
MAVEN_REGISTRY_URL="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/maven/"
# VS Code carries its credential as a URL path segment (_ak/<token>) rather than
# in userinfo, so only the base is known here; the token is appended at install
# time once the attribution label exists.
VSCODE_GALLERY_BASE="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/vscode"
API_SECRET_B64=$(printf '%s' "${ENDOR_API_SECRET}" | base64 | tr -d '\n')

# ─── Output directory ─────────────────────────────────────────────────────────
OUT_DIR="${SCRIPT_DIR}/out/${ENDOR_NAMESPACE}"
mkdir -p "$OUT_DIR"

# ─── Template substitution ────────────────────────────────────────────────────
substitute() {
  sed \
    -e "s|{{NAMESPACE}}|${ENDOR_NAMESPACE}|g" \
    -e "s|{{API_KEY_ID}}|${ENDOR_API_KEY_ID}|g" \
    -e "s|{{API_SECRET}}|${ENDOR_API_SECRET}|g" \
    -e "s|{{API_SECRET_B64}}|${API_SECRET_B64}|g" \
    -e "s|{{FQDN}}|${FQDN}|g" \
    -e "s|{{FQDN_HOST}}|${FQDN_HOST}|g" \
    -e "s|{{NPM_REGISTRY_URL}}|${NPM_REGISTRY_URL}|g" \
    -e "s|{{NPM_REGISTRY_HOST}}|${NPM_REGISTRY_HOST}|g" \
    -e "s|{{PYPI_URL}}|${PYPI_URL}|g" \
    -e "s|{{TRUSTED_HOST}}|${TRUSTED_HOST}|g" \
    -e "s|{{MAVEN_REGISTRY_URL}}|${MAVEN_REGISTRY_URL}|g" \
    -e "s|{{VSCODE_GALLERY_BASE}}|${VSCODE_GALLERY_BASE}|g"
}

# inline_common
inline_common() {
  grep -v '^# ' "$LIB_DIR/common.sh" | sed '/^[[:space:]]*$/d' \
    || cat "$LIB_DIR/common.sh"
}

# emit_block_assignment <varname> <file>
# Reads a block file, applies substitutions, and emits a quoted heredoc
# assignment for embedding in generated scripts. The quoted delimiter prevents
# the generated script from expanding ${VAR} refs — tools do that at runtime.
emit_block_assignment() {
  local varname="$1"
  local file="$2"
  local delim="ENDOR_${varname}"
  echo "${varname}=\$(cat <<'${delim}'"
  substitute < "$file"
  echo ""
  echo "${delim}"
  echo ")"
}

# emit_all_blocks — emits all block variable assignments into the generated
# script. Attribution {{...}} tokens are filled at install time by the templates.
emit_all_blocks() {
  echo "# ── Block content (from shared/blocks/) ─────────────────────────────────────"
  emit_block_assignment "ENVSH_BLOCK"         "$SHARED_BLOCKS_DIR/envsh.txt"
  emit_block_assignment "NPMRC_BLOCK"         "$SHARED_BLOCKS_DIR/npmrc.txt"
  emit_block_assignment "YARNRC_CLASSIC_BLOCK" "$SHARED_BLOCKS_DIR/yarnrc_classic.txt"
  emit_block_assignment "YARNRC_BLOCK"        "$SHARED_BLOCKS_DIR/yarnrc.txt"
  emit_block_assignment "PIP_BLOCK"           "$SHARED_BLOCKS_DIR/pipconf.txt"
  emit_block_assignment "UV_BLOCK"            "$SHARED_BLOCKS_DIR/uvtoml.txt"
  emit_block_assignment "GO_BLOCK"            "$SHARED_BLOCKS_DIR/goenv.txt"
  emit_block_assignment "MAVEN_BLOCK"         "$SHARED_BLOCKS_DIR/mavensettings.txt"
  emit_block_assignment "VSCODE_GALLERY_BLOCK" "$SHARED_BLOCKS_DIR/vscodegallery.txt"
  echo "# ─────────────────────────────────────────────────────────────────────────────"
  echo ""
}

arg_parsing_block() {
  cat << 'ARGBLOCK'
# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=0
VSCODE_WATCHER=1
_ENDOR_WARNED=0
for _arg in "$@"; do
  case "$_arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-vscode-watcher) VSCODE_WATCHER=0 ;;
    *) echo "[endor] Unknown argument: $_arg  (supported: --dry-run, --no-vscode-watcher)" >&2; exit 1 ;;
  esac
done
unset _arg
[[ "$DRY_RUN" == "1" ]] && echo "[endor] DRY RUN — no files will be modified."
ARGBLOCK
}

script_footer() {
  cat << 'FOOTERBLOCK'
# ── Exit non-zero if any warnings were emitted (MDM alert hook) ───────────────
if [[ "$_ENDOR_WARNED" -eq 1 ]]; then
  echo "" >&2
  echo "[endor] Script completed with warnings — review output above." >&2
  exit 1
fi
FOOTERBLOCK
}

user_detection_block() {
  cat << 'USERBLOCK'
# ── Detect console user and home ──────────────────────────────────────────────
CONSOLE_USER=$(detect_console_user)
USER_HOME=$(resolve_user_home "$CONSOLE_USER")
USER_GROUP=$(id -gn "$CONSOLE_USER" 2>/dev/null || echo "staff")
USERBLOCK
}

# credentials_block — attribution values computed on the dev machine at install
# time (the <console-user>@<machine> label doesn't exist at generation time).
credentials_block() {
  substitute << 'CREDBLOCK'
# ── User attribution (computed at install time) ───────────────────────────────
ENDOR_API_KEY_ID='{{API_KEY_ID}}'
ENDOR_API_SECRET='{{API_SECRET}}'

ENDOR_ATTR_LABEL="${CONSOLE_USER}@$(endor_host_label)"
ENDOR_ATTR_USER="$(endor_attr_username "$ENDOR_ATTR_LABEL" "$ENDOR_API_KEY_ID")"

# npm _auth = base64(username:password)
ENDOR_AUTH_B64="$(printf '%s:%s' "$ENDOR_ATTR_USER" "$ENDOR_API_SECRET" | endor_b64)"

# pip / uv / go URLs: percent-encode both userinfo halves ('/' would break the URL).
ENDOR_PYPI_URL="https://$(endor_urlenc_b64 "$ENDOR_ATTR_USER"):$(endor_urlenc_b64 "$ENDOR_API_SECRET")@{{FQDN_HOST}}/v1/namespaces/{{NAMESPACE}}/firewall/pypi/simple/"
ENDOR_GO_PROXY_URL="https://$(endor_urlenc_b64 "$ENDOR_ATTR_USER"):$(endor_urlenc_b64 "$ENDOR_API_SECRET")@{{FQDN_HOST}}/v1/namespaces/{{NAMESPACE}}/firewall/go/,direct"

# VS Code cannot send Basic auth for the gallery and cannot expand env vars in
# product.json, so the credential travels as a base64url path segment instead.
# Same attributed username as every other ecosystem — the firewall runs
# applyUserAttribution after resolving the _ak path token.
ENDOR_VSCODE_TOKEN="$(printf '%s:%s' "$ENDOR_ATTR_USER" "$ENDOR_API_SECRET" | endor_b64url)"
ENDOR_VSCODE_GALLERY_URL="{{VSCODE_GALLERY_BASE}}/_ak/${ENDOR_VSCODE_TOKEN}"

# No exports — every consumer is same-process template code inlined below.

echo "[endor] user attribution → ${ENDOR_ATTR_LABEL}"
CREDBLOCK
}

# script_header <output> <description>
script_header() {
  local output="$1"
  local description="$2"
  echo "#!/usr/bin/env bash"
  echo "# MDM-deployable: ${description}"
  echo "# Generated for namespace=${ENDOR_NAMESPACE} fqdn=${FQDN}."
  echo "# Do not edit — regenerate with generate.sh."
  echo "# Usage: $( basename "$output" ) [--dry-run]"
  echo ""
  echo "set -euo pipefail"
  echo ""
  echo "# ── Common functions (inlined from lib/common.sh) ────────────────────────────"
  inline_common
  echo "# ─────────────────────────────────────────────────────────────────────────────"
  echo ""
  arg_parsing_block
  echo ""
  user_detection_block
  echo ""
}

# ── VS Code re-apply watcher payload ──────────────────────────────────────────
# VS Code replaces product.json on every update, so a watcher re-applies the
# patch. The watcher needs a script at a stable path; copying "$0" is not an
# option because MDM tools routinely pipe scripts to bash or exec them from an
# already-unlinked temp file. Instead the repatch script is generated here, then
# base64'd into the installer, which decodes it next to the sidecar state.
#
# It deliberately re-uses neither credentials_block nor user_detection_block: the
# watcher can fire from launchd at boot with no console user, and detect_console_user
# exits 1 in that case. The already-rendered URL and home are read back from the
# 0600 root-owned sidecar state instead, so nothing has to be recomputed.

# repatch_prelude — stands in for arg parsing, user detection and credentials.
repatch_prelude() {
  cat << 'REPATCHBLOCK'
DRY_RUN=0
_ENDOR_WARNED=0
VSCODE_WATCHER=0
_ENDOR_VSCODE_MODE=repatch

ENDOR_VSCODE_GALLERY_URL="$(vscode_state_get gallery_url 2>/dev/null || true)"
USER_HOME="$(vscode_state_get user_home 2>/dev/null || true)"

if [[ -z "$ENDOR_VSCODE_GALLERY_URL" ]]; then
  echo "[endor-vscode] ERROR: no gallery_url in sidecar state — cannot re-apply." >&2
  echo "[endor-vscode]        Re-run endor-vscode.sh (or endor-all.sh) to reinitialise." >&2
  exit 1
fi
REPATCHBLOCK
}

# build_repatch_script <output>
build_repatch_script() {
  local output="$1"
  {
    echo "#!/usr/bin/env bash"
    echo "# MDM-deployable: re-applies the Endor VS Code gallery patch to product.json."
    echo "# Installed by endor-vscode.sh and run by launchd/systemd/cron after VS Code"
    echo "# updates replace product.json. Not intended to be run by hand."
    echo "# Generated for namespace=${ENDOR_NAMESPACE} fqdn=${FQDN}."
    echo "# Do not edit — regenerate with generate.sh."
    echo ""
    echo "set -euo pipefail"
    echo ""
    echo "# ── Common functions (inlined from lib/common.sh) ────────────────────────────"
    inline_common
    echo "# ─────────────────────────────────────────────────────────────────────────────"
    echo ""
    repatch_prelude
    echo ""
    emit_block_assignment "VSCODE_GALLERY_BLOCK" "$SHARED_BLOCKS_DIR/vscodegallery.txt"
    echo ""
    substitute < "$TMPL_DIR/vscode.sh"
    echo ""
    script_footer
  } > "$output"

  chmod 700 "$output"
}

# emit_repatch_payload <repatch_script>
# Emits the base64 payload assignment the installer decodes to a stable path.
emit_repatch_payload() {
  echo "# ── VS Code update-watcher payload (endor-vscode-repatch.sh) ────────────────"
  echo "_ENDOR_VSCODE_REPATCH_B64=\$(cat <<'ENDOR_VSCODE_REPATCH_B64'"
  endor_b64_file "$1"
  echo "ENDOR_VSCODE_REPATCH_B64"
  echo ")"
  echo "# ─────────────────────────────────────────────────────────────────────────────"
  echo ""
}

# endor_b64_file <file> — base64, no line wrapping (GNU wraps at 76 by default).
endor_b64_file() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w0 < "$1"
  else
    base64 < "$1" | tr -d '\n'
  fi
  echo ""
}

# build_script <template> <output> <description> [extra_emitter] [no_envsh]
# <extra_emitter> runs after the block assignments, before the ecosystem template
#   — used to inject the VS Code watcher payload.
# <no_envsh> set to 1 skips the env.sh / shell-rc setup. VS Code reads no ENDOR_*
#   env vars (its credential is baked into product.json), so writing env.sh and
#   sourcing it from the user's .zshrc would be a side effect with no purpose.
build_script() {
  local template="$1"
  local output="$2"
  local description="$3"
  local extra_emitter="${4:-}"
  local no_envsh="${5:-0}"

  {
    script_header "$output" "$description"
    credentials_block
    echo ""
    emit_all_blocks
    [[ -n "$extra_emitter" ]] && "$extra_emitter"
    if [[ "$no_envsh" != "1" ]]; then
      echo "# ════════════════════════════════════════════════════════════════════════════"
      echo "# Env setup"
      echo "# ════════════════════════════════════════════════════════════════════════════"
      substitute < "$TMPL_DIR/envsh.sh"
      echo ""
    fi
    substitute < "$template"
    echo ""
    script_footer
  } > "$output"

  chmod 700 "$output"
}

# build_remove_script <output>
# Remove script has no block content to write — skips emit_all_blocks and env setup.
build_remove_script() {
  local output="$1"

  {
    script_header "$output" "Removes Endor Package Firewall configuration from all managed config files."
    substitute < "$TMPL_DIR/remove.sh"
  } > "$output"

  chmod 700 "$output"
}

# ─── Generate per-ecosystem install scripts ────────────────────────────────────
build_script \
  "$TMPL_DIR/js.sh" \
  "$OUT_DIR/endor-js.sh" \
  "Configures JavaScript package managers (npm, pnpm, yarn, bun) for Endor Package Firewall."

build_script \
  "$TMPL_DIR/python.sh" \
  "$OUT_DIR/endor-python.sh" \
  "Configures Python package managers (pip, uv, poetry) for Endor Package Firewall."

build_script \
  "$TMPL_DIR/go.sh" \
  "$OUT_DIR/endor-go.sh" \
  "Configures Go modules (GOPROXY) for Endor Package Firewall."

build_script \
  "$TMPL_DIR/maven.sh" \
  "$OUT_DIR/endor-maven.sh" \
  "Configures Maven (~/.m2/settings.xml) for Endor Package Firewall."

# The repatch script must exist before anything that embeds it.
build_repatch_script "$OUT_DIR/endor-vscode-repatch.sh"
REPATCH_SCRIPT="$OUT_DIR/endor-vscode-repatch.sh"
emit_vscode_repatch_payload() { emit_repatch_payload "$REPATCH_SCRIPT"; }

build_script \
  "$TMPL_DIR/vscode.sh" \
  "$OUT_DIR/endor-vscode.sh" \
  "Configures VS Code (product.json extension gallery) for Endor Package Firewall." \
  emit_vscode_repatch_payload \
  1

# ─── Generate remove script ───────────────────────────────────────────────────
build_remove_script "$OUT_DIR/endor-remove.sh"

# ─── Generate combined all.sh ─────────────────────────────────────────────────
# VS Code is deliberately NOT part of endor-all. It is the only ecosystem that
# writes inside an application bundle (which breaks codesign verification and, on
# macOS Ventura+, needs the App Management TCC grant) and the only one that
# installs a persistent daemon. Folding it in here would silently widen the blast
# radius of every existing endor-all deployment on the next regeneration.
# Deploy endor-vscode.sh alongside endor-all.sh instead — see the READMEs.
{
  script_header "$OUT_DIR/endor-all.sh" \
    "Configures all package managers for Endor Package Firewall. Covers: npm · pnpm · yarn classic · yarn 2+ · bun · pip · uv · poetry · go · maven"
  credentials_block
  echo ""
  emit_all_blocks
  echo "# ════════════════════════════════════════════════════════════════════════════"
  echo "# Env setup"
  echo "# ════════════════════════════════════════════════════════════════════════════"
  substitute < "$TMPL_DIR/envsh.sh"
  echo ""
  echo "# ════════════════════════════════════════════════════════════════════════════"
  echo "# JavaScript"
  echo "# ════════════════════════════════════════════════════════════════════════════"
  substitute < "$TMPL_DIR/js.sh"
  echo ""
  echo "# ════════════════════════════════════════════════════════════════════════════"
  echo "# Python"
  echo "# ════════════════════════════════════════════════════════════════════════════"
  substitute < "$TMPL_DIR/python.sh"
  echo ""
  echo "# ════════════════════════════════════════════════════════════════════════════"
  echo "# Go"
  echo "# ════════════════════════════════════════════════════════════════════════════"
  substitute < "$TMPL_DIR/go.sh"
  echo ""
  echo "# ════════════════════════════════════════════════════════════════════════════"
  echo "# Maven"
  echo "# ════════════════════════════════════════════════════════════════════════════"
  substitute < "$TMPL_DIR/maven.sh"
  echo ""
  echo "echo \"\""
  echo "echo \"[endor] ✓ All package managers configured for ${ENDOR_NAMESPACE}.\""
  echo ""
  script_footer
} > "$OUT_DIR/endor-all.sh"
chmod 700 "$OUT_DIR/endor-all.sh"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "✓  Generated → $OUT_DIR"
echo ""
printf "   %-24s  %s\n" "endor-js.sh"     "npm · pnpm · yarn classic · yarn 2+ · bun"
printf "   %-24s  %s\n" "endor-python.sh" "pip · uv · poetry"
printf "   %-24s  %s\n" "endor-go.sh"     "go modules (GOPROXY)"
printf "   %-24s  %s\n" "endor-maven.sh"  "maven (~/.m2/settings.xml)"
printf "   %-24s  %s\n" "endor-all.sh"    "all of the above (single-script deploy)"
printf "   %-24s  %s\n" "endor-vscode.sh" "VS Code + Insiders extension gallery (deploy alongside endor-all.sh)"
printf "   %-24s  %s\n" "endor-remove.sh" "offboarding — strips all Endor config"
echo ""
printf "   %-24s  %s\n" "endor-vscode-repatch.sh" "installed by endor-vscode.sh; shown so you can read it"
echo ""
echo "   All scripts accept --dry-run to preview changes without writing anything."
echo "   endor-vscode.sh also accepts --no-vscode-watcher (not recommended — see below)."
echo "   Upload to your MDM tool. Each script is self-contained and idempotent."
echo ""
echo "   ⚠  VS Code prerequisites — endor-vscode.sh is NOT included in endor-all.sh:"
echo "      · macOS Ventura+ requires the App Management (SystemPolicyAppBundles) TCC"
echo "        grant for your MDM agent, via a PPPC profile. root is NOT exempt."
echo "      · The gallery token lands in world-readable product.json (0644) — VS Code"
echo "        offers no indirection. Use a dedicated, separately revocable API key."
echo "      · Keep *.vsassets.io / *.vscode-unpkg.net reachable: extension downloads"
echo "        still come from Microsoft's CDN by design."
echo "      · codesign --verify will report the bundle as modified. Expected. Do not re-sign."
echo ""
echo "   To customise: edit shared/blocks/*.txt (shared config content)"
echo "                 or shared/blocks/envsh.txt (bash env var block)"
echo "                 or templates/*.sh (orchestration logic)"
echo ""
echo "   Re-running overwrites the same output directory."
