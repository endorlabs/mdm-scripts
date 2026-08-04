#!/usr/bin/env bash
# The JSON editing primitives in bash/lib/common.sh, in isolation.
#
# product.json is JSON, so it can carry neither an Endor sentinel comment nor an
# env-var reference — which is why these primitives exist at all, and why they are
# awk rather than jq (no new dependency may be introduced on a managed machine).
# Everything here is about byte-level fidelity: an edit must touch the two keys it
# claims to touch and nothing else, and the original must come back byte-exact.
#
# Every mutation routes through endor_replace_contents_inplace, exactly as the
# generated install script does, so trailing-newline fidelity is under test too.
#
# Target: tests/fixtures/product.json, whose shape mirrors a shipped product.json
# (tab-indented, no final newline, extensionsGallery at depth 1). Pass a path to
# run against a different file — a real install, say — but note that the
# fixture-specific counts below will then not apply.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_json_tool

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
source_stripped_lib "$T"

PJ_SRC="${1:-$FIXTURE}"
PJ="$T/pj.json"
cp "$PJ_SRC" "$PJ"
echo "target: $PJ_SRC"

URL='https://factory.endorlabs.com/v1/namespaces/spiderman/firewall/vscode/_ak/dGVzdDp0b2tlbg'
MARK=$(printf '\t"_endorPackageFirewall": {"schema":1,"namespace":"spiderman"},')

# apply <fn> <file> [args...] — run a primitive and write the result back in place,
# the way the shipping code does.
apply() {
  local fn="$1" f="$2" t rc
  shift 2
  t="$T/apply.$$"
  "$fn" "$f" "$@" > "$t"
  rc=$?
  [ "$rc" -eq 0 ] && endor_replace_contents_inplace "$f" "$t"
  rm -f "$t"
  return $rc
}

echo "== 1. extract a depth-1 object =="
endor_json_extract_top_object "$PJ" extensionsGallery > "$T/orig.block"
chk "exit 0"           "$?" "0"
chk "opening line"     "$(head -1 "$T/orig.block" | tr '\t' '@')" '@"extensionsGallery": {'
chk "closing line"     "$(tail -1 "$T/orig.block" | tr '\t' '@')" '@},'
chk "captured every line" "$(wc -l < "$T/orig.block" | tr -d ' ')" "$FIXTURE_GALLERY_LINES"
endor_json_extract_top_object "$PJ" noSuchKeyHere > /dev/null 2>&1
chk "missing key -> exit 1" "$?" "1"
chk "top-level version, not the nested one in builtInExtensions" \
  "$(endor_json_top_string "$PJ" version)" "$FIXTURE_VERSION"
chk "top-level commit" "$(endor_json_top_string "$PJ" commit)" "$FIXTURE_COMMIT"

echo "== 2. the actual patch: set serviceUrl, delete extensionUrlTemplate =="
printf '"serviceUrl": "%s"\n' "$URL" > "$T/set.txt"
printf 'extensionUrlTemplate\n' > "$T/del.txt"
cp "$PJ" "$T/patched.json"
apply endor_json_merge_object_keys "$T/patched.json" extensionsGallery "$T/set.txt" "$T/del.txt"
chk "exit 0" "$?" "0"
if json_ok "$T/patched.json"; then ok "valid JSON"; else bad "INVALID JSON"; fi
chk "serviceUrl points at the firewall" \
  "$(jget "$T/patched.json" "d['extensionsGallery']['serviceUrl'].endswith('/_ak/dGVzdDp0b2tlbg')")" "true"
chk "extensionUrlTemplate gone (the 5xx unpkg bypass)" \
  "$(jget "$T/patched.json" "'extensionUrlTemplate' in d['extensionsGallery']")" "false"
chk "every sibling key survived" \
  "$(jget "$T/patched.json" "all(k in d['extensionsGallery'] for k in ('nlsBaseUrl','itemUrl','publisherUrl','resourceUrlTemplate','controlUrl','mcpUrl','accessSKUs'))")" "true"
chk "accessSKUs untouched by a key-level merge" \
  "$(jget "$T/patched.json" "len(d['extensionsGallery']['accessSKUs'])")" "$FIXTURE_SKUS"
chk "top-level key order unchanged" \
  "$(jget "$T/patched.json" "list(d.keys())" | tr -d " '")" \
  "$(jget "$PJ" "list(d.keys())" | tr -d " '")"
