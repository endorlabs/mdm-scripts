# templates/remove.sh
# Removes the Endor Package Firewall sentinel block from all config files
# written by endor-js.sh and endor-python.sh.
#
# Files targeted (mirrors exactly what the install scripts write to):
#
#   JavaScript:
#     ~/.npmrc
#     ~/.yarnrc
#     ~/.yarnrc.yml
#
#   Python:
#     ~/.pip/pip.conf
#     ~/.config/pip/pip.conf
#     ~/Library/Application Support/pip/pip.conf
#     ~/.config/uv/uv.toml
#
#   Go:
#     ~/.config/go/env
#
#   .NET / NuGet:
#     ~/.nuget/NuGet/NuGet.Config  (sections kept; nuget.org restored if no source is left)
#
#   Ruby / Bundler:
#     ~/.bundle/config  (Endor mirror keys removed, including stale copies left by `bundle config`;
#                        user keys kept; the credential is in env.sh)
#
#   Ruby / gem:
#     ~/.gemrc          (pre-install original restored from ~/.gemrc.endor-bak, or deleted if Endor created it)
#     root's .gemrc     (same; only when running as root)
#
#   VS Code:
#     Restores default gallery properties and removes update remediation. On macOS this
#     swaps Microsoft's original app back in and deletes the per-device signing identity.
#     On Linux it also removes Endor's ExtensionGalleryServiceUrl policy from
#     /etc/vscode/policy.json. On macOS it reports an Endor configuration profile, which only
#     the MDM can remove.
#
#   Shell profiles (env.sh source line):
#     ~/.zshrc
#     ~/.bash_profile
#     ~/.bashrc
#
# Behaviour:
#   - Files with no Endor block are skipped (nothing modified)
#   - Files where Endor block is the only content are deleted
#   - Files with other content have only the block stripped
#   - --dry-run: prints what would happen, writes nothing
#   - Safe to run multiple times (idempotent)

echo ""
echo "[endor-remove] ── Endor Package Firewall removal ──────────────────────────"
echo "[endor-remove]    namespace={{NAMESPACE}}"
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "[endor-remove]    mode=DRY RUN — no files will be modified"
fi
echo ""

# ── env.sh and shell profile source lines ────────────────────────────────────
echo "[endor-remove] ── env.sh ────────────────────────────────────────────────────"

remove_block "$USER_HOME/.config/endor/env.sh" "$CONSOLE_USER" "$USER_GROUP"

if [[ "${DRY_RUN:-0}" != "1" ]]; then
  rmdir "$USER_HOME/.config/endor" 2>/dev/null || true
fi

echo ""
echo "[endor-remove] ── Shell profiles (env.sh source line) ───────────────────────"

for _profile in \
  "$USER_HOME/.zshrc" \
  "$USER_HOME/.bash_profile" \
  "$USER_HOME/.bashrc"; do
  remove_block "$_profile" "$CONSOLE_USER" "$USER_GROUP"
done
unset _profile

# ── JavaScript config files ───────────────────────────────────────────────────
echo ""
echo "[endor-remove] ── JavaScript ───────────────────────────────────────────────"

remove_block "$USER_HOME/.npmrc"      "$CONSOLE_USER" "$USER_GROUP"
remove_block "$USER_HOME/.yarnrc"     "$CONSOLE_USER" "$USER_GROUP"
remove_block "$USER_HOME/.yarnrc.yml" "$CONSOLE_USER" "$USER_GROUP"

