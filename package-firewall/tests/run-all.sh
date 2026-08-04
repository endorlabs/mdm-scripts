#!/usr/bin/env bash
# Runs every suite and aggregates the tallies.
#
#   ./run-all.sh              all suites
#   ./run-all.sh lib watcher  only suites whose name matches one of these
#   ./run-all.sh --bash       only the bash suites
#   ./run-all.sh --powershell only the PowerShell suites
#
# Suites are discovered by glob — bash/*.sh and powershell/*.ps1, minus the shared
# harness — so adding one needs no edit here.
#
# Nothing here needs root, and nothing touches an installed VS Code: the suites work
# on copies of tests/fixtures/product.json inside a temp directory.
set -uo pipefail
cd "$(dirname "$0")"

want_bash=1; want_ps=1
filters=()
for a in "$@"; do
  case "$a" in
    --bash)       want_ps=0 ;;
    --powershell) want_bash=0 ;;
    -h|--help)    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            filters+=("$a") ;;
  esac
done

wanted() {
  [ "${#filters[@]}" -eq 0 ] && return 0
  local f
  for f in "${filters[@]}"; do case "$1" in *"$f"*) return 0 ;; esac; done
  return 1
}

# discover <dir> <ext> — suite paths, excluding the dot-sourced harness.
discover() {
  local p
  for p in "$1"/*."$2"; do
    [ -e "$p" ] || continue
    case "$(basename "$p")" in harness.sh|Harness.ps1) continue ;; esac
    printf '%s\n' "$p"
  done
}

PWSH=$(command -v pwsh || command -v powershell || true)
tot_pass=0; tot_fail=0; tot_skip=0; failed_suites=(); ran=0

run() { # run <label> <command...>
  local label="$1"; shift
  printf '\n\033[1m─── %s ───\033[0m\n' "$label"
  local out rc line
  out=$("$@" 2>&1); rc=$?
  printf '%s\n' "$out"
  ran=$((ran+1))
  # The tally line every suite ends with.
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
  while IFS= read -r s; do
    label="bash/$(basename "$s" .sh)"
    wanted "$label" && run "$label" bash "$s"
  done < <(discover bash sh)
fi

if [ "$want_ps" -eq 1 ]; then
  ps_wanted=0
  while IFS= read -r s; do
    label="powershell/$(basename "$s" .ps1)"
    wanted "$label" || continue
    ps_wanted=$((ps_wanted+1))
    [ -n "$PWSH" ] && run "$label" "$PWSH" -NoProfile -File "$s"
  done < <(discover powershell ps1)
  if [ -z "$PWSH" ] && [ "$ps_wanted" -gt 0 ]; then
    printf '\n\033[1m─── powershell ───\033[0m\n'
    echo "  skip $ps_wanted PowerShell suite(s) (no pwsh on PATH)"
    echo "       macOS/Linux: brew install powershell  |  https://aka.ms/powershell"
    tot_skip=$(( tot_skip + ps_wanted ))
  fi
fi

printf '\n\033[1m─── total ───\033[0m\n'
if [ "$ran" -eq 0 ] && [ "$tot_skip" -eq 0 ]; then
  echo "no suites matched"
  exit 1
fi
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
