# templates/ruby.sh
# Ruby ecosystem — Bundler (bundle install · add · update · lock) and the gem CLI
# (gem install · update · fetch)
#
# Bundler — ~/.bundle/config, Bundler's global config, read by every Ruby on the
# machine (system, rbenv, rvm, asdf). Block content: shared/blocks/bundleconfig.txt.
# Mechanism: a Bundler *mirror*. `mirror.https://rubygems.org/` sends every
# request a Gemfile makes to rubygems.org to the firewall instead, so Gemfile
# and Gemfile.lock stay untouched (the lock keeps `remote: https://rubygems.org/`)
# and private `source "…" do` blocks are not redirected. The bare-host key
# `mirror.rubygems.org` also catches http:// spellings. Credentials are NOT in
# this file: Bundler reads any BUNDLE_* environment variable as a setting, so
# env.sh exports BUNDLE_<FIREWALL_HOST>="user:password" (written by the env.sh
# step) and Bundler applies it to every request to that host. Same model as
# npm / maven / nuget — and the same limit: only processes that source env.sh get it.
#
# gem — ~/.gemrc, read by every Ruby. Block content: shared/blocks/gemrc.txt.
# gem queries EVERY url in :sources:, so the user's sources are replaced by the
# firewall (the file is backed up verbatim to ~/.gemrc.endor-bak and restored on
# removal). The credential is literal in the source url: gemrc has no env var
# expansion and RubyGems has no other credential channel for downloads (same as
# pip). Apple's Ruby installs with `sudo gem install` and sudo may reset HOME,
# so root gets the same file.

echo ""
echo "[endor-ruby] ── Ruby / Bundler ───────────────────────────────────────────────"

BUNDLE_CONFIG="$USER_HOME/.bundle/config"

# A pre-existing rubygems.org mirror or mirror.all means the machine already
# routes through a registry — warn the admin (our keys still go in last).
warn_if_bundle_mirror_conflict "$BUNDLE_CONFIG" "{{GEM_MIRROR_URL}}"

upsert_bundle_config "$BUNDLE_CONFIG" "$BUNDLE_BLOCK" "$CONSOLE_USER" "$USER_GROUP"

echo "[endor-ruby] bundle config   → $BUNDLE_CONFIG"
echo "[endor-ruby]    mirror: https://rubygems.org → {{GEM_MIRROR_URL}}"
echo "[endor-ruby]   covers: bundler (every Ruby version)"
echo "[endor-ruby]   credentials: via env.sh (BUNDLE_{{BUNDLE_HOST_KEY}})"

echo ""
echo "[endor-ruby] ── Ruby / gem ───────────────────────────────────────────────────"

# The attributed source url is filled at install time (literal credentials, like pip).
GEMRC_BLOCK=${GEMRC_BLOCK//'{{GEM_SOURCE_URL}}'/"$ENDOR_GEM_SOURCE_URL"}

GEMRC="$USER_HOME/.gemrc"
GEMRC_XDG="$USER_HOME/.config/gem/gemrc"

# Command defaults that add sources (gem: --source …) bypass :sources:; check the
# user files and each Ruby's system-wide gemrc (never edited, only reported).
warn_if_gemrc_source_override "$GEMRC" "$GEMRC_XDG"
for _gem_bin in /usr/bin/gem /opt/homebrew/bin/gem /usr/local/bin/gem; do
  [[ -x "$_gem_bin" ]] || continue
  _gem_sysdir=$("$_gem_bin" env 2>/dev/null | sed -n 's/.*SYSTEM CONFIGURATION DIRECTORY: //p' || true)
  if [[ -n "$_gem_sysdir" ]]; then warn_if_gemrc_source_override "$_gem_sysdir/gemrc"; fi
done
unset _gem_bin _gem_sysdir

upsert_gemrc "$GEMRC" "$GEMRC_XDG" "$GEMRC_BLOCK" "{{GEM_MIRROR_URL}}" "$CONSOLE_USER" "$USER_GROUP"

# root's copy covers `sudo gem install` (Apple's Ruby) when sudo resets HOME, and sudo -H / -i.
if [[ "$EUID" -eq 0 ]]; then
  _ROOT_HOME=$(resolve_user_home root)
  upsert_gemrc "$_ROOT_HOME/.gemrc" "" "$GEMRC_BLOCK" "{{GEM_MIRROR_URL}}" root "$(id -gn root)"
  unset _ROOT_HOME
else
  echo "[endor-ruby]   root's .gemrc skipped (not running as root) — sudo gem install may bypass the firewall"
fi

echo "[endor-ruby] gemrc           → $GEMRC"
echo "[endor-ruby]    source: {{GEM_MIRROR_URL}} (the only source; credentials literal in the url)"
echo "[endor-ruby]   covers: gem install / update / fetch (every Ruby version)"
echo "[endor-ruby]   NOTE: open a new terminal (or run 'source ~/.zshrc') for Bundler's env vars to take effect."
echo "[endor-ruby] ✓ Ruby done"
