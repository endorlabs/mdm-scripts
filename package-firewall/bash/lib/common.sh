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
#   vscode_install_paths / vscode_managed_state / vscode_patch / vscode_unpatch
#   vscode_install_watcher / vscode_remove_watcher
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

# launchd / systemd identifiers for the product.json re-apply watcher.
# The three directories are overridable purely so the generated plist and unit
# files can be inspected and linted without root; deployments use the defaults.
ENDOR_VSCODE_LABEL="com.endorlabs.pkgfirewall.vscode"
ENDOR_VSCODE_LOG="${ENDOR_VSCODE_LOG:-/var/log/endor-vscode-firewall.log}"
ENDOR_VSCODE_LAUNCHD_DIR="${ENDOR_VSCODE_LAUNCHD_DIR:-/Library/LaunchDaemons}"
ENDOR_VSCODE_SYSTEMD_DIR="${ENDOR_VSCODE_SYSTEMD_DIR:-/etc/systemd/system}"
ENDOR_VSCODE_CRON_DIR="${ENDOR_VSCODE_CRON_DIR:-/etc/cron.hourly}"

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
# Hence: a key-level merge into the depth-1 "extensionsGallery" object, a
# top-level JSON marker key holding the byte-exact original for restore, and a
# watcher to re-apply after updates.
#
# The editors below are deliberately line-oriented rather than JSON-aware. There
# is no jq or python3 guarantee on a stock macOS or a minimal Linux image, and
# plutil is not an option: it reorders every top-level key and minifies the file
# (and `plutil -lint` does not even validate JSON — it accepts old-style plists).
# Shipped product.json is pretty-printed, one entry per line, so a depth-1 line
# range is unambiguous. Anything else falls through to vscode_patch_via_node.
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

# vscode_install_paths [user_home]
# Prints one product.json path per line for every VS Code install found, stable
# and Insiders. On Windows the equivalent must resolve the console user's
# AppData rather than the SYSTEM account's; here the analogue is <user_home>.
vscode_install_paths() {
  local home="${1:-}" p
  local -a candidates=()

  if [[ "$(uname -s)" == "Darwin" ]]; then
    candidates+=(
      "/Applications/Visual Studio Code.app/Contents/Resources/app/product.json"
      "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/product.json"
    )
    if [[ -n "$home" ]]; then
      candidates+=(
        "$home/Applications/Visual Studio Code.app/Contents/Resources/app/product.json"
        "$home/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/product.json"
      )
    fi
  else
    candidates+=(
      "/usr/share/code/resources/app/product.json"
      "/usr/share/code-insiders/resources/app/product.json"
      "/opt/visual-studio-code/resources/app/product.json"
      "/opt/visual-studio-code-insiders/resources/app/product.json"
      "/usr/lib/code/product.json"
      "/snap/code/current/usr/share/code/resources/app/product.json"
    )
  fi

  for p in "${candidates[@]}"; do
    [[ -f "$p" ]] && printf '%s\n' "$p"
  done
  return 0
}

# vscode_edition_label <product.json> — human label for logs.
vscode_edition_label() {
  local name
  name=$(endor_json_top_string "$1" nameLong 2>/dev/null) || name=""
  [[ -n "$name" ]] || name="VS Code"
  printf '%s' "$name"
}

