# templates/nuget.sh
# .NET / NuGet ecosystem — dotnet CLI · NuGet CLI · Rider · VS Code
#
# Config file: ~/.nuget/NuGet/NuGet.Config (read by every NuGet-based tool).
# Blocks come from shared/blocks/nugetconfig_*.txt. Credentials are env var
# refs (%ENDOR_ATTR_USER% / %ENDOR_API_SECRET%, NuGet's syntax on every OS)
# resolved from env.sh at runtime.
#
# NuGet queries every enabled source with no priority, so ours must be the only
# public one: the block's <clear /> supersedes everything above it (nuget.org
# included). NuGet reads only the first <packageSources> section per file, so
# the block is merged INTO the existing section — see upsert_nuget_block.

echo ""
echo "[endor-nuget] ── NuGet / .NET ─────────────────────────────────────────────────"

# Optional: use {{ATTR_USER}} in nugetconfig_credentials.txt to bake literals.
NUGET_CREDENTIALS_BLOCK=${NUGET_CREDENTIALS_BLOCK//'{{ATTR_USER}}'/"$ENDOR_ATTR_USER"}

NUGET_CONFIG="$USER_HOME/.nuget/NuGet/NuGet.Config"

# Private feeds outside the block are superseded by <clear /> — warn the admin.
warn_if_nuget_source_conflict "$NUGET_CONFIG"

upsert_nuget_block "$NUGET_CONFIG" "packageSources"           "$NUGET_SOURCES_BLOCK"     "$CONSOLE_USER" "$USER_GROUP"
upsert_nuget_block "$NUGET_CONFIG" "packageSourceCredentials" "$NUGET_CREDENTIALS_BLOCK" "$CONSOLE_USER" "$USER_GROUP"

# Only when the user already maps packages to sources: a mapping that never
# names endor-firewall would resolve nothing from it.
if grep -q '<packageSourceMapping' "$NUGET_CONFIG" 2>/dev/null; then
  upsert_nuget_block "$NUGET_CONFIG" "packageSourceMapping" "$NUGET_SOURCEMAPPING_BLOCK" "$CONSOLE_USER" "$USER_GROUP"
fi

echo "[endor-nuget] NuGet.Config     → $NUGET_CONFIG"
echo "[endor-nuget]    source: {{NUGET_SOURCE_URL}} (replaces nuget.org via <clear />; credentials via env.sh)"
echo "[endor-nuget] ✓ NuGet done"