# yarn 1.x rewrites ~/.yarnrc on its own and can copy the Endor registry
# outside the managed block. Delete only lines that exactly match our URL —
# they can't be anyone else's config.
_YARNRC="$USER_HOME/.yarnrc"
_ENDOR_YARN_LINE='registry "{{NPM_REGISTRY_URL}}"'
if [[ -f "$_YARNRC" ]] && awk -v s="$ENDOR_BLOCK_START" -v e="$ENDOR_BLOCK_END" '
      index($0, s) { skip=1; next }
      index($0, e) { skip=0; next }
      !skip        { print }
    ' "$_YARNRC" | grep -qxF "$_ENDOR_YARN_LINE"; then
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run]   action : DELETE yarn-copied Endor registry line from $_YARNRC"
  else
    _tmp=$(mktemp)
    grep -vxF "$_ENDOR_YARN_LINE" "$_YARNRC" | grep -vx 'always-auth true' > "$_tmp" || true
    if [[ -z "$(tr -d '[:space:]' < "$_tmp")" ]]; then
      rm -f "$_YARNRC" "$_tmp"
      echo "[endor-remove] deleted (was empty) : $_YARNRC"
    else
      mv "$_tmp" "$_YARNRC"
      chown "$CONSOLE_USER:$USER_GROUP" "$_YARNRC"
      chmod 600 "$_YARNRC"
      echo "[endor-remove] yarn-copied line removed: $_YARNRC"
    fi
  fi
fi
unset _YARNRC _ENDOR_YARN_LINE _tmp

# ── Python config files ───────────────────────────────────────────────────────
echo ""
echo "[endor-remove] ── Python ────────────────────────────────────────────────────"

# remove_block also restores pip keys disabled with '#endor-bak#' at install time
for pip_conf in \
  "$USER_HOME/.pip/pip.conf" \
  "$USER_HOME/.config/pip/pip.conf" \
  "$USER_HOME/Library/Application Support/pip/pip.conf"; do
  remove_block "$pip_conf" "$CONSOLE_USER" "$USER_GROUP"
done
unset pip_conf

remove_block "$USER_HOME/.config/uv/uv.toml" "$CONSOLE_USER" "$USER_GROUP"

# ── Go config file ────────────────────────────────────────────────────────────
echo ""
echo "[endor-remove] ── Go ────────────────────────────────────────────────────────────"

# Resolve go env file path the same way the install script does.
_GO_ENV_FILE=""
for _go_bin in \
  /usr/local/go/bin/go \
  /opt/homebrew/bin/go \
  /opt/homebrew/opt/go/bin/go \
  /usr/local/bin/go \
  /usr/bin/go; do
  if [[ -x "$_go_bin" ]]; then
    _GO_ENV_FILE=$(HOME="$USER_HOME" GOENV="" "$_go_bin" env GOENV 2>/dev/null || true)
    break
  fi
done
if [[ -z "$_GO_ENV_FILE" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    _GO_ENV_FILE="$USER_HOME/Library/Application Support/go/env"
  else
    _GO_ENV_FILE="${XDG_CONFIG_HOME:-$USER_HOME/.config}/go/env"
  fi
fi
unset _go_bin

remove_block "$_GO_ENV_FILE" "$CONSOLE_USER" "$USER_GROUP"
unset _GO_ENV_FILE

# ── Maven config file ────────────────────────────────────────────────────────────
echo ""
echo "[endor-remove] ── Maven ────────────────────────────────────────────────────────────"

remove_xml_block "$USER_HOME/.m2/settings.xml" "$CONSOLE_USER" "$USER_GROUP"

# ── NuGet config file ─────────────────────────────────────────────────────────
echo ""
echo "[endor-remove] ── NuGet / .NET ────────────────────────────────────────────────"

remove_nuget_blocks "$USER_HOME/.nuget/NuGet/NuGet.Config" "$CONSOLE_USER" "$USER_GROUP"

# ── Bundler config file ───────────────────────────────────────────────────────
echo ""
echo "[endor-remove] ── Ruby / Bundler ──────────────────────────────────────────────"

remove_bundle_config "$USER_HOME/.bundle/config" "{{GEM_MIRROR_URL}}" "$CONSOLE_USER" "$USER_GROUP"

# ── gem config files ──────────────────────────────────────────────────────────
echo ""
echo "[endor-remove] ── Ruby / gem ──────────────────────────────────────────────────"

remove_gemrc "$USER_HOME/.gemrc" "{{GEM_MIRROR_URL}}" "$CONSOLE_USER" "$USER_GROUP"
if [[ "$EUID" -eq 0 ]]; then
  _ROOT_HOME=$(resolve_user_home root)
  remove_gemrc "$_ROOT_HOME/.gemrc" "{{GEM_MIRROR_URL}}" root "$(id -gn root)"
  unset _ROOT_HOME
fi

# >>> endor-vscode-remove
# ── VS Code extension firewall ────────────────────────────────────────────────
# Removes the VS Code methods in scope: the product.json patch, the ExtensionGalleryServiceUrl
# policy, or both. endor-remove.sh removes both, and generate.sh builds
# endor-vscode-disable-patch.sh and endor-vscode-disable-policy.sh from this section with the
# scope filled in. So the section stands on its own, and doesn't use the console user.
_vscode_remove_scope='{{VSCODE_REMOVE_SCOPE}}'
case "$_vscode_remove_scope" in patch|policy) ;; *) _vscode_remove_scope=all ;; esac
echo ""
echo "[endor-remove] ── VS Code extensions ───────────────────────────────────────"

