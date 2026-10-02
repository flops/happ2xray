#!/bin/sh
#
# Installs happ2xray: installs its opkg dependencies (where opkg is
# available, e.g. Keenetic/Entware), downloads happ_routing_to_xray.sh /
# happ_watch.sh / .env.example into INSTALL_DIR, and creates .env from the
# example if one doesn't already exist. Written in POSIX sh (no bashisms)
# so it runs under a bare BusyBox ash shell before bash itself is installed.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/flops/happ2xray/main/install.sh | sh
#   INSTALL_DIR=/opt/etc/happ2xray sh install.sh

set -eu

INSTALL_DIR="${INSTALL_DIR:-/opt/etc/happ2xray}"
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/flops/happ2xray/main}"

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }

if command -v opkg >/dev/null 2>&1; then
    echo "Installing dependencies via opkg..."
    opkg update || echo "warning: opkg update failed, continuing with whatever is cached" >&2
    for pkg in bash jq curl; do
        opkg install "$pkg" || echo "warning: opkg install $pkg failed (may already be installed)" >&2
    done
    echo "Note: happ_watch.sh -watch also needs a cron daemon (crond); install your router's cron package if you don't already have one running."
else
    echo "warning: opkg not found, skipping package install -- make sure bash, jq, curl and base64 are available." >&2
fi

mkdir -p "$INSTALL_DIR"

for f in happ_routing_to_xray.sh happ_watch.sh up.sh down.sh .env.example README.md; do
    echo "Downloading $f..."
    curl -fsSL "$REPO_RAW_BASE/$f" -o "$INSTALL_DIR/$f"
done

chmod +x "$INSTALL_DIR/happ_routing_to_xray.sh" "$INSTALL_DIR/happ_watch.sh" "$INSTALL_DIR/up.sh" "$INSTALL_DIR/down.sh"

if [ ! -f "$INSTALL_DIR/.env" ]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    echo "Created $INSTALL_DIR/.env from the example -- edit it and set XRAY_SUBSCRIPTION_URL."
else
    echo "$INSTALL_DIR/.env already exists, leaving it as-is."
fi

cat <<EOF

Installed to $INSTALL_DIR.

Next steps:
  1. Edit $INSTALL_DIR/.env (at least XRAY_SUBSCRIPTION_URL, and XRAY_DIR_PATH
     if your Xray install isn't at /opt/etc/xray).
  2. bash $INSTALL_DIR/happ_routing_to_xray.sh
  3. bash $INSTALL_DIR/happ_watch.sh -watch
EOF
