# endorctl bootstrap, inlined into each agent's session hook. Never blocks: the
# foreground decides what is needed and hands it to a detached background job,
# so a ~300 MB download cannot hold up a session start. A machine with no
# endorctl yet skips that one audit rather than waiting for the install.
# Comments are stripped when render.sh inlines this, so they cost nothing here.
BIN="${HOME}/.endorctl/endorctl"
DIR="${HOME}/.endorctl"
STAMP="$DIR/.update-check"
TTL="${ENDORCTL_UPDATE_TTL_MINUTES:-1440}"
case "$TTL" in ''|*[!0-9]*) TTL=1440 ;; esac

need=
if [ ! -x "$BIN" ]; then
  need=1
elif [ -z "${ENDORCTL_SKIP_UPDATE:-}" ]; then
  # A stamp newer than the TTL means no network I/O at all this session.
  [ -f "$STAMP" ] && [ -z "$(find "$STAMP" -mmin +"$TTL" 2>/dev/null)" ] || need=1
fi

if [ -n "$need" ]; then
  (
    # The redirections release the hook's stdout pipe, which the agent waits on.
    # Clear any EXIT trap inherited from the caller (Cursor's wrapper sets one).
    trap '' HUP
    trap - EXIT

    LOCK="$DIR/.update.lock"
    PART="$DIR/.endorctl.part"
    SHAF="$DIR/.endorctl.sha"
    sha256() {
      if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
      else shasum -a 256 "$1" | awk '{print $1}'; fi
    }
    mkdir -p "$DIR" || exit 0

    # One downloader per machine. Staleness is judged by the partial's mtime,
    # which curl advances as it writes, so a live slow download is never broken.
    if [ -d "$LOCK" ]; then
      ref="$PART"; [ -f "$PART" ] || ref="$LOCK"
      [ -n "$(find "$ref" -mmin +30 2>/dev/null)" ] || exit 0
      mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null && rm -rf "$LOCK.stale.$$"
    fi
    mkdir "$LOCK" 2>/dev/null || exit 0
    # Stand down unless the lock is ours, before arming the trap that removes it.
    echo "$$" > "$LOCK/owner" 2>/dev/null || { rmdir "$LOCK" 2>/dev/null; exit 0; }
    [ "$(cat "$LOCK/owner" 2>/dev/null)" = "$$" ] || exit 0
    # INT/TERM route through exit so the EXIT trap does the one cleanup.
    trap 'rm -rf "$LOCK"' EXIT
    trap 'exit 1' INT TERM

    # Leftovers from the previous mktemp-based scheme, and from killed runs.
    find "$DIR" -name 'endorctl-download-*' -mmin +60 -delete 2>/dev/null

    case "$(uname -s)" in Darwin) os=macos ;; Linux) os=linux ;; *) exit 0 ;; esac
    case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) exit 0 ;; esac
    URL="https://api.endorlabs.com/download/latest/endorctl_${os}_${arch}"
    ARCH_KEY="ARCH_TYPE_$(echo "${os}_${arch}" | tr '[:lower:]' '[:upper:]')"
    current=$([ -x "$BIN" ] && "$BIN" --version 2>/dev/null | awk '/version/ {print $NF; exit}')
    meta=$(curl -fsSL --connect-timeout 5 --max-time 30 https://api.endorlabs.com/meta/version) || exit 0
    latest=$(echo "$meta" | sed -n 's/.*"ClientVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    expected_sha=$(echo "$meta" | sed -n "s/.*\"${ARCH_KEY}\"[[:space:]]*:[[:space:]]*\"\([a-f0-9]*\)\".*/\1/p")
    [ -n "$latest" ] || exit 0
    [ ${#expected_sha} -eq 64 ] || exit 0
    case "$expected_sha" in *[!0-9a-f]*) exit 0 ;; esac

    if [ -n "$current" ] && [ "$current" = "$latest" ]; then
      rm -f "$PART" "$SHAF"
      : > "$STAMP"
      exit 0
    fi

    # Pin the partial to the digest it is being built for: endorctl is rebuilt
    # roughly daily, and a partial spanning two builds could never verify.
    if [ ! -f "$SHAF" ] || [ "$(cat "$SHAF" 2>/dev/null)" != "$expected_sha" ]; then
      rm -f "$PART"
      printf '%s\n' "$expected_sha" > "$SHAF" || exit 0
    fi

    if [ ! -f "$PART" ] || [ "$(sha256 "$PART")" != "$expected_sha" ]; then
      # Resume with an explicit closed range, not `curl -C -`: this endpoint
      # answers a closed bytes=A-B with a 206 but an open-ended bytes=A- with the
      # whole file, and the open form is what -C - sends. Hence the HEAD probe.
      total=$(curl -fsSLI --connect-timeout 5 --max-time 30 "$URL" 2>/dev/null \
        | tr -d '\r' | sed -n 's/^[Cc]ontent-[Ll]ength: *//p' | tail -1)
      case "$total" in ''|*[!0-9]*) total= ;; esac
      size=$(wc -c < "$PART" 2>/dev/null | tr -d ' ')
      case "$size" in ''|*[!0-9]*) size=0 ;; esac
      # No length to resume against, or a full-length partial that failed its
      # digest (racing downloaders can make one): either way, start over.
      if [ -z "$total" ] || [ "$size" -ge "$total" ]; then rm -f "$PART"; fi

      n=0; ok=
      while [ "$n" -lt 3 ]; do
        n=$((n + 1))
        # Recomputed per attempt: one that dies midway leaves a correct prefix.
        size=$(wc -c < "$PART" 2>/dev/null | tr -d ' ')
        case "$size" in ''|*[!0-9]*) size=0 ;; esac
        rng=
        [ -n "$total" ] && [ "$size" -gt 0 ] && rng="-r $size-$((total - 1))"
        # No --max-time: off the critical path, a slow link should finish.
        # $rng is deliberately unquoted - it is either empty or two words.
        if curl -fsSL --connect-timeout 10 --speed-limit 10240 --speed-time 60 \
             $rng "$URL" >> "$PART"; then ok=1; break; fi
        sleep 5
      done
      [ -n "$ok" ] || exit 0
      [ "$(sha256 "$PART")" = "$expected_sha" ] || { rm -f "$PART" "$SHAF"; exit 0; }
    fi

    chmod +x "$PART" || exit 0
    mv "$PART" "$BIN" || exit 0
    rm -f "$SHAF"
    : > "$STAMP"
  ) >/dev/null 2>&1 </dev/null &
fi

# Nothing to audit with yet. Exiting 0 (not 1) keeps the hook successful and
# stops the appended audit call from running against a missing binary.
[ -x "$BIN" ] || exit 0
