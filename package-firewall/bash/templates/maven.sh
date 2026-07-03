# templates/maven.sh
# Java / Maven ecosystem

# Config file written to the console user's Maven user-settings:
#     ~/.m2/settings.xml

# Block content is defined in shared/blocks/mavensettings.txt.
# {{MAVEN_REGISTRY_URL}} is substituted at generation time. Credentials are NOT
# baked in -- settings.xml references env vars, which Maven expands at runtime
# from the values provided by env.sh.

echo ""
echo "[endor-maven] ── Maven ────────────────────────────────────────────────────────"

# User attribution: the shared block references ${env.ENDOR_API_KEY_ID} so the
# Windows generator (which has no ENDOR_ATTR_USER env var yet) keeps working
# unchanged. On bash we swap the reference to the attributed username so Maven
# installs carry <console-user>@<machine> to the firewall log. The Windows
# attribution follow-up flips the block itself and removes this swap.
MAVEN_BLOCK=${MAVEN_BLOCK//'${env.ENDOR_API_KEY_ID}'/'${env.ENDOR_ATTR_USER}'}

MAVEN_SETTINGS="$USER_HOME/.m2/settings.xml"

# warn if the admin already defines a mirror/server outside an Endor block --
# Maven mirror precedence could conflict and needs a human decision.
warn_if_key_conflict \
    "$MAVEN_SETTINGS" \
    "<mirror>" \
    "existing <mirror> (Maven)"

upsert_xml_block \
    "$MAVEN_SETTINGS" \
    "$MAVEN_BLOCK" \
    "$CONSOLE_USER" \
    "$USER_GROUP"

echo "[endor-maven] settings.xml     -> $MAVEN_SETTINGS"
echo "[endor-maven]    covers: maven (all versions), and Gradle when it reads ~/.m2"
echo "[endor-maven]    mirror: {{MAVEN_REGISTRY_URL}} (mirrorOf=*)"
echo "[endor-maven]    NOTE: credentials come from env vars (ENDOR_ATTR_USER/API_SECRET) via env.sh"
echo "[endor-maven] ✓ Maven done"