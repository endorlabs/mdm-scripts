#!/bin/sh
# endor-hook.sh - run one Endor AI-governance audit for a Claude Cowork hook.
# Called by every hook in hooks/hooks.json:
#   sh "${CLAUDE_PLUGIN_ROOT}/scripts/endor-hook.sh" session   (SessionStart)
#   sh "${CLAUDE_PLUGIN_ROOT}/scripts/endor-hook.sh" audit     (every other event)
# Loads the tenant settings from endor.env (written by render.sh) and passes the
# hook event on stdin to endorctl, whose exit code and output are the hook's.
# No `set -eu`: a hook must not fail on an unset variable.

root="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$root" ] || root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) || exit 0

# No endor.env, no tenant to audit into. Exit 1 is a visible, non-blocking hook
# error (only exit 2 blocks).
if [ ! -r "$root/endor.env" ]; then
  echo "endor-cowork-governance: $root/endor.env is missing, so this session is not audited. Rebuild the plugin with render.sh --agent claude-cowork." >&2
  exit 1
fi

# set -a exports the settings, so behavior envs reach endorctl.
set -a
# shellcheck source=/dev/null
. "$root/endor.env"
set +a

# Sourced, not executed: the bootstrap ends this hook when endorctl is not installed yet.
if [ "${1:-}" = session ] && [ -r "$root/scripts/bootstrap.sh" ]; then
  # shellcheck source=/dev/null
  . "$root/scripts/bootstrap.sh"
fi

[ -x "$HOME/.endorctl/endorctl" ] || exit 0

exec "$HOME/.endorctl/endorctl" \
  --api "$AGENT_HOOK_ENDOR_API" \
  --namespace "$AGENT_HOOK_ENDOR_NAMESPACE" \
  --api-key "$AGENT_HOOK_ENDOR_API_CREDENTIALS_KEY" \
  --api-secret "$AGENT_HOOK_ENDOR_API_CREDENTIALS_SECRET" \
  ai-audit claudecode
