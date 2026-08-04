#!/usr/bin/env bash
# Runs every suite and aggregates the tallies.
#
#   ./run-all.sh              all suites
#   ./run-all.sh lib watcher  only suites whose name matches one of these
#   ./run-all.sh --bash       only the bash suites
#   ./run-all.sh --powershell only the PowerShell suites
#
# Nothing here needs root, and nothing touches an installed VS Code: the suites work
# on copies of tests/fixtures/product.json inside a temp directory, and the two that
# run generated scripts redirect install discovery into that sandbox and verify the
# redirect before executing anything.
set -uo pipefail
cd "$(dirname "$0")"

want_bash=1; want_ps=1
filters=()
for a in "$@"; do
  case "$a" in
    --bash)       want_ps=0 ;;
    --powershell) want_bash=0 ;;
    -h|--help)    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            filters+=("$a") ;;
  esac
done

wanted() {
  [ "${#filters[@]}" -eq 0 ] && return 0
  local f
  for f in "${filters[@]}"; do case "$1" in *"$f"*) return 0 ;; esac; done
  return 1
}

PWSH=$(command -v pwsh || command -v powershell || true)
tot_pass=0; tot_fail=0; tot_skip=0; failed_suites=()

run() { # run <label> <command...>
  local label="$1"; shift
  wanted "$label" || return 0
  printf '\n\033[1m─── %s ───\033[0m\n' "$label"
  local out rc
  out=$("$@" 2>&1); rc=$?
  printf '%s\n' "$out"
  # The tally line every suite ends with.
  local line
  line=$(printf '%s' "$out" | grep -E '^passed [0-9]+, failed [0-9]+' | tail -1)
  if [ -n "$line" ]; then
    tot_pass=$(( tot_pass + $(printf '%s' "$line" | sed -n 's/^passed \([0-9]*\).*/\1/p') ))
    tot_fail=$(( tot_fail + $(printf '%s' "$line" | sed -n 's/.*failed \([0-9]*\).*/\1/p') ))
    case "$line" in *skipped*)
      tot_skip=$(( tot_skip + $(printf '%s' "$line" | sed -n 's/.*skipped \([0-9]*\).*/\1/p') )) ;;
    esac
  else
    # No tally means the suite died before finishing, which must not be mistaken for
    # a pass.
    tot_fail=$(( tot_fail + 1 ))
  fi
  [ "$rc" -eq 0 ] || failed_suites+=("$label")
}

if [ "$want_bash" -eq 1 ]; then
  run "bash/json-primitives" bash bash/json-primitives.sh
  run "bash/lib"             bash bash/lib.sh
  run "bash/watcher"         bash bash/watcher.sh
  run "bash/e2e"             bash bash/e2e.sh
fi

ps_suites=(powershell/json-primitives powershell/lib powershell/e2e)
if [ "$want_ps" -eq 1 ]; then
  if [ -z "$PWSH" ]; then
    n=0
    for s in "${ps_suites[@]}"; do wanted "$s" && n=$((n+1)); done
    if [ "$n" -gt 0 ]; then
      printf '\n\033[1m─── powershell ───\033[0m\n'
      echo "  skip $n PowerShell suite(s) (no pwsh on PATH)"
      echo "       macOS/Linux: brew install powershell  |  https://aka.ms/powershell"
      tot_skip=$(( tot_skip + n ))
    fi
  else
    run "powershell/json-primitives" "$PWSH" -NoProfile -File powershell/json-primitives.ps1
    run "powershell/lib"             "$PWSH" -NoProfile -File powershell/lib.ps1
    run "powershell/e2e"             "$PWSH" -NoProfile -File powershell/e2e.ps1
  fi
fi

printf '\n\033[1m─── total ───\033[0m\n'
if [ "$tot_skip" -gt 0 ]; then
  printf 'passed %d, failed %d, skipped %d\n' "$tot_pass" "$tot_fail" "$tot_skip"
else
  printf 'passed %d, failed %d\n' "$tot_pass" "$tot_fail"
fi
if [ "${#failed_suites[@]}" -gt 0 ]; then
  printf 'failing suites: %s\n' "${failed_suites[*]}"
  exit 1
fi
[ "$tot_fail" -eq 0 ]
