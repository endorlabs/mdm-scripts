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
#   ENDOR_NAMESPACE    Required. Your Endor namespace (e.g. my-team).
#                      Letters, digits, dots, hyphens, underscores only.
#   ENDOR_API_KEY_ID   Required. API key ID (Basic Auth username)
#   ENDOR_API_SECRET   Required. API secret  (Basic Auth password)
#   ENDOR_FQDN         Optional. Base URL — https:// + host, optional numeric
#                      port, no path, no userinfo, no query/fragment.
#                      http:// is rejected: both hosted tenants are https, and
#                      the generated scripts send Basic Auth credentials.
#                      US (default): https://factory.endorlabs.com
#                      EU:           https://factory.eu.endorlabs.com
#
# To customise config blocks, edit shared/blocks/*.txt directly.
# To customise orchestration logic, edit templates/*.sh directly.
#
# Output (out/<namespace>/):
#   endor-js.sh       — JavaScript: npm · pnpm · yarn classic · yarn 2+ · bun
#   endor-python.sh   — Python:     pip · uv · poetry
#   endor-go.sh       — Go:         go modules (GOPROXY → ~/.config/go/env)
#   endor-maven.sh    — Maven:      Maven (settings.xml → ~/.m2/settings.xml)
#   endor-nuget.sh    — .NET:       NuGet / dotnet (NuGet.Config → ~/.nuget/NuGet/NuGet.Config)
#   endor-vscode.sh   — VS Code:    extension gallery firewall + update watcher
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

# ─── Input validation ─────────────────────────────────────────────────────────
# Every guard below turns on a bracket range ([A-Za-z0-9.-]) or a character class
# ([:print:]), and bash resolves both against the current locale. Outside the C
# locale a range is a collation-order span, not an ASCII span: 'é' and Cyrillic
# 'а' sort between 'a' and 'z' and therefore match [A-Za-z]. bash 5.0+ turns
# `globasciiranges` on by default, which pins ranges back to ASCII; bash 3.2 has
# no such option, and 3.2.57 is the stock /bin/bash on macOS — what
# `#!/usr/bin/env bash` resolves to on an admin Mac, and what GitHub's macos
# runners ship. macOS is the primary target for this tooling, so an unforced
# guard accepts https://café.endorlabs.com under en_US.UTF-8 and bakes that host
# into all seven generated artifacts.
#
# Each guard therefore runs inside a function that declares `local LC_ALL=C`.
# bash calls setlocale() on that assignment and restores the previous value —
# including the "was unset" case — when the function returns, so the C locale
# covers the guard and any helper it calls, while the generation code further
# down (base64, sed, tr, the emitted bytes) still runs under the operator's
# locale, unchanged.
#
# Two alternatives do not work here. `shopt -s globasciiranges` does not exist in
# bash 3.2. A `LC_ALL=C funcname` command prefix does not work either: bash 3.2
# sets the variable for the call but does not call setlocale() for a temporary
# assignment, so the range still collates — verified on 3.2.57. Only a real
# assignment takes effect on 3.2.

# Reject namespace characters that would escape OUT_DIR or inject shell syntax
# into the generated scripts. Real Endor namespaces are letters, digits, dots,
# hyphens and underscores (e.g. lab.team_x, my-team.2_x). '.' and '..' pass the
# charset check but still break OUT_DIR, so they are rejected explicitly.
validate_namespace() {
  local LC_ALL=C ns_shown
  case "$1" in
    ""|.|..|*[!A-Za-z0-9._-]*)
      ns_shown="${1//[![:print:]]/?}"
      echo "ERROR: ENDOR_NAMESPACE must be letters, digits, dots, hyphens or underscores" >&2
      echo "       (e.g. my-team, lab.team_x) — and not '.' or '..'." >&2
      echo "       got: ${ns_shown}" >&2
      if [[ "$ns_shown" != "$1" ]]; then
        echo "       (non-ASCII or non-printable characters shown as '?')" >&2
      fi
      exit 1 ;;
  esac
}
validate_namespace "$ENDOR_NAMESPACE"