chk "no other top-level key touched" \
  "$(jget "$T/patched.json" "{k:v for k,v in d.items() if k!='extensionsGallery'} == {k:v for k,v in __import__('json').load(open('$PJ')).items() if k!='extensionsGallery'}")" "true"
# One line replaced (< plus >) and one line removed (<) = 3 diff lines. This is the
# assertion that makes "one key set, one key removed" a checked claim rather than
# an intention — a writer that reserialized the object would blow it up.
chk "diff touches only the 2 intended keys" \
  "$(diff "$PJ" "$T/patched.json" | grep -c '^[<>]')" "3"
chk "final-newline state matches the source" \
  "$(endor_file_has_final_newline "$T/patched.json" && echo y || echo n)" \
  "$(endor_file_has_final_newline "$PJ" && echo y || echo n)"

echo "== 3. delete the LAST entry, which is multi-line -> no trailing comma =="
# The comma rewrite is the subtle part: JSON has no trailing commas, so removing or
# appending the final entry must fix up the entry before it.
printf 'accessSKUs\n' > "$T/del2.txt"; : > "$T/set2.txt"
cp "$PJ" "$T/drop_last.json"
apply endor_json_merge_object_keys "$T/drop_last.json" extensionsGallery "$T/set2.txt" "$T/del2.txt"
if json_ok "$T/drop_last.json"; then ok "valid JSON"; else bad "INVALID JSON"; fi
chk "the entry before it lost its comma" \
  "$(endor_json_extract_top_object "$T/drop_last.json" extensionsGallery | tail -2 | head -1 | sed 's/^[[:space:]]*//')" \
  '"mcpUrl": "https://main.vscode-cdn.net/mcp/servers.json"'

echo "== 4. delete the FIRST entry =="
printf 'nlsBaseUrl\n' > "$T/del4.txt"; : > "$T/set4.txt"
cp "$PJ" "$T/drop_first.json"
apply endor_json_merge_object_keys "$T/drop_first.json" extensionsGallery "$T/set4.txt" "$T/del4.txt"
if json_ok "$T/drop_first.json"; then ok "valid JSON"; else bad "INVALID JSON"; fi
chk "first entry gone, the rest intact" \
  "$(jget "$T/drop_first.json" "'nlsBaseUrl' not in d['extensionsGallery'] and len(d['extensionsGallery'])==$((FIXTURE_GALLERY_KEYS - 1))")" "true"

echo "== 5. append a key that is not there yet =="
printf '"endorProbe": "x"\n' > "$T/set3.txt"; : > "$T/del3.txt"
cp "$PJ" "$T/appended.json"
apply endor_json_merge_object_keys "$T/appended.json" extensionsGallery "$T/set3.txt" "$T/del3.txt"
if json_ok "$T/appended.json"; then ok "valid JSON"; else bad "INVALID JSON"; fi
chk "appended, and the preceding entry gained its comma" \
  "$(jget "$T/appended.json" "d['extensionsGallery']['endorProbe']=='x' and len(d['extensionsGallery']['accessSKUs'])==$FIXTURE_SKUS")" "true"

echo "== 6. idempotency =="
cp "$T/patched.json" "$T/patched2.json"
apply endor_json_merge_object_keys "$T/patched2.json" extensionsGallery "$T/set.txt" "$T/del.txt"
if cmp -s "$T/patched.json" "$T/patched2.json"; then ok "re-patch is byte-identical"; else bad "re-patch differs"; fi

echo "== 7. restore round-trip =="
cp "$T/patched.json" "$T/restored.json"
apply endor_json_replace_top_object "$T/restored.json" extensionsGallery "$T/orig.block"
chk "exit 0" "$?" "0"
if cmp -s "$PJ" "$T/restored.json"; then ok "byte-identical to pristine"
else bad "differs: $(diff "$PJ" "$T/restored.json" | head -4)"; fi

echo "== 8. marker insert and removal =="
cp "$T/patched.json" "$T/marked.json"
apply endor_json_insert_top_line "$T/marked.json" "$MARK"
if json_ok "$T/marked.json"; then ok "valid JSON with the marker"; else bad "INVALID with the marker"; fi
chk "marker is readable by a real parser" \
  "$(jget "$T/marked.json" "d['_endorPackageFirewall']['namespace']")" "spiderman"
cp "$T/marked.json" "$T/unmarked.json"
apply endor_json_remove_top_key "$T/unmarked.json" _endorPackageFirewall
if cmp -s "$T/patched.json" "$T/unmarked.json"; then ok "removal is byte-exact"; else bad "removal differs"; fi