_vscode_remove_os=$(uname -s)
if [[ "$_vscode_remove_scope" != "policy" ]]; then
  case "$_vscode_remove_os" in
    Darwin)
      _VSCODE_STATE_DIR="${ENDOR_VSCODE_STATE_DIR:-/Library/Application Support/Endor Labs/vscode-firewall}"
      _vscode_plist="/Library/LaunchDaemons/com.endorlabs.vscode-firewall.plist"
      if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[dry-run]   action : UNLOAD and DELETE $_vscode_plist"
      elif [[ "${ENDOR_VSCODE_SKIP_WATCHER:-0}" != "1" ]]; then
        /bin/launchctl bootout system/com.endorlabs.vscode-firewall >/dev/null 2>&1 || true
        rm -f "$_vscode_plist"
      fi
      ;;
    Linux)
      _VSCODE_STATE_DIR="${ENDOR_VSCODE_STATE_DIR:-/var/lib/endor/vscode-firewall}"
      if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[dry-run]   action : DELETE /etc/dpkg/dpkg.cfg.d/endor-vscode-firewall"
        echo "[dry-run]   action : DISABLE and DELETE endor-vscode-firewall systemd units"
      elif [[ "${ENDOR_VSCODE_SKIP_WATCHER:-0}" != "1" ]]; then
        # The dpkg hook goes first, so no package install patches VS Code again during removal.
        rm -f /etc/dpkg/dpkg.cfg.d/endor-vscode-firewall
        if command -v systemctl >/dev/null 2>&1; then
          systemctl disable --now endor-vscode-firewall.path endor-vscode-firewall.timer >/dev/null 2>&1 || true
          systemctl stop endor-vscode-firewall.service >/dev/null 2>&1 || true
        fi
        rm -f \
          /etc/systemd/system/endor-vscode-firewall.path \
          /etc/systemd/system/endor-vscode-firewall.timer \
          /etc/systemd/system/endor-vscode-firewall.service
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
      fi
      ;;
    *)
      _VSCODE_STATE_DIR=""
      ;;
  esac

  # On macOS the worker swaps Microsoft's original app back in (or restores product.json in a
  # re-signed copy), then --purge deletes its signing identity from the System keychain.
  _vscode_run_worker() {
    if [[ "$_vscode_remove_os" == "Darwin" ]]; then
      ENDOR_VSCODE_STATE_DIR="$_VSCODE_STATE_DIR" ENDOR_VSCODE_LOCK_WAIT=600 \
        /bin/bash "$_VSCODE_STATE_DIR/worker.sh" "$@"
    else
      ENDOR_VSCODE_STATE_DIR="$_VSCODE_STATE_DIR" "$_VSCODE_STATE_DIR/worker.sh" "$@"
    fi
  }

  _vscode_restore_ok=1
  if [[ -n "$_VSCODE_STATE_DIR" && -x "$_VSCODE_STATE_DIR/worker.sh" ]]; then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      _vscode_run_worker --restore --dry-run || _vscode_restore_ok=0
    else
      _vscode_run_worker --restore || _vscode_restore_ok=0
      # Workers from before --purge existed never created a signing identity.
      if [[ "$_vscode_restore_ok" == "1" ]] && grep -q -- '--purge)' "$_VSCODE_STATE_DIR/worker.sh"; then
        _vscode_run_worker --purge || _vscode_restore_ok=0
      fi
      if [[ "$_vscode_restore_ok" == "1" ]]; then
        rm -rf "$_VSCODE_STATE_DIR"
        # The daemon's log belongs to the real state folder, not to one a test points at.
        if [[ "$_vscode_remove_os" == "Darwin" && -z "${ENDOR_VSCODE_STATE_DIR:-}" ]]; then
          rm -f "/Library/Logs/Endor Labs/vscode-firewall.log" "/Library/Logs/Endor Labs/vscode-firewall.log.1"
          rmdir "/Library/Logs/Endor Labs" 2>/dev/null || true
        fi
      fi
    fi
  else
    echo "[endor-remove] skip (no VS Code managed state)"
  fi

  if [[ "$_vscode_restore_ok" != "1" ]]; then
    echo "[endor-remove] WARNING: VS Code restoration was incomplete; managed state was retained." >&2
    _ENDOR_WARNED=1
  fi
