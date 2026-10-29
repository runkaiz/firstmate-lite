#!/usr/bin/env bash
set -u
export TMPDIR="$PWD/.test-phase-tmp"
shopt -s extdebug
trap 'case "$BASH_COMMAND" in test_*) trap - DEBUG; return 0 ;; esac' DEBUG
source tests/fm-pr-check-security.test.sh
shopt -u extdebug
fail() {
  printf 'not ok - %s\n' "$1" >&2
  cp -R "$TMP_ROOT/merged-retirement-once" /home/runkai/.no-mistakes/evidence/01M62N2AYVWBQFB4KXEE7WECX5/pr-failure-state
  exit 1
}
for attempt in 1 2 3; do
  printf 'Watcher retirement repeat %s\n' "$attempt"
  test_merged_poll_retires_once
  rm -rf "$TMP_ROOT/merged-retirement-once"
done
