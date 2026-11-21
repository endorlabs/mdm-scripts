# tests/attribution.sh: sourced by the VS Code suites after they set ROOT_DIR, TMP_DIR, NAMESPACE,
# KEY_ID and SECRET. From then on no one is logged in, so the user of the machine running the tests
# stays out of the URLs they check.
# find_console_user sees ENDOR_TEST_CONSOLE_OWNER as the owner of /dev/console: logname finds no
# login, as under an MDM agent, and stat reports that owner for /dev/console and runs the real stat
# for anything else. A test sets ENDOR_TEST_CONSOLE_OWNER=alice to log alice in; root and
# _mbsetupuser are no one, as at the login window and in Setup Assistant.
FAKE_CONSOLE_BIN="$TMP_DIR/fake-console-bin"
mkdir -p "$FAKE_CONSOLE_BIN"
printf '#!/bin/sh\nexit 1\n' > "$FAKE_CONSOLE_BIN/logname"
cat > "$FAKE_CONSOLE_BIN/stat" <<'STAT'
#!/bin/sh
for arg in "$@"; do
  if [ "$arg" = /dev/console ]; then
    echo "$ENDOR_TEST_CONSOLE_OWNER"
    exit 0
  fi
done
exec /usr/bin/stat "$@"
STAT
chmod 755 "$FAKE_CONSOLE_BIN/logname" "$FAKE_CONSOLE_BIN/stat"
export PATH="$FAKE_CONSOLE_BIN:$PATH"
export ENDOR_TEST_CONSOLE_OWNER=root

# fake_console_in <endor-vscode.sh>: the same for the macOS worker, which resets PATH, so the fakes
# above don't reach it. A find_console_user that answers from ENDOR_TEST_CONSOLE_OWNER goes at the
# end of each lib/attribution.sh the script carries, its own and its worker's, replacing the real one.
fake_console_in() {
  python3 -I - "$1" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
ends = []
for banner in ("# ── Common functions (inlined from lib/attribution.sh and lib/common.sh)",
               "# ── User attribution (inlined from lib/attribution.sh)"):
    start = text.find(banner)
    if start < 0 or text.find(banner, start + 1) >= 0:
        sys.exit("expected one '%s' in %s" % (banner, path))
    ends.append(text.index("\n# ─────", start + 1))
ends.sort()
fake = """
find_console_user() {
  case "${ENDOR_TEST_CONSOLE_OWNER:-}" in
    ''|root|loginwindow|_mbsetupuser) echo "" ;;
    *) echo "$ENDOR_TEST_CONSOLE_OWNER" ;;
  esac
}
"""
for end in reversed(ends):
    text = text[:end] + fake + text[end:]
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
}

# The machine name in labels, as lib/attribution.sh's endor_host_label gets it.
# shellcheck disable=SC2034 # used by the suites
HOST_LABEL=$(bash -c 'source "$1"; endor_host_label' _ "$ROOT_DIR/package-firewall/bash/lib/attribution.sh")

# attributed_url <label> [secret]: the gallery URL attributed to label, built as the firewall
# decodes it: base64url(base64(base64("userattr:" + label) + ":" + key ID) + ":" + secret).
attributed_url() {
  python3 -I - "$NAMESPACE" "$KEY_ID" "${2:-$SECRET}" "$1" <<'PY'
import base64
import os
import sys
namespace, key_id, secret, label = sys.argv[1:5]
inner = base64.b64encode(b"userattr:" + os.fsencode(label))
user = base64.b64encode(inner + b":" + key_id.encode())
token = base64.urlsafe_b64encode(user + b":" + secret.encode()).decode().rstrip("=")
print("https://factory.endorlabs.com/v1/namespaces/%s/firewall/vscode/_ak/%s" % (namespace, token))
PY
}
