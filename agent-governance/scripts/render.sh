#!/bin/sh
# render.sh — generate Endor AI-governance hook config (JSON) for an AI coding agent.
#
# Builds the config with jq, which escapes JSON correctly by construction. The
# Claude MDM profile (.mobileconfig) is produced by piping this script's Claude
# output through render-plist.sh.
#
# Outputs (JSON): --agent {claude,cursor}. The hook command strings are emitted
# for --target-os: macos/linux share a POSIX shell form; windows inlines the
# PowerShell bootstrap + audit, invoked as a self-contained, shell-agnostic
#   powershell -NoProfile -EncodedCommand <base64-UTF16LE>
# so it runs whether the agent launches hooks via Git Bash, PowerShell, or cmd.
# (The readable source is download_endorctl.ps1; the config carries its encoding.)
#
# Prerequisites: jq; for --target-os windows also iconv + base64 (all standard
# on the macOS/Linux machine that generates the config).
#
# Credentials (dedicated flags) resolve flag > env var > prompt. The prompt fires
# only when stdin is a TTY, so unattended callers (the runner) never block.
#   --api-key     ENDOR_API_CREDENTIALS_KEY
#   --api-secret  ENDOR_API_CREDENTIALS_SECRET
#   --namespace   ENDOR_NAMESPACE
#   --api-url     ENDOR_API                  (default: https://api.endorlabs.com)
#
# Behavior settings go through --env KEY=VALUE (repeatable), routed to Claude's
# env block / Cursor's sessionStart. Cache is on by default; monitor-only is just
# --env ENDOR_AI_AUDIT_NO_BLOCKING=true. --skip-endorctl-update uses an installed
# endorctl as-is (no per-session version check), installing only when missing.
#
# Example:
#   render.sh --agent cursor --api-key K --api-secret S --namespace NS -o hooks.json
#   render.sh --agent claude --target-os windows --api-key K --api-secret S --namespace NS
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEFAULT_API_URL="https://api.endorlabs.com"

die() { echo "render.sh: error: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required (install it, e.g. 'brew install jq')"

# Behavior env vars, newline-separated KEY=VALUE. Cache is on by default;
# add_env replaces any existing entry for the same key (later flag wins).
env_lines="ENDOR_AI_AUDIT_CACHE_ENABLED=true"
add_env() {
  _key=${1%%=*}
  env_lines=$(printf '%s\n' "$env_lines" | grep -v "^${_key}=" || true)
  env_lines="${env_lines}
${1}"
}

# --- defaults / arg parsing ---------------------------------------------------
agent=""; output=""; skip_update=""; target_os="macos"
api_url="${ENDOR_API:-$DEFAULT_API_URL}"
api_key="${ENDOR_API_CREDENTIALS_KEY:-}"
api_secret="${ENDOR_API_CREDENTIALS_SECRET:-}"
namespace="${ENDOR_NAMESPACE:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)                agent="$2"; shift 2 ;;
    --target-os)            target_os="$2"; shift 2 ;;
    -o|--output)            output="$2"; shift 2 ;;
    --env)                  add_env "$2"; shift 2 ;;
    --skip-endorctl-update) skip_update=1; shift ;;
    --api-url)              api_url="$2"; shift 2 ;;
    --api-key)              api_key="$2"; shift 2 ;;
    --api-secret)           api_secret="$2"; shift 2 ;;
    --namespace)            namespace="$2"; shift 2 ;;
    -h|--help)              sed -n '2,33p' "$0"; exit 0 ;;
    *)                      die "unknown argument: $1" ;;
  esac
done

# --- validation ---------------------------------------------------------------
case "$agent" in
  claude|cursor) ;;
  "") die "--agent is required (claude|cursor)" ;;
  *) die "unknown agent: $agent (claude|cursor)" ;;
esac
case "$target_os" in
  macos|linux|windows) ;;
  *) die "unknown --target-os: $target_os (macos|linux|windows)" ;;
esac
if [ "$target_os" = windows ]; then
  command -v iconv >/dev/null || die "iconv is required for --target-os windows"
  command -v base64 >/dev/null || die "base64 is required for --target-os windows"
  boot=$(cat "$SCRIPT_DIR/download_endorctl.ps1")
