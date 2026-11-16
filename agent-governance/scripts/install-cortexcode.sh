#!/bin/sh
# install-cortexcode.sh - put a rendered Cortex Code hooks.json in place for each
# target user, merged with what the user already has. runner.sh runs it as root
# when AGENT=cortexcode.
#
#   install-cortexcode.sh [--users "NAME ..."] [--dest PATH] [--timeout SECS]
#                         [--dry-run] RENDERED
#
#   --users    install for these users. Empty or absent = find them (below).
#   --dest     the file to write. An absolute path, or one that starts with ~/
#              (the target user's home). Default: ~/.snowflake/cortex/hooks.json
#   --timeout  seconds each step run as the user may take (default 30).
#   --dry-run  print "<user> <file>" per target and change nothing.
#
# Cortex Code has no managed hooks path. It reads only a file in the user's home:
# $CORTEX_HOME/hooks.json, else $SNOWFLAKE_HOME/cortex/hooks.json, else
# ~/.snowflake/cortex/hooks.json. The two variables live in the user's shell,
# which root cannot see, so only the default is used unless --dest says otherwise.
#
# The user controls that directory, so a symlink there could aim a root write at
# any file on the machine. So root never opens a path in it. Every read and write
# there runs as the user (runuser on Linux, sudo on macOS: each is the stock way
# for root to run one command as another user on that OS), so a planted symlink
# reaches only what the user could already change. Root works only on copies in
# its own private directory. The file ends up owned by the user, mode 600.
#
# The user also controls those steps: they can stop them, hold a lease on the
# file, or swap it for a FIFO. So each step has a time limit, at most 1 MiB is
# read, and a user whose step fails or times out counts as failed while the run
# goes on to the next user.
#
# The merge keeps the user's own hooks (see cortexcode-merge.sh). A file that
# cannot be merged stays as it is and the user counts as failed, so the MDM
# reports the run. The file is replaced only when its content changes.
#
# Targets, when --users is empty:
#   macOS: the console user. No one at the console means no target.
#   Linux: every user with a login session (logind, else utmp), local or SSH,
#          from UID_MIN in /etc/login.defs (default 1000) up. There is no single
#          console user, and Cortex Code is a terminal agent that people often
#          run over SSH. The display manager's greeter is below UID_MIN.
# No target exits 0 with a message: the next scheduled run tries again.
set -eu

SAFE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
say() { echo "install-cortexcode.sh: $*" >&2; }
die() { say "error: $*"; exit 1; }

MAX_BYTES=1048576
users=""; dest=""; dry=""; rendered=""; timeout=30
while [ $# -gt 0 ]; do
  case "$1" in
    --users|--dest|--timeout) [ $# -ge 2 ] || die "$1 requires a value" ;;
  esac
  case "$1" in
    --users)   users=$2; shift 2 ;;
    --dest)    dest=$2; shift 2 ;;
    --timeout) timeout=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    -*)        die "unknown argument: $1" ;;
    *)         [ -z "$rendered" ] || die "one RENDERED file only"; rendered=$1; shift ;;
  esac
