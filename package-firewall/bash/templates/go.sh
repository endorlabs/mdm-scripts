# templates/go.sh
# Go ecosystem
#
# Config file written to the console user's go env file.
# The path is resolved via `go env GOENV` (varies by OS):
#   macOS  → ~/Library/Application Support/go/env
#   Linux  → ~/.config/go/env  (or $XDG_CONFIG_HOME/go/env)
#
# Block content is defined in shared/blocks/goenv.txt.
# Go env files do not support env var expansion, so the GOPROXY credential — which
# carries the per-machine attributed username and so only exists at install time —
# is baked in as a literal here: generate.sh leaves the {{GO_PROXY_URL}} token
# untouched and it is filled below, from the value computed in credentials.sh.
#
# The go env file takes lower precedence than the GOPROXY process env var, so
# project-level overrides (go env -w GOPROXY=... in a workspace) remain possible.
# Sentinel comment lines (# ...) are silently ignored by `go env` parsing.

echo ""
echo "[endor-go] ── Go package manager ───────────────────────────────────────────"

# Fill the attributed GOPROXY into the block content (go env can't expand env vars).
GO_BLOCK=${GO_BLOCK//'{{GO_PROXY_URL}}'/$ENDOR_GO_PROXY_URL}

# ── Resolve go env file path ──────────────────────────────────────────────────
# Run `go env GOENV` with the user's HOME so Go's os.UserConfigDir() returns
# the correct user-specific path (macOS: ~/Library/Application Support/go/env,
# Linux: ~/.config/go/env). Fall back to OS defaults if go is not installed.
_GO_ENV_FILE=""

for _go_bin in \
  /usr/local/go/bin/go \
  /opt/homebrew/bin/go \
  /opt/homebrew/opt/go/bin/go \
  /usr/local/bin/go \
  /usr/bin/go; do
  if [[ -x "$_go_bin" ]]; then
    _GO_ENV_FILE=$(HOME="$USER_HOME" GOENV="" "$_go_bin" env GOENV 2>/dev/null || true)
    break
  fi
done

if [[ -z "$_GO_ENV_FILE" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    _GO_ENV_FILE="$USER_HOME/Library/Application Support/go/env"
  else
    _GO_ENV_FILE="${XDG_CONFIG_HOME:-$USER_HOME/.config}/go/env"
  fi
  echo "[endor-go]   go binary not found — using OS default path"
fi
unset _go_bin

GO_ENV_FILE="$_GO_ENV_FILE"
unset _GO_ENV_FILE

# ── Write GOPROXY to go env file ──────────────────────────────────────────────
warn_if_key_conflict \
  "$GO_ENV_FILE" \
  "^GOPROXY=" \
  "GOPROXY"

upsert_block \
  "$GO_ENV_FILE" \
  "$GO_BLOCK" \
  "$CONSOLE_USER" \
  "$USER_GROUP"

echo "[endor-go] go env file     → $GO_ENV_FILE"
echo "[endor-go]   covers: go modules (all versions)"
echo "[endor-go]   GOPROXY: {{FQDN}}/v1/namespaces/{{NAMESPACE}}/firewall/go/ (with ,direct fallback)"
echo "[endor-go] ✓ Go done"