else
  boot=$(cat "$SCRIPT_DIR/download_endorctl.sh")
fi

# Prompt only when interactive; unattended runs must supply creds up front.
prompt_if_tty() {  # prompt_if_tty VAR_NAME LABEL hide-input?
  eval "_cur=\${$1}"
  [ -n "$_cur" ] && return 0
  [ -t 0 ] || die "$2 not provided (pass --$2 or set its env var; no TTY to prompt)"
  printf '%s: ' "$2" >&2
  [ "$3" = secret ] && { stty -echo 2>/dev/null || true; }
  IFS= read -r _val
  [ "$3" = secret ] && { stty echo 2>/dev/null || true; echo >&2; }
  eval "$1=\$_val"
}
prompt_if_tty api_key    "api-key"    secret
prompt_if_tty api_secret "api-secret" secret
prompt_if_tty namespace  "namespace"  plain

# --- behavior envs ------------------------------------------------------------
# env_obj: JSON object for Claude's env block.
# env_prefix: "K=V " inline prefix for the POSIX Cursor sessionStart.
# ps_env_sets: "$env:K = 'V'" lines for the PowerShell Cursor sessionStart.
env_obj=$(printf '%s\n' "$env_lines" | jq -Rn \
  '[inputs | select(length > 0) | {key: .[:index("=")], value: .[index("=")+1:]}] | from_entries')
env_prefix=$(printf '%s' "$env_obj" | jq -r 'to_entries | map(.key + "=" + .value + " ") | add // ""')
ps_env_sets=$(printf '%s' "$env_obj" | jq -r 'to_entries | map("$env:" + .key + " = '\''" + .value + "'\''") | join("\n")')

# Fold the skip toggle into the bootstrap (read at the top of download_endorctl).
if [ -n "$skip_update" ]; then
  if [ "$target_os" = windows ]; then
    boot=$(printf "\$env:ENDORCTL_SKIP_UPDATE = '1'\n%s" "$boot")
  else
    boot=$(printf 'ENDORCTL_SKIP_UPDATE=1\n%s' "$boot")
  fi
fi

# Encode PowerShell source into a shell-agnostic invocation (base64 is plain
# alphanumeric, so it survives Git Bash, PowerShell, and cmd identically).
psenc() {
  _b64=$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
  printf 'powershell -NoProfile -EncodedCommand %s' "$_b64"
}

# The audit invocation each hook runs (literal $VARS expand at hook time; Cursor
# non-session hooks read AGENT_HOOK_ENDOR_* that endorctl sets at sessionStart).
# endorctl's audit subcommand per agent (Claude Code is "claudecode", not "claude").
case "$agent" in claude) subcmd="claudecode" ;; cursor) subcmd="cursor" ;; esac
posix_audit='$HOME/.endorctl/endorctl --api $AGENT_HOOK_ENDOR_API --namespace $AGENT_HOOK_ENDOR_NAMESPACE --api-key $AGENT_HOOK_ENDOR_API_CREDENTIALS_KEY --api-secret $AGENT_HOOK_ENDOR_API_CREDENTIALS_SECRET ai-audit '"$subcmd"
ps_bin='& "$env:USERPROFILE\.endorctl\endorctl.exe"'
ps_audit="$ps_bin"' --api $env:AGENT_HOOK_ENDOR_API --namespace $env:AGENT_HOOK_ENDOR_NAMESPACE --api-key $env:AGENT_HOOK_ENDOR_API_CREDENTIALS_KEY --api-secret $env:AGENT_HOOK_ENDOR_API_CREDENTIALS_SECRET ai-audit '"$subcmd"

