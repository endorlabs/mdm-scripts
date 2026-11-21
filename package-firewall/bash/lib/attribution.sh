# lib/attribution.sh
# User attribution: the label every generated script attributes to. generate.sh inlines this file
# into every script, before lib/common.sh. Do NOT source this file directly — it is embedded at
# generation time.
#
# The firewall decodes the label from the Basic-auth username, auths with the real API key, and logs
# it as "User". Unverified telemetry only — never an authz signal.
#
# Functions:
#   endor_attr_label        <console-user>     — the label: <console-user>@<machine>
#   endor_attr_username     <label> <key-id>   — the attributed Basic-auth username
#   find_console_user                          — finds the logged-in user when running as root;
#                                                prints nothing when no one is logged in
#   endor_b64, endor_host_label                — what those need

# endor_b64 — portable base64, no line wrapping (GNU wraps at 76 cols; BSD doesn't).
endor_b64() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
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

# endor_attr_label <console-user>
# The label every ecosystem attributes to: <console-user>@<machine>. Fails with no user, when no
# one is logged in. To label users another way (by email, or by looking the machine up), change
# only this function before generating. Anything it calls belongs in this file too.
endor_attr_label() {
  [[ -n "${1:-}" ]] || return 1
  printf '%s@%s' "$1" "$(endor_host_label)"
}

# find_console_user
# MDM tools (Kandji, Jamf) run scripts as root. $HOME resolves to /var/root, which
# is not where developer config files live. Prints the name of the actual logged-in
# console user so config is written to the correct home directory, or nothing when no
# one is logged in: the console belongs to root at the login window, and to
# _mbsetupuser during Setup Assistant.
find_console_user() {
  local user=""

  if command -v logname &>/dev/null; then
    user=$(logname 2>/dev/null || true)
  fi

  if [[ -z "$user" || "$user" == "root" ]] && [[ -e /dev/console ]]; then
    # GNU stat's -f reports on the file system instead, and doesn't take a format.
    if stat -c %U / >/dev/null 2>&1; then
      user=$(stat -c %U /dev/console 2>/dev/null || true)
    else
      user=$(stat -f '%Su' /dev/console 2>/dev/null || true)
    fi
  fi

  case "$user" in
    root|loginwindow|_mbsetupuser) user="" ;;
  esac

  echo "$user"
}
