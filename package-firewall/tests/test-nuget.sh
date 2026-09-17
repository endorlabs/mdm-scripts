#!/usr/bin/env bash
# Exercises the NuGet.Config runtime helpers (inlined into every generated
# script) against fixture files, then checks the generator wires NuGet in.
# Running the generated installer itself needs root + a console user, so the
# library functions are sourced and driven directly here.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
PF_DIR="$ROOT_DIR/package-firewall"
GENERATOR="$PF_DIR/bash/generate.sh"
NAMESPACE="ci-smoke"
KEY_ID="ci-smoke-key-id"
SECRET="ci-smoke-secret"
SOURCE_URL="https://factory.endorlabs.com/v1/namespaces/ci-smoke/firewall/nuget/v3/index.json"
NUGET_ORG_URL="https://api.nuget.org/v3/index.json"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

OWNER=$(id -un)
GROUP=$(id -gn)

# Both are read by the sourced common.sh functions (DRY_RUN also via `DRY_RUN=1 apply`).
# shellcheck disable=SC2034
DRY_RUN=0
_ENDOR_WARNED=0
# shellcheck source=../bash/lib/common.sh
source "$PF_DIR/bash/lib/common.sh"

SOURCES_BLOCK=$(sed "s|{{NUGET_SOURCE_URL}}|$SOURCE_URL|g" "$PF_DIR/shared/blocks/nugetconfig_sources.txt")
CREDS_BLOCK=$(cat "$PF_DIR/shared/blocks/nugetconfig_credentials.txt")
MAPPING_BLOCK=$(cat "$PF_DIR/shared/blocks/nugetconfig_sourcemapping.txt")

HAVE_DOTNET=0
if command -v dotnet >/dev/null 2>&1; then
  HAVE_DOTNET=1
  export DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
fi

# Mirrors templates/nuget.sh: sources + credentials always, mapping only when present.
apply() {
  upsert_nuget_block "$1" "packageSources"           "$SOURCES_BLOCK" "$OWNER" "$GROUP"
  upsert_nuget_block "$1" "packageSourceCredentials" "$CREDS_BLOCK"   "$OWNER" "$GROUP"
  if [[ -f "$1" ]] && grep -q '<packageSourceMapping' "$1" 2>/dev/null; then
    upsert_nuget_block "$1" "packageSourceMapping"   "$MAPPING_BLOCK" "$OWNER" "$GROUP"
  fi
}

assert_xml() {
  python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$1"
}

# assert_sources <file> <expected-url>... — what NuGet itself resolves from the file.
# Skipped when dotnet is not installed (structure is still asserted via XML/grep).
assert_sources() {
  local file="$1"; shift
  [[ "$HAVE_DOTNET" == "1" ]] || return 0
  local got expected
  got=$(dotnet nuget list source --configfile "$file" --format Short 2>/dev/null \
        | awk 'NF >= 2 { print $2 }' | sort | tr '\n' ' ')
  expected=$(printf '%s\n' "$@" | sort | tr '\n' ' ')
  if [[ "$got" != "$expected" ]]; then
    echo "sources mismatch for $file"; echo "  got     : $got"; echo "  expected: $expected"
    return 1
  fi
}

sha() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }

count_markers() { grep -cF "$ENDOR_XML_BLOCK_START" "$1" || true; }

