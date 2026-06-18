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

# ─── Resolve FQDN ─────────────────────────────────────────────────────────────
FQDN="${ENDOR_FQDN:-https://factory.endorlabs.com}"

# ─── Compute derived values ────────────────────────────────────────────────────
FQDN_HOST="${FQDN#https://}"
FQDN_HOST="${FQDN_HOST#http://}"
TRUSTED_HOST="${FQDN_HOST%%:*}"

NPM_REGISTRY_URL="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/npm/"
NPM_REGISTRY_HOST="${FQDN_HOST}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/npm/"
NPM_AUTH_B64=$(printf '%s' "${ENDOR_API_KEY_ID}:${ENDOR_API_SECRET}" | base64 | tr -d '\n')
API_SECRET_B64=$(printf '%s' "${ENDOR_API_SECRET}" | base64 | tr -d '\n')

PYPI_URL="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/pypi/simple/"
PIP_INDEX_URL="https://${ENDOR_API_KEY_ID}:${ENDOR_API_SECRET}@${FQDN_HOST}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/pypi/simple/"

GO_PROXY_URL="https://${ENDOR_API_KEY_ID}:${ENDOR_API_SECRET}@${FQDN_HOST}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/go/,direct"
MAVEN_REGISTRY_URL="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/maven/"

# ─── Output directory ─────────────────────────────────────────────────────────
OUT_DIR="${SCRIPT_DIR}/out/${ENDOR_NAMESPACE}"
mkdir -p "$OUT_DIR"

# ─── Template substitution ────────────────────────────────────────────────────
substitute() {
  sed \
    -e "s|{{NAMESPACE}}|${ENDOR_NAMESPACE}|g" \
    -e "s|{{API_KEY_ID}}|${ENDOR_API_KEY_ID}|g" \
    -e "s|{{API_SECRET}}|${ENDOR_API_SECRET}|g" \
    -e "s|{{FQDN}}|${FQDN}|g" \
    -e "s|{{NPM_REGISTRY_URL}}|${NPM_REGISTRY_URL}|g" \
    -e "s|{{NPM_REGISTRY_HOST}}|${NPM_REGISTRY_HOST}|g" \
    -e "s|{{NPM_AUTH_B64}}|${NPM_AUTH_B64}|g" \
    -e "s|{{API_SECRET_B64}}|${API_SECRET_B64}|g" \
    -e "s|{{PYPI_URL}}|${PYPI_URL}|g" \
    -e "s|{{PIP_INDEX_URL}}|${PIP_INDEX_URL}|g" \
    -e "s|{{ENDOR_PYPI_URL}}|${PIP_INDEX_URL}|g" \
    -e "s|{{TRUSTED_HOST}}|${TRUSTED_HOST}|g" \
    -e "s|{{GO_PROXY_URL}}|${GO_PROXY_URL}|g" \
    -e "s|{{MAVEN_REGISTRY_URL}}|${MAVEN_REGISTRY_URL}|g"
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

# emit_all_blocks
# Emits all block variable assignments into the generated script.
# Edit shared/blocks/*.txt to change shared config content.
# Edit templates/envsh.txt to change the bash-only env var block.
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
  echo "# ─────────────────────────────────────────────────────────────────────────────"
  echo ""
}

arg_parsing_block() {
  cat << 'ARGBLOCK'
# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=0
_ENDOR_WARNED=0
for _arg in "$@"; do
  case "$_arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "[endor] Unknown argument: $_arg  (supported: --dry-run)" >&2; exit 1 ;;
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

# build_script <template> <output> <description>
build_script() {
  local template="$1"
  local output="$2"
  local description="$3"

  {
    script_header "$output" "$description"
    emit_all_blocks
    echo "# ════════════════════════════════════════════════════════════════════════════"
    echo "# Env setup"
    echo "# ════════════════════════════════════════════════════════════════════════════"
    substitute < "$TMPL_DIR/envsh.sh"
    echo ""
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

# ─── Generate remove script ───────────────────────────────────────────────────
build_remove_script "$OUT_DIR/endor-remove.sh"

# ─── Generate combined all.sh ─────────────────────────────────────────────────
{
  script_header "$OUT_DIR/endor-all.sh" \
    "Configures all package managers for Endor Package Firewall. Covers: npm · pnpm · yarn classic · yarn 2+ · bun · pip · uv · poetry · go · maven"
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
printf "   %-24s  %s\n" "endor-remove.sh" "offboarding — strips all Endor config"
echo ""
echo "   All scripts accept --dry-run to preview changes without writing anything."
echo "   Upload to your MDM tool. Each script is self-contained and idempotent."
echo ""
echo "   To customise: edit shared/blocks/*.txt (shared config content)"
echo "                 or templates/envsh.txt (bash env var block)"
echo "                 or templates/*.sh (orchestration logic)"
echo ""
echo "   Re-running overwrites the same output directory."