# vscode_is_readonly_install <product.json>
# snap and flatpak mount their payload read-only, so these installs are
# structurally unpatchable. Tested by path prefix rather than by [[ -w ]],
# because under root [[ -w ]] reports true even on a read-only mount.
vscode_is_readonly_install() {
  case "$1" in
    /snap/*|/var/lib/snapd/*|/var/lib/flatpak/*|/app/*|*/.local/share/flatpak/*) return 0 ;;
  esac
  return 1
}

# vscode_can_write <product.json>
# Opens the file for append without writing anything: no content change, no mtime
# change, but it fails with EPERM exactly where a real write would. On macOS
# Ventura+ that is the App Management (TCC) check, which root is NOT exempt from.
vscode_can_write() {
  ( : >> "$1" ) 2>/dev/null
}

# vscode_node_bin <product.json>
# Path to the bundled Electron, usable as node via ELECTRON_RUN_AS_NODE=1 — the
# same trick VS Code's own bin/code shim uses, so it needs no extra dependency.
# The macOS executable name comes from CFBundleExecutable ("Code" on stable,
# different on Insiders); it must never be hardcoded to "Electron".
vscode_node_bin() {
  local pj="$1" root exe c
  root=$(cd "$(dirname "$pj")/../.." 2>/dev/null && pwd) || return 1

  if [[ -f "$root/Info.plist" && -x /usr/bin/plutil ]]; then
    exe=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$root/Info.plist" 2>/dev/null)
    if [[ -n "$exe" && -x "$root/MacOS/$exe" ]]; then
      printf '%s' "$root/MacOS/$exe"; return 0
    fi
  fi
  # Linux .deb/.rpm/tarball: the Electron binary sits at the install root next to
  # resources/. Deliberately NOT $root/bin/code or /usr/bin/code — those are the
  # `code` CLI wrapper, which would interpret -e as a CLI flag rather than as node.
  for c in "$root/code" "$root/code-insiders"; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# vscode_marker_field <product.json> <field>
# Reads one field out of the marker. The marker holds only base64, an integer and
# URL-safe text, so sed is enough — the removal path must not need a JSON parser.
#
# Two shapes have to be handled: the awk writer emits the whole marker on one
# line, while the node writer runs it through JSON.stringify and pretty-prints it
# across many. Reading only the single-line shape silently breaks restore for
# node-written files, so fall back to extracting the marker object as a block.
vscode_marker_field() {
  local file="$1" field="$2" v pat
  pat="s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"

  v=$(grep -F "\"${ENDOR_JSON_MARKER_KEY}\"" "$file" 2>/dev/null | sed -n "$pat" | head -1)
  if [[ -z "$v" ]]; then
    v=$(endor_json_extract_top_object "$file" "$ENDOR_JSON_MARKER_KEY" 2>/dev/null \
        | sed -n "$pat" | head -1)
  fi
  printf '%s' "$v"
}

# vscode_managed_state <product.json> <expected_service_url> <delete_keys>
# Prints unmanaged | current | stale.
#   unmanaged — no marker; capture the original, then patch
#   current   — marker present, expected serviceUrl in place, deleted keys gone;
#               nothing to do, so no write happens at all
#   stale     — marker present but the content no longer matches (credential
#               rotation, namespace change, edited block, or a VS Code update
#               that restored a key). Must be unpatched before re-patching:
#               never patch on top of a patch, or the original is lost forever.
vscode_managed_state() {
  local file="$1" url="$2" delete_keys="$3" k

  grep -qF "\"${ENDOR_JSON_MARKER_KEY}\"" "$file" 2>/dev/null || {
    printf 'unmanaged'; return 0
  }
  if ! grep -qF "\"serviceUrl\": \"${url}\"" "$file" 2>/dev/null; then
    printf 'stale'; return 0
  fi
  for k in $delete_keys; do
    if grep -qF "\"${k}\"" "$file" 2>/dev/null; then printf 'stale'; return 0; fi
  done
  printf 'current'
}

# vscode_top_indent <product.json> — the file's own top-level indent unit.
vscode_top_indent() {
  local t
  t=$(awk 'NR == 2 { s = $0; sub(/[^ \t].*/, "", s); print s; exit }' "$1")
  [[ -n "$t" ]] && printf '%s' "$t" || printf '\t'
}

