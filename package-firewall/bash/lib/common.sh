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

# Per-entry sentinel markers wrapping our <server> and <mirror>. They live in the
# shared fragment (shared/blocks/mavensettings.txt) and are what let each entry be
# merged into whichever <servers>/<mirrors> container already exists — Maven's
# schema forbids a second container. Both the bash and PowerShell generators read
# that same fragment, so these strings MUST match it byte-for-byte. The legacy
# ENDOR_XML_BLOCK_* pair above is still recognised on strip/remove so files written
# by older versions are cleaned up correctly.
ENDOR_XML_SERVER_START="<!-- ===== BEGIN ENDOR PACKAGE FIREWALL server (managed — do not edit) ===== -->"
ENDOR_XML_SERVER_END="<!-- ===== END ENDOR PACKAGE FIREWALL server ===== -->"
ENDOR_XML_MIRROR_START="<!-- ===== BEGIN ENDOR PACKAGE FIREWALL mirror (managed — do not edit) ===== -->"
ENDOR_XML_MIRROR_END="<!-- ===== END ENDOR PACKAGE FIREWALL mirror ===== -->"

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

  printf '%s\n%s\n%s\n' \
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

# ── Maven XML helpers ─────────────────────────────────────────────────────────
# Support upsert_xml_block / remove_xml_block. Multi-line content is read from a
# temp file with getline rather than `awk -v`, because BSD/macOS awk rejects a
# multi-line -v value ("newline in string"). Awk built-in names (sub, close, index,
# length, split…) must NOT be used as awk variables — the injected block is held in
# `blk` and the closing tag in `closetag`.

# _endor_xml_extract <start> <end>   (fragment on stdin) -> inclusive block on stdout
# Emits the sentinel-delimited entry (the markers included) so it can be merged
# as-is into an existing container and located again on re-run/removal.
_endor_xml_extract() {
  awk -v s="$1" -v e="$2" '
    index($0,s){grab=1}
    grab{print}
    index($0,e){grab=0}
  '
}

# _endor_xml_strip_managed <file> -> stdout with every managed region removed
# (the per-entry server/mirror sub-blocks AND the legacy combined block).
_endor_xml_strip_managed() {
  awk -v ss="$ENDOR_XML_SERVER_START" -v se="$ENDOR_XML_SERVER_END" \
      -v ms="$ENDOR_XML_MIRROR_START" -v me="$ENDOR_XML_MIRROR_END" \
      -v bs="$ENDOR_XML_BLOCK_START"  -v be="$ENDOR_XML_BLOCK_END" '
    index($0,ss){skip=1} index($0,ms){skip=1} index($0,bs){skip=1}
    !skip{print}
    index($0,se){skip=0} index($0,me){skip=0} index($0,be){skip=0}
  ' "$1"
}

# _endor_xml_into_container <file> <open> <close> <selfclose> <subfile>
# Inserts <subfile> as the FIRST child of an existing container (so an Endor
# catch-all mirror wins Maven precedence). Prints result; rc 0 = injected,
# rc 1 = container absent (caller must create it). Handles the multi-line form
# (<servers> … </servers>), the single-line empty form (<servers></servers>),
# and the self-closed form (<servers/>).
_endor_xml_into_container() {
  local file="$1" open="$2" closetag="$3" selfclose="$4" subfile="$5"
  if grep -qF "$open" "$file"; then
    awk -v openlit="$open" -v subfile="$subfile" '
      BEGIN{ while((getline l < subfile)>0) blk=(blk==""?l:blk RS l); close(subfile) }
      !done && (p=index($0,openlit)) {
        print substr($0,1,p+length(openlit)-1); print blk
        rest=substr($0,p+length(openlit)); if(rest!="") print rest
        done=1; next
      }
      { print }
    ' "$file"
    return 0
  elif grep -qF "$selfclose" "$file"; then
    awk -v sclit="$selfclose" -v opentag="$open" -v closetag="$closetag" -v subfile="$subfile" '
      BEGIN{ while((getline l < subfile)>0) blk=(blk==""?l:blk RS l); close(subfile) }
      !done && (p=index($0,sclit)) {
        print substr($0,1,p-1) opentag; print blk
        print closetag substr($0,p+length(sclit))
        done=1; next
      }
      { print }
    ' "$file"
    return 0
  fi
  return 1
}