# Reject credential characters that would corrupt generated scripts/URLs.
# Same locale hazard as the guards either side of it: under en_US.UTF-8 on bash
# 3.2 an unforced range accepts a non-ASCII secret and interpolates it into the
# sed replacements and the quoted shell strings of five of the seven artifacts,
# and into the base64 VS Code service token of a sixth. The offending value is
# deliberately not echoed back — it is a credential.
validate_credentials() {
  local LC_ALL=C
  case "$1" in
    *[!A-Za-z0-9+/=_.-]*)
      echo "ERROR: ENDOR_API_KEY_ID / ENDOR_API_SECRET contain unsupported characters" >&2
      exit 1 ;;
  esac
}
validate_credentials "${ENDOR_API_KEY_ID}${ENDOR_API_SECRET}"

# ─── Resolve FQDN ─────────────────────────────────────────────────────────────
FQDN="${ENDOR_FQDN:-https://factory.endorlabs.com}"

# Trim trailing slashes so ${FQDN}/v1/... never doubles up — matches TrimEnd('/')
# in generate.ps1.
while [[ "$FQDN" == */ ]]; do FQDN="${FQDN%/}"; done

# Accept only https:// + host[:port]. This is an allowlist, not a denylist: the
# value is interpolated into sed replacements and into shell strings inside
# scripts pushed fleet-wide, so every character outside [A-Za-z0-9.-] (plus one
# optional numeric port) is rejected rather than escaped. Ports are allowed —
# TRUSTED_HOST strips them below. Mirrors the regex in generate.ps1.
#
# http:// is rejected, not accepted-and-downgraded. Both hosted base URLs are
# https; the generated config carries Basic Auth credentials on every request,
# so plaintext transport is not something this generator should bless; and no
# working setup is lost, because credentials_block() below hardcodes https:// in
# ENDOR_PYPI_URL (pip and uv) and ENDOR_GO_PROXY_URL — an http:// value only ever
# produced a half-broken fleet deploy: npm/maven/VS Code on http, pip/uv/go on
# https, and exit 0 to tell the admin it worked.
#
# Called only from validate_fqdn below, so it inherits that function's
# `local LC_ALL=C` and renders under the C locale — see the note above.
fqdn_error() {
  # Render the offending value with every byte outside printable ASCII replaced
  # by '?'. Without this a CRLF .env prints a 'got:' line byte-identical to the
  # correct value, an ANSI escape in the value repaints the operator's terminal,
  # and a Cyrillic homoglyph host (fаctory, U+0430) prints a line visually
  # identical to the real one. ENDOR_FQDN may be unset under 'set -u', and bash
  # cannot combine ${v-default} with ${v//pattern/repl} in one expansion, so
  # default into a local first.
  local raw shown
  raw="${ENDOR_FQDN-}"
  shown="${raw//[![:print:]]/?}"
  echo "ERROR: ENDOR_FQDN must be https:// + host[:port], e.g. https://factory.endorlabs.com (US)" >&2
  echo "       or https://factory.eu.endorlabs.com (EU) — letters, digits, dots, hyphens only." >&2
  echo "       http:// is not accepted. got: ${shown}" >&2
  if [[ "$shown" != "$raw" ]]; then
    echo "       (non-ASCII or non-printable characters shown as '?')" >&2
  fi
  exit 1
}
validate_fqdn() {
  local LC_ALL=C authority
  case "$1" in https://*) ;; *) fqdn_error ;; esac
  authority="${1#*://}"
  case "$authority" in
    *:*)
      case "${authority##*:}" in ""|*[!0-9]*) fqdn_error ;; esac
      authority="${authority%:*}" ;;
  esac
  case "$authority" in ""|*[!A-Za-z0-9.-]*) fqdn_error ;; esac
}
validate_fqdn "$FQDN"

# ─── Compute derived values ────────────────────────────────────────────────────
# Only machine-independent values are derived here. Attribution values
# (<console-user>@<machine>) are computed at install time — see credentials_block.
FQDN_HOST="${FQDN#https://}"
TRUSTED_HOST="${FQDN_HOST%%:*}"