echo "test: fresh machine — scaffold created, only the Endor source resolves, idempotent, dry-run inert, removal restores nuget.org"
f="$TMP_DIR/fresh/.nuget/NuGet/NuGet.Config"
apply "$f"
assert_xml "$f"
[[ "$(count_markers "$f")" == "2" ]]                 # no mapping block on a fresh file
grep -qF '<clear />' "$f"
grep -qF "value=\"$SOURCE_URL\"" "$f"
grep -qF '<endor-firewall>' "$f"
grep -qF 'value="%ENDOR_ATTR_USER%"' "$f"
! grep -q 'packageSourceMapping' "$f"
assert_sources "$f" "$SOURCE_URL"
before=$(sha "$f"); apply "$f"; [[ "$(sha "$f")" == "$before" ]]
DRY_RUN=1 apply "$f" >/dev/null; [[ "$(sha "$f")" == "$before" ]]
out=$(DRY_RUN=1 remove_nuget_blocks "$f" "$OWNER" "$GROUP"); [[ "$out" == *'RESTORE nuget.org'* ]]
[[ "$(sha "$f")" == "$before" ]]
remove_nuget_blocks "$f" "$OWNER" "$GROUP" | grep -q 'nuget.org default restored'
assert_xml "$f"
[[ "$(count_markers "$f")" == "0" ]]
grep -qF '<packageSources>' "$f"                             # sections stay in place
grep -qF '<packageSourceCredentials>' "$f"
[[ "$(grep -c 'key="nuget.org"' "$f")" == "1" ]]
assert_sources "$f" "$NUGET_ORG_URL"
remove_nuget_blocks "$f" "$OWNER" "$GROUP" | grep -q 'skip (no Endor block)'   # second removal is a no-op
apply "$f"; assert_sources "$f" "$SOURCE_URL"                # re-install after removal works

echo "test: dotnet default config (BOM, nuget.org) — merged into existing section, nuget.org superseded, original content restored on removal"
f="$TMP_DIR/default/NuGet.Config"; mkdir -p "$(dirname "$f")"
printf '\xEF\xBB\xBF<?xml version="1.0" encoding="utf-8"?>\n<configuration>\n  <packageSources>\n    <add key="nuget.org" value="%s" protocolVersion="3" />\n  </packageSources>\n</configuration>\n' "$NUGET_ORG_URL" > "$f"
cp "$f" "$f.orig"
_ENDOR_WARNED=0; warn_if_nuget_source_conflict "$f"; [[ "$_ENDOR_WARNED" == "0" ]]  # nuget.org alone is not a conflict
apply "$f"
assert_xml "$f"
[[ "$(grep -c '<packageSources>' "$f")" == "1" ]]           # merged, not duplicated
grep -qF 'key="nuget.org"' "$f"                              # existing entry preserved in file
assert_sources "$f" "$SOURCE_URL"                            # ...but cleared for NuGet
before=$(sha "$f"); apply "$f"; [[ "$(sha "$f")" == "$before" ]]
remove_nuget_blocks "$f" "$OWNER" "$GROUP" | grep -qv 'default restored'   # nuget.org was there — not re-added
assert_xml "$f"
[[ "$(count_markers "$f")" == "0" ]]
[[ "$(grep -c 'key="nuget.org"' "$f")" == "1" ]]
head -c 3 "$f" | cmp -s - <(printf '\xEF\xBB\xBF')           # BOM preserved
grep -qF '<packageSourceCredentials>' "$f"                   # section the install created stays (empty)
# Everything that was there before is still there, in order.
diff <(grep -vE 'packageSourceCredentials' "$f") "$f.orig"
assert_sources "$f" "$NUGET_ORG_URL"

echo "test: private feed outside the block triggers the conflict warning"
f="$TMP_DIR/conflict/NuGet.Config"; mkdir -p "$(dirname "$f")"
cat > "$f" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nuget.org" value="$NUGET_ORG_URL" protocolVersion="3" />
    <add key="corp" value="https://corp.example.com/nuget/v3/index.json" />
  </packageSources>
</configuration>
EOF
_ENDOR_WARNED=0; warn_if_nuget_source_conflict "$f" 2>/dev/null; [[ "$_ENDOR_WARNED" == "1" ]]
apply "$f"
_ENDOR_WARNED=0; warn_if_nuget_source_conflict "$f" 2>/dev/null; [[ "$_ENDOR_WARNED" == "1" ]]  # persists on re-run
assert_sources "$f" "$SOURCE_URL"
_ENDOR_WARNED=0

echo "test: private feed only (no nuget.org) — removal leaves the feed alone and does NOT add nuget.org"
f="$TMP_DIR/feedonly/NuGet.Config"; mkdir -p "$(dirname "$f")"
cat > "$f" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="corp" value="https://corp.example.com/nuget/v3/index.json" />
  </packageSources>
