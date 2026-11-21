# lib/attribution.sh
# User attribution: the label every generated script attributes to, and what VS Code needs to put
# it into its gallery URL. generate.sh inlines this file into every script, before lib/common.sh,
# and into the worker endor-vscode.sh installs, which carries this file alone, so the worker labels
# users as every script does. Do NOT source this file directly — it is embedded at generation time.
#
# The firewall decodes the label from the Basic-auth username, auths with the real API key, and logs
# it as "User". Unverified telemetry only — never an authz signal.
#
# Functions:
#   endor_attr_label        <console-user>     — the label: <console-user>@<machine>
#   endor_attr_username     <label> <key-id>   — the attributed Basic-auth username
#   find_console_user                          — finds the logged-in user when running as root;
#                                                prints nothing when no one is logged in
#   endor_vscode_label      <kept-file> [--kept]
#                                              — VS Code's label: the logged-in user's, or the kept one
#   endor_vscode_keep_label <kept-file> <label> — keeps VS Code's label beside a method's state
#   endor_vscode_url        <url> <label>      — VS Code's gallery URL with the label in its token
#   endor_b64, endor_b64d, endor_host_label    — what those need

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
# The label every ecosystem attributes to, VS Code included: <console-user>@<machine>. Fails with
# no user, when no one is logged in. To label users another way (by email, or by looking the
# machine up), change only this function before generating. Anything it calls must be in this
# file too, because the worker endor-vscode.sh installs carries only this file.
endor_attr_label() {
  [[ -n "${1:-}" ]] || return 1
  printf '%s@%s' "$1" "$(endor_host_label)"
}

# ── VS Code's user attribution (endor-vscode.sh, and its worker) ──────────────
# VS Code's gallery URL is machine-wide, so it carries the label of the user logged in now and,
# while no one is, the label kept beside each method's root-only state.

# endor_vscode_label <kept-file> [--kept]: the label of the user logged in now. With no one logged
# in, or with --kept, the one in <kept-file>, unless endor_attr_label gives one without a user.
# Fails with none, or with one that has control characters, and when someone is logged in whose
# label fails: the kept one may be another user's. With no <kept-file>, only the user logged in now.
endor_vscode_label() {
  local user="" label=""
  if [[ "${2:-}" != "--kept" ]]; then
    user=$(find_console_user)
    label=$(endor_attr_label "$user" 2>/dev/null) || label=""
    [[ "$label" != *[[:cntrl:]]* ]] || label=""
    [[ -z "$user" || -n "$label" ]] || return 1
  fi
  if [[ -z "$label" && -n "$1" && -f "$1" && ! -L "$1" ]]; then
    IFS= read -r label < "$1" || true
    label="${label%$'\r'}"
  fi
  [[ -n "$label" && "$label" != *[[:cntrl:]]* ]] || return 1
  printf '%s' "$label"
}

# endor_vscode_keep_label <kept-file> <label>: keeps the label when it changed, if the file's
# folder, a method's root-only state, exists. It never creates the folder.
endor_vscode_keep_label() {
  [[ -d "${1%/*}" && "$(cat "$1" 2>/dev/null)" != "$2" ]] || return 0
  ( umask 077 && printf '%s\n' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1" ) 2>/dev/null || rm -f "$1.tmp"
}

# endor_b64d <base64>: decoded. macOS takes -D; before macOS 13, its -d is --debug, which encodes.
# GNU takes only -d.
endor_b64d() {
  local out
  out=$(printf '%s' "$1" | base64 -D 2>/dev/null) \
    || out=$(printf '%s' "$1" | base64 -d 2>/dev/null) || return 1
  printf '%s' "$out"
}

# endor_vscode_url <url> <label>: VS Code's gallery URL with the label in its token. The token is
# base64url(<key ID>:<secret>); the key ID becomes the attributed username, as in the other
# ecosystems' credentials, and the firewall decodes it.
endor_vscode_url() {
  local token="${1##*/_ak/}" padded pair
  [[ "$1" == */_ak/* && -n "$token" && "$token" != */* ]] || return 1
  padded=$(printf '%s' "$token" | tr '_-' '/+')
  while (( ${#padded} % 4 )); do padded="$padded="; done
  pair=$(endor_b64d "$padded") || return 1
  [[ "$pair" == ?*:?* ]] || return 1
  token=$(printf '%s:%s' "$(endor_attr_username "$2" "${pair%%:*}")" "${pair#*:}" \
    | endor_b64 | tr -d '=' | tr '+/' '-_')
  printf '%s/_ak/%s' "${1%/_ak/*}" "$token"
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
