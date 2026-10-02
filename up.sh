#!/usr/bin/env bash
#
# Restarts xkeen. Called by happ_watch.sh after deploying changed config
# files, but also safe to run standalone.
#
# To change this behavior (different command, extra steps, disable it
# entirely, etc.), just edit this file directly.
#
# Usage: ./up.sh

set -euo pipefail

if command -v xkeen >/dev/null 2>&1; then
    echo "Restarting xkeen..."
    xkeen -restart
else
    echo "warning: xkeen command not found, skipping restart" >&2
fi
