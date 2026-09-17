#!/usr/bin/env bash
# Drives the NuGet.Config helpers from lib/common.sh against fixture files
# (the generated installer itself needs root + a console user), then checks
# the generator wires NuGet in. `dotnet nuget list source` validates what
# NuGet actually resolves when dotnet is installed.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF_DIR="$(cd "$TEST_DIR/.." && pwd)"
SOURCE_URL="https://factory.endorlabs.com/v1/namespaces/ci-smoke/firewall/nuget/v3/index.json"
NUGET_ORG_URL="https://api.nuget.org/v3/index.json"
CORP_URL="https://corp.example.com/nuget/v3/index.json"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
OWNER=$(id -un); GROUP=$(id -gn)

# Both are read by the sourced common.sh functions.
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

# Mirrors templates/nuget.sh.
apply() {
  upsert_nuget_block "$1" "packageSources"           "$SOURCES_BLOCK" "$OWNER" "$GROUP"
  upsert_nuget_block "$1" "packageSourceCredentials" "$CREDS_BLOCK"   "$OWNER" "$GROUP"
  if grep -q '<packageSourceMapping' "$1" 2>/dev/null; then
    upsert_nuget_block "$1" "packageSourceMapping"   "$MAPPING_BLOCK" "$OWNER" "$GROUP"
  fi
}
remove() { remove_nuget_blocks "$1" "$OWNER" "$GROUP"; }

