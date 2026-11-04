# tests/fake-console.sh: sourced by the VS Code suites after they set TMP_DIR. From then on no one
# is logged in, so the user of the machine running the tests stays out of the URLs they check.
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
