# templates/envsh.sh
# Writes ~/.config/endor/env.sh — the single credential source for all
# env-var-based tools (npm, yarn 2+, maven, poetry).
# Then adds a one-line source directive to shell profiles.
#
# Block content comes from shared/blocks/envsh.txt; attribution tokens are
# filled at install time. Leftover {{...}} tokens warn and exit non-zero.
# pip / uv / go don't read env.sh — their configs get baked literals instead.

echo ""
echo "[endor] ── env.sh setup ─────────────────────────────────────────────────────"

ENDOR_ENV_SH="$USER_HOME/.config/endor/env.sh"

# Fill the attribution-dependent tokens (values from the credentials block).
ENVSH_BLOCK=${ENVSH_BLOCK//'{{ATTR_USER}}'/"$ENDOR_ATTR_USER"}
ENVSH_BLOCK=${ENVSH_BLOCK//'{{NPM_AUTH_B64}}'/"$ENDOR_AUTH_B64"}

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

# Resolve the console user's login shell; MDM runs as root, so $SHELL is unreliable.
_OS=$(uname -s)
if [[ "$_OS" == "Darwin" ]]; then
  _USER_SHELL=$(dscl . -read "/Users/$CONSOLE_USER" UserShell 2>/dev/null \
    | awk '{print $2}' || true)
else
  _USER_SHELL=$(getent passwd "$CONSOLE_USER" 2>/dev/null | cut -d: -f7 || true)
fi

case "$_USER_SHELL" in
  *zsh*)  _PRIMARY_PROFILE="$USER_HOME/.zshrc" ;;
  *bash*) [[ "$_OS" == "Darwin" ]] \
            && _PRIMARY_PROFILE="$USER_HOME/.bash_profile" \
            || _PRIMARY_PROFILE="$USER_HOME/.bashrc" ;;
  *)      [[ "$_OS" == "Darwin" ]] \
            && _PRIMARY_PROFILE="$USER_HOME/.zshrc" \
            || _PRIMARY_PROFILE="$USER_HOME/.bashrc" ;;
esac

for _profile in \
  "$USER_HOME/.zshrc" \
  "$USER_HOME/.bash_profile" \
  "$USER_HOME/.bashrc"; do
  [[ -f "$_profile" || "$_profile" == "$_PRIMARY_PROFILE" ]] || continue

  upsert_block \
    "$_profile" \
    "$SOURCE_BLOCK" \
    "$CONSOLE_USER" \
    "$USER_GROUP"

  echo "[endor] sourced from   → $_profile"
done

unset _profile _OS _USER_SHELL _PRIMARY_PROFILE
echo "[endor] ✓ env.sh done"