done
[ -n "$rendered" ] || die "usage: install-cortexcode.sh [--users \"NAME ...\"] [--dest PATH] [--timeout SECS] [--dry-run] RENDERED"
case "$timeout" in ''|0|*[!0-9]*) die "--timeout must be a positive number of seconds (got: $timeout)" ;; esac
[ -f "$rendered" ] || die "no such file: $rendered"
case "$dest" in
  ''|/*|'~/'?*) ;;
  *) die "--dest must be absolute or start with ~/ (got: $dest)" ;;
esac
rendered=$(CDPATH='' cd -- "$(dirname -- "$rendered")" && pwd)/$(basename -- "$rendered")
# A target user may not be able to enter root's working directory.
cd / || die "cannot change to /"

os=$(uname -s)

passwd_entry() {
  if command -v getent >/dev/null 2>&1; then
    getent passwd "$1"
  else
    awk -F: -v u="$1" '$1 == u' /etc/passwd
  fi
}

home_of() {
  case "$os" in
    # dscl puts a value that holds a space on the next line, indented by one.
    Darwin) dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '
              /^NFSHomeDirectory:/ { v = substr($0, 18); sub(/^ /, "", v)
                                     if (v != "") { print v; exit }
                                     if ((getline line) > 0) { sub(/^ /, "", line); print line }
                                     exit }' ;;
    *)      passwd_entry "$1" | cut -d: -f6 ;;
  esac
}

detect_users() {
  case "$os" in
    Darwin)
      # loginwindow (or root) owns the console when no one is logged in;
      # _mbsetupuser runs Setup Assistant.
      _u=$(stat -f%Su /dev/console 2>/dev/null || true)
      case "$_u" in ''|root|loginwindow|_mbsetupuser) ;; *) echo "$_u" ;; esac ;;
    *)
      _min=$(awk '$1 == "UID_MIN" { print $2 }' /etc/login.defs 2>/dev/null || true)
      case "$_min" in ''|*[!0-9]*) _min=1000 ;; esac
      # loginctl fails when logind is not running (no systemd, or a container).
      if command -v loginctl >/dev/null 2>&1 && _s=$(loginctl list-sessions --no-legend 2>/dev/null); then
        printf '%s\n' "$_s" | awk 'NF >= 3 { print $3 }'
      else
        who 2>/dev/null | awk '{ print $1 }'
      fi | sort -u | while IFS= read -r _u; do
        _uid=$(passwd_entry "$_u" | cut -d: -f3)
        case "$_uid" in ''|*[!0-9]*) continue ;; esac
        if [ "$_uid" -ge "$_min" ]; then echo "$_u"; fi
      done ;;
  esac
}

# as_user USER UID CMD... - exec CMD as USER, with an empty environment, so the
# MDM's credentials do not reach a process the user can inspect. Only run it in
# the background through user_step.
as_user() {
  _au=$1; _auid=$2; shift 2
  if [ "$(id -u)" = "$_auid" ]; then
    exec env -i PATH="$SAFE_PATH" "$@"
  elif [ "$(id -u)" != 0 ]; then
    say "error: must run as root to act as $_au"; return 1
  elif command -v runuser >/dev/null 2>&1; then
    exec runuser -u "$_au" -- env -i PATH="$SAFE_PATH" "$@"
  elif command -v sudo >/dev/null 2>&1; then
    exec sudo -n -u "$_au" -- env -i PATH="$SAFE_PATH" "$@"
  else
    say "error: neither runuser nor sudo is available to act as $_au"; return 1
  fi
}

# kill_step TAG UID - kill every process of a step: those of UID whose argv
# carries TAG, and all their descendants of UID. A tag, not a process group or
# session: runuser and sudo each decide the child's group and session (sudo
# with use_pty starts a new session), so a group kill can miss the step, and
# killing only the wrapper leaves the step's shell alive. Only the step's own
# shell has TAG as an argument, so nothing else of the user's is touched.
# STOP before KILL, and repeat, so a fork in between is caught on the next pass.
# A listed process can be gone by the time it is signalled, and the user can
# cause that on purpose, so no command here may end the caller: errexit is off
# (this runs only in the watchdog subshell) and every signal is non-fatal.
kill_step() {
  set +e
  for _r in 1 2 3; do
    # The tag reaches awk through its environment: in awk's argv it would match
    # awk, and so this pipeline.
    _pids=$(ps -A -o pid= -o ppid= -o uid= -o args= 2>/dev/null | STEP_TAG=" $1 " STEP_UID=$2 awk '
      BEGIN { tag = ENVIRON["STEP_TAG"]; uid = ENVIRON["STEP_UID"] }
      { pid[NR] = $1; ppid[NR] = $2; u[NR] = $3
        if ($3 == uid && index(" " $0 " ", tag)) mark[$1] = 1 }
      END {
        do {
          more = 0
          for (i = 1; i <= NR; i++)
            if (u[i] == uid && !(pid[i] in mark) && (ppid[i] in mark)) { mark[pid[i]] = 1; more = 1 }
        } while (more)
        for (p in mark) print p
      }')
    [ -n "$_pids" ] || return 0
    kill -STOP $_pids 2>/dev/null || :
    kill -KILL $_pids 2>/dev/null || :
  done
}

step_n=0
# user_step USER UID IN OUT SCRIPT ARG... - run the sh SCRIPT as USER and kill
# it after $timeout seconds. Its stdin, stdout, and stderr are files in root's
# work directory, never this script's own output: a step process the user keeps
# alive must not hold the MDM's pipe open. stderr is relayed after the step.
# SCRIPT travels in the environment so that the shell's argv is one short line
# that ends in the step's tag (see kill_step). One watchdog in sh, because macOS
# has no timeout(1). It writes $work/timedout when it fires. Returns the step's
# exit status.
user_step() {
  _su=$1; _suid=$2; _in=$3; _out=$4; _script=$5; shift 5
  step_n=$((step_n + 1)); _tag="endor-step-$$-$step_n"; _err="$work/step.err"
  rm -f "$work/timedout"
  as_user "$_su" "$_suid" ENDOR_STEP="$_script" /bin/sh -c 'eval "$ENDOR_STEP"' "$_tag" "$@" \
    < "$_in" > "$_out" 2> "$_err" &
  _child=$!
  # The watchdog must reach its last line whatever fails on the way (a process
  # already gone, the child already reaped), else the wait below never returns.
  (
    set +e
    _s=""
    trap 'kill "$_s" 2>/dev/null; exit 0' TERM
    sleep "$timeout" & _s=$!; wait "$_s"
    : > "$work/timedout" 2>/dev/null || :
    kill_step "$_tag" "$_suid"
    kill -TERM "$_child" 2>/dev/null || :
    sleep 2 & _s=$!; wait "$_s"
    kill -KILL "$_child" 2>/dev/null || :
    kill_step "$_tag" "$_suid"
  ) </dev/null >/dev/null 2>&1 &
  _dog=$!
  if wait "$_child" 2>/dev/null; then _rc=0; else _rc=$?; fi
  kill -TERM "$_dog" 2>/dev/null || true
  wait "$_dog" 2>/dev/null || true
  while IFS= read -r _line || [ -n "$_line" ]; do say "$_su: $_line"; done < "$_err"
  return "$_rc"
}

# Run as the user. Exit 0 and print at most $2 bytes of the file, exit 3 when
# there is no file, or exit 4 when the path is a symlink or not a regular file.
# The type is checked again on the open descriptor, so a FIFO swapped in after
# the path check is refused too (its open blocks instead, and the time limit
# ends it). A symlink is refused rather than replaced: it often points into a
# dotfiles repository, and the rename below would cut that link.
READ_SH='
if [ -L "$1" ]; then echo "$1 is a symlink; not following it" >&2; exit 4; fi
[ -e "$1" ] || exit 3
if [ ! -f "$1" ]; then echo "$1 is not a regular file" >&2; exit 4; fi
exec 3< "$1" || exit 1
if [ ! -f /dev/fd/3 ]; then echo "$1 is not a regular file once opened" >&2; exit 4; fi
head -c "$2" <&3'

# Run as the user, with the new content on stdin. The temp file is in the same
# directory, so the rename is atomic and Cortex Code never reads half a file.
WRITE_SH='
umask 077
d=$(dirname -- "$1")
mkdir -p -- "$d" || exit 1
if [ -L "$1" ] || { [ -e "$1" ] && [ ! -f "$1" ]; }; then
  echo "$1 is not a regular file; not replacing it" >&2; exit 1
fi
t=$(mktemp "$d/.endor-hooks.XXXXXX") || exit 1
if cat > "$t" && chmod 600 "$t" && mv -f -- "$t" "$1"; then exit 0; fi
rm -f -- "$t"
exit 1'

# read_as USER UID FILE OUT - sets _st to absent, present, or failed, and _why
# to the reason for failed. One byte over the limit is read so that a file of
# exactly MAX_BYTES is not refused.
read_as() {
  _why="could not read $3"
  if user_step "$1" "$2" /dev/null "$4" "$READ_SH" "$3" $((MAX_BYTES + 1)); then _st=present
  else
    case $? in 3) _st=absent ;; *) _st=failed ;; esac
  fi
  if [ -f "$work/timedout" ]; then
    _st=failed; _why="reading $3 took longer than ${timeout}s"
  elif [ "$_st" = present ] && [ "$(wc -c < "$4" | tr -d ' ')" -gt "$MAX_BYTES" ]; then
    _st=failed; _why="$3 is larger than $MAX_BYTES bytes"
  fi
}

install_for() {
  _u=$1
  _uid=$(id -u "$_u" 2>/dev/null) || { say "skipped $_u: no such user"; return 0; }
  case "$dest" in
    /*) _dest=$dest ;;
    *)
      _home=$(home_of "$_u")
      case "$_home" in /*) ;; *) say "skipped $_u: no home directory found"; return 0 ;; esac
      [ -d "$_home" ] || { say "skipped $_u: home $_home does not exist"; return 0; }
      if [ -z "$dest" ]; then _dest="$_home/.snowflake/cortex/hooks.json"
      else _dest="$_home/${dest#'~/'}"; fi ;;
  esac
  if [ -n "$dry" ]; then echo "$_u $_dest"; return 0; fi

  _cur="$work/$_uid.current"; _new="$work/$_uid.new"; _again="$work/$_uid.again"
  read_as "$_u" "$_uid" "$_dest" "$_cur"
  case "$_st" in
    failed) say "error: $_u: $_why; left it as it is"; return 1 ;;
    absent) cp "$rendered" "$_new" ;;
    present)
      sh "$SCRIPT_DIR/cortexcode-merge.sh" "$_cur" "$rendered" "$_new" \
        || { say "error: $_u: did not update $_dest"; return 1; }
      if cmp -s "$_new" "$_cur"; then say "$_u: $_dest is current"; return 0; fi ;;
  esac

  # The user can edit the file while this runs. Write only if it is still what
  # the merge read, else that edit would be lost. A change is not an error: the
  # next scheduled run merges the new content.
  _was=$_st
  read_as "$_u" "$_uid" "$_dest" "$_again"
  if [ "$_st" = failed ]; then say "error: $_u: $_why; left it as it is"; return 1; fi
  if [ "$_st" != "$_was" ] || { [ "$_st" = present ] && ! cmp -s "$_again" "$_cur"; }; then
    say "$_u: $_dest changed during this run; not written, the next run retries"
    return 0
  fi

  if ! user_step "$_u" "$_uid" "$_new" /dev/null "$WRITE_SH" "$_dest"; then
    if [ -f "$work/timedout" ]; then say "error: $_u: writing $_dest took longer than ${timeout}s"
    else say "error: $_u: could not write $_dest"; fi
    return 1
  fi
  say "$_u: wrote $_dest"
}

[ -n "$users" ] || users=$(detect_users)
if [ -z "$users" ]; then
  say "no logged-in user to install for; nothing done. The next run tries again (or set TARGET_USER)."
  exit 0
fi

work=""
if [ -z "$dry" ]; then
  work=$(mktemp -d "$(dirname -- "$rendered")/install.XXXXXX")
  trap 'rm -rf "$work"' EXIT
fi

failed=0
set -f
for u in $users; do
  install_for "$u" || failed=$((failed + 1))
done
set +f
[ "$failed" -eq 0 ] || die "$failed user(s) not updated (see above)"
