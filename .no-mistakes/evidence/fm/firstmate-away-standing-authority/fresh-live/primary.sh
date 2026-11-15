#!/usr/bin/env bash
set -eu
rtk bin/fm-lock.sh
while [ ! -e "$FM_HOME/ready" ]; do rtk sleep 1; done
rtk bin/fm-afk-contract.sh enter --words 'strange, I did not touch ssh or the desktop this time'
FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_SUPERVISION_HOST_PRIMARY=claude FM_SUPERVISION_HOST_PARK_SECONDS=2400 FM_SUPERVISION_HOST_TURN_TIMEOUT=600 rtk bin/fm-supervision-host.sh park