# --- compose per-hook command strings (session = bootstrap + audit) -----------
case "$agent:$target_os" in
  claude:macos|claude:linux)
    cmd_audit="$posix_audit"
    cmd_session=$(printf '%s\n%s' "$boot" "$posix_audit") ;;
  cursor:macos|cursor:linux)
    cmd_audit="$posix_audit"
    # Capture stdin first (Cursor closes its pipe quickly), bootstrap, then audit
    # with inline creds reading the captured stdin.
    cmd_session=$(printf 'cat > /tmp/cursor-hook-stdin-$$\n%s\n%s$HOME/.endorctl/endorctl --api '\''%s'\'' --namespace '\''%s'\'' --api-key '\''%s'\'' --api-secret '\''%s'\'' ai-audit cursor < /tmp/cursor-hook-stdin-$$\nrm -f /tmp/cursor-hook-stdin-$$' \
      "$boot" "$env_prefix" "$api_url" "$namespace" "$api_key" "$api_secret") ;;
  claude:windows)
    cmd_audit=$(psenc "$ps_audit")
    cmd_session=$(psenc "$(printf '%s\n%s' "$boot" "$ps_audit")") ;;
  cursor:windows)
    cmd_audit=$(psenc "$ps_audit")
    cmd_session=$(psenc "$(printf '$in = [Console]::In.ReadToEnd()\n%s\n%s\n$in | %s --api '\''%s'\'' --namespace '\''%s'\'' --api-key '\''%s'\'' --api-secret '\''%s'\'' ai-audit cursor' \
      "$boot" "$ps_env_sets" "$ps_bin" "$api_url" "$namespace" "$api_key" "$api_secret")") ;;
esac

# --- build (jq is pure structure; commands are injected) ----------------------
build_cursor() {
  jq -n --arg session "$cmd_session" --arg audit "$cmd_audit" '
    def hook($c): {command: $c};
    {
      version: 1,
      hooks: {
        sessionStart:         [hook($session)],
        sessionEnd:           [hook($audit)],
        beforeSubmitPrompt:   [hook($audit)],
        preToolUse:           [hook($audit)],
        postToolUse:          [hook($audit)],
        postToolUseFailure:   [hook($audit)],
        beforeShellExecution: [hook($audit)],
        afterShellExecution:  [hook($audit)],
        beforeMCPExecution:   [hook($audit)],
        beforeReadFile:       [hook($audit)],
        afterFileEdit:        [hook($audit)],
        stop:                 [hook($audit)]
      }
    }'
}

build_claude() {
  jq -n --arg session "$cmd_session" --arg audit "$cmd_audit" --argjson envobj "$env_obj" \
    --arg url "$api_url" --arg key "$api_key" --arg secret "$api_secret" --arg ns "$namespace" '
    def hook($c):  {hooks: [{type: "command", command: $c}]};
    def mhook($c): hook($c) + {matcher: ".*"};
    # Hook-scoped AGENT_HOOK_ENDOR_* names keep audit creds out of any endorctl
    # the agent itself spawns; behavior envs use their canonical names.
    {
      env: ({
        AGENT_HOOK_ENDOR_API:                    $url,
        AGENT_HOOK_ENDOR_API_CREDENTIALS_KEY:    $key,
        AGENT_HOOK_ENDOR_API_CREDENTIALS_SECRET: $secret,
        AGENT_HOOK_ENDOR_NAMESPACE:              $ns
      } + $envobj),
      hooks: {
        SessionStart:       [hook($session)],
        UserPromptSubmit:   [hook($audit)],
        PreToolUse:         [mhook($audit)],
        PostToolUse:        [mhook($audit)],
        PostToolUseFailure: [mhook($audit)],
        Stop:               [hook($audit)]
      }
    }'
}

# --- emit ---------------------------------------------------------------------
emit() { case "$agent" in claude) build_claude ;; cursor) build_cursor ;; esac; }
case "$agent" in claude) def_out="claude-settings.json" ;; cursor) def_out="cursor-hooks.json" ;; esac
out_path="${output:-$def_out}"

if [ "$out_path" = "-" ]; then
  emit
else
  out_dir=$(dirname -- "$out_path")
  [ -d "$out_dir" ] || die "output directory does not exist: $out_dir (run: mkdir -p \"$out_dir\")"
  emit > "$out_path"
  echo "render.sh: wrote $out_path (agent=$agent, target-os=$target_os)" >&2
fi