fi

# The policy, in /etc/vscode/policy.json on Linux: only Endor's keys go, and the file too if this
# machine's record says the installer created it. The program is the installer's; a test keeps
# the two copies identical. ENDOR_VSCODE_POLICY_FILE and ENDOR_VSCODE_POLICY_STATE_DIR are for
# tests, as in the installer.
IFS= read -r -d '' _VSCODE_POLICY_PY <<'ENDOR_VSCODE_POLICY_PY' || true
import json
import os
import stat
import sys
import tempfile

URL_KEY = "ExtensionGalleryServiceUrl"
AUTH_KEY = "ExtensionGalleryAuthProvider"


def say(message):
    print("[endor-vscode] " + message)


def warn(message):
    print("[endor-vscode] WARNING: " + message, file=sys.stderr)


def is_endor(value):
    return isinstance(value, str) and "/firewall/vscode/_ak/" in value


def safe(path, strict):
    """False for a symbolic link and, as root, for anything another user can change."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return True
    if stat.S_ISLNK(info.st_mode):
        warn(path + " is a symbolic link; leaving it alone")
        return False
    if strict and (info.st_uid != 0 or info.st_mode & 0o022):
        warn(path + " is not owned by root, or others can change it; leaving it alone")
        return False
    return True


def load(path):
    """The policy object, or None when there is no file. Raises ValueError if it isn't one."""
    try:
        handle = open(path, encoding="utf-8")
    except FileNotFoundError:
        return None
    with handle:
        policy = json.load(handle)
    if not isinstance(policy, dict):
        raise ValueError("not a JSON object")
    return policy


def write(path, value, mode):
    """Replaces path in one step. A file that exists keeps its mode and owner; a new one gets mode."""
    try:
        before = os.stat(path)
    except FileNotFoundError:
        before = None
    fd, temp = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".endor.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        if before is None:
            os.chmod(temp, mode)
        else:
            os.chmod(temp, stat.S_IMODE(before.st_mode))
            after = os.stat(temp)
            if (after.st_uid, after.st_gid) != (before.st_uid, before.st_gid):
                os.chown(temp, before.st_uid, before.st_gid)
        os.replace(temp, path)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def load_record(state):
    try:
        with open(os.path.join(state, "record.json"), encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, ValueError):
        return {}
    return record if isinstance(record, dict) else {}


