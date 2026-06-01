# templates/js.sh
# JavaScript ecosystem — npm · pnpm · yarn classic · yarn 2+ (berry) · bun
#
# Config files written to the console user's home:
#   ~/.npmrc       covers: npm, pnpm, yarn classic (1.x), bun
#   ~/.yarnrc.yml  covers: yarn 2+ / berry (does NOT read .npmrc for auth)
#
# Block content is defined in templates/blocks/npmrc.txt and yarnrc.txt.
# ${ENDOR_...} values in those files are env var refs — tools expand them at runtime.
#
# Auth note: uses _auth (base64-encoded key:secret) throughout for .npmrc.
#   _authToken causes 401 for bun. _auth is verified working for all tools above.
#
# Yarn classic + .yarnrc alone = FAIL. Yarn classic needs .npmrc for auth — covered here.
# bunfig.toml is project-level only; skip for MDM (document separately for devs).

echo ""
echo "[endor-js] ── JavaScript package managers ──────────────────────────────────"

# ── .npmrc ────────────────────────────────────────────────────────────────────
# Covers: npm (all versions), pnpm (8.x–11.x), yarn classic (1.x), bun (all versions)
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
echo "[endor-js]   covers: npm · pnpm · yarn classic · bun"

# ── .yarnrc.yml ───────────────────────────────────────────────────────────────
# Covers: yarn 2+ / berry only
# yarn 2+ reads .yarnrc.yml for registry and auth — it does NOT read .npmrc.
# Uses npmAuthIdent (plain "key:secret") — confirmed working with Endor firewall.
# Yarn berry supports ${VAR} expansion in .yarnrc.yml values (yarn 3+).
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
