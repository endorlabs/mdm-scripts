# templates/envsh.sh
# Writes ~/.config/endor/env.sh — the single credential source for all
# env-var-based tools (npm, yarn 2+, maven, poetry).
# Then adds a one-line source directive to existing shell profiles.
#
# Block content is defined in shared/blocks/envsh.txt, with the same {{...}}
# token names as always. Most are baked at generation time like every other
# block; the four attribution-dependent ones ({{ATTR_USER}}, {{NPM_AUTH_B64}},
# {{PIP_INDEX_URL}}, {{GO_PROXY_URL}}) derive from <console-user>@<machine>, so
# generate.sh leaves them untouched and they are filled HERE, at install time,
# from the values templates/credentials.sh computed — the written file is a
# plain set of literal exports, no per-shell computation on every startup.
# A token added to envsh.txt must be substituted by generate.sh or filled below,
# or the script exits non-zero with a warning.
#
# pip / uv / go are intentionally NOT sourced from here — those tools cannot expand
# ${VAR}, so their config files get the literal value written by python.sh / go.sh.

echo ""
echo "[endor] ── env.sh setup ─────────────────────────────────────────────────────"

ENDOR_ENV_SH="$USER_HOME/.config/endor/env.sh"

# Fill the attribution-dependent tokens (values computed in credentials.sh).
ENVSH_BLOCK=${ENVSH_BLOCK//'{{ATTR_USER}}'/$ENDOR_ATTR_USER}
ENVSH_BLOCK=${ENVSH_BLOCK//'{{NPM_AUTH_B64}}'/$ENDOR_AUTH_B64}
ENVSH_BLOCK=${ENVSH_BLOCK//'{{PIP_INDEX_URL}}'/$ENDOR_PYPI_URL}
ENVSH_BLOCK=${ENVSH_BLOCK//'{{GO_PROXY_URL}}'/$ENDOR_GO_PROXY_URL}

if [[ "$ENVSH_BLOCK" == *'{{'* ]]; then
  echo "[endor] WARNING: unresolved {{...}} token in the env.sh block — a token in" >&2
  echo "[endor]          shared/blocks/envsh.txt is neither substituted by generate.sh" >&2
  echo "[endor]          nor filled in templates/envsh.sh. Tools would read a broken value." >&2
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
