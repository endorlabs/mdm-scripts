# lib/common.sh
# Shared runtime functions inlined into every generated MDM script by generate.sh.
# Do NOT source this file directly — it is embedded at generation time.
#
# Functions:
#   detect_console_user                        — finds the logged-in user when running as root
#   resolve_user_home       <user>             — resolves home via dscl / getent / POSIX
#   upsert_block            <file> <content> <owner> <group>
#                                              — non-destructive, idempotent sentinel-block writer
#                                                delegates to upsert_block_pip when <content> has
#                                                [global]; honours DRY_RUN=1 (prints intent, no writes)
#   upsert_block_pip        <file> <content> <owner> <group>
#                                              — pip.conf writer; merges into an existing [global]
#                                                (conflicting keys disabled with '#endor-bak#')
#                                                when both <content> and the file declare [global]
#   remove_block            <file> <owner> <group>
#                                              — strips Endor sentinel block from a file,
#                                                restores keys disabled with '#endor-bak#'
#                                                honours DRY_RUN=1 (prints intent, no writes)
#   warn_if_key_conflict    <file> <pattern> <label>
#                                              — warns when a key exists outside an Endor block
#   warn_if_xml_key_conflict <file> <pattern> <label>
#                                              — same, but for XML-comment-delimited blocks
#                                                (e.g. Maven settings.xml)

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
#
# Delegates to upsert_block_pip when <content> carries a [global] header (pip.conf).
upsert_block() {
  local file="$1"
  local content="$2"
  local owner="$3"
  local group="$4"

  if printf '%s\n' "$content" | grep -qxF '[global]'; then
    upsert_block_pip "$file" "$content" "$owner" "$group"
    return 0
  fi

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

  printf '%s\n%s\n%s' \
    "$ENDOR_BLOCK_START" \
    "$content" \
    "$ENDOR_BLOCK_END" >> "$file"

  chown "$owner:$group" "$file"
  chmod 600 "$file"
}

