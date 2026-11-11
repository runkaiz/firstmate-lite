#!/usr/bin/env bash
# Usage: fm-start.sh <agent> [agent arguments...]
# Launch from the current Firstmate home (or explicit FM_HOME). Keep the
# harness's working directory, project trust and history scoped to that home.
set -eu

if [ "$#" -eq 0 ] || [ "$1" = --help ] || [ "$1" = -h ]; then
  printf 'usage: fm-start.sh <agent> [agent arguments...]\n'
  [ "$#" -gt 0 ]
  exit
fi

code=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CDPATH='' cd -- "${FM_HOME:-.}"
FM_HOME=$(pwd -P)
if [ ! "$FM_HOME/bin" -ef "$code/bin" ] || [ ! "$FM_HOME/AGENTS.md" -ef "$code/AGENTS.md" ]; then
  printf 'fm-start: %s is not a home linked to %s\n' "$FM_HOME" "$code" >&2
  exit 1
fi
export FM_HOME FM_ROOT_OVERRIDE="$code"
exec -- "$@"
