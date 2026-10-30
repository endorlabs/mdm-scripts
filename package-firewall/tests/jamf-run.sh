# tests/jamf-run.sh
# Sourced by the macOS end-to-end tests. jamf_run runs a generated script the way Jamf Pro runs a
# policy's script, so the tests meet what a Jamf deployment meets:
#   - as root, from a launchd job in the system domain: launchd's environment (PATH
#     /usr/bin:/bin:/usr/sbin:/sbin, no HOME, no sudo variables, no terminal), and launchd ends
#     whatever the script leaves running when it exits;
#   - executed by its path, so "#!/usr/bin/env bash" finds /bin/bash 3.2 on that PATH;
#   - from a root-owned copy in a folder whose path has a space, like Jamf's
#     /Library/Application Support/JAMF/tmp;
#   - with Jamf's arguments: the target volume "/", the computer name and the console user, then
#     script parameters 4-11, empty unless set.
# It needs passwordless sudo.
#
#   jamf_run [NAME=value...] <script> <log> [parameter...]
#       Runs the script and returns its exit status. Its output goes to <log>, written as the
#       user running the test. The parameters fill Jamf's parameters 4-11. NAME=value pairs go
#       into the job's environment: Jamf sets none, so they are for a test's overrides only.
#   jamf_cleanup
#       Unloads the job and deletes the copies. Call it from the test's exit trap.
#
# Output of root commands is redirected as the user running the test, so it stays readable.
# shellcheck disable=SC2024

JAMF_RUN_LABEL="com.endorlabs.e2e.jamf-run"
JAMF_RUN_DIR=""

# jamf_xml <text>: the text, escaped for a property list.
jamf_xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# jamf_plist <output file> <NAME=value lines> <program argument...>: the launchd job, which
# writes its output to the file. The second argument holds one NAME=value pair a line.
jamf_plist() {
  local out="$1" pairs="$2" pair arg strings="" envs=""
  shift 2
  for arg in "$@"; do
    strings="$strings    <string>$(jamf_xml "$arg")</string>
"
  done
  while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    envs="$envs    <key>$(jamf_xml "${pair%%=*}")</key><string>$(jamf_xml "${pair#*=}")</string>
"
  done <<< "$pairs"
  if [[ -n "$envs" ]]; then
    envs="  <key>EnvironmentVariables</key>
  <dict>
$envs  </dict>
"
  fi
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$JAMF_RUN_LABEL</string>
  <key>ProgramArguments</key>
  <array>
$strings  </array>
$envs  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$(jamf_xml "$out")</string>
  <key>StandardErrorPath</key><string>$(jamf_xml "$out")</string>
</dict>
</plist>
PLIST
}

jamf_run() {
  local pairs="" script log name copy plist out rc command i status start
  local limit="${JAMF_RUN_TIMEOUT:-1800}"
  local -a params
  while [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    pairs="$pairs$1
"
    shift
  done
  script="$1"
  log="$2"
  shift 2
  if (( $# > 8 )); then
    echo "jamf_run: Jamf has eight script parameters, not $#" >&2
    return 2
  fi
  if [[ -z "$JAMF_RUN_DIR" ]]; then
    JAMF_RUN_DIR=$(sudo /usr/bin/mktemp -d /private/var/tmp/endor-e2e-jamf.XXXXXX) || return 2
    sudo /bin/mkdir -p "$JAMF_RUN_DIR/Application Support/JAMF/tmp" || return 2
  fi
  name=$(basename "$script")
  copy="$JAMF_RUN_DIR/Application Support/JAMF/tmp/$name"
  plist="$JAMF_RUN_DIR/$JAMF_RUN_LABEL.plist"
  out="$JAMF_RUN_DIR/output.log"
  rc="$JAMF_RUN_DIR/rc"
  sudo /usr/bin/install -m 0700 -o root -g wheel "$script" "$copy" || return 2
  sudo /bin/rm -f "$out" "$rc" "$rc.tmp"

  # Jamf's parameters 4-11: the ones given, then empty strings.
  params=("$@")
  for (( i = $#; i < 8; i++ )); do
    params+=("")
  done
  # /bin/sh only records the exit status; it runs the script by its path, as Jamf does.
  command="\"\$0\" \"\$@\"; echo \$? > '$rc.tmp' && mv '$rc.tmp' '$rc'"
  jamf_plist "$out" "$pairs" /bin/sh -c "$command" "$copy" / \
    "$(/usr/sbin/scutil --get ComputerName)" "$(/usr/bin/stat -f %Su /dev/console)" "${params[@]}" \
    | sudo /usr/bin/tee "$plist" >/dev/null
  sudo /bin/chmod 644 "$plist"

  sudo /bin/launchctl bootout "system/$JAMF_RUN_LABEL" >/dev/null 2>&1 || true
  if ! sudo /bin/launchctl bootstrap system "$plist"; then
    echo "jamf_run: launchd did not load $plist" >&2
    return 2
  fi
  start=$SECONDS
  until sudo /bin/test -f "$rc"; do
    if (( SECONDS - start >= limit )); then
      sudo /bin/launchctl bootout "system/$JAMF_RUN_LABEL" >/dev/null 2>&1 || true
      sudo /bin/cat "$out" > "$log" 2>/dev/null
      echo "jamf_run: $name did not finish within ${limit}s" >&2
      return 124
    fi
    sleep 2
  done
  status=$(sudo /bin/cat "$rc")
  sudo /bin/launchctl bootout "system/$JAMF_RUN_LABEL" >/dev/null 2>&1 || true
  sudo /bin/cat "$out" > "$log"
  sudo /bin/rm -f "$plist" "$copy" "$out" "$rc"
  return "${status:-2}"
}

jamf_cleanup() {
  [[ -n "$JAMF_RUN_DIR" ]] || return 0
  sudo /bin/launchctl bootout "system/$JAMF_RUN_LABEL" >/dev/null 2>&1 || true
  sudo /bin/rm -rf "$JAMF_RUN_DIR"
  JAMF_RUN_DIR=""
}
