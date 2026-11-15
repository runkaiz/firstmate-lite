#!/usr/bin/env bash
set -eu
bin/fm-lock.sh
while [ ! -e "$FM_HOME/ready" ]; do sleep 1; done
bin/fm-afk-contract.sh enter --words 'strange, I did not touch ssh or the desktop this time'
FM_POLL=1 FM_SUPERVISION_HOST_PRIMARY=claude FM_SUPERVISION_HOST_PARK_SECONDS=600 FM_SUPERVISION_HOST_TURN_TIMEOUT=420 bin/fm-supervision-host.sh park