</configuration>
EOF
cp "$f" "$f.orig"
apply "$f"
assert_sources "$f" "$SOURCE_URL"
remove_nuget_blocks "$f" "$OWNER" "$GROUP" | grep -qv 'default restored'
! grep -q 'api.nuget.org' "$f"
grep -qF 'key="corp"' "$f"
grep -qF '<packageSourceCredentials>' "$f"                   # created section stays, empty
assert_xml "$f"
assert_sources "$f" "https://corp.example.com/nuget/v3/index.json"

echo "test: customer <clear /> above our block — disabled as endor-bak so ours takes effect, restored on removal"
# NuGet honours only the FIRST <clear /> in a section; without this handling the
# customer's clear would win and nuget.org would stay active (silent bypass).
f="$TMP_DIR/userclear/NuGet.Config"; mkdir -p "$(dirname "$f")"
cat > "$f" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="$NUGET_ORG_URL" protocolVersion="3" />
  </packageSources>
</configuration>
EOF
cp "$f" "$f.orig"
out=$(DRY_RUN=1 upsert_nuget_block "$f" packageSources "$SOURCES_BLOCK" "$OWNER" "$GROUP"); [[ "$out" == *'endor-bak'* ]]
cmp -s "$f" "$f.orig"                                        # dry-run wrote nothing
out=$(apply "$f"); [[ "$out" == *'NOTE: existing <clear />'* ]]
assert_xml "$f"
grep -qF '<!-- endor-bak <clear /> -->' "$f"
[[ "$(grep -c '^\s*<clear />' "$f")" == "1" ]]               # only ours is live
assert_sources "$f" "$SOURCE_URL"                            # nuget.org really gone
before=$(sha "$f"); out=$(apply "$f"); [[ "$out" != *NOTE* ]]; [[ "$(sha "$f")" == "$before" ]]   # idempotent, no repeat note
remove_nuget_blocks "$f" "$OWNER" "$GROUP" | grep -qv 'default restored'
! grep -q 'endor-bak' "$f"
diff <(grep -vE 'packageSourceCredentials' "$f") "$f.orig"   # user clear + nuget.org back verbatim
assert_sources "$f" "$NUGET_ORG_URL"

echo "test: existing <packageSourceMapping> — routed to endor-firewall, user mappings restored on removal"
f="$TMP_DIR/mapping/NuGet.Config"; mkdir -p "$(dirname "$f")"
cat > "$f" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nuget.org" value="$NUGET_ORG_URL" protocolVersion="3" />
    <add key="corp" value="https://corp.example.com/nuget/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="corp">
      <package pattern="Corp.*" />
    </packageSource>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
EOF
cp "$f" "$f.orig"
apply "$f"
assert_xml "$f"
[[ "$(count_markers "$f")" == "3" ]]
[[ "$(grep -c '<packageSourceMapping>' "$f")" == "1" ]]
grep -qF '<packageSource key="endor-firewall">' "$f"
grep -qF 'pattern="Corp.*"' "$f"                              # user mapping kept in file
assert_sources "$f" "$SOURCE_URL"
if [[ "$HAVE_DOTNET" == "1" ]]; then
  # A restore against the (unreachable) firewall must fail on the network, not
  # on mapping (NU1100 "no source mapped") — proves the "*" mapping is in effect.
  proj="$TMP_DIR/mapping/proj"; mkdir -p "$proj"
  printf '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>netstandard2.0</TargetFramework></PropertyGroup><ItemGroup><PackageReference Include="Newtonsoft.Json" Version="13.0.3" /></ItemGroup></Project>\n' > "$proj/proj.csproj"
  restore_out=$(cd "$proj" && dotnet restore --configfile "$f" 2>&1 || true)
  ! grep -q 'NU1100' <<< "$restore_out"
  grep -q 'NU1301' <<< "$restore_out"
