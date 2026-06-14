BIN="${HOME}/.endorctl/endorctl"
skip=
[ -n "${ENDORCTL_SKIP_UPDATE:-}" ] && [ -x "$BIN" ] && skip=1
if [ -z "$skip" ]; then
  case "$(uname -s)" in Darwin) os=macos ;; Linux) os=linux ;; *) exit 1 ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) exit 1 ;; esac
  URL="https://api.endorlabs.com/download/latest/endorctl_${os}_${arch}"
  ARCH_KEY="ARCH_TYPE_$(echo "${os}_${arch}" | tr '[:lower:]' '[:upper:]')"
  current=$([ -x "$BIN" ] && "$BIN" --version 2>/dev/null | awk '/version/ {print $NF; exit}')
  meta=$(curl -fsSL --retry 5 --retry-connrefused --retry-all-errors https://api.endorlabs.com/meta/version)
  latest=$(echo "$meta" | sed -n 's/.*"ClientVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  expected_sha=$(echo "$meta" | sed -n "s/.*\"${ARCH_KEY}\"[[:space:]]*:[[:space:]]*\"\([a-f0-9]*\)\".*/\1/p")
  uptodate=
  [ -n "$current" ] && { [ -z "$latest" ] || [ "$current" = "$latest" ]; } && uptodate=1
  if [ -z "$uptodate" ]; then
    DIR=$(dirname "$BIN")
    mkdir -p "$DIR"
    # Sweep leftovers from interrupted past runs. Age-gated so a concurrent
    # session's in-flight download is never deleted; the name cannot match the
    # installed binary ("endorctl").
    find "$DIR" -name 'endorctl-download-*' -mmin +60 -delete 2>/dev/null
    TMP=$(mktemp "$DIR/endorctl-download-XXXXXX") || exit 1
    curl -fsSL --retry 5 --retry-connrefused --retry-all-errors -o "$TMP" "$URL" || { rm -f "$TMP"; exit 1; }
    [ ${#expected_sha} -eq 64 ] || { rm -f "$TMP"; exit 1; }
    case "$expected_sha" in *[!0-9a-f]*) rm -f "$TMP"; exit 1 ;; esac
    if command -v sha256sum >/dev/null 2>&1; then sum=$(sha256sum "$TMP" | awk '{print $1}'); else sum=$(shasum -a 256 "$TMP" | awk '{print $1}'); fi
    [ "$sum" = "$expected_sha" ] || { rm -f "$TMP"; exit 1; }
    chmod +x "$TMP" || { rm -f "$TMP"; exit 1; }
    mv "$TMP" "$BIN"
  fi
fi
