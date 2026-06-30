# templates/python.sh
# Python ecosystem — pip · uv · poetry
#
# Config files written to the console user's home:
#   ~/.pip/pip.conf                              pip (legacy location, still respected)
#   ~/.config/pip/pip.conf                       pip (XDG / Linux standard)
#   ~/Library/Application Support/pip/pip.conf   pip (macOS primary)
#   ~/.config/uv/uv.toml                         uv  (does NOT read pip.conf)
#
# Block content is defined in templates/blocks/pipconf.txt and uvtoml.txt.
#
# Credential approach per tool:
#   pip     → literal index-url in pip.conf (pip cannot expand env vars)
#   uv      → literal index-url in uv.toml  (baked at install time, like pip)
#   poetry  → POETRY_HTTP_BASIC_ENDOR_FIREWALL_* env vars via env.sh (written by env.sh step)
#
# pip/uv credentials carry the per-machine attributed username, so they must be the
# literal value computed in attribution.sh — resolve the ${ENDOR_PYPI_URL} placeholder now.
#
# pip section uses [endor-firewall] named section — avoids clobbering admin's [global].

echo ""
echo "[endor-python] ── Python package managers ──────────────────────────────────"

# Resolve the attributed index-url into the block content (pip/uv can't expand ${VAR}).
PIP_BLOCK=${PIP_BLOCK//'${ENDOR_PYPI_URL}'/$ENDOR_PYPI_URL}
UV_BLOCK=${UV_BLOCK//'${ENDOR_PYPI_URL}'/$ENDOR_PYPI_URL}

# ── pip ───────────────────────────────────────────────────────────────────────
# pip reads pip.conf automatically from all three locations below.
# pip does not support env var expansion — credentials are literal values (see pipconf.txt).
for pip_conf in \
  "$USER_HOME/.pip/pip.conf" \
  "$USER_HOME/.config/pip/pip.conf" \
  "$USER_HOME/Library/Application Support/pip/pip.conf"; do

  warn_if_key_conflict \
    "$pip_conf" \
    "^index-url" \
    "index-url (pip)"

  upsert_block \
    "$pip_conf" \
    "$PIP_BLOCK" \
    "$CONSOLE_USER" \
    "$USER_GROUP"

  echo "[endor-python] pip.conf        → $pip_conf"
done

echo "[endor-python]   covers: pip"

# ── uv ────────────────────────────────────────────────────────────────────────
# uv does NOT read pip.conf. ~/.config/uv/uv.toml is the user-level global config.
# uv supports ${VAR} env var expansion in uv.toml values — see uvtoml.txt.
UV_TOML="$USER_HOME/.config/uv/uv.toml"

warn_if_key_conflict \
  "$UV_TOML" \
  "^\[\[index\]\]" \
  "[[index]] (uv)"

upsert_block \
  "$UV_TOML" \
  "$UV_BLOCK" \
  "$CONSOLE_USER" \
  "$USER_GROUP"

echo "[endor-python] uv.toml         → $UV_TOML"
echo "[endor-python]   covers: uv"

# ── poetry ────────────────────────────────────────────────────────────────────
# Poetry credentials (POETRY_HTTP_BASIC_ENDOR_FIREWALL_*) are written to
# ~/.config/endor/env.sh by the env.sh setup step — not here.
#
# Developers still need to add the source URL to pyproject.toml (URL only, no credentials):
#   [[tool.poetry.source]]
#   name     = "endor-firewall"
#   url      = "{{PYPI_URL}}"
#   priority = "primary"

echo "[endor-python]   poetry: credentials via env.sh (POETRY_HTTP_BASIC_ENDOR_FIREWALL_*)"
echo "[endor-python]   NOTE: open a new terminal (or run 'source ~/.zshrc') for env vars to take effect."
echo "[endor-python] ✓ Python done"