# vscode_marker_base <namespace> <fqdn> <product.json>
# The marker fields that both writers share. Values are base64, integers and
# URL-safe text only, so no JSON escaper is needed here.
vscode_marker_base() {
  local ns="$1" fqdn="$2" pj="$3" ver commit
  ver=$(endor_json_top_string "$pj" version 2>/dev/null) || ver="unknown"
  commit=$(endor_json_top_string "$pj" commit 2>/dev/null) || commit="unknown"
  printf '{"schema":1,"namespace":"%s","fqdn":"%s","appVersion":"%s","appCommit":"%s","patchedAt":"%s"' \
    "$ns" "$fqdn" "$ver" "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# vscode_patch_via_node <product.json> <node_bin> <url> <delete_keys> <marker_base> <out>
# Fallback for a product.json that is not line-oriented (repackaged or minified).
# Reformats the whole file, which is acceptable precisely because the layout was
# already non-standard. Records via:"node" so unpatch restores the same way.
vscode_patch_via_node() {
  local pj="$1" node_bin="$2" url="$3" delete_keys="$4" marker_base="$5" out="$6"
  ENDOR_PJ="$pj" ENDOR_URL="$url" ENDOR_DEL="$delete_keys" ENDOR_OUT="$out" \
  ENDOR_MARKER_KEY="$ENDOR_JSON_MARKER_KEY" ENDOR_MARKER="${marker_base}}" \
  ELECTRON_RUN_AS_NODE=1 "$node_bin" -e '
    const fs = require("fs");
    const d = JSON.parse(fs.readFileSync(process.env.ENDOR_PJ, "utf8"));
    const orig = JSON.stringify(d.extensionsGallery || {});
    const g = Object.assign({}, d.extensionsGallery || {});
    g.serviceUrl = process.env.ENDOR_URL;
    (process.env.ENDOR_DEL || "").split(/\s+/).filter(Boolean).forEach(k => { delete g[k]; });
    const marker = Object.assign(JSON.parse(process.env.ENDOR_MARKER), {
      via: "node",
      originalExtensionsGalleryB64: Buffer.from(orig).toString("base64"),
    });
    const out = {};
    out[process.env.ENDOR_MARKER_KEY] = marker;
    for (const k of Object.keys(d)) out[k] = (k === "extensionsGallery") ? g : d[k];
    fs.writeFileSync(process.env.ENDOR_OUT, JSON.stringify(out, null, "\t"));
  ' >/dev/null 2>&1
}

# vscode_unpatch_via_node <product.json> <node_bin> <out>
vscode_unpatch_via_node() {
  ENDOR_PJ="$1" ENDOR_OUT="$3" ENDOR_MARKER_KEY="$ENDOR_JSON_MARKER_KEY" \
  ELECTRON_RUN_AS_NODE=1 "$2" -e '
    const fs = require("fs");
    const d = JSON.parse(fs.readFileSync(process.env.ENDOR_PJ, "utf8"));
    const m = d[process.env.ENDOR_MARKER_KEY] || {};
    if (m.originalExtensionsGalleryB64) {
      d.extensionsGallery = JSON.parse(
        Buffer.from(m.originalExtensionsGalleryB64, "base64").toString("utf8"));
    }
    delete d[process.env.ENDOR_MARKER_KEY];
    fs.writeFileSync(process.env.ENDOR_OUT, JSON.stringify(d, null, "\t"));
  ' >/dev/null 2>&1
}

# vscode_patch <product.json> <service_url> <set_lines> <delete_keys> <namespace> <fqdn>
# Returns 0 patched · 2 already current (nothing written) · 1 failed (caller warns).
#
# <set_lines> is the rendered gallery block, one '"key": value' per line.
# <delete_keys> is a space-separated list of keys to drop from extensionsGallery.
vscode_patch() {
  local pj="$1" url="$2" set_lines="$3" delete_keys="$4" ns="$5" fqdn="$6"
  local label state node_bin tind marker_base origb64 rc
  local setf delf blockf tmp tmp2

  label=$(vscode_edition_label "$pj")

  if vscode_is_readonly_install "$pj"; then
    echo "[endor-vscode] SKIP  ${label}: read-only install (snap/flatpak) — $pj" >&2
    echo "[endor-vscode]       product.json cannot be patched there. Install the .deb/.tar.gz build" >&2
    echo "[endor-vscode]       instead, or enforce via the AllowedExtensions policy." >&2
    return 1
  fi

  state=$(vscode_managed_state "$pj" "$url" "$delete_keys")
  if [[ "$state" == "current" ]]; then
    echo "[endor-vscode] ok    ${label}: already current — no change"
    return 2
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run]   action : ${state} -> PATCH product.json"
    [[ "$state" == "stale" ]] && echo "[dry-run]   note   : stale — original restored first, then re-patched"
    echo "[dry-run]   file   : $pj"
    echo "[dry-run]   set    : $(printf '%s' "$set_lines" | endor_redact_ak)"
    echo "[dry-run]   remove : ${delete_keys:-<none>}"
    echo "[dry-run]   marker : ${ENDOR_JSON_MARKER_KEY} (carries the original for restore)"
    echo ""
    return 0
  fi

  if ! vscode_can_write "$pj"; then
    echo "[endor-vscode] ERROR ${label}: cannot write $pj" >&2
    if [[ "$(uname -s)" == "Darwin" ]]; then
      echo "[endor-vscode]       On macOS Ventura and later, writing inside another developer's" >&2
      echo "[endor-vscode]       .app bundle requires the App Management (SystemPolicyAppBundles)" >&2
      echo "[endor-vscode]       TCC grant — root is NOT exempt. Grant your MDM agent App" >&2
      echo "[endor-vscode]       Management (or Full Disk Access) via a PPPC profile and re-run." >&2
    else
      echo "[endor-vscode]       Re-run with sufficient privileges (root) for this install path." >&2
    fi
    return 1
  fi

  if [[ "$state" == "stale" ]]; then
    echo "[endor-vscode]       ${label}: managed but out of date — restoring original first"
    vscode_unpatch "$pj" || return 1
  fi

  node_bin=$(vscode_node_bin "$pj" 2>/dev/null || true)
  tind=$(vscode_top_indent "$pj")
  marker_base=$(vscode_marker_base "$ns" "$fqdn" "$pj")

  setf=$(mktemp); delf=$(mktemp); blockf=$(mktemp); tmp=$(mktemp); tmp2=$(mktemp)
  printf '%s\n' "$set_lines" > "$setf"
  printf '%s\n' $delete_keys > "$delf"

  rc=1
  if endor_json_extract_top_object "$pj" extensionsGallery > "$blockf" 2>/dev/null; then
    origb64=$(endor_b64 < "$blockf")
    if endor_json_merge_object_keys "$pj" extensionsGallery "$setf" "$delf" > "$tmp" 2>/dev/null; then
      endor_json_insert_top_line "$tmp" \
        "${tind}\"${ENDOR_JSON_MARKER_KEY}\": ${marker_base},\"via\":\"awk\",\"originalExtensionsGalleryB64\":\"${origb64}\"}," \
        > "$tmp2" && rc=0
    fi
  fi

  if [[ "$rc" -ne 0 ]]; then
    if [[ -n "$node_bin" ]] && vscode_patch_via_node \
         "$pj" "$node_bin" "$url" "$delete_keys" "$marker_base" "$tmp2"; then
      echo "[endor-vscode]       ${label}: product.json is not line-oriented — used the bundled node writer"
      rc=0
    else
      echo "[endor-vscode] ERROR ${label}: unrecognised product.json layout and no usable node binary" >&2
      echo "[endor-vscode]       $pj was left untouched." >&2
      rm -f "$setf" "$delf" "$blockf" "$tmp" "$tmp2"
      return 1
    fi
  fi

  if ! endor_json_validate "$tmp2" "$node_bin"; then
    echo "[endor-vscode] ERROR ${label}: patched product.json failed validation — not installing it" >&2
    echo "[endor-vscode]       $pj was left untouched." >&2
    rm -f "$setf" "$delf" "$blockf" "$tmp" "$tmp2"
    return 1
  fi

  endor_replace_contents_inplace "$pj" "$tmp2"
  rc=$?
  rm -f "$setf" "$delf" "$blockf" "$tmp" "$tmp2"

  if [[ "$rc" -ne 0 ]]; then
    echo "[endor-vscode] ERROR ${label}: write failed for $pj" >&2
    return 1
  fi
  echo "[endor-vscode] ok    ${label}: gallery routed through the Endor firewall"
  return 0
}

