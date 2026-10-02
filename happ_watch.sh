#!/usr/bin/env bash
#
# Regenerate the Happ -> Xray configs/dat files into a temp dir, compare them
# against what's already deployed under XRAY_DIR_PATH, and only if something
# actually changed: run down.sh (placeholder pre-update hook), copy the new
# files over, then run up.sh (restarts xkeen).
#
# Reads the same .env (next to this script) as happ_routing_to_xray.sh for:
#   XRAY_DIR_PATH              Where configs/ and dat/ are deployed (required
#                              for this script -- that's what gets diffed
#                              against and what xkeen reads from).
#   XRAY_WATCH_INTERVAL_MINUTES  Default cron interval in minutes for -watch
#                              (default: 60).
#   XRAY_CRONTAB               Crontab file to edit (default: /opt/etc/crontabs/root).
#
# To change how xkeen gets restarted (or skip it), edit up.sh directly.
#
# Commands:
#   (none)         Check for changes; update + restart xkeen only if needed.
#                  This is what the cron job installed by -watch runs.
#   -update        Force update + restart xkeen, skipping the change check.
#   -watch [MIN]   Install a cron job running this script (no args) every
#                  MIN minutes (default: $XRAY_WATCH_INTERVAL_MINUTES or 60).
#   -stop          Remove the cron job installed by -watch.
#
# Usage: ./happ_watch.sh [-update|-watch [MIN]|-stop]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
SYNC_SCRIPT="$SCRIPT_DIR/happ_routing_to_xray.sh"
UP_SCRIPT="$SCRIPT_DIR/up.sh"
DOWN_SCRIPT="$SCRIPT_DIR/down.sh"
CRON_MARKER="# happ2xray-watch"

# Parse KEY=VALUE lines from .env directly instead of `source`-ing it, so a
# stray malformed line is just skipped instead of being executed as a shell command.
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        val="${line#*=}"
        if [[ "$val" == \"*\" && "$val" == *\" ]]; then
            val="${val:1:-1}"
        elif [[ "$val" == \'*\' && "$val" == *\' ]]; then
            val="${val:1:-1}"
        fi
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        export "$key=$val"
    done <"$SCRIPT_DIR/.env"
fi

BASE_DIR="${XRAY_DIR_PATH:-.}"
CRONTAB_FILE="${XRAY_CRONTAB:-/opt/etc/crontabs/root}"
WATCH_INTERVAL_MINUTES="${XRAY_WATCH_INTERVAL_MINUTES:-60}"

run_sync() {
    local force="$1"

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    bash "$SYNC_SCRIPT" "" \
        "$tmp_dir/configs/04_routing_happ.json" \
        "$tmp_dir/dat" \
        "$tmp_dir/configs/02_outbounds_happ.json" \
        "$tmp_dir/configs/03_observatory_happ.json" \
        "$tmp_dir/configs/01_dns_happ.json"

    local changed="$force"
    local f name

    for f in "$tmp_dir"/configs/*.json; do
        name="$(basename "$f")"
        cmp -s "$f" "$BASE_DIR/configs/$name" 2>/dev/null || changed=true
    done

    for f in "$tmp_dir"/dat/*; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f")"
        cmp -s "$f" "$BASE_DIR/dat/$name" 2>/dev/null || changed=true
    done

    if [[ "$changed" != true ]]; then
        echo "No changes detected; nothing to do."
        return 0
    fi

    echo "Changes detected, updating $BASE_DIR ..."
    bash "$DOWN_SCRIPT"
    mkdir -p "$BASE_DIR/configs" "$BASE_DIR/dat"
    cp -f "$tmp_dir"/configs/*.json "$BASE_DIR/configs/"
    cp -f "$tmp_dir"/dat/* "$BASE_DIR/dat/" 2>/dev/null || true
    bash "$UP_SCRIPT"
}

restart_cron_daemon() {
    local f started=false
    for f in /opt/etc/init.d/S*cron; do
        [[ -x "$f" ]] || continue
        "$f" restart >/dev/null 2>&1 && started=true
    done
    [[ "$started" == true ]] || killall -HUP crond 2>/dev/null || true
}

watch_action() {
    local interval="${1:-$WATCH_INTERVAL_MINUTES}"
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || (( interval < 1 )); then
        echo "error: interval must be a positive number of minutes" >&2
        exit 1
    fi

    stop_action >/dev/null

    mkdir -p "$(dirname "$CRONTAB_FILE")"
    touch "$CRONTAB_FILE"

    local bash_path
    bash_path="$(command -v bash || echo /opt/bin/bash)"

    printf '*/%s * * * * %s %s >> %s/happ_watch.log 2>&1 %s\n' \
        "$interval" "$bash_path" "$SCRIPT_PATH" "$SCRIPT_DIR" "$CRON_MARKER" >>"$CRONTAB_FILE"

    restart_cron_daemon
    echo "Scheduled: checking for subscription changes every $interval minute(s) via $CRONTAB_FILE."
}

stop_action() {
    if [[ -f "$CRONTAB_FILE" ]] && grep -qF "$CRON_MARKER" "$CRONTAB_FILE"; then
        sed -i "\\|$CRON_MARKER|d" "$CRONTAB_FILE"
        restart_cron_daemon
        echo "Removed from cron ($CRONTAB_FILE)."
    else
        echo "Not currently scheduled in cron."
    fi
}

case "${1:-}" in
    -update)
        run_sync true
        ;;
    -watch)
        watch_action "${2:-}"
        ;;
    -stop)
        stop_action
        ;;
    "")
        run_sync false
        ;;
    *)
        echo "error: unknown command '$1' (expected -update, -watch [MIN], or -stop)" >&2
        exit 1
        ;;
esac
