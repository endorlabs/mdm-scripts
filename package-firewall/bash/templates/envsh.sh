# templates/envsh.sh
# Writes ~/.config/endor/env.sh — the single credential source for all
# env-var-based tools (npm, uv, yarn 2+, poetry; Go in future).
# Then adds a one-line source directive to existing shell profiles.
#
# Block content is defined in templates/blocks/envsh.txt.
# pip is intentionally excluded — pip.conf does not support env var expansion,
# so pip credentials are written as literal values in python.sh instead.

echo ""
echo "[endor] ── env.sh setup ─────────────────────────────────────────────────────"

ENDOR_ENV_SH="$USER_HOME/.config/endor/env.sh"

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
fi

unset _profile _PROFILE_UPDATED
echo "[endor] ✓ env.sh done"