# vscode_unpatch <product.json>
# Restores the captured original extensionsGallery and drops the marker. Returns
# 0 on success (including "nothing to do"), 1 on failure.
vscode_unpatch() {
  local pj="$1" label via origb64 blockf tmp tmp2 node_bin rc

  label=$(vscode_edition_label "$pj")

  if ! grep -qF "\"${ENDOR_JSON_MARKER_KEY}\"" "$pj" 2>/dev/null; then
    echo "[endor-vscode] skip  ${label}: not managed by Endor — $pj"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run]   action : RESTORE original extensionsGallery, drop marker"
    echo "[dry-run]   file   : $pj"
    return 0
  fi

  if ! vscode_can_write "$pj"; then
    echo "[endor-vscode] ERROR ${label}: cannot write $pj (App Management/TCC or privileges)" >&2
    return 1
  fi

  via=$(vscode_marker_field "$pj" via)
  origb64=$(vscode_marker_field "$pj" originalExtensionsGalleryB64)
  node_bin=$(vscode_node_bin "$pj" 2>/dev/null || true)

  if [[ -z "$origb64" ]]; then
    echo "[endor-vscode] ERROR ${label}: marker carries no original — refusing to guess" >&2
    echo "[endor-vscode]       Reinstall ${label} to restore a pristine product.json." >&2
    return 1
  fi

  tmp=$(mktemp); tmp2=$(mktemp); blockf=$(mktemp)
  rc=1

  if [[ "$via" == "node" ]]; then
    if [[ -n "$node_bin" ]] && vscode_unpatch_via_node "$pj" "$node_bin" "$tmp2"; then rc=0; fi
  else
    printf '%s' "$origb64" | endor_b64d > "$blockf" 2>/dev/null
    if [[ -s "$blockf" ]] \
       && endor_json_replace_top_object "$pj" extensionsGallery "$blockf" > "$tmp" 2>/dev/null \
       && endor_json_remove_top_key "$tmp" "$ENDOR_JSON_MARKER_KEY" > "$tmp2"; then rc=0; fi
  fi

  if [[ "$rc" -ne 0 ]] || ! endor_json_validate "$tmp2" "$node_bin"; then
    echo "[endor-vscode] ERROR ${label}: restore failed validation — $pj left as-is" >&2
    rm -f "$tmp" "$tmp2" "$blockf"
    return 1
  fi

  endor_replace_contents_inplace "$pj" "$tmp2"
  rc=$?
  rm -f "$tmp" "$tmp2" "$blockf"

  if [[ "$rc" -ne 0 ]]; then
    echo "[endor-vscode] ERROR ${label}: write failed for $pj" >&2
    return 1
  fi
  echo "[endor-vscode] ok    ${label}: original gallery restored"
  return 0
}

