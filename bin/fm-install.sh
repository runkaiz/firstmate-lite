#!/usr/bin/env bash
# Usage: fm-install.sh [home]
# Install one shared checkout under ${XDG_DATA_HOME:-$HOME/.local/share}/firstmate
# and link the launch surfaces into a private home (default: ~/firstmate).
# Re-running initializes another home or fills in missing links in the same one.
set -eu

usage() { printf 'usage: fm-install.sh [home]\n'; }
die() { printf 'fm-install: %s\n' "$*" >&2; exit 1; }

case ${1:-} in -h|--help) usage; exit 0 ;; esac
[ "$#" -le 1 ] || die "$(usage)"

repo=https://github.com/runkaiz/firstmate-lite.git
canonical_path() { python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "$1"; }
code=$(canonical_path "${XDG_DATA_HOME:-$HOME/.local/share}/firstmate")
home=$(canonical_path "${1:-$HOME/firstmate}")
case "$home/" in "$code/"*) die "home must be outside $code" ;; esac
case "$code/" in "$home/"*) die "code must be outside $home" ;; esac
[ ! -e "$home/.git" ] && [ ! -L "$home/.git" ] ||
  die "$home is already a checkout; use it as-is or choose a separate home"

if [ -e "$code" ]; then
  [ "$(git -C "$code" rev-parse --show-toplevel 2>/dev/null)" = "$code" ] &&
    [ "$(git -C "$code" config --local --get remote.origin.url)" = "$repo" ] ||
    die "$code is not the Firstmate-lite installation"
else
  mkdir -p -- "$(dirname -- "$code")"
  git clone -- "$repo" "$code"
fi

dirs=(data state config projects .agents .claude .codex .pi)
# Claude treats an @ import through the AGENTS.md symlink as external.
links=(AGENTS.md CLAUDE.md:AGENTS.md bin docs .agents/skills .claude/settings.json .claude/skills .codex/hooks.json .pi/extensions)
for dir in "${dirs[@]}"; do
  path=$home/$dir
  if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
    die "$path must be a directory"
  fi
done
for link in "${links[@]}"; do
  source=$code/${link##*:}
  path=$home/${link%%:*}
  [ -e "$source" ] || die "missing $source"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -L "$path" ] && [ "$path" -ef "$source" ] || die "would overwrite $path"
  fi
done

umask 077
for dir in "${dirs[@]}"; do
  mkdir -p -- "$home/$dir"
done
for link in "${links[@]}"; do
  path=$home/${link%%:*}
  [ -L "$path" ] || ln -sn -- "$code/${link##*:}" "$path"
done

printf 'Start in your terminal workspace with:\n  cd %q && bin/fm-start.sh claude\n' "$home"
