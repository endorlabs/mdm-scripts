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

# XML sentinel markers — used for settings.xml (Maven), which cannot use '#' comments.
# These MUST match the BEGIN/END lines in shared/blocks/mavensettings.txt exactly,
# or re-runs and removal cannot find the managed block.
ENDOR_XML_BLOCK_START="<!-- ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) ===== -->"
ENDOR_XML_BLOCK_END="<!-- ===== END ENDOR PACKAGE FIREWALL ===== -->"

# ── User attribution helpers ──────────────────────────────────────────────────
# Encode <console-user>@<machine> into the Basic-auth username. The firewall
# decodes the label, auths with the real API key, and logs it as "User".

# endor_b64 — portable base64, no line wrapping (GNU wraps at 76 cols; BSD doesn't).
endor_b64() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

# endor_urlenc_b64 <b64> — percent-encode base64 chars (+ / =) for URL userinfo.
endor_urlenc_b64() {
  printf '%s' "$1" | sed -e 's/+/%2B/g' -e 's#/#%2F#g' -e 's/=/%3D/g'
}

# endor_host_label — a stable, human-readable machine name for attribution.
endor_host_label() {
  scutil --get ComputerName 2>/dev/null || hostname 2>/dev/null || echo unknown
}

# endor_attr_username <label> <api_key_id>
# Returns base64(base64("userattr:"+label)+":"+keyId) — the format
# decodeAttributedUsername() expects in endorfactory's auth layer.
endor_attr_username() {
  local label="$1" key_id="$2" inner
  inner=$(printf '%s' "userattr:${label}" | endor_b64)
  printf '%s:%s' "$inner" "$key_id" | endor_b64
}

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

# upsert_xml_block <file> <fragment> <owner> <group>
#
# Idempotent writer for an XML settings file (Maven ~/.m2/settings.xml).
# Inserts an XML-comment-delimited <fragment> immediately BEFORE the closing
# </settings> tag, so it always lands inside the <settings> root element.
#   - File absent             → create a minimal settings.xml wrapping the fragment
#   - File present, has block  → replace only the delimited fragment
#   - File present, no block   → insert fragment just before </settings>
#   - DRY_RUN=1               → print intent, write nothing
upsert_xml_block() {
  local file="$1" fragment="$2" owner="$3" group="$4" tmp

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    if [[ -f "$file" ]] && grep -qF "$ENDOR_XML_BLOCK_START" "$file" 2>/dev/null; then
      echo "[dry-run]   action : REPLACE Endor block in settings.xml"
    elif [[ -f "$file" ]]; then
      echo "[dry-run]   action : INSERT Endor block before </settings>"
    else
      echo "[dry-run]   action : CREATE settings.xml with Endor block"
    fi
    echo "[dry-run]   file    : $file"
    echo "$fragment" | sed 's/^/[dry-run]     /'
    echo ""
    return 0
  fi

  mkdir -p "$(dirname "$file")"

  # Case 1: file does not exist -> write a complete minimal settings.xml
  if [[ ! -f "$file" ]]; then
    {
      echo '<?xml version="1.0" encoding="UTF-8"?>'
      echo '<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"'
      echo '          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
      echo '          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.2.0 http://maven.apache.org/xsd/settings-1.2.0.xsd">'
      echo "$fragment"
      echo '</settings>'
    } > "$file"
    chown "$owner:$group" "$file"; chmod 600 "$file"
    return 0
  fi

  # Case 2: existing Endor block -> strip it first (preserve the rest)
  if grep -qF "$ENDOR_XML_BLOCK_START" "$file" 2>/dev/null; then
    tmp=$(mktemp)
    awk -v s="$ENDOR_XML_BLOCK_START" -v e="$ENDOR_XML_BLOCK_END" '
      index($0, s) { skip=1; next }
      index($0, e) { skip=0; next }
      !skip        { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  fi

  # Case 3: insert the fresh fragment immediately before the first </settings>.
  # The fragment is passed via a temp file and read with getline rather than
  # `awk -v frag=...`, because BSD/macOS awk rejects a multi-line value in -v
  # ("newline in string"). getline-from-file is portable across BSD and GNU awk.
  local fragfile; fragfile=$(mktemp)
  printf '%s\n' "$fragment" > "$fragfile"
  tmp=$(mktemp)
  awk -v fragfile="$fragfile" '
    /<\/settings>/ && !done {
      while ((getline line < fragfile) > 0) print line
      close(fragfile)
      done=1
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  rm -f "$fragfile"

  chown "$owner:$group" "$file"; chmod 600 "$file"
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

# remove_xml_block <file> <owner> <group>
# Strips the Endor XML fragment from settings.xml. If the file is left with an
# empty <settings> element (i.e. it was Endor-only), the whole file is deleted.
remove_xml_block() {
  local file="$1" owner="$2" group="$3" tmp

  [[ -f "$file" ]] || { echo "[endor-remove] skip (not found)    : $file"; return 0; }
  if ! grep -qF "$ENDOR_XML_BLOCK_START" "$file" 2>/dev/null; then
    echo "[endor-remove] skip (no Endor block): $file"; return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run]   action : REMOVE Endor block from settings.xml"
    echo "[dry-run]   file   : $file"
    return 0
  fi

  tmp=$(mktemp)
  awk -v s="$ENDOR_XML_BLOCK_START" -v e="$ENDOR_XML_BLOCK_END" '
    index($0, s) { skip=1; next }
    index($0, e) { skip=0; next }
    !skip        { print }
  ' "$file" > "$tmp"

  # If only the empty XML scaffold remains, the file was Endor-only -> delete it
  if ! grep -qE '<(server|mirror|profile|proxy|pluginGroup|repository)' "$tmp"; then
    rm -f "$file" "$tmp"
    echo "[endor-remove] deleted (was empty) : $file"
  else
    mv "$tmp" "$file"; chown "$owner:$group" "$file"; chmod 600 "$file"
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
    _ENDOR_WARNED=1
  fi
}
