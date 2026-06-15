#!/bin/sh
# render-plist.sh — wrap a managed-settings JSON into an MDM Configuration
# Profile (.mobileconfig). It reads the settings object on stdin and embeds it
# under a payload of the given type, so the agent-specific config is produced by
# render.sh and reused verbatim — this script only adds the profile envelope and
# converts to a plist. The envelope is agent-agnostic; --payload-type selects the
# app (default: Claude Code).
#
#   render.sh --agent claude --api-key K --api-secret S --namespace NS -o - \
#     | render-plist.sh --identifier com.acme.ai-governance.claudecode \
#                       --organization "Acme Corp" -o profile.mobileconfig
#
# Prerequisites: jq and plutil (plutil is native on macOS, where profiles are
# made). UUIDs default to freshly generated.
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
command -v jq >/dev/null     || die "jq is required (install it, e.g. 'brew install jq')"
command -v plutil >/dev/null || die "plutil is required (macOS)"

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

# Read the managed-settings object produced by render.sh and embed it whole.
settings=$(cat)
printf '%s' "$settings" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || die "stdin is not a JSON settings object (pipe: render.sh --agent <name> ... -o -)"

jq -n --argjson s "$settings" \
  --arg ident "$identifier" --arg pident "$profile_identifier" \
  --arg name "$name" --arg org "$organization" --arg ptype "$payload_type" \
  --arg puuid "$profile_uuid" --arg cuuid "$content_uuid" '
  {
    PayloadContent: [({
      PayloadDescription: "Managed settings (env + hooks) for Endor Labs AI governance auditing.",
      PayloadDisplayName: $name,
      PayloadEnabled:     true,
      PayloadIdentifier:  ($ident + ".settings"),
      PayloadType:        $ptype,
      PayloadUUID:        $cuuid,
      PayloadVersion:     1
    } + $s)],
    PayloadDescription:  "Deploys managed AI-tool settings for Endor Labs AI auditing.",
    PayloadDisplayName:  $name,
    PayloadIdentifier:   $pident,
    PayloadOrganization: $org,
    PayloadScope:        "System",
    PayloadType:         "Configuration",
    PayloadUUID:         $puuid,
    PayloadVersion:      1
  }' | plutil -convert xml1 -o "$output" -

[ "$output" = "-" ] || echo "render-plist.sh: wrote $output" >&2
