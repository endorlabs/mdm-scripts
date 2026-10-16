# templates/ruby.sh
# Ruby ecosystem — Bundler (bundle install · add · update · lock)
#
# Config file: ~/.bundle/config — Bundler's global config, read by every Ruby on
# the machine (system, rbenv, rvm, asdf). Block content comes from
# shared/blocks/bundleconfig.txt.
#
# Mechanism: a Bundler *mirror*. `mirror.https://rubygems.org/` sends every
# request a Gemfile makes to rubygems.org to the firewall instead, so Gemfile
# and Gemfile.lock stay untouched (the lock keeps `remote: https://rubygems.org/`)
# and private `source "…" do` blocks are not redirected. The bare-host key
# `mirror.rubygems.org` also catches http:// spellings.
#
# Credentials are NOT in this file: Bundler reads any BUNDLE_* environment
# variable as a setting, so env.sh exports BUNDLE_<FIREWALL_HOST>="user:password"
# (written by the env.sh step) and Bundler applies it to every request to that
# host, whichever project sends it. Same model as npm / maven / nuget — and the
# same limit: only processes that source env.sh (terminals) get it.
# `gem install` does not read Bundler config — it is not covered here.

echo ""
echo "[endor-ruby] ── Ruby / Bundler ───────────────────────────────────────────────"

BUNDLE_CONFIG="$USER_HOME/.bundle/config"

# A pre-existing rubygems.org mirror or mirror.all means the machine already
# routes through a registry — warn the admin (our keys still go in last).
warn_if_bundle_mirror_conflict "$BUNDLE_CONFIG" "{{GEM_MIRROR_URL}}"

upsert_bundle_config "$BUNDLE_CONFIG" "$BUNDLE_BLOCK" "$CONSOLE_USER" "$USER_GROUP"

echo "[endor-ruby] bundle config   → $BUNDLE_CONFIG"
echo "[endor-ruby]    mirror: https://rubygems.org → {{GEM_MIRROR_URL}}"
echo "[endor-ruby]   covers: bundler (every Ruby version); gem CLI not covered"
echo "[endor-ruby]   credentials: via env.sh (BUNDLE_{{BUNDLE_HOST_KEY}})"
echo "[endor-ruby]   NOTE: open a new terminal (or run 'source ~/.zshrc') for env vars to take effect."
echo "[endor-ruby] ✓ Ruby done"
