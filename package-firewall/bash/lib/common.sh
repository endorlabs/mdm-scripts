# lib/common.sh
# Shared runtime functions inlined into every generated MDM script by generate.sh.
# Do NOT source this file directly — it is embedded at generation time.
#
# Functions:
#   detect_console_user                        — finds the logged-in user when running as root
#   resolve_user_home       <user>             — resolves home via dscl / getent / POSIX
#   upsert_block            <file> <content> <owner> <group>
#                                              — non-destructive, idempotent sentinel-block writer
#                                                honours DRY_RUN=1 (prints intent, no writes)
#   remove_block            <file> <owner> <group>
#                                              — strips Endor sentinel block from a file
#                                                honours DRY_RUN=1 (prints intent, no writes)
#   warn_if_key_conflict    <file> <pattern> <label>
#                                              — warns when a key exists outside an Endor block

# Sentinel markers — identical across all config files so re-runs and remove work reliably
ENDOR_BLOCK_START="# ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) ====="
ENDOR_BLOCK_END="# ===== END ENDOR PACKAGE FIREWALL ====="

# detect_console_user
# MDM tools (Kandji, Jamf) run scripts as root. $HOME resolves to /var/root, which
# is not where developer config files live. Returns the name of the actual logged-in
# console user so config is written to the correct home directory.
detect_console_user() {
  local user=""

  if command -v logname &>/dev/null; then
    user=$(logname 2>/dev/null || true)
  fi

  if [[ -z "$user" || "$user" == "root" ]] && [[ -r /dev/console ]]; then
    user=$(stat -f '%Su' /dev/console 2>/dev/null || true)
  fi

  if [[ -z "$user" || "$user" == "root" ]]; then
    echo "[endor] ERROR: could not detect console user. Ensure a user is logged in." >&2
    exit 1
  fi

  echo "$user"
}

# resolve_user_home <username>
# Resolution order: dscl (macOS) → getent (Linux) → POSIX tilde expansion.
resolve_user_home() {
  local user="$1"
  local home=""

  if [[ -x /usr/bin/dscl ]]; then
    home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null \
           | awk '{print $2}' || true)
  fi

  if [[ -z "$home" ]] && command -v getent &>/dev/null; then
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)
  fi

  if [[ -z "$home" ]]; then
    home=$(eval echo "~$user")
  fi

  echo "$home"
}

# upsert_block <file> <content> <owner> <group>
#
# Non-destructive, idempotent config writer using sentinel blocks.
#   - File absent          → creates it with the Endor block
#   - File present, no block → appends the block; existing content untouched
#   - File present, block found → replaces only the block; rest untouched
#   - DRY_RUN=1            → prints what would happen, writes nothing
upsert_block() {
  local file="$1"
  local content="$2"
  local owner="$3"
  local group="$4"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    if [[ -f "$file" ]] && grep -qF "$ENDOR_BLOCK_START" "$file" 2>/dev/null; then
      echo "[dry-run]   action : REPLACE existing Endor block"
    elif [[ -f "$file" ]]; then
      echo "[dry-run]   action : APPEND Endor block to existing file"
    else
      echo "[dry-run]   action : CREATE file with Endor block"
    fi
    echo "[dry-run]   file   : $file"
    echo "[dry-run]   content:"
    echo "$content" | sed 's/^/[dry-run]     /'
    echo ""
    return 0
  fi

  mkdir -p "$(dirname "$file")"

  # Strip any existing Endor block, preserving everything else
  if [[ -f "$file" ]] && grep -qF "$ENDOR_BLOCK_START" "$file" 2>/dev/null; then
    local tmp
    tmp=$(mktemp)
    awk -v start="$ENDOR_BLOCK_START" -v end="$ENDOR_BLOCK_END" '
      index($0, start) { skip=1; next }
      index($0, end)   { skip=0; next }
      !skip             { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  fi

  printf '\n%s\n%s\n%s\n' \
    "$ENDOR_BLOCK_START" \
    "$content" \
    "$ENDOR_BLOCK_END" >> "$file"

  chown "$owner:$group" "$file"
  chmod 600 "$file"
}

# remove_block <file> <owner> <group>
#
# Strips the Endor sentinel block from a config file.
#   - File absent           → skips silently
#   - No Endor block found  → skips with a notice
#   - Block found           → removes block; preserves everything else
#   - File empty after removal → deletes the file entirely
#   - DRY_RUN=1             → prints what would happen, writes nothing
remove_block() {
  local file="$1"
  local owner="$2"
  local group="$3"

  if [[ ! -f "$file" ]]; then
    echo "[endor-remove] skip (not found)    : $file"
    return 0
  fi

  if ! grep -qF "$ENDOR_BLOCK_START" "$file" 2>/dev/null; then
    echo "[endor-remove] skip (no Endor block): $file"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    # Check whether removal would leave the file empty
    local remaining
    remaining=$(awk -v start="$ENDOR_BLOCK_START" -v end="$ENDOR_BLOCK_END" '
      index($0, start) { skip=1; next }
      index($0, end)   { skip=0; next }
      !skip             { print }
    ' "$file" | tr -d '[:space:]')

    if [[ -z "$remaining" ]]; then
      echo "[dry-run]   action : REMOVE block → file would be empty → DELETE file"
    else
      echo "[dry-run]   action : REMOVE block, preserve remaining content"
    fi
    echo "[dry-run]   file   : $file"
    echo ""
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  awk -v start="$ENDOR_BLOCK_START" -v end="$ENDOR_BLOCK_END" '
    index($0, start) { skip=1; next }
    index($0, end)   { skip=0; next }
    !skip             { print }
  ' "$file" > "$tmp"

  # Delete the file if it's effectively empty after block removal
  if [[ -z "$(tr -d '[:space:]' < "$tmp")" ]]; then
    rm -f "$file" "$tmp"
    echo "[endor-remove] deleted (was empty) : $file"
  else
    mv "$tmp" "$file"
    chown "$owner:$group" "$file"
    chmod 600 "$file"
    echo "[endor-remove] block removed       : $file"
  fi
}

# warn_if_key_conflict <file> <awk-pattern> <label>
# Warns when <pattern> exists in <file> outside an Endor-managed block.
# Helps IT admins catch precedence conflicts before they cause a broken environment.
warn_if_key_conflict() {
  local file="$1"
  local pattern="$2"
  local label="$3"

  [[ -f "$file" ]] || return 0
  grep -qF "$ENDOR_BLOCK_START" "$file" 2>/dev/null && return 0  # already managed

  if awk "/$pattern/" "$file" 2>/dev/null | grep -q .; then
    echo "[endor] WARNING: existing '${label}' found in ${file}." >&2
    echo "[endor]          Endor block will be appended — verify key precedence with your tool." >&2
  fi
}
