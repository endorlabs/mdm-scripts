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
#
#   Go:
#     ~/.config/go/env
#
#   Maven:
#     ~/.m2/settings.xml
#
#   VS Code (stable + Insiders, all discovered install paths):
#     .../Contents/Resources/app/product.json      (macOS)
#     /usr/share/code*/resources/app/product.json  (Linux)
#     plus the update watcher (launchd/systemd/cron) and the sidecar state dir
#
#   Shell profiles (env.sh source line):
#     ~/.zshrc
#     ~/.bash_profile
#     ~/.bashrc
#
# Behaviour:
#   - Files with no Endor block are skipped (nothing modified)
#   - Files where Endor block is the only content are deleted
#   - Files with other content have only the block stripped
#   - product.json is restored from the original captured in its marker, not by
#     stripping a block — JSON cannot carry a sentinel comment
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

# yarn 1.x rewrites ~/.yarnrc on its own and can copy the Endor registry
# outside the managed block. Delete only lines that exactly match our URL —
# they can't be anyone else's config.
_YARNRC="$USER_HOME/.yarnrc"
_ENDOR_YARN_LINE='registry "{{NPM_REGISTRY_URL}}"'
if [[ -f "$_YARNRC" ]] && awk -v s="$ENDOR_BLOCK_START" -v e="$ENDOR_BLOCK_END" '
      index($0, s) { skip=1; next }
      index($0, e) { skip=0; next }
      !skip        { print }
    ' "$_YARNRC" | grep -qxF "$_ENDOR_YARN_LINE"; then
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run]   action : DELETE yarn-copied Endor registry line from $_YARNRC"
  else
    _tmp=$(mktemp)
    grep -vxF "$_ENDOR_YARN_LINE" "$_YARNRC" | grep -vx 'always-auth true' > "$_tmp" || true
    if [[ -z "$(tr -d '[:space:]' < "$_tmp")" ]]; then
      rm -f "$_YARNRC" "$_tmp"
      echo "[endor-remove] deleted (was empty) : $_YARNRC"
    else
      mv "$_tmp" "$_YARNRC"
      chown "$CONSOLE_USER:$USER_GROUP" "$_YARNRC"
      chmod 600 "$_YARNRC"
      echo "[endor-remove] yarn-copied line removed: $_YARNRC"
    fi
  fi
fi
unset _YARNRC _ENDOR_YARN_LINE _tmp

# ── Python config files ───────────────────────────────────────────────────────
echo ""
echo "[endor-remove] ── Python ────────────────────────────────────────────────────"

# remove_block also restores pip keys disabled with '#endor-bak#' at install time
for pip_conf in \
  "$USER_HOME/.pip/pip.conf" \
  "$USER_HOME/.config/pip/pip.conf" \
  "$USER_HOME/Library/Application Support/pip/pip.conf"; do
  remove_block "$pip_conf" "$CONSOLE_USER" "$USER_GROUP"
done
unset pip_conf

remove_block "$USER_HOME/.config/uv/uv.toml" "$CONSOLE_USER" "$USER_GROUP"

# ── Go config file ────────────────────────────────────────────────────────────
echo ""
echo "[endor-remove] ── Go ────────────────────────────────────────────────────────────"

# Resolve go env file path the same way the install script does.
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
fi
unset _go_bin

remove_block "$_GO_ENV_FILE" "$CONSOLE_USER" "$USER_GROUP"
unset _GO_ENV_FILE

# ── Maven config file ────────────────────────────────────────────────────────────
echo ""
echo "[endor-remove] ── Maven ────────────────────────────────────────────────────────────"

remove_xml_block "$USER_HOME/.m2/settings.xml" "$CONSOLE_USER" "$USER_GROUP"

# ── VS Code product.json ─────────────────────────────────────────────────────────
# Not a sentinel block: the original extensionsGallery is restored byte-for-byte
# from the base64 copy stored in the product.json marker, then the marker itself is
# dropped. Removing the update watcher first means it cannot re-patch a file we are
# about to restore.
echo ""
echo "[endor-remove] ── VS Code ──────────────────────────────────────────────────────────"

vscode_remove_watcher

_VSCODE_REMOVED=0
while IFS= read -r _vsc_pj; do
  [[ -n "$_vsc_pj" ]] || continue
  _VSCODE_REMOVED=1
  vscode_unpatch "$_vsc_pj" || _ENDOR_WARNED=1
done < <(vscode_install_paths "$USER_HOME")
unset _vsc_pj

if [[ "$_VSCODE_REMOVED" == "0" ]]; then
  echo "[endor-remove] skip (no VS Code)   : no installation found"
fi

echo ""
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "[endor-remove] ✓ Dry run complete — no files modified."
else
  echo "[endor-remove] ✓ Removal complete."
  echo "[endor-remove]   Package managers will fall back to their default registries."
  echo "[endor-remove]   Open a new terminal for shell profile changes to take effect."
  if [[ "$_VSCODE_REMOVED" == "1" ]]; then
    echo "[endor-remove]   Restart VS Code — product.json is only read at startup."
  fi
fi
