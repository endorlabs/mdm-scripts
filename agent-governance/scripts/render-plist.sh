#!/bin/sh
# render-plist.sh - wrap an agent config on stdin into an MDM Configuration
# Profile (.mobileconfig). Two envelope styles:
#
#   --style plist  (default)  Embed a managed-settings JSON object directly under
#                             a custom payload of --payload-type. Used by Claude
#                             Code (com.anthropic.claudecode).
#   --style mcx               Base64-encode the raw stdin (e.g. Codex's
#                             requirements.toml) and set it as an MCX Forced
#                             preference: --pref-domain / --pref-key. Used by
#                             Codex (com.openai.codex : requirements_toml_base64).
#
# The agent config is produced by render.sh and reused verbatim - this script
# only adds the profile envelope and converts it to a plist.
#
#   render.sh --agent claude ... -o - | render-plist.sh \
#     --identifier com.acme.ai-governance.claudecode --organization "Acme Corp" \
#     -o claude.mobileconfig
#
#   render.sh --agent codex ... -o - | render-plist.sh --style mcx \
#     --identifier com.acme.ai-governance.codex --organization "Acme Corp" \
#     -o codex.mobileconfig
#
# Prerequisites: jq, plutil (native on macOS); --style mcx also needs base64.
# UUIDs default to freshly generated.
#
#   --style               plist (default) | mcx
#   --identifier          required; reverse-DNS base. Inner payload is <id>.settings
#   --organization        required; profile PayloadOrganization
#   --payload-type        (plist) app's managed-settings payload domain
#                         (default: com.anthropic.claudecode)
#   --pref-domain         (mcx) preference domain (default: com.openai.codex)
#   --pref-key            (mcx) preference key (default: requirements_toml_base64)
#   --name                profile + payload display name (default: Endor AI Governance)
#   --profile-identifier  outer PayloadIdentifier (default: --identifier)
#   --profile-uuid        outer PayloadUUID (default: uuidgen)
#   --content-uuid        inner PayloadUUID (default: uuidgen)
#   -o / --output         output path (default: stdout)
set -eu

die() { echo "render-plist.sh: error: $*" >&2; exit 1; }
command -v jq >/dev/null     || die "jq is required (install it, e.g. 'brew install jq')"
command -v plutil >/dev/null || die "plutil is required (macOS)"

style="plist"; identifier=""; profile_identifier=""; organization=""
payload_type="com.anthropic.claudecode"; name="Endor AI Governance"
pref_domain="com.openai.codex"; pref_key="requirements_toml_base64"
profile_uuid=""; content_uuid=""; output="-"
while [ $# -gt 0 ]; do
  case "$1" in  # every flag here takes a value; require one (avoids a raw set -u error)
    -h|--help) ;;
    -*) [ $# -ge 2 ] || die "$1 requires a value" ;;
  esac
  case "$1" in
    --style)              style="$2"; shift 2 ;;
    --identifier)         identifier="$2"; shift 2 ;;
    --profile-identifier) profile_identifier="$2"; shift 2 ;;
    --organization)       organization="$2"; shift 2 ;;
    --payload-type)       payload_type="$2"; shift 2 ;;
    --pref-domain)        pref_domain="$2"; shift 2 ;;
    --pref-key)           pref_key="$2"; shift 2 ;;
    --name)               name="$2"; shift 2 ;;
    --profile-uuid)       profile_uuid="$2"; shift 2 ;;
    --content-uuid)       content_uuid="$2"; shift 2 ;;
    -o|--output)          output="$2"; shift 2 ;;
    -h|--help)            sed -n '2,38p' "$0"; exit 0 ;;
    *)                    die "unknown argument: $1" ;;
  esac
done

case "$style" in plist|mcx) ;; *) die "unknown --style: $style (plist|mcx)" ;; esac
[ -n "$identifier" ]   || die "--identifier is required"
[ -n "$organization" ] || die "--organization is required"
[ -n "$profile_identifier" ] || profile_identifier="$identifier"
[ -n "$profile_uuid" ] || profile_uuid=$(uuidgen)
[ -n "$content_uuid" ] || content_uuid=$(uuidgen)

if [ "$style" = mcx ]; then
  # MCX manifest: base64 the raw config (TOML) and force it as a managed pref.
  command -v base64 >/dev/null || die "base64 is required for --style mcx"
  config=$(cat)
  [ -n "$config" ] || die "stdin is empty (pipe: render.sh --agent codex ... -o -)"
  b64=$(printf '%s' "$config" | base64 | tr -d '\n')
  jq -n --arg b64 "$b64" --arg domain "$pref_domain" --arg key "$pref_key" \
    --arg ident "$identifier" --arg pident "$profile_identifier" \
    --arg name "$name" --arg org "$organization" \
    --arg puuid "$profile_uuid" --arg cuuid "$content_uuid" '
    {
      PayloadContent: [{
        PayloadDescription: "Managed preferences (Endor Labs AI governance hooks) for the agent.",
        PayloadDisplayName: $name,
        PayloadEnabled:     true,
        PayloadIdentifier:  ($ident + ".settings"),
        PayloadType:        "com.apple.ManagedClient.preferences",
        PayloadUUID:        $cuuid,
        PayloadVersion:     1,
        PayloadContent: {
          ($domain): { Forced: [ { mcx_preference_settings: { ($key): $b64 } } ] }
        }
      }],
      PayloadDescription:  "Deploys managed AI-tool preferences for Endor Labs AI auditing.",
      PayloadDisplayName:  $name,
      PayloadIdentifier:   $pident,
      PayloadOrganization: $org,
      PayloadScope:        "System",
      PayloadType:         "Configuration",
      PayloadUUID:         $puuid,
      PayloadVersion:      1
    }' | plutil -convert xml1 -o "$output" -
else
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
fi

[ "$output" = "-" ] || echo "render-plist.sh: wrote $output" >&2