def save_record(state, record):
    os.makedirs(state, mode=0o700, exist_ok=True)
    write(os.path.join(state, "record.json"), record, 0o600)


def forget(state):
    try:
        os.unlink(os.path.join(state, "record.json"))
    except OSError:
        pass
    try:
        os.rmdir(state)
    except OSError:
        pass


def apply(path, state, url, auth, dry_run, strict):
    folder = os.path.dirname(path)
    if not (safe(folder, strict) and safe(path, strict)):
        return 1
    try:
        current = load(path)
    except ValueError:
        warn(path + " is not a JSON object, so VS Code ignores every policy in it. Fix or delete it, then run this again")
        return 1
    record = load_record(state)
    policy = dict(current or {})
    if policy.get(URL_KEY) not in (None, "") and not is_endor(policy[URL_KEY]):
        warn(path + " sets " + URL_KEY + " to another gallery; leaving it. Remove that value to use the Endor firewall")
        return 1
    status = 0
    policy[URL_KEY] = url
    ours = record.get("auth")
    present = policy.get(AUTH_KEY)
    owned = None
    if auth:
        if present is None or present == ours:
            policy[AUTH_KEY] = auth
            owned = auth
        elif present != auth:
            warn(path + " sets " + AUTH_KEY + " to " + repr(present) + "; leaving it rather than setting " + repr(auth))
            status = 1
    elif ours and present == ours:
        del policy[AUTH_KEY]
    new_record = {
        "createdFile": bool(record.get("createdFile")) or current is None,
        "createdFolder": bool(record.get("createdFolder")) or not os.path.isdir(folder),
        "auth": owned,
    }
    if policy == current:
        if not dry_run and new_record != record:
            save_record(state, new_record)
        say("policy already set: " + path)
        return status
    if dry_run:
        print("[dry-run]   action : SET " + URL_KEY + (" and " + AUTH_KEY if owned else ""))
        print("[dry-run]   file   : " + path)
        return status
    save_record(state, new_record)
    if not os.path.isdir(folder):
        os.makedirs(folder)
        os.chmod(folder, 0o755)
    write(path, policy, 0o644)
    say("policy set: " + path)
    return status


def remove(path, state, dry_run, strict):
    folder = os.path.dirname(path)
    if not (safe(folder, strict) and safe(path, strict)):
        return 1
    try:
        current = load(path)
    except ValueError:
        warn(path + " is not a JSON object; leaving it alone")
        return 1
    record = load_record(state)
    policy = dict(current or {})
    if is_endor(policy.get(URL_KEY)):
        del policy[URL_KEY]
        if not record:
            say("note: this machine has no record of setting " + URL_KEY + " in " + path
                + ". If another tool set it, that tool may set it again")
    ours = record.get("auth")
    if ours and policy.get(AUTH_KEY) == ours:
        del policy[AUTH_KEY]
    if current is None or policy == current:
        say("skip (no Endor policy): " + path)
    elif dry_run:
        print("[dry-run]   action : REMOVE the Endor " + URL_KEY + " policy")
        print("[dry-run]   file   : " + path)
        return 0
    elif not policy and record.get("createdFile"):
        os.unlink(path)
        if record.get("createdFolder"):
            try:
                os.rmdir(folder)
            except OSError:
                pass
        say("removed " + path)
    else:
        write(path, policy, 0o644)
        say("removed the Endor policy from " + path)
    if not dry_run:
        forget(state)
    return 0


def version(package):
    try:
        with open(package, encoding="utf-8") as handle:
            value = json.load(handle).get("version")
    except (OSError, ValueError, AttributeError):
        return 0
    if isinstance(value, str):
        print(value)
    return 0


def main(argv):
    try:
        if argv[1] == "apply":
            path, state, auth, dry_run, strict = argv[2:7]
            return apply(path, state, os.environ["ENDOR_VSCODE_POLICY_URL"], auth, dry_run == "1", strict == "1")
        if argv[1] == "remove":
            path, state, dry_run, strict = argv[2:6]
            return remove(path, state, dry_run == "1", strict == "1")
        if argv[1] == "version":
            return version(argv[2])
    except OSError as error:
        warn(str(error))
        return 1
    warn("unknown policy command")
    return 2


