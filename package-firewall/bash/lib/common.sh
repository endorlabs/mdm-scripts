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
#
# VS Code (product.json) — see the "VS Code" section at the bottom of this file:
#   endor_b64url / endor_b64d                  — base64url encode (stdin) / decode
#   endor_json_*                               — dependency-free depth-1 JSON editors
#
# NOTE for anyone adding to this file: generate.sh inlines it via
#   grep -v '^# ' lib/common.sh | sed '/^[[:space:]]*$/d'
# so every column-0 comment and every blank line is stripped from the generated
# scripts. Nothing here may depend on a blank line or a '# '-prefixed line *inside*
# a heredoc — which is why the launchd plist and systemd units below are emitted
# with printf rather than heredocs.

# Sentinel markers — identical across all config files so re-runs and remove work reliably
ENDOR_BLOCK_START="# ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) ====="
ENDOR_BLOCK_END="# ===== END ENDOR PACKAGE FIREWALL ====="

# XML sentinel markers — used for settings.xml (Maven), which cannot use '#' comments.
# These MUST match the BEGIN/END lines in shared/blocks/mavensettings.txt exactly,
# or re-runs and removal cannot find the managed block.
ENDOR_XML_BLOCK_START="<!-- ===== BEGIN ENDOR PACKAGE FIREWALL (managed — do not edit) ===== -->"
ENDOR_XML_BLOCK_END="<!-- ===== END ENDOR PACKAGE FIREWALL ===== -->"

# JSON sentinel — product.json cannot carry '#' comments, so the managed marker is
# a top-level JSON key instead. Part of the same SENTINEL CONTRACT as the strings
# above: changing it orphans the marker on every already-deployed machine, and the
# marker is the only record of the original extensionsGallery. Do not change it.
ENDOR_JSON_MARKER_KEY="_endorPackageFirewall"

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

# endor_b64url — base64url from stdin (matches endor_b64's stdin interface).
# Used for the VS Code gallery URL, where the credential is a path segment rather
# than userinfo, so '+' and '/' must be substituted rather than percent-encoded.
# Padding is stripped; the firewall applies strings.TrimRight(token, "=") anyway.
endor_b64url() {
  endor_b64 | tr '+/' '-_' | tr -d '='
}

# endor_redact_ak — replace the _ak/<token> path segment on stdin.
#
# A deliberate deviation from the other ecosystems, which echo full credentialed
# URLs in --dry-run: this token is a bearer credential in a URL *path*, and MDM
# consoles retain script output for far more people than can read the target file.
# Redacted wholesale rather than truncated to a prefix, so it is safe regardless
# of token length.
endor_redact_ak() {
  sed -e 's#/_ak/[A-Za-z0-9_-]*#/_ak/<redacted>#g'
}

# endor_b64d — decode base64 from stdin. Probes for the flag rather than trying
# and retrying, because a failed attempt would already have consumed stdin.
# GNU and current macOS both accept --decode; older macOS base64 only had -D.
endor_b64d() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -D
  fi
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

# ══════════════════════════════════════════════════════════════════════════════
# VS Code
#
# VS Code reads its extension gallery endpoints from product.json inside the
# install directory. Unlike every other ecosystem here, the target file is owned
# and rewritten by a third party (VS Code's own updater), and it is JSON, so it
# can carry neither an Endor sentinel comment nor an env-var reference.
#
# Hence: a key-level merge into the depth-1 "extensionsGallery" object, and a
# top-level JSON marker key holding the byte-exact original for restore.
#
# The editors below are deliberately line-oriented rather than JSON-aware. There
# is no jq or python3 guarantee on a stock macOS or a minimal Linux image, and
# plutil is not an option: it reorders every top-level key and minifies the file
# (and `plutil -lint` does not even validate JSON — it accepts old-style plists).
# Shipped product.json is pretty-printed, one entry per line, so a depth-1 line
# range is unambiguous. Anything else makes these editors decline — they return
# non-zero and leave the file untouched rather than guessing — so a caller can
# fall back to a real JSON parser.
# ══════════════════════════════════════════════════════════════════════════════

# endor_file_has_final_newline <file>
# Command substitution strips trailing newlines, so an empty capture of the last
# byte means that byte was a newline.
endor_file_has_final_newline() {
  [[ -s "$1" ]] || return 1
  [[ -z "$(tail -c 1 "$1")" ]]
}