NPM_REGISTRY_URL="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/npm/"
NPM_REGISTRY_HOST="${FQDN_HOST}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/npm/"
PYPI_URL="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/pypi/simple/"
MAVEN_REGISTRY_URL="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/maven/"
NUGET_SOURCE_URL="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/nuget/v3/index.json"
API_SECRET_B64=$(printf '%s' "${ENDOR_API_SECRET}" | base64 | tr -d '\n')
VSCODE_TOKEN=$(printf '%s:%s' "${ENDOR_API_KEY_ID}" "${ENDOR_API_SECRET}" \
  | base64 | tr -d '\n=' | tr '+/' '-_')
VSCODE_SERVICE_URL="${FQDN}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/vscode/_ak/${VSCODE_TOKEN}"

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
    -e "s|{{NUGET_SOURCE_URL}}|${NUGET_SOURCE_URL}|g" \
    -e "s|{{VSCODE_SERVICE_URL}}|${VSCODE_SERVICE_URL}|g"
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
  emit_block_assignment "NUGET_SOURCES_BLOCK" "$SHARED_BLOCKS_DIR/nugetconfig_sources.txt"
  emit_block_assignment "NUGET_CREDENTIALS_BLOCK" "$SHARED_BLOCKS_DIR/nugetconfig_credentials.txt"
  emit_block_assignment "NUGET_SOURCEMAPPING_BLOCK" "$SHARED_BLOCKS_DIR/nugetconfig_sourcemapping.txt"
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

# system_script_header <output> <description>
# Used by machine-level integrations that do not require an interactive user.
system_script_header() {
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
  arg_parsing_block
  echo ""
}

# build_script <template> <output> <description>
build_script() {
  local template="$1"
  local output="$2"
  local description="$3"

  {
    script_header "$output" "$description"
    credentials_block
    echo ""
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

# build_system_script <template> <output> <description>
build_system_script() {
  local template="$1"
  local output="$2"
  local description="$3"

  {
    system_script_header "$output" "$description"
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

build_script \
  "$TMPL_DIR/nuget.sh" \
  "$OUT_DIR/endor-nuget.sh" \
  "Configures NuGet / .NET (~/.nuget/NuGet/NuGet.Config) for Endor Package Firewall."

build_system_script \
  "$TMPL_DIR/vscode.sh" \
  "$OUT_DIR/endor-vscode.sh" \
  "Configures Microsoft VS Code Stable extensions for Endor Package Firewall and installs update remediation."

# ─── Generate remove script ───────────────────────────────────────────────────
build_remove_script "$OUT_DIR/endor-remove.sh"

# ─── Generate combined all.sh ─────────────────────────────────────────────────
{
  script_header "$OUT_DIR/endor-all.sh" \
    "Configures all package managers for Endor Package Firewall. Covers: npm · pnpm · yarn classic · yarn 2+ · bun · pip · uv · poetry · go · maven · nuget · vscode"
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
  echo "# ════════════════════════════════════════════════════════════════════════════"
  echo "# NuGet / .NET"
  echo "# ════════════════════════════════════════════════════════════════════════════"
  substitute < "$TMPL_DIR/nuget.sh"
  echo ""
  echo "# ════════════════════════════════════════════════════════════════════════════"
  echo "# VS Code extensions"
  echo "# ════════════════════════════════════════════════════════════════════════════"
  substitute < "$TMPL_DIR/vscode.sh"
  echo ""
  echo "echo \"\""
  echo "echo \"[endor] ✓ All package managers and VS Code configured for ${ENDOR_NAMESPACE}.\""
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
printf "   %-24s  %s\n" "endor-nuget.sh"  "nuget / dotnet (~/.nuget/NuGet/NuGet.Config)"
printf "   %-24s  %s\n" "endor-vscode.sh" "VS Code extension gallery + update remediation"
printf "   %-24s  %s\n" "endor-all.sh"    "all of the above (single-script deploy)"
printf "   %-24s  %s\n" "endor-remove.sh" "offboarding — strips all Endor config"
echo ""
echo "   All scripts accept --dry-run to preview changes without writing anything."
echo "   Upload to your MDM tool. Each script is self-contained and idempotent."
echo ""
echo "   To customise: edit shared/blocks/*.txt (shared config content)"
echo "                 or shared/blocks/envsh.txt (bash env var block)"
echo "                 or templates/*.sh (orchestration logic)"
echo ""
echo "   Re-running overwrites the same output directory."
