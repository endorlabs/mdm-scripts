# templates/attribution.sh
# User attribution — runs on the developer's machine (where MDM executes this
# script), AFTER the console user has been detected. Computes the attributed
# Basic-auth username so the Package Firewall log can attribute installs to
# <console-user>@<machine> without issuing per-user API keys.
#
# Username = base64( base64("userattr:"+label) + ":" + apiKeyId ); the password is
# the real api secret, unchanged. The firewall decodes the label, authenticates
# with the real key, and stamps the label on the log. UNVERIFIED telemetry only.
#
# The api key id / secret and host / namespace are substituted at generation time;
# everything else is derived here, at runtime, from the per-machine label.

ENDOR_API_KEY_ID='{{API_KEY_ID}}'
ENDOR_API_SECRET='{{API_SECRET}}'

ENDOR_ATTR_LABEL="${CONSOLE_USER}@$(endor_host_label)"
ENDOR_ATTR_USER="$(endor_attr_username "$ENDOR_ATTR_LABEL" "$ENDOR_API_KEY_ID")"

# npm _auth = base64(username:password); _password = base64(password).
ENDOR_AUTH_B64="$(printf '%s:%s' "$ENDOR_ATTR_USER" "$ENDOR_API_SECRET" | endor_b64)"
ENDOR_API_SECRET_B64="$(printf '%s' "$ENDOR_API_SECRET" | endor_b64)"

ENDOR_NPM_REGISTRY_URL='{{NPM_REGISTRY_URL}}'

# pip / uv / go embed the attributed username in URL userinfo — percent-encode it.
ENDOR_PYPI_URL="https://$(endor_urlenc_b64 "$ENDOR_ATTR_USER"):${ENDOR_API_SECRET}@{{FQDN_HOST}}/v1/namespaces/{{NAMESPACE}}/firewall/pypi/simple/"
ENDOR_GO_PROXY_URL="https://$(endor_urlenc_b64 "$ENDOR_ATTR_USER"):${ENDOR_API_SECRET}@{{FQDN_HOST}}/v1/namespaces/{{NAMESPACE}}/firewall/go/,direct"

export ENDOR_API_KEY_ID ENDOR_API_SECRET ENDOR_ATTR_LABEL ENDOR_ATTR_USER \
       ENDOR_AUTH_B64 ENDOR_API_SECRET_B64 ENDOR_NPM_REGISTRY_URL \
       ENDOR_PYPI_URL ENDOR_GO_PROXY_URL

echo "[endor] user attribution → ${ENDOR_ATTR_LABEL}"