# ── product.json re-apply watcher ─────────────────────────────────────────────
# VS Code replaces product.json wholesale on every update — monthly for stable,
# nightly for Insiders — on a schedule uncorrelated with MDM check-in. Waiting for
# the next check-in would leave the fleet unfiltered for part of every day once
# Insiders is in scope, so a watcher is the default rather than an extra.
#
# The race is not fully closable: if the user relaunches VS Code before the
# watcher fires, that session talks to the public marketplace. Both platforms
# therefore watch the file *and* its parent directory (the updater swaps the whole
# directory, so a file-only vnode watch goes stale) and keep an hourly trigger as
# the real backstop. repatch_count in the state file makes the races countable
# instead of invisible.

# endor_vscode_state_dir — sidecar dir for watcher telemetry and the repatch
# payload. Never inside the app bundle. Overridable for the same reason as the
# watcher directories above: so it can be exercised without root.
endor_vscode_state_dir() {
  if [[ -n "${ENDOR_VSCODE_STATE_DIR:-}" ]]; then
    printf '%s' "$ENDOR_VSCODE_STATE_DIR"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s' "/Library/Application Support/Endor/package-firewall/vscode"
  else
    printf '%s' "/var/lib/endor/package-firewall/vscode"
  fi
}

# vscode_state_set <key> <value> — KEY=VALUE sidecar, deliberately not JSON so the
# removal path needs no parser.
vscode_state_set() {
  local dir key="$1" value="$2" f tmp
  dir=$(endor_vscode_state_dir); f="$dir/state"
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp=$(mktemp)
  [[ -f "$f" ]] && grep -v "^${key}=" "$f" > "$tmp" 2>/dev/null
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$f" 2>/dev/null && chmod 600 "$f" 2>/dev/null
  return 0
}

# vscode_state_get <key>
vscode_state_get() {
  local f
  f="$(endor_vscode_state_dir)/state"
  [[ -f "$f" ]] || return 1
  sed -n "s/^${1}=//p" "$f" | tail -1
}

# vscode_state_report — surface watcher activity into MDM logs, so an admin can
# see that updates really are clobbering product.json on this fleet.
vscode_state_report() {
  local n last
  n=$(vscode_state_get repatch_count 2>/dev/null) || n=""
  last=$(vscode_state_get last_repatch 2>/dev/null) || last=""
  if [[ -n "$n" && "$n" != "0" ]]; then
    echo "[endor-vscode]       watcher has re-applied the patch ${n}× (last: ${last:-unknown})"
  fi
  return 0
}

