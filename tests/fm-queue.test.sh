#!/usr/bin/env bash
# Native storage acceptance through the shipped executable, using synthetic homes.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FM_QUEUE_TEST_ROOT=$(fm_test_tmproot fm-queue-native)
export FM_QUEUE_TEST_ROOT
python3 "$ROOT/tests/fm-queue.test.py"
