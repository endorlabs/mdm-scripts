# templates/nuget.sh
# .NET / NuGet ecosystem — dotnet CLI · NuGet CLI · Rider · VS Code (C# Dev Kit)
#
# Config file written to the console user's NuGet user settings:
#   ~/.nuget/NuGet/NuGet.Config      read by every NuGet-based tool on the machine
#
# Block content is defined in shared/blocks/nugetconfig_sources.txt,
# nugetconfig_credentials.txt and nugetconfig_sourcemapping.txt.
# {{NUGET_SOURCE_URL}} is substituted at generation time. Credentials are NOT
# baked in — NuGet.Config references %ENDOR_ATTR_USER% / %ENDOR_API_SECRET%
# (NuGet uses Windows-style %VAR% syntax on every OS), which NuGet expands at
# runtime from the values exported by env.sh.
#
# NuGet has no source priority: it queries every enabled source and takes
# whichever answers, so "our source first" changes nothing. Ours must be the
# only public source. NuGet also honours only the FIRST <packageSources> section
# in a file and silently ignores later duplicates, so the Endor items are merged
# INTO the existing section (see upsert_nuget_block). The block's <clear />
# supersedes every source defined before it — including nuget.org.
#
# <packageSourceMapping>, when the user already has one, restricts which source
# may serve which package IDs; a mapping that never names endor-firewall would
# resolve nothing from it. A third block (clear + pattern "*" → endor-firewall)
# is merged into that section only when it exists.

echo ""
echo "[endor-nuget] ── NuGet / .NET ─────────────────────────────────────────────────"

# Optional install-time fill: replace %ENDOR_ATTR_USER% with {{ATTR_USER}} in
# nugetconfig_credentials.txt to bake literal credentials instead (covers IDEs
# launched from the Dock/Finder, which do not inherit shell profile env vars).
NUGET_CREDENTIALS_BLOCK=${NUGET_CREDENTIALS_BLOCK//'{{ATTR_USER}}'/"$ENDOR_ATTR_USER"}

# ── Resolve NuGet.Config path ─────────────────────────────────────────────────
# dotnet reads ~/.nuget/NuGet/<name> where <name> is the first existing of
# nuget.config, NuGet.config, NuGet.Config (case matters on Linux), and creates
# NuGet.Config when none exists. Prefer the canonical name; fall back to an
# existing variant so we edit the file NuGet actually reads.
NUGET_CONFIG="$USER_HOME/.nuget/NuGet/NuGet.Config"
for _name in NuGet.Config nuget.config NuGet.config; do
  if [[ -f "$USER_HOME/.nuget/NuGet/$_name" ]]; then
    NUGET_CONFIG="$USER_HOME/.nuget/NuGet/$_name"
    break
  fi
done
unset _name

# Warn when private feeds exist outside the block — the <clear /> supersedes them.
warn_if_nuget_source_conflict "$NUGET_CONFIG"

upsert_nuget_block \
  "$NUGET_CONFIG" \
  "packageSources" \
  "$NUGET_SOURCES_BLOCK" \
  "$CONSOLE_USER" \
  "$USER_GROUP"

upsert_nuget_block \
  "$NUGET_CONFIG" \
  "packageSourceCredentials" \
  "$NUGET_CREDENTIALS_BLOCK" \
  "$CONSOLE_USER" \
  "$USER_GROUP"

# Only when the user already maps packages to sources — otherwise NuGet lets
# every source serve every package and no mapping is needed.
if [[ -f "$NUGET_CONFIG" ]] && grep -q '<packageSourceMapping' "$NUGET_CONFIG" 2>/dev/null; then
  echo "[endor-nuget]    existing <packageSourceMapping> found — routing pattern \"*\" to endor-firewall"
  upsert_nuget_block \
    "$NUGET_CONFIG" \
    "packageSourceMapping" \
    "$NUGET_SOURCEMAPPING_BLOCK" \
    "$CONSOLE_USER" \
    "$USER_GROUP"
fi

echo "[endor-nuget] NuGet.Config     → $NUGET_CONFIG"
echo "[endor-nuget]    covers: dotnet CLI, NuGet CLI, Rider, VS Code — any tool reading the user-level NuGet.Config"
echo "[endor-nuget]    source: {{NUGET_SOURCE_URL}} (replaces nuget.org via <clear />)"
echo "[endor-nuget]    NOTE: credentials come from env vars (ENDOR_ATTR_USER/API_SECRET) via env.sh"
echo "[endor-nuget] ✓ NuGet done"
