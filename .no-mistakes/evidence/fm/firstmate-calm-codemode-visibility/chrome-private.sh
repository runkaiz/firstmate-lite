#!/usr/bin/env bash
profile=$(mktemp -d /tmp/fm-calm-browser.XXXXXX)
trap 'rm -rf "$profile"' EXIT
TMPDIR=/tmp HOME="$profile" XDG_CONFIG_HOME="$profile/.config" XDG_CACHE_HOME="$profile/.cache" /var/home/runkai/.cache/ms-playwright/chromium-1243/chrome-linux64/chrome "$@"