sys.exit(main(sys.argv))
ENDOR_VSCODE_POLICY_PY
if [[ "$_vscode_remove_scope" != "patch" ]]; then
  _vscode_policy_file="${ENDOR_VSCODE_POLICY_FILE:-/etc/vscode/policy.json}"
  _vscode_policy_state="${ENDOR_VSCODE_POLICY_STATE_DIR:-/var/lib/endor/vscode-policy}"
  if [[ -z "${ENDOR_VSCODE_POLICY_FILE:-}" && "$_vscode_remove_os" == "Darwin" ]]; then
    # On macOS the policy comes from a configuration profile, which only the MDM can remove.
    # ENDOR_VSCODE_MANAGED_PREFS is for tests, as in the installer.
    _vscode_managed="${ENDOR_VSCODE_MANAGED_PREFS:-/Library/Managed Preferences}"
    _vscode_profile_left=""
    for _vscode_file in "$_vscode_managed/com.microsoft.VSCode.plist" "$_vscode_managed"/*/com.microsoft.VSCode.plist; do
      [[ -f "$_vscode_file" ]] || continue
      case "$(/usr/bin/plutil -extract ExtensionGalleryServiceUrl raw -o - "$_vscode_file" 2>/dev/null || true)" in
        */firewall/vscode/_ak/*) _vscode_profile_left="$_vscode_file"; break ;;
      esac
    done
    if [[ -n "$_vscode_profile_left" ]]; then
      echo "[endor-remove] WARNING: a configuration profile sets VS Code's ExtensionGalleryServiceUrl ($_vscode_profile_left)." >&2
      echo "[endor-remove]   Remove the profile in your MDM; this script can't." >&2
      _ENDOR_WARNED=1
    else
      echo "[endor-remove] skip (no VS Code configuration profile)"
    fi
  elif [[ -z "${ENDOR_VSCODE_POLICY_FILE:-}" && "$_vscode_remove_os" != "Linux" ]]; then
    :
  elif [[ ! -e "$_vscode_policy_file" && ! -e "$_vscode_policy_state" ]]; then
    echo "[endor-remove] skip (no VS Code policy file)"
  elif ! command -v python3 >/dev/null 2>&1; then
    echo "[endor-remove] WARNING: python3 is required to remove VS Code's policy from $_vscode_policy_file." >&2
    _ENDOR_WARNED=1
  else
    _vscode_strict=1
    [[ -z "${ENDOR_VSCODE_POLICY_FILE:-}" ]] || _vscode_strict=0
    if ! python3 -I -c "$_VSCODE_POLICY_PY" remove "$_vscode_policy_file" "$_vscode_policy_state" \
        "${DRY_RUN:-0}" "$_vscode_strict"; then
      echo "[endor-remove] WARNING: VS Code's policy was not removed from $_vscode_policy_file." >&2
      _ENDOR_WARNED=1
    fi
  fi
fi
unset -f _vscode_run_worker
unset _vscode_remove_os _VSCODE_STATE_DIR _vscode_plist _vscode_restore_ok _vscode_remove_scope
unset _VSCODE_POLICY_PY _vscode_policy_file _vscode_policy_state _vscode_strict
unset _vscode_managed _vscode_profile_left _vscode_file
# <<< endor-vscode-remove

echo ""
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "[endor-remove] ✓ Dry run complete — no files modified."
else
  echo "[endor-remove] ✓ Removal complete."
  echo "[endor-remove]   Package managers will fall back to their default registries."
  echo "[endor-remove]   Open a new terminal for shell profile changes to take effect."
fi

if [[ "${_ENDOR_WARNED:-0}" -eq 1 ]]; then
  exit 1
fi
