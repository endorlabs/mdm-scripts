# templates/js.sh
# JavaScript ecosystem — npm · pnpm · yarn classic · yarn 2+ (berry) · bun
#
# Config files written to the console user's home:
#   ~/.npmrc       covers: npm, pnpm, yarn classic (1.x), bun
#   ~/.yarnrc      covers: yarn classic (1.x) registry redirect
#   ~/.yarnrc.yml  covers: yarn 2+ / berry (does NOT read .npmrc for auth)
#
# Block content is defined in shared/blocks/npmrc.txt, yarnrc_classic.txt, yarnrc.txt.
# ${ENDOR_...} values in those files are env var refs — tools expand them at runtime.
#
# Auth note: .npmrc uses _auth, _username, _password (base64-encoded key:secret).
#   _authToken causes 401 for bun. _auth is verified working for all tools above.
#
# Yarn classic reads .npmrc for auth and .yarnrc for registry — both written here.
# bunfig.toml is project-level only; skip for MDM (document separately for devs).

echo ""
echo "[endor-js] ── JavaScript package managers ──────────────────────────────────"

# ── .npmrc ────────────────────────────────────────────────────────────────────
# Covers: npm (all versions), pnpm (8.x–11.x), yarn classic (1.x), bun (all versions)

# The shared block says ${ENDOR_API_KEY_ID} (Windows-safe); swap to the
# attributed user on bash — bun parses .npmrc last-write-wins, so a raw-key
# username line after _auth would drop bun's attribution. Remove once Windows
# gets attribution.
NPMRC_BLOCK=${NPMRC_BLOCK//'${ENDOR_API_KEY_ID}'/'${ENDOR_ATTR_USER}'}

warn_if_key_conflict \
  "$USER_HOME/.npmrc" \
  "^registry=" \
  "registry"

upsert_block \
  "$USER_HOME/.npmrc" \
  "$NPMRC_BLOCK" \
  "$CONSOLE_USER" \
  "$USER_GROUP"

echo "[endor-js] .npmrc          → $USER_HOME/.npmrc"
echo "[endor-js]   covers: npm · pnpm · yarn classic (auth) · bun"

# ── .yarnrc ───────────────────────────────────────────────────────────────────
# Covers: yarn classic (1.x) — registry redirect only; auth comes from .npmrc above
warn_if_key_conflict \
  "$USER_HOME/.yarnrc" \
  "^registry " \
  "registry"

upsert_block \
  "$USER_HOME/.yarnrc" \
  "$YARNRC_CLASSIC_BLOCK" \
  "$CONSOLE_USER" \
  "$USER_GROUP"

echo "[endor-js] .yarnrc         → $USER_HOME/.yarnrc"
echo "[endor-js]   covers: yarn classic (1.x)"

# ── .yarnrc.yml ───────────────────────────────────────────────────────────────
# Covers: yarn 2+ / berry only
# yarn 2+ reads .yarnrc.yml for registry and auth — it does NOT read .npmrc.
# Uses npmAuthIdent (plain "user:secret") — confirmed working with Endor firewall.
# Yarn berry supports ${VAR} expansion in .yarnrc.yml values (yarn 3+).

# The shared block says ${ENDOR_API_KEY_ID} (Windows-safe); swap to the
# attributed user on bash. Remove once Windows gets attribution.
YARNRC_BLOCK=${YARNRC_BLOCK//'${ENDOR_API_KEY_ID}'/'${ENDOR_ATTR_USER}'}

warn_if_key_conflict \
  "$USER_HOME/.yarnrc.yml" \
  "^npmRegistryServer:" \
  "npmRegistryServer"

upsert_block \
  "$USER_HOME/.yarnrc.yml" \
  "$YARNRC_BLOCK" \
  "$CONSOLE_USER" \
  "$USER_GROUP"

echo "[endor-js] .yarnrc.yml     → $USER_HOME/.yarnrc.yml"
echo "[endor-js]   covers: yarn 2+ (berry)"
echo "[endor-js] ✓ JavaScript done"
