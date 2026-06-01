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
# Overrides:
#   overrides/blocks/<name>.txt  replaces a config block (e.g. overrides/blocks/npmrc.txt)
#   overrides/<name>.sh          replaces a full template  (e.g. overrides/js.sh)
#   Override files go through the same {{PLACEHOLDER}} substitution as defaults.
#
# Output (out/<namespace>/):
#   endor-js.sh       — JavaScript: npm · pnpm · yarn classic · yarn 2+ · bun
#   endor-python.sh   — Python:     pip · uv · poetry
#   endor-all.sh      — All of the above (single-script MDM deploy)
#   endor-remove.sh   — Offboarding: strips Endor config from all files
#
# All scripts accept --dry-run: prints what would change without writing anything.
# All scripts are idempotent — safe to re-push on MDM check-in cycles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
TMPL_DIR="$SCRIPT_DIR/templates"
BLOCKS_DIR="$SCRIPT_DIR/templates/blocks"
OVERRIDES_DIR="$SCRIPT_DIR/overrides"

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

PYPI_URL="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/pypi/simple/"
PIP_INDEX_URL="https://${ENDOR_API_KEY_ID}:${ENDOR_API_SECRET}@${FQDN_HOST}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/pypi/simple/"

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
    -e "s|{{PYPI_URL}}|${PYPI_URL}|g" \
    -e "s|{{PIP_INDEX_URL}}|${PIP_INDEX_URL}|g" \
    -e "s|{{TRUSTED_HOST}}|${TRUSTED_HOST}|g"
}

# inline_common
inline_common() {
  grep -v '^# ' "$LIB_DIR/common.sh" | sed '/^[[:space:]]*$/d' \
    || cat "$LIB_DIR/common.sh"
}

# resolve_template <name>
# Returns overrides/<name> if it exists, else templates/<name>.
resolve_template() {
  local name="$1"
  local override="$OVERRIDES_DIR/$name"
  if [[ -f "$override" ]]; then
    echo "[override] using overrides/${name}" >&2
    echo "$override"
  else
    echo "$TMPL_DIR/$name"
  fi
}

# resolve_block <name>
# Returns overrides/blocks/<name> if it exists, else templates/blocks/<name>.
resolve_block() {
  local name="$1"
  local override="$OVERRIDES_DIR/blocks/$name"
  if [[ -f "$override" ]]; then
    echo "[override] using overrides/blocks/${name}" >&2
    echo "$override"
  else
    echo "$BLOCKS_DIR/$name"
  fi
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
  echo "${delim}"
  echo ")"
}

# emit_all_blocks
# Emits all block variable assignments into the generated script.
# All block vars are always emitted — templates use whichever they need.
emit_all_blocks() {
  echo "# ── Block content (from templates/blocks/ — edit to customise) ───────────────"
  emit_block_assignment "ENVSH_BLOCK"  "$(resolve_block envsh.txt)"
  emit_block_assignment "NPMRC_BLOCK"  "$(resolve_block npmrc.txt)"
  emit_block_assignment "YARNRC_BLOCK" "$(resolve_block yarnrc.txt)"
  emit_block_assignment "PIP_BLOCK"    "$(resolve_block pipconf.txt)"
  emit_block_assignment "UV_BLOCK"     "$(resolve_block uvtoml.txt)"
  echo "# ─────────────────────────────────────────────────────────────────────────────"
  echo ""
}

arg_parsing_block() {
  cat << 'ARGBLOCK'
# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=0
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
  } > "$output"

  chmod 700 "$output"
}

# build_remove_script <output>
# Remove script has no block content to write — skips emit_all_blocks and env setup.
build_remove_script() {
  local output="$1"
  local template
  template="$(resolve_template remove.sh)"

  {
    script_header "$output" "Removes Endor Package Firewall configuration from all managed config files."
    substitute < "$template"
  } > "$output"

  chmod 700 "$output"
}

# ─── Generate per-ecosystem install scripts ────────────────────────────────────
build_script \
  "$(resolve_template js.sh)" \
  "$OUT_DIR/endor-js.sh" \
  "Configures JavaScript package managers (npm, pnpm, yarn, bun) for Endor Package Firewall."

build_script \
  "$(resolve_template python.sh)" \
  "$OUT_DIR/endor-python.sh" \
  "Configures Python package managers (pip, uv, poetry) for Endor Package Firewall."

# ─── Generate remove script ───────────────────────────────────────────────────
build_remove_script "$OUT_DIR/endor-remove.sh"

# ─── Generate combined all.sh ─────────────────────────────────────────────────
{
  script_header "$OUT_DIR/endor-all.sh" \
    "Configures all package managers for Endor Package Firewall. Covers: npm · pnpm · yarn classic · yarn 2+ · bun · pip · uv · poetry"
  emit_all_blocks
  echo "# ════════════════════════════════════════════════════════════════════════════"
  echo "# Env setup"
  echo "# ════════════════════════════════════════════════════════════════════════════"
  substitute < "$TMPL_DIR/envsh.sh"
  echo ""
  echo "# ════════════════════════════════════════════════════════════════════════════"
  echo "# JavaScript"
  echo "# ════════════════════════════════════════════════════════════════════════════"
  substitute < "$(resolve_template js.sh)"
  echo ""
  echo "# ════════════════════════════════════════════════════════════════════════════"
  echo "# Python"
  echo "# ════════════════════════════════════════════════════════════════════════════"
  substitute < "$(resolve_template python.sh)"
  echo ""
  echo "echo \"\""
  echo "echo \"[endor] ✓ All package managers configured for ${ENDOR_NAMESPACE}.\""
} > "$OUT_DIR/endor-all.sh"
chmod 700 "$OUT_DIR/endor-all.sh"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "✓  Generated → $OUT_DIR"
echo ""
printf "   %-24s  %s\n" "endor-js.sh"     "npm · pnpm · yarn classic · yarn 2+ · bun"
printf "   %-24s  %s\n" "endor-python.sh" "pip · uv · poetry"
printf "   %-24s  %s\n" "endor-all.sh"    "all of the above (single-script deploy)"
printf "   %-24s  %s\n" "endor-remove.sh" "offboarding — strips all Endor config"
echo ""
echo "   All scripts accept --dry-run to preview changes without writing anything."
echo "   Upload to your MDM tool. Each script is self-contained and idempotent."
echo ""
_HAS_OVERRIDES=0
if [[ -d "$OVERRIDES_DIR" ]]; then
  if compgen -G "$OVERRIDES_DIR/blocks/*.txt" > /dev/null 2>&1; then
    _HAS_OVERRIDES=1
    echo "   Active block overrides (from overrides/blocks/):"
    for _f in "$OVERRIDES_DIR"/blocks/*.txt; do
      printf "     %s\n" "$(basename "$_f")"
    done
    unset _f
  fi
  if compgen -G "$OVERRIDES_DIR/*.sh" > /dev/null 2>&1; then
    _HAS_OVERRIDES=1
    echo "   Active template overrides (from overrides/):"
    for _f in "$OVERRIDES_DIR"/*.sh; do
      printf "     %s\n" "$(basename "$_f")"
    done
    unset _f
  fi
fi
[[ $_HAS_OVERRIDES -eq 0 ]] || echo ""
unset _HAS_OVERRIDES
echo "   Re-running this script overwrites the same output directory."