fi
before=$(sha "$f"); apply "$f"; [[ "$(sha "$f")" == "$before" ]]
remove_nuget_blocks "$f" "$OWNER" "$GROUP" | grep -q 'block removed'
assert_xml "$f"
[[ "$(count_markers "$f")" == "0" ]]
! grep -q 'endor-firewall' "$f"
diff <(grep -vE 'packageSourceCredentials' "$f") "$f.orig"   # user sources + mappings restored verbatim
assert_sources "$f" "$NUGET_ORG_URL" "https://corp.example.com/nuget/v3/index.json"

echo "test: self-closing sections and unrelated <config> — expanded, preserved, nuget.org restored on removal"
f="$TMP_DIR/selfclose/NuGet.Config"; mkdir -p "$(dirname "$f")"
cat > "$f" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <config>
    <add key="globalPackagesFolder" value="/opt/nuget-packages" />
  </config>
  <packageSources />
  <packageSourceCredentials></packageSourceCredentials>
</configuration>
EOF
apply "$f"
assert_xml "$f"
[[ "$(count_markers "$f")" == "2" ]]
grep -qF 'globalPackagesFolder' "$f"
assert_sources "$f" "$SOURCE_URL"
remove_nuget_blocks "$f" "$OWNER" "$GROUP" | grep -q 'nuget.org default restored'
assert_xml "$f"
[[ "$(count_markers "$f")" == "0" ]]
grep -qF 'globalPackagesFolder' "$f"
grep -qF '<packageSources>' "$f"
assert_sources "$f" "$NUGET_ORG_URL"

echo "test: existing Endor block in one section only — the other section is added, the first replaced in place"
f="$TMP_DIR/partial/NuGet.Config"; mkdir -p "$(dirname "$f")"
cat > "$f" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nuget.org" value="$NUGET_ORG_URL" protocolVersion="3" />
    $ENDOR_XML_BLOCK_START
    <clear />
    <add key="endor-firewall" value="https://old.example.com/stale/index.json" protocolVersion="3" />
    $ENDOR_XML_BLOCK_END
  </packageSources>
</configuration>
EOF
apply "$f"
assert_xml "$f"
! grep -q 'old.example.com' "$f"
[[ "$(count_markers "$f")" == "2" ]]
assert_sources "$f" "$SOURCE_URL"

echo "test: malformed file (no </configuration>) is left untouched with a warning"
f="$TMP_DIR/malformed/NuGet.Config"; mkdir -p "$(dirname "$f")"
printf '<?xml version="1.0"?>\n<configuration>\n  <packageSources>\n' > "$f"
before=$(sha "$f")
_ENDOR_WARNED=0; apply "$f" 2>/dev/null; [[ "$_ENDOR_WARNED" == "1" ]]
[[ "$(sha "$f")" == "$before" ]]
_ENDOR_WARNED=0

echo "test: generator emits endor-nuget.sh and wires NuGet into endor-all.sh / endor-remove.sh"
ENDOR_NAMESPACE="$NAMESPACE" ENDOR_API_KEY_ID="$KEY_ID" ENDOR_API_SECRET="$SECRET" bash "$GENERATOR" >/dev/null
out="$PF_DIR/bash/out/$NAMESPACE"
test -f "$out/endor-nuget.sh"
bash -n "$out/endor-nuget.sh"
grep -qF "$SOURCE_URL" "$out/endor-nuget.sh"
grep -qF 'upsert_nuget_block' "$out/endor-nuget.sh"
grep -qF 'NUGET_SOURCEMAPPING_BLOCK=' "$out/endor-nuget.sh"
grep -qF "$SOURCE_URL" "$out/endor-all.sh"
grep -qF 'remove_nuget_blocks "$_NUGET_CONFIG"' "$out/endor-remove.sh"
! grep -q '{{NUGET_SOURCE_URL}}' "$out/endor-nuget.sh"

echo "ok: nuget tests passed (dotnet validation: $([[ "$HAVE_DOTNET" == "1" ]] && echo on || echo skipped))"