echo "== 9. full lifecycle: pristine -> patch+mark -> unmark+restore =="
cp "$PJ" "$T/life.json"
apply endor_json_merge_object_keys "$T/life.json" extensionsGallery "$T/set.txt" "$T/del.txt"
apply endor_json_insert_top_line "$T/life.json" "$MARK"
if json_ok "$T/life.json"; then ok "the managed state is valid JSON"; else bad "managed state INVALID"; fi
apply endor_json_remove_top_key "$T/life.json" _endorPackageFirewall
apply endor_json_replace_top_object "$T/life.json" extensionsGallery "$T/orig.block"
if cmp -s "$PJ" "$T/life.json"; then ok "returns to pristine bytes"; else bad "lifecycle drifted"; fi

echo "== 10. the greps the state machine relies on =="
# vscode_managed_state decides current-vs-stale with plain grep -F, so the patched
# lines have to be greppable exactly as written.
grep -qF "\"serviceUrl\": \"$URL\"" "$T/patched.json" \
  && ok "expected serviceUrl line is greppable" || bad "grep -F for the serviceUrl line failed"
grep -qF '"extensionUrlTemplate"' "$T/patched.json" \
  && bad "extensionUrlTemplate still greppable" || ok "extensionUrlTemplate absent"

echo "== 11. shapes other than the shipped one =="
# 4-space indentation: the indent must be read from the file, never assumed to be
# a tab. Forks and repackagers do reformat product.json.
printf '{\n    "a": 1,\n    "extensionsGallery": {\n        "serviceUrl": "old",\n        "extensionUrlTemplate": "u",\n        "itemUrl": "i"\n    },\n    "z": 2\n}\n' > "$T/sp.json"
apply endor_json_merge_object_keys "$T/sp.json" extensionsGallery "$T/set.txt" "$T/del.txt"
if json_ok "$T/sp.json"; then ok "space-indented file valid"; else bad "space-indented file INVALID"; fi
chk "space-indented: edit applied, siblings intact" \
  "$(jget "$T/sp.json" "d['extensionsGallery']['serviceUrl'].startswith('https://factory') and 'extensionUrlTemplate' not in d['extensionsGallery'] and d['extensionsGallery']['itemUrl']=='i' and d['z']==2")" "true"
chk "the set line took the file's own 8-space indent, not a tab" \
  "$(awk '/factory/ { s=$0; sub(/[^ \t].*/,"",s); printf "%d:%s\n", length(s), (index(s,"\t")?"tab":"spaces"); exit }' "$T/sp.json")" \
  "8:spaces"

# Deleting the sole entry must leave a valid empty object, not a dangling comma.
printf '{\n\t"extensionsGallery": {\n\t\t"extensionUrlTemplate": "u"\n\t}\n}\n' > "$T/only.json"
apply endor_json_merge_object_keys "$T/only.json" extensionsGallery "$T/set2.txt" "$T/del.txt"
if json_ok "$T/only.json"; then ok "deleting the sole entry leaves a valid empty object"
else bad "sole-entry delete INVALID: $(cat "$T/only.json")"; fi

# Minified: there is no depth-1 line range to edit, so the awk writer must decline
# and leave the file alone — that refusal is what hands off to the node writer.
printf '{"extensionsGallery":{"serviceUrl":"old"},"z":1}' > "$T/min.json"
endor_json_extract_top_object "$T/min.json" extensionsGallery >/dev/null 2>&1
chk "minified -> extract returns 1 (the fallback trigger)" "$?" "1"
apply endor_json_merge_object_keys "$T/min.json" extensionsGallery "$T/set.txt" "$T/del.txt"
chk "minified -> merge returns 1" "$?" "1"
chk "minified file left untouched" "$(cat "$T/min.json")" '{"extensionsGallery":{"serviceUrl":"old"},"z":1}'

echo "== 12. validation refuses what it must =="
printf 'not json at all' > "$T/bad.json"
chk "rejects non-JSON" "$(endor_json_validate "$T/bad.json" && echo y || echo n)" "n"
printf '{\n\t"a": 1\n}\n' > "$T/good.json"
chk "accepts good JSON" "$(endor_json_validate "$T/good.json" && echo y || echo n)" "y"
# A trailing comma is precisely the malformation the comma rewrite can produce, and
# it must be caught on machines where no node binary is resolvable.
printf '{\n\t"a": 1,\n}\n' > "$T/tc.json"
chk "rejects a trailing comma with no node available" \
  "$(endor_json_validate "$T/tc.json" && echo y || echo n)" "n"

summarize
