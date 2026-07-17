#!/bin/sh
# render-plist.sh - wrap a managed-settings JSON into an MDM Configuration
# Profile (.mobileconfig). It reads the settings object on stdin and embeds it
# under a payload of the given type, so the agent-specific config is produced by
# render.sh and reused verbatim - this script only adds the profile envelope and
# converts to a plist. The envelope is agent-agnostic; --payload-type selects the
# app (default: Claude Code).
#
#   render.sh --agent claude --api-key K --api-secret S --namespace NS -o - \
#     | render-plist.sh --identifier com.acme.ai-governance.claudecode \
#                       --organization "Acme Corp" -o profile.mobileconfig
#
# Prerequisites: plutil (native on macOS, where profiles are made) - it parses
# the JSON envelope and converts it to a plist, so no jq is needed. UUIDs default
# to freshly generated.
#
#   --identifier          required; reverse-DNS base. Inner payload is <id>.settings
#   --organization        required; profile PayloadOrganization
#   --payload-type        app's managed-settings payload domain
#                         (default: com.anthropic.claudecode)
#   --name                profile + payload display name (default: Endor AI Governance)
#   --profile-identifier  outer PayloadIdentifier (default: --identifier)
#   --profile-uuid        outer PayloadUUID (default: uuidgen)
#   --content-uuid        inner PayloadUUID (default: uuidgen)
#   -o / --output         output path (default: stdout)
set -eu

die() { echo "render-plist.sh: error: $*" >&2; exit 1; }
command -v plutil >/dev/null || die "plutil is required (macOS)"

# JSON-escape a string for use inside "..." (backslash, double-quote, newlines).
# Same escaper render.sh uses - keeps this script jq-free.
js() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | awk 'BEGIN{ORS=""} {printf "%s%s", sep, $0; sep="\\n"}'
}

identifier=""; profile_identifier=""; organization=""
payload_type="com.anthropic.claudecode"; name="Endor AI Governance"
profile_uuid=""; content_uuid=""; output="-"
while [ $# -gt 0 ]; do
  case "$1" in  # every flag here takes a value; require one (avoids a raw set -u error)
    -h|--help) ;;
    -*) [ $# -ge 2 ] || die "$1 requires a value" ;;
  esac
  case "$1" in
    --identifier)         identifier="$2"; shift 2 ;;
    --profile-identifier) profile_identifier="$2"; shift 2 ;;
    --organization)       organization="$2"; shift 2 ;;
    --payload-type)       payload_type="$2"; shift 2 ;;
    --name)               name="$2"; shift 2 ;;
    --profile-uuid)       profile_uuid="$2"; shift 2 ;;
    --content-uuid)       content_uuid="$2"; shift 2 ;;
    -o|--output)          output="$2"; shift 2 ;;
    -h|--help)            sed -n '2,24p' "$0"; exit 0 ;;
    *)                    die "unknown argument: $1" ;;
  esac
done

[ -n "$identifier" ]   || die "--identifier is required"
[ -n "$organization" ] || die "--organization is required"
[ -n "$profile_identifier" ] || profile_identifier="$identifier"
[ -n "$profile_uuid" ] || profile_uuid=$(uuidgen)
[ -n "$content_uuid" ] || content_uuid=$(uuidgen)

# Read the managed-settings object produced by render.sh. It must be a JSON
# object; its members are spliced into the inner payload dict (the flattening
# jq's `{...} + $s` did). Confirm it opens with `{`, then strip the outermost
# braces to get the body to splice; plutil re-parses the result and rejects it
# if the splice produced anything malformed, so it doubles as validation.
settings=$(cat)
[ "$(printf '%s' "$settings" | tr -d '[:space:]' | cut -c1)" = "{" ] \
  || die "stdin is not a JSON settings object (pipe: render.sh --agent <name> ... -o -)"
inner=$(printf '%s' "$settings" | awk 'BEGIN{RS="\1"} { sub(/^[ \t\r\n]*\{/,""); sub(/\}[ \t\r\n]*$/,""); printf "%s", $0 }')
merge=""
[ -n "$(printf '%s' "$inner" | tr -d '[:space:]')" ] && merge=",
$inner"

# Pre-escape the string values, then print the profile as JSON and let plutil
# parse + convert it. Keys are fixed; only these operator-supplied values need it.
_ident=$(js "$identifier"); _pident=$(js "$profile_identifier")
_name=$(js "$name"); _org=$(js "$organization"); _ptype=$(js "$payload_type")
_puuid=$(js "$profile_uuid"); _cuuid=$(js "$content_uuid")
{
  printf '{\n'
  printf '  "PayloadContent": [{\n'
  printf '    "PayloadDescription": "Managed settings (env + hooks) for Endor Labs AI governance auditing.",\n'
  printf '    "PayloadDisplayName": "%s",\n' "$_name"
  printf '    "PayloadEnabled": true,\n'
  printf '    "PayloadIdentifier": "%s.settings",\n' "$_ident"
  printf '    "PayloadType": "%s",\n' "$_ptype"
  printf '    "PayloadUUID": "%s",\n' "$_cuuid"
  printf '    "PayloadVersion": 1%s\n' "$merge"
  printf '  }],\n'
  printf '  "PayloadDescription": "Deploys managed AI-tool settings for Endor Labs AI auditing.",\n'
  printf '  "PayloadDisplayName": "%s",\n' "$_name"
  printf '  "PayloadIdentifier": "%s",\n' "$_pident"
  printf '  "PayloadOrganization": "%s",\n' "$_org"
  printf '  "PayloadScope": "System",\n'
  printf '  "PayloadType": "Configuration",\n'
  printf '  "PayloadUUID": "%s",\n' "$_puuid"
  printf '  "PayloadVersion": 1\n'
  printf '}\n'
} | plutil -convert xml1 -o "$output" - \
  || die "could not build the profile (is stdin a valid render.sh settings object?)"

[ "$output" = "-" ] || echo "render-plist.sh: wrote $output" >&2