# vscode_install_watcher <repatch_script> <pathsfile>
vscode_install_watcher() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      echo "[dry-run]   watcher: ${ENDOR_VSCODE_LAUNCHD_DIR}/${ENDOR_VSCODE_LABEL}.plist (WatchPaths + hourly)"
    else
      echo "[dry-run]   watcher: systemd endor-vscode-firewall.{service,path,timer}, or /etc/cron.hourly fallback"
    fi
    echo "[dry-run]   repatch: $1"
    return 0
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    _vscode_watcher_launchd "$1" "$2"
  else
    _vscode_watcher_linux "$1" "$2"
  fi
}

# _vscode_watcher_launchd <repatch_script> <pathsfile>
# Built with printf, not a heredoc: inline_common() strips blank and '# '-prefixed
# lines, which would silently mangle heredoc content.
_vscode_watcher_launchd() {
  local script="$1" pathsfile="$2" plist p dir
  plist="${ENDOR_VSCODE_LAUNCHD_DIR}/${ENDOR_VSCODE_LABEL}.plist"

  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    printf '\t<key>Label</key><string>%s</string>\n' "$ENDOR_VSCODE_LABEL"
    printf '%s\n' '	<key>ProgramArguments</key>'
    printf '%s\n' '	<array>'
    printf '\t\t<string>/bin/bash</string>\n'
    printf '\t\t<string>%s</string>\n' "$script"
    printf '%s\n' '	</array>'
    printf '%s\n' '	<key>RunAtLoad</key><true/>'
    printf '%s\n' '	<key>StartInterval</key><integer>3600</integer>'
    printf '%s\n' '	<key>WatchPaths</key>'
    printf '%s\n' '	<array>'
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      dir=$(dirname "$p")
      printf '\t\t<string>%s</string>\n' "$p"
      printf '\t\t<string>%s</string>\n' "$dir"
    done < "$pathsfile"
    printf '%s\n' '	</array>'
    printf '\t<key>StandardOutPath</key><string>%s</string>\n' "$ENDOR_VSCODE_LOG"
    printf '\t<key>StandardErrorPath</key><string>%s</string>\n' "$ENDOR_VSCODE_LOG"
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
  } > "$plist"

  chown root:wheel "$plist" 2>/dev/null
  chmod 644 "$plist" 2>/dev/null

  launchctl bootout "system/${ENDOR_VSCODE_LABEL}" 2>/dev/null || true
  if ! launchctl bootstrap system "$plist" 2>/dev/null; then
    launchctl load -w "$plist" 2>/dev/null || {
      echo "[endor-vscode] WARNING: could not load the update watcher ($plist)." >&2
      echo "[endor-vscode]          The patch is in place but will be lost on the next VS Code update." >&2
      _ENDOR_WARNED=1
      return 1
    }
  fi
  echo "[endor-vscode]       update watcher installed → $plist"
  return 0
}

