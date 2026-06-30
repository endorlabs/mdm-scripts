# templates/envsh.sh
# Writes ~/.config/endor/env.sh — the single credential source for all
# env-var-based tools (npm, yarn 2+, maven, poetry).
# Then adds a one-line source directive to existing shell profiles.
#
# The values come from templates/attribution.sh, which computes the attributed
# Basic-auth username (<console-user>@<machine>) at install time. They are written
# here as resolved literals so the file is a plain set of exports — no per-shell
# computation on every startup.
#
# pip / uv / go are intentionally NOT sourced from here — those tools cannot expand
# ${VAR}, so their config files get the literal value written by python.sh / go.sh.

echo ""
echo "[endor] ── env.sh setup ─────────────────────────────────────────────────────"

ENDOR_ENV_SH="$USER_HOME/.config/endor/env.sh"

ENVSH_BLOCK=$(cat <<EOF
export ENDOR_API_KEY_ID="$ENDOR_API_KEY_ID"
export ENDOR_API_SECRET="$ENDOR_API_SECRET"
export ENDOR_ATTR_USER="$ENDOR_ATTR_USER"
export ENDOR_AUTH_B64="$ENDOR_AUTH_B64"
export ENDOR_API_SECRET_B64="$ENDOR_API_SECRET_B64"
export ENDOR_NPM_REGISTRY_URL="$ENDOR_NPM_REGISTRY_URL"
export ENDOR_PYPI_URL="$ENDOR_PYPI_URL"
export ENDOR_GO_PROXY_URL="$ENDOR_GO_PROXY_URL"
export POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME="$ENDOR_ATTR_USER"
export POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD="$ENDOR_API_SECRET"
EOF
)

upsert_block \
  "$ENDOR_ENV_SH" \
  "$ENVSH_BLOCK" \
  "$CONSOLE_USER" \
  "$USER_GROUP"

echo "[endor] env.sh         → $ENDOR_ENV_SH"

SOURCE_BLOCK='[ -f "$HOME/.config/endor/env.sh" ] && source "$HOME/.config/endor/env.sh"'

_PROFILE_UPDATED=0
for _profile in \
  "$USER_HOME/.zshrc" \
  "$USER_HOME/.bash_profile" \
  "$USER_HOME/.bashrc"; do
  [[ -f "$_profile" ]] || continue

  upsert_block \
    "$_profile" \
    "$SOURCE_BLOCK" \
    "$CONSOLE_USER" \
    "$USER_GROUP"

  echo "[endor] sourced from   → $_profile"
  _PROFILE_UPDATED=1
done

if [[ $_PROFILE_UPDATED -eq 0 ]]; then
  echo "" >&2
  echo "[endor] WARNING: no shell profile found (.zshrc / .bash_profile / .bashrc)." >&2
  echo "[endor]   Add this line manually to your shell profile:" >&2
  echo "[endor]     [ -f \"\$HOME/.config/endor/env.sh\" ] && source \"\$HOME/.config/endor/env.sh\"" >&2
  _ENDOR_WARNED=1
fi

unset _profile _PROFILE_UPDATED
echo "[endor] ✓ env.sh done"