# upsert_block_pip <file> <content> <owner> <group>
#
# pip.conf-aware sentinel-block writer. Identical to upsert_block except when both
# <content> and the pre-existing file (outside any Endor block) declare [global]:
# pip rejects duplicate [global] sections, so the Endor keys are inserted inside the
# existing section and conflicting keys are disabled reversibly with '#endor-bak#'.
upsert_block_pip() {
  local file="$1"
  local content="$2"
  local owner="$3"
  local group="$4"
  local outside merge=0 has_block=0 tmp key_pattern

  if [[ -f "$file" ]] && grep -qF "$ENDOR_BLOCK_START" "$file" 2>/dev/null; then
    has_block=1
  fi

  if [[ -f "$file" ]]; then
    outside=$(awk -v start="$ENDOR_BLOCK_START" -v end="$ENDOR_BLOCK_END" '
      index($0, start) { skip=1; next }
      index($0, end)   { skip=0; next }
      !skip             { print }
    ' "$file")
    if printf '%s\n' "$content" | grep -qxF '[global]' \
        && printf '%s\n' "$outside" | grep -qxF '[global]'; then
      merge=1
    fi
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    if [[ "$has_block" == "1" ]]; then
      echo "[dry-run]   action : REPLACE existing Endor block"
    elif [[ "$merge" == "1" ]]; then
      echo "[dry-run]   action : MERGE into existing [global] (conflicting keys disabled via #endor-bak#)"
      echo "[dry-run]   note   : pre-existing index keys will be disabled via '#endor-bak#'"
      echo "[dry-run]            and the Endor keys merged into the existing [global]"
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

  if [[ "$merge" == "1" ]]; then
    key_pattern=$(printf '%s\n' "$content" | awk '
      match($0, /^[A-Za-z0-9_-]+[[:space:]]*[=:]/) {
        key = substr($0, RSTART, RLENGTH)
        sub(/[[:space:]]*[=:].*/, "", key)
        gsub(/[-_]/, "[-_]", key)
        if (pattern != "") pattern = pattern "|"
        pattern = pattern key
      }
      END { print pattern }
    ')

    local bodyfile keysfile outfile
    bodyfile=$(mktemp)
    keysfile=$(mktemp)
    outfile=$(mktemp)

    awk -v key_pattern="$key_pattern" '
      BEGIN { cont = 0 }
      {
        if (key_pattern != "" && $0 ~ ("^[[:space:]]*(" key_pattern ")[[:space:]]*[=:]")) {
          print "#endor-bak#" $0
          cont = 1
          next
        }
        if (cont && $0 ~ /^[[:space:]]+\S/) {
          print "#endor-bak#" $0
          next
        }
        cont = 0
        print
      }
    ' <<< "$outside" > "$bodyfile"

    if grep -qF '#endor-bak#' "$bodyfile" 2>/dev/null; then
      echo "[endor] NOTE: existing pip index keys in $file disabled with '#endor-bak#' (restored on removal)"
    fi

    {
      echo "$ENDOR_BLOCK_START"
      printf '%s\n' "$content" | grep -vxF '[global]'
      echo "$ENDOR_BLOCK_END"
    } > "$keysfile"

    awk -v keysfile="$keysfile" '
      BEGIN { done = 0 }
      {
        print
        if (!done && $0 == "[global]") {
          while ((getline line < keysfile) > 0) print line
          close(keysfile)
          done = 1
        }
      }
    ' "$bodyfile" > "$outfile"

    mv "$outfile" "$file"
    rm -f "$bodyfile" "$keysfile"
    chown "$owner:$group" "$file"
    chmod 600 "$file"
    return 0
  fi

  # Non-merge path: identical to upsert_block
  if [[ -f "$file" ]] && grep -qF "$ENDOR_BLOCK_START" "$file" 2>/dev/null; then
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
# Strips the Endor sentinel block and restores '#endor-bak#'-disabled keys.
#   - File absent           → skips silently
#   - No Endor block found  → skips with a notice
#   - Block found           → removes block; preserves everything else
#   - File empty after removal → deletes it (a bare [global] counts as empty)
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

    if [[ -z "$remaining" || "$remaining" == "[global]" ]]; then
      echo "[dry-run]   action : REMOVE block → file would be empty → DELETE file"
    else
      echo "[dry-run]   action : REMOVE block, preserve remaining content"
    fi
    if grep -qF '#endor-bak#' "$file" 2>/dev/null; then
      echo "[dry-run]   restore: keys disabled with '#endor-bak#'"
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
  ' "$file" | sed -E 's/^([[:space:]]*)#endor-bak#/\1/' > "$tmp"

  # Delete if effectively empty (whitespace only, or a bare [global])
  local remaining
  remaining=$(tr -d '[:space:]' < "$tmp")
  if [[ -z "$remaining" || "$remaining" == "[global]" ]]; then
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

# warn_if_xml_key_conflict <file> <awk-pattern> <label>
# Warns when <pattern> exists in <file> outside an Endor-managed XML block.
# Unlike warn_if_key_conflict, scans only lines outside ENDOR_XML_BLOCK_START/END
# so re-runs on an already-managed settings.xml do not false-positive.
warn_if_xml_key_conflict() {
  local file="$1"
  local pattern="$2"
  local label="$3"

  [[ -f "$file" ]] || return 0

  if awk -v start="$ENDOR_XML_BLOCK_START" -v end="$ENDOR_XML_BLOCK_END" -v pat="$pattern" '
    index($0, start) { skip=1; next }
    index($0, end)   { skip=0; next }
    !skip && $0 ~ pat { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$file" 2>/dev/null; then
    echo "[endor] WARNING: existing '${label}' found in ${file}." >&2
    echo "[endor]          Endor block will be inserted — verify key precedence with your tool." >&2
    _ENDOR_WARNED=1
  fi
}
