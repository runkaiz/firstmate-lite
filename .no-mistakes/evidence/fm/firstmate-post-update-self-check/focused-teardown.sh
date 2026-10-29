#!/usr/bin/env bash
set -u
export TMPDIR="$PWD/.test-phase-tmp"
# Select existing top-level cases without changing their fixture or assertions.
shopt -s extdebug
trap 'case "$BASH_COMMAND" in test_*) trap - DEBUG; return 0 ;; esac' DEBUG
source tests/fm-teardown.test.sh
shopt -u extdebug
test_herdr_interrupted_cleanup_preserves_owner_across_replay
test_local_only_truly_unpushed_refuses