assert_xml() { python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$1"; }
sha()        { shasum -a 256 "$1" | awk '{print $1}'; }
markers()    { grep -cF "$ENDOR_XML_BLOCK_START" "$1" || true; }
# assert_sources <file> <url>... — the sources NuGet resolves (skipped without dotnet)
assert_sources() {
  local file="$1"; shift
  [[ "$HAVE_DOTNET" == "1" ]] || return 0
  local got expected
  got=$(dotnet nuget list source --configfile "$file" --format Short 2>/dev/null | awk 'NF >= 2 {print $2}' | sort | tr '\n' ' ')
  expected=$(printf '%s\n' "$@" | sort | tr '\n' ' ')
  [[ "$got" == "$expected" ]] || { echo "sources mismatch: got '$got' expected '$expected'"; return 1; }
}
# assert_restored <file> — everything pre-install is back; only an empty created section may remain
assert_restored() {
  [[ "$(markers "$1")" == "0" ]]
  diff <(grep -vE 'packageSourceCredentials' "$1") "$1.orig"
}
new_fixture() { f="$TMP_DIR/$1/NuGet.Config"; mkdir -p "$(dirname "$f")"; cat > "$f"; cp "$f" "$f.orig"; }

echo "test: fresh machine — created, idempotent, dry-run inert, removal restores nuget.org"
f="$TMP_DIR/fresh/.nuget/NuGet/NuGet.Config"
apply "$f"; assert_xml "$f"
[[ "$(markers "$f")" == "2" ]]
grep -qF '<clear />' "$f"; grep -qF 'value="%ENDOR_ATTR_USER%"' "$f"
assert_sources "$f" "$SOURCE_URL"
before=$(sha "$f"); apply "$f"; [[ "$(sha "$f")" == "$before" ]]
DRY_RUN=1 apply "$f" >/dev/null; [[ "$(sha "$f")" == "$before" ]]
out=$(remove "$f"); [[ "$out" == *'nuget.org default restored'* ]]
assert_xml "$f"; [[ "$(markers "$f")" == "0" ]]
assert_sources "$f" "$NUGET_ORG_URL"
out=$(remove "$f"); [[ "$out" == *'skip (no Endor block)'* ]]
apply "$f"; assert_sources "$f" "$SOURCE_URL"                # re-install after removal

echo "test: dotnet default config (BOM, nuget.org) — merged, superseded, restored"
new_fixture default < <(printf '\xEF\xBB\xBF<?xml version="1.0" encoding="utf-8"?>\n<configuration>\n  <packageSources>\n    <add key="nuget.org" value="%s" protocolVersion="3" />\n  </packageSources>\n</configuration>\n' "$NUGET_ORG_URL")
_ENDOR_WARNED=0; warn_if_nuget_source_conflict "$f"; [[ "$_ENDOR_WARNED" == "0" ]]   # nuget.org alone: no warning
apply "$f"; assert_xml "$f"
[[ "$(grep -c '<packageSources>' "$f")" == "1" ]]             # merged, not duplicated
assert_sources "$f" "$SOURCE_URL"
before=$(sha "$f"); apply "$f"; [[ "$(sha "$f")" == "$before" ]]
out=$(remove "$f"); [[ "$out" != *'default restored'* ]]      # nuget.org was there — not re-added
assert_restored "$f"; assert_sources "$f" "$NUGET_ORG_URL"

echo "test: private feed — warning fires, feed superseded, restored without adding nuget.org"
new_fixture feed <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="corp" value="$CORP_URL" />
  </packageSources>
</configuration>
EOF
_ENDOR_WARNED=0; warn_if_nuget_source_conflict "$f" 2>/dev/null; [[ "$_ENDOR_WARNED" == "1" ]]
apply "$f"; assert_sources "$f" "$SOURCE_URL"
_ENDOR_WARNED=0; warn_if_nuget_source_conflict "$f" 2>/dev/null; [[ "$_ENDOR_WARNED" == "1" ]]   # persists on re-run
_ENDOR_WARNED=0
remove "$f" >/dev/null; assert_restored "$f"
! grep -q 'api.nuget.org' "$f"; assert_sources "$f" "$CORP_URL"

echo "test: customer <clear /> above our block — disabled (only the first clear counts), restored"
new_fixture userclear <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="$NUGET_ORG_URL" protocolVersion="3" />
  </packageSources>
</configuration>
EOF
out=$(DRY_RUN=1 upsert_nuget_block "$f" packageSources "$SOURCES_BLOCK" "$OWNER" "$GROUP"); [[ "$out" == *endor-bak* ]]
cmp -s "$f" "$f.orig"
out=$(apply "$f"); [[ "$out" == *'NOTE: existing <clear />'* ]]
grep -qF '<!-- endor-bak <clear /> -->' "$f"
assert_sources "$f" "$SOURCE_URL"                             # nuget.org really gone
before=$(sha "$f"); out=$(apply "$f"); [[ "$out" != *NOTE* && "$(sha "$f")" == "$before" ]]
remove "$f" >/dev/null; assert_restored "$f"; assert_sources "$f" "$NUGET_ORG_URL"

echo "test: existing <packageSourceMapping> — pattern * routed to endor-firewall, mappings restored"
new_fixture mapping <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nuget.org" value="$NUGET_ORG_URL" protocolVersion="3" />
    <add key="corp" value="$CORP_URL" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="corp"><package pattern="Corp.*" /></packageSource>
    <packageSource key="nuget.org"><package pattern="*" /></packageSource>
  </packageSourceMapping>
</configuration>
EOF
apply "$f"; assert_xml "$f"
[[ "$(markers "$f")" == "3" ]]
grep -qF '<packageSource key="endor-firewall">' "$f"
assert_sources "$f" "$SOURCE_URL"
remove "$f" >/dev/null; assert_restored "$f"; assert_sources "$f" "$NUGET_ORG_URL" "$CORP_URL"

echo "test: self-closing sections and unrelated <config> — expanded and preserved"
new_fixture selfclose <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <config>
    <add key="globalPackagesFolder" value="/opt/nuget-packages" />
  </config>
  <packageSources />
</configuration>
EOF
apply "$f"; assert_xml "$f"
[[ "$(markers "$f")" == "2" ]]; grep -qF 'globalPackagesFolder' "$f"
assert_sources "$f" "$SOURCE_URL"
remove "$f" >/dev/null; assert_xml "$f"
grep -qF 'globalPackagesFolder' "$f"; assert_sources "$f" "$NUGET_ORG_URL"

echo "test: malformed file (no </configuration>) is left untouched with a warning"
f="$TMP_DIR/bad/NuGet.Config"; mkdir -p "$(dirname "$f")"
printf '<?xml version="1.0"?>\n<configuration>\n  <packageSources>\n' > "$f"
before=$(sha "$f"); _ENDOR_WARNED=0
apply "$f" 2>/dev/null; [[ "$_ENDOR_WARNED" == "1" && "$(sha "$f")" == "$before" ]]
_ENDOR_WARNED=0

echo "test: generator emits endor-nuget.sh and wires NuGet into endor-all.sh / endor-remove.sh"
ENDOR_NAMESPACE=ci-smoke ENDOR_API_KEY_ID=ci-smoke-key-id ENDOR_API_SECRET=ci-smoke-secret bash "$PF_DIR/bash/generate.sh" >/dev/null
out="$PF_DIR/bash/out/ci-smoke"
bash -n "$out/endor-nuget.sh"
grep -qF "$SOURCE_URL" "$out/endor-nuget.sh"; grep -qF "$SOURCE_URL" "$out/endor-all.sh"
grep -qF 'remove_nuget_blocks' "$out/endor-remove.sh"
! grep -q '{{NUGET_SOURCE_URL}}' "$out/endor-nuget.sh"

echo "ok: nuget tests passed (dotnet validation: $([[ "$HAVE_DOTNET" == "1" ]] && echo on || echo skipped))"