# _vscode_watcher_linux <repatch_script> <pathsfile>
# systemd .path units track vnodes just like launchd WatchPaths, so both the file
# and its parent directory are watched; the .timer is the backstop. Without
# systemd, run-parts drives an hourly cron job — the filename must carry no
# extension or run-parts skips it.
_vscode_watcher_linux() {
  local script="$1" pathsfile="$2" p unit
  if command -v systemctl &>/dev/null && [[ -d "$ENDOR_VSCODE_SYSTEMD_DIR" ]]; then
    {
      printf '%s\n' '[Unit]'
      printf '%s\n' 'Description=Re-apply Endor Package Firewall settings to VS Code product.json'
      printf '%s\n' '[Service]'
      printf '%s\n' 'Type=oneshot'
      printf 'ExecStart=/bin/bash %s\n' "$script"
      printf 'StandardOutput=append:%s\n' "$ENDOR_VSCODE_LOG"
      printf 'StandardError=append:%s\n' "$ENDOR_VSCODE_LOG"
    } > "${ENDOR_VSCODE_SYSTEMD_DIR}/endor-vscode-firewall.service"
    {
      printf '%s\n' '[Unit]'
      printf '%s\n' 'Description=Watch VS Code product.json for updater overwrites'
      printf '%s\n' '[Path]'
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        printf 'PathModified=%s\n' "$p"
        printf 'PathModified=%s\n' "$(dirname "$p")"
      done < "$pathsfile"
      printf '%s\n' 'Unit=endor-vscode-firewall.service'
      printf '%s\n' '[Install]'
      printf '%s\n' 'WantedBy=multi-user.target'
    } > "${ENDOR_VSCODE_SYSTEMD_DIR}/endor-vscode-firewall.path"
    {
      printf '%s\n' '[Unit]'
      printf '%s\n' 'Description=Hourly backstop for the Endor VS Code product.json patch'
      printf '%s\n' '[Timer]'
      printf '%s\n' 'OnBootSec=1min'
      printf '%s\n' 'OnUnitActiveSec=1h'
      printf '%s\n' 'Unit=endor-vscode-firewall.service'
      printf '%s\n' '[Install]'
      printf '%s\n' 'WantedBy=timers.target'
    } > "${ENDOR_VSCODE_SYSTEMD_DIR}/endor-vscode-firewall.timer"
    chmod 644 "$ENDOR_VSCODE_SYSTEMD_DIR"/endor-vscode-firewall.* 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    systemctl enable --now endor-vscode-firewall.path endor-vscode-firewall.timer 2>/dev/null || {
      echo "[endor-vscode] WARNING: systemd units written but could not be enabled." >&2
      _ENDOR_WARNED=1
      return 1
    }
    echo "[endor-vscode]       update watcher installed → systemd endor-vscode-firewall.{path,timer}"
    return 0
  fi

  unit="${ENDOR_VSCODE_CRON_DIR}/endor-vscode-firewall"
  if [[ -d "$ENDOR_VSCODE_CRON_DIR" ]]; then
    printf '#!/bin/sh\nexec /bin/bash %s >> %s 2>&1\n' "$script" "$ENDOR_VSCODE_LOG" > "$unit"
    chmod 755 "$unit"
    echo "[endor-vscode]       update watcher installed → $unit (no systemd; hourly cron)"
    return 0
  fi

  echo "[endor-vscode] WARNING: no systemd and no ${ENDOR_VSCODE_CRON_DIR} — cannot install the update watcher." >&2
  echo "[endor-vscode]          The patch will be lost on the next VS Code update. Re-push on check-in," >&2
  echo "[endor-vscode]          or schedule $script yourself." >&2
  _ENDOR_WARNED=1
  return 1
}

# vscode_remove_watcher — offboarding; safe to call when nothing is installed.
vscode_remove_watcher() {
  local plist="${ENDOR_VSCODE_LAUNCHD_DIR}/${ENDOR_VSCODE_LABEL}.plist"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run]   action : REMOVE update watcher (launchd/systemd/cron) and sidecar state"
    return 0
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ -f "$plist" ]]; then
      launchctl bootout "system/${ENDOR_VSCODE_LABEL}" 2>/dev/null \
        || launchctl unload -w "$plist" 2>/dev/null || true
      rm -f "$plist"
      echo "[endor-remove] watcher removed     : $plist"
    else
      echo "[endor-remove] skip (no watcher)   : $plist"
    fi
  else
    if [[ -f "${ENDOR_VSCODE_SYSTEMD_DIR}/endor-vscode-firewall.path" ]]; then
      systemctl disable --now endor-vscode-firewall.path endor-vscode-firewall.timer 2>/dev/null || true
      rm -f "${ENDOR_VSCODE_SYSTEMD_DIR}/endor-vscode-firewall.service" \
            "${ENDOR_VSCODE_SYSTEMD_DIR}/endor-vscode-firewall.path" \
            "${ENDOR_VSCODE_SYSTEMD_DIR}/endor-vscode-firewall.timer"
      systemctl daemon-reload 2>/dev/null || true
      echo "[endor-remove] watcher removed     : systemd endor-vscode-firewall.*"
    fi
    if [[ -f "${ENDOR_VSCODE_CRON_DIR}/endor-vscode-firewall" ]]; then
      rm -f "${ENDOR_VSCODE_CRON_DIR}/endor-vscode-firewall"
      echo "[endor-remove] watcher removed     : ${ENDOR_VSCODE_CRON_DIR}/endor-vscode-firewall"
    fi
  fi

  local dir
  dir=$(endor_vscode_state_dir)
  if [[ -d "$dir" ]]; then
    rm -rf "$dir"
    echo "[endor-remove] sidecar removed     : $dir"
  fi
  return 0
}