# _endor_xml_insert_ordered <file> <subfile> <later-open-tag>...
# Inserts <subfile> before the first "later-ordered" sibling (per Maven's schema
# sequence servers→mirrors→profiles→activeProfiles→pluginGroups), else before
# </settings>. Keeps a newly-created container in its schema-valid position.
_endor_xml_insert_ordered() {
  local file="$1" subfile="$2"; shift 2
  awk -v subfile="$subfile" -v laters="$*" '
    BEGIN{ while((getline l < subfile)>0) blk=(blk==""?l:blk RS l); close(subfile); n=split(laters,arr," ") }
    !done { for(i=1;i<=n;i++) if(index($0,arr[i])){ print blk; done=1; break } }
    !done && index($0,"</settings>"){ print blk; done=1 }
    { print }
  ' "$file"
}

# upsert_xml_block <file> <fragment> <owner> <group>
#
# Idempotent, MERGE-AWARE writer for Maven ~/.m2/settings.xml. The <fragment>
# (shared/blocks/mavensettings.txt) carries two sentinel-delimited entries — a
# <server> and a <mirror>. Maven's schema forbids a second <servers>/<mirrors>, so
# each entry is merged into whichever container already exists; a container is
# created only when it is absent.
#   - File absent              → create a minimal settings.xml with both containers
#   - <servers> present        → insert our <server> as its first child
#   - <servers> absent         → create <servers> (in schema order) wrapping our entry
#   - <mirrors> present/absent → same treatment for our <mirror>
#   - Re-run                   → prior managed entries (new or legacy) stripped first
#   - DRY_RUN=1                → print intent, write nothing
upsert_xml_block() {
  local file="$1" fragment="$2" owner="$3" group="$4" tmp cf sf_server sf_mirror

  # Pull each sentinel-delimited entry out of the fragment. Each keeps its own
  # markers so it can be merged into an existing container and found again later.
  sf_server=$(mktemp); sf_mirror=$(mktemp)
  printf '%s\n' "$fragment" | _endor_xml_extract "$ENDOR_XML_SERVER_START" "$ENDOR_XML_SERVER_END" > "$sf_server"
  printf '%s\n' "$fragment" | _endor_xml_extract "$ENDOR_XML_MIRROR_START" "$ENDOR_XML_MIRROR_END" > "$sf_mirror"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    if [[ ! -f "$file" ]]; then
      echo "[dry-run]   action : CREATE settings.xml with <servers> + <mirrors>"
    else
      if grep -qF "<servers>" "$file" 2>/dev/null; then
        echo "[dry-run]   action : MERGE <server> into existing <servers>"
      else
        echo "[dry-run]   action : CREATE <servers> with Endor <server>"
      fi
      if grep -qF "<mirrors>" "$file" 2>/dev/null; then
        echo "[dry-run]   action : MERGE <mirror> into existing <mirrors> (inserted first)"
      else
        echo "[dry-run]   action : CREATE <mirrors> with Endor <mirror>"
      fi
    fi
    echo "[dry-run]   file    : $file"
    echo "$fragment" | sed 's/^/[dry-run]     /'
    echo ""
    rm -f "$sf_server" "$sf_mirror"
    return 0
  fi

  mkdir -p "$(dirname "$file")"

  # Case 1: file absent -> minimal settings.xml with both containers, in order.
  if [[ ! -f "$file" ]]; then
    {
      echo '<?xml version="1.0" encoding="UTF-8"?>'
      echo '<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"'
      echo '          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
      echo '          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.2.0 http://maven.apache.org/xsd/settings-1.2.0.xsd">'
      echo '  <servers>'; cat "$sf_server"; echo '  </servers>'
      echo '  <mirrors>'; cat "$sf_mirror"; echo '  </mirrors>'
      echo '</settings>'
    } > "$file"
    chown "$owner:$group" "$file"; chmod 600 "$file"
    rm -f "$sf_server" "$sf_mirror"
    return 0
  fi

  # Case 2: strip any prior managed entries so re-runs stay idempotent.
  tmp=$(mktemp); _endor_xml_strip_managed "$file" > "$tmp"; mv "$tmp" "$file"

  # Case 3a: merge the <server> entry (create <servers> only if absent).
  tmp=$(mktemp)
  if _endor_xml_into_container "$file" "<servers>" "</servers>" "<servers/>" "$sf_server" > "$tmp"; then
    mv "$tmp" "$file"
  else
    cf=$(mktemp); { echo '  <servers>'; cat "$sf_server"; echo '  </servers>'; } > "$cf"
    _endor_xml_insert_ordered "$file" "$cf" "<mirrors" "<profiles" "<activeProfiles" "<pluginGroups" > "$tmp"
    mv "$tmp" "$file"; rm -f "$cf"
  fi

  # Case 3b: merge the <mirror> entry (create <mirrors> only if absent).
  tmp=$(mktemp)
  if _endor_xml_into_container "$file" "<mirrors>" "</mirrors>" "<mirrors/>" "$sf_mirror" > "$tmp"; then
    mv "$tmp" "$file"
  else
    cf=$(mktemp); { echo '  <mirrors>'; cat "$sf_mirror"; echo '  </mirrors>'; } > "$cf"
    _endor_xml_insert_ordered "$file" "$cf" "<profiles" "<activeProfiles" "<pluginGroups" > "$tmp"
    mv "$tmp" "$file"; rm -f "$cf"
  fi

  rm -f "$sf_server" "$sf_mirror"
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
# Strips the Endor managed entries (new per-entry server/mirror sub-blocks AND the
# legacy combined block) from settings.xml. Any pre-existing <server>/<mirror> the
# user had is preserved. If nothing but empty scaffolding remains, the file is
# deleted. An emptied <servers></servers>/<mirrors></mirrors> we may have created
# is harmless (valid, no-op) and is left in place when other content survives.
remove_xml_block() {
  local file="$1" owner="$2" group="$3" tmp

  [[ -f "$file" ]] || { echo "[endor-remove] skip (not found)    : $file"; return 0; }
  if ! grep -qF "$ENDOR_XML_SERVER_START" "$file" 2>/dev/null \
     && ! grep -qF "$ENDOR_XML_MIRROR_START" "$file" 2>/dev/null \
     && ! grep -qF "$ENDOR_XML_BLOCK_START" "$file" 2>/dev/null; then
    echo "[endor-remove] skip (no Endor block): $file"; return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run]   action : REMOVE Endor <server>/<mirror> from settings.xml"
    echo "[dry-run]   file   : $file"
    return 0
  fi

  tmp=$(mktemp)
  _endor_xml_strip_managed "$file" > "$tmp"

  # Delete only if no real child entry survives. The regex matches the SINGULAR
  # child tags (a following '>' or space) but not the plural containers, so an
  # emptied <servers></servers> does not count as content.
  if ! grep -qE '<(server|mirror|profile|proxy|pluginGroup|repository|activeProfile|localRepository)[ >]' "$tmp"; then
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

  # Scan lines OUTSIDE any Endor-managed region (per-entry server/mirror sub-blocks
  # and the legacy combined block) so a re-run does not flag our own <mirror>.
  if awk -v ss="$ENDOR_XML_SERVER_START" -v se="$ENDOR_XML_SERVER_END" \
         -v ms="$ENDOR_XML_MIRROR_START" -v me="$ENDOR_XML_MIRROR_END" \
         -v bs="$ENDOR_XML_BLOCK_START"  -v be="$ENDOR_XML_BLOCK_END" -v pat="$pattern" '
    index($0,ss){skip=1} index($0,ms){skip=1} index($0,bs){skip=1}
    !skip && $0 ~ pat { found=1 }
    index($0,se){skip=0} index($0,me){skip=0} index($0,be){skip=0}
    END { exit(found ? 0 : 1) }
  ' "$file" 2>/dev/null; then
    echo "[endor] WARNING: existing '${label}' found in ${file}." >&2
    echo "[endor]          Endor block will be inserted — verify key precedence with your tool." >&2
    _ENDOR_WARNED=1
  fi
}