# endor_replace_contents_inplace <file> <tmp>
# Overwrites <file> with <tmp> in place, preserving inode, mode and owner — we
# must never add a new file inside a signed app bundle, because an *added*
# unsealed resource is worse for codesign than a modified one.
#
# Shipped product.json has no trailing newline but awk always emits one, so the
# newline is normalised back to whatever the target had. Without this every patch
# would dirty the final line and a restore could never be byte-exact.
endor_replace_contents_inplace() {
  local file="$1" tmp="$2" size
  if [[ -f "$file" ]] && ! endor_file_has_final_newline "$file" \
     && endor_file_has_final_newline "$tmp"; then
    size=$(wc -c < "$tmp")
    head -c "$(( size - 1 ))" "$tmp" > "$file"
  else
    cat "$tmp" > "$file"
  fi
}

# endor_json_top_string <file> <key>
# Prints a depth-1 string value. Anchored to the exact indent of the first
# top-level key (line 2), because product.json contains nested "version" keys
# hundreds of lines before the top-level one — an indent-agnostic match returns
# the wrong value.
endor_json_top_string() {
  awk -v key="$2" '
    function indentof(l,   s) { s = l; sub(/[^ \t].*/, "", s); return s }
    NR == 2 { tind = indentof($0) }
    NR >= 2 && !done && indentof($0) == tind {
      pat = "^" tind "\"" key "\"[ \t]*:[ \t]*\""
      if ($0 ~ pat) {
        line = $0; sub(pat, "", line); sub(/".*/, "", line)
        print line; done = 1; exit
      }
    }
    END { exit(done ? 0 : 1) }
  ' "$1"
}

# endor_json_extract_top_object <file> <key>
# Prints the raw lines of a depth-1 object value, opening and closing lines
# included. Returns 1 when the key is absent or the file is not line-oriented,
# which is the signal to fall back to the node writer.
endor_json_extract_top_object() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { pat = "^[ \t]*\"" key "\"[ \t]*:[ \t]*\\{[ \t]*$" }
    !inblk && $0 ~ pat { ind = $0; sub(/".*/, "", ind); inblk = 1; print; next }
    inblk {
      print
      if ($0 == ind "}" || $0 == ind "},") { done = 1; exit }
    }
    END { exit(done ? 0 : 1) }
  ' "$file"
}

# endor_json_merge_object_keys <file> <key> <setfile> <delfile>
# Rewrites the depth-1 object <key>, printing the whole file to stdout:
#   - each line in <setfile> ("key": value) replaces the matching entry in place,
#     keeping its position, or is appended when the key is absent
#   - each key named in <delfile> has its entry removed, however many lines it
#     spans (so deleting a multi-line value like accessSKUs works)
#   - entry-terminating commas are recomputed from scratch, so removing or
#     appending the last entry cannot leave a trailing comma
# Every other byte of the file passes through untouched. Returns 1 if <key> was
# not found as a multi-line object.
#
# Entries are segmented by indent: a line whose indent equals the first inner
# line's indent and which starts with "name": opens a new entry, and everything
# more deeply indented belongs to the entry above it. That is what makes the
# comma rewrite safe across nested arrays and objects.
endor_json_merge_object_keys() {
  local file="$1" key="$2" setfile="$3" delfile="$4"
  awk -v key="$key" -v setfile="$setfile" -v delfile="$delfile" '
    function entrykey(line,   k) {
      if (match(line, /^[ \t]*"[^"]+"[ \t]*:/) == 0) return ""
      k = substr(line, RSTART, RLENGTH)
      sub(/^[ \t]*"/, "", k); sub(/"[ \t]*:$/, "", k)
      return k
    }
    function indentof(line,   s) { s = line; sub(/[^ \t].*/, "", s); return s }
    function flush(   i, j, k, n, out, line, last) {
      for (i = 1; i <= nset; i++) {
        if (setkey[i] in entryidx) {
          j = entryidx[setkey[i]]; entrylines[j] = 1; entry[j, 1] = iind setline[i]
        } else {
          ne++; entryidx[setkey[i]] = ne; entrylines[ne] = 1
          entry[ne, 1] = iind setline[i]
        }
      }
      n = 0
      for (i = 1; i <= ne; i++) if (!dropped[i]) out[++n] = i
      for (i = 1; i <= n; i++) {
        j = out[i]
        last = entrylines[j]
        for (k = 1; k <= last; k++) {
          line = entry[j, k]
          if (k == last) { sub(/,[ \t]*$/, "", line); if (i < n) line = line "," }
          print line
        }
      }
    }
    BEGIN {
      pat = "^[ \t]*\"" key "\"[ \t]*:[ \t]*\\{[ \t]*$"
      while ((getline line < setfile) > 0) {
        if (line ~ /^[ \t]*$/) continue
        sub(/^[ \t]+/, "", line); sub(/,[ \t]*$/, "", line)
        setline[++nset] = line; setkey[nset] = entrykey(line)
      }
      close(setfile)
      while ((getline line < delfile) > 0) {
        if (line ~ /^[ \t]*$/) continue
        gsub(/[ \t]/, "", line); del[line] = 1
      }
      close(delfile)
    }
    !inblk && !after && $0 ~ pat { ind = indentof($0); inblk = 1; print; next }
    inblk {
      if ($0 == ind "}" || $0 == ind "},") {
        flush(); print; inblk = 0; after = 1; next
      }
      if (iind == "") iind = indentof($0)
      k = (indentof($0) == iind) ? entrykey($0) : ""
      if (k != "") {
        ne++; entryidx[k] = ne; entrylines[ne] = 0
        if (k in del) dropped[ne] = 1
      }
      if (ne == 0) { ne = 1; entrylines[1] = 0 }
      entry[ne, ++entrylines[ne]] = $0
      next
    }
    { print }
    END { exit(after ? 0 : 1) }
  ' "$file"
}

# endor_json_replace_top_object <file> <key> <blockfile>
# Replaces the depth-1 object <key> with the verbatim lines of <blockfile>, which
# must include its own opening and closing lines. This is the restore path: the
# captured original goes back exactly as it was. The trailing comma is taken from
# whatever is being replaced, so the enclosing object stays well-formed.
endor_json_replace_top_object() {
  local file="$1" key="$2" blockfile="$3"
  awk -v key="$key" -v blockfile="$blockfile" '
    BEGIN { pat = "^[ \t]*\"" key "\"[ \t]*:[ \t]*\\{[ \t]*$" }
    !inblk && !after && $0 ~ pat { ind = $0; sub(/".*/, "", ind); inblk = 1; next }
    inblk {
      if ($0 == ind "}" || $0 == ind "},") {
        comma = ($0 ~ /,[ \t]*$/)
        nb = 0
        while ((getline line < blockfile) > 0) blk[++nb] = line
        close(blockfile)
        for (i = 1; i <= nb; i++) {
          if (i == nb) { sub(/,[ \t]*$/, "", blk[i]); if (comma) blk[i] = blk[i] "," }
          print blk[i]
        }
        inblk = 0; after = 1
      }
      next
    }
    { print }
    END { exit(after ? 0 : 1) }
  ' "$file"
}

# endor_json_insert_top_line <file> <line>
# Inserts <line> immediately after the opening brace on line 1. Inserting at the
# top means we emit our own trailing comma and never have to append one to a line
# that already exists.
endor_json_insert_top_line() {
  awk -v ins="$2" 'NR == 1 { print; print ins; next } { print }' "$1"
}

# endor_json_remove_top_key <file> <key>
# Removes a depth-1 key whose value is a single-line scalar or object — which is
# how the marker is always written.
endor_json_remove_top_key() {
  awk -v key="$2" '
    BEGIN { pat = "^[ \t]*\"" key "\"[ \t]*:" }
    $0 ~ pat { next }
    { print }
  ' "$1"
}

# endor_json_validate <file> [node_bin]
# Cheap structural self-check, always run; plus a real JSON.parse when a node
# binary is available. Guards against ever installing a corrupt product.json.
#
# The trailing-comma check is not redundant with the node parse: node is not
# always resolvable (some Linux layouts ship no Electron next to product.json),
# and a dangling comma before } or ] is precisely what the comma rewrite in
# endor_json_merge_object_keys could introduce. Checked structurally — a line
# ending in a bare comma followed by a line starting with } or ] — because a
# string value always ends in a quote, so this cannot false-positive on content.
endor_json_validate() {
  local file="$1" node_bin="${2:-}"

  [[ -s "$file" ]] || return 1
  [[ "$(head -c 1 "$file")" == "{" ]] || return 1
  [[ "$(tr -d '[:space:]' < "$file" | tail -c 1)" == "}" ]] || return 1
  [[ "$(grep -cF "\"${ENDOR_JSON_MARKER_KEY}\"" "$file")" -le 1 ]] || return 1

  awk '
    { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line) }
    line == "" { next }
    prev ~ /,$/ && line ~ /^[}\]]/ { bad = 1; exit }
    { prev = line }
    END { exit(bad ? 1 : 0) }
  ' "$file" || return 1

  if [[ -n "$node_bin" && -x "$node_bin" ]]; then
    ENDOR_PJ="$file" ELECTRON_RUN_AS_NODE=1 "$node_bin" \
      -e 'JSON.parse(require("fs").readFileSync(process.env.ENDOR_PJ,"utf8"))' \
      >/dev/null 2>&1 || return 1
  fi
  return 0
}
