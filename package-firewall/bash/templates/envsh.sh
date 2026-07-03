# templates/envsh.sh
# Writes ~/.config/endor/env.sh — the single credential source for all
# env-var-based tools (npm, yarn 2+, maven, poetry).
# Then adds a one-line source directive to existing shell profiles.
#
# Block content comes from shared/blocks/envsh.txt. The attribution tokens
# ({{ATTR_USER}}, {{NPM_AUTH_B64}}, {{PIP_INDEX_URL}}, {{GO_PROXY_URL}}) are
# filled here at install time from the credentials block; a token filled by neither
# generate.sh nor this step triggers a warning and a non-zero exit.
#
# pip / uv / go don't read env.sh — they can't expand ${VAR}; python.sh/go.sh
# bake literal values instead.

echo ""
echo "[endor] ── env.sh setup ─────────────────────────────────────────────────────"

ENDOR_ENV_SH="$USER_HOME/.config/endor/env.sh"

# Fill the attribution-dependent tokens (values from the credentials block).
ENVSH_BLOCK=${ENVSH_BLOCK//'{{ATTR_USER}}'/$ENDOR_ATTR_USER}
ENVSH_BLOCK=${ENVSH_BLOCK//'{{NPM_AUTH_B64}}'/$ENDOR_AUTH_B64}
ENVSH_BLOCK=${ENVSH_BLOCK//'{{PIP_INDEX_URL}}'/$ENDOR_PYPI_URL}
ENVSH_BLOCK=${ENVSH_BLOCK//'{{GO_PROXY_URL}}'/$ENDOR_GO_PROXY_URL}

if [[ "$ENVSH_BLOCK" == *'{{'* ]]; then
  echo "[endor] WARNING: unresolved {{...}} token in env.sh block — a token in" >&2
  echo "[endor]          shared/blocks/envsh.txt has no fill in templates/envsh.sh." >&2
  _ENDOR_WARNED=1
fi

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
