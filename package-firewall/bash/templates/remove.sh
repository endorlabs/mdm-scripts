# templates/remove.sh
# Removes the Endor Package Firewall sentinel block from all config files
# written by endor-js.sh and endor-python.sh.
#
# Files targeted (mirrors exactly what the install scripts write to):
#
#   JavaScript:
#     ~/.npmrc
#     ~/.yarnrc
#     ~/.yarnrc.yml
#
#   Python:
#     ~/.pip/pip.conf
#     ~/.config/pip/pip.conf
#     ~/Library/Application Support/pip/pip.conf
#     ~/.config/uv/uv.toml
#     ~/.zshrc
#     ~/.bash_profile
#     ~/.bashrc
#
# Behaviour:
#   - Files with no Endor block are skipped (nothing modified)
#   - Files where Endor block is the only content are deleted
#   - Files with other content have only the block stripped
#   - --dry-run: prints what would happen, writes nothing
#   - Safe to run multiple times (idempotent)

echo ""
echo "[endor-remove] ── Endor Package Firewall removal ──────────────────────────"
echo "[endor-remove]    namespace={{NAMESPACE}}"
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "[endor-remove]    mode=DRY RUN — no files will be modified"
fi
echo ""

# ── env.sh and shell profile source lines ────────────────────────────────────
echo "[endor-remove] ── env.sh ────────────────────────────────────────────────────"

remove_block "$USER_HOME/.config/endor/env.sh" "$CONSOLE_USER" "$USER_GROUP"

if [[ "${DRY_RUN:-0}" != "1" ]]; then
  rmdir "$USER_HOME/.config/endor" 2>/dev/null || true
fi

echo ""
echo "[endor-remove] ── Shell profiles (env.sh source line) ───────────────────────"

for _profile in \
  "$USER_HOME/.zshrc" \
  "$USER_HOME/.bash_profile" \
  "$USER_HOME/.bashrc"; do
  remove_block "$_profile" "$CONSOLE_USER" "$USER_GROUP"
done
unset _profile

# ── JavaScript config files ───────────────────────────────────────────────────
echo ""
echo "[endor-remove] ── JavaScript ───────────────────────────────────────────────"

remove_block "$USER_HOME/.npmrc"      "$CONSOLE_USER" "$USER_GROUP"
remove_block "$USER_HOME/.yarnrc"     "$CONSOLE_USER" "$USER_GROUP"
remove_block "$USER_HOME/.yarnrc.yml" "$CONSOLE_USER" "$USER_GROUP"

# ── Python config files ───────────────────────────────────────────────────────
echo ""
echo "[endor-remove] ── Python ────────────────────────────────────────────────────"

for pip_conf in \
  "$USER_HOME/.pip/pip.conf" \
  "$USER_HOME/.config/pip/pip.conf" \
  "$USER_HOME/Library/Application Support/pip/pip.conf"; do
  remove_block "$pip_conf" "$CONSOLE_USER" "$USER_GROUP"
done
unset pip_conf

remove_block "$USER_HOME/.config/uv/uv.toml" "$CONSOLE_USER" "$USER_GROUP"

echo ""
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "[endor-remove] ✓ Dry run complete — no files modified."
else
  echo "[endor-remove] ✓ Removal complete."
  echo "[endor-remove]   Package managers will fall back to their default registries."
  echo "[endor-remove]   Open a new terminal for shell profile changes to take effect."
fi
