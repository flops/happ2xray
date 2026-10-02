#!/bin/sh
#
# Installs happ2xray: installs its opkg dependencies (where opkg is
# available, e.g. Keenetic/Entware), downloads happ_routing_to_xray.sh /
# happ_watch.sh / .env.example into INSTALL_DIR, creates .env from the
# example if one doesn't already exist, and installs a thin "happ_watch"
# command wrapper into BIN_DIR (same idea as /opt/sbin/xkeen) so
# happ_watch.sh can be run as a plain command. Written in POSIX sh (no
# bashisms) so it runs under a bare BusyBox ash shell before bash itself
# is installed.
#
# Usage (curl):
#   curl -fsSL https://raw.githubusercontent.com/flops/happ2xray/main/install.sh | sh
# Usage (wget, if curl isn't available):
#   wget -qO- https://raw.githubusercontent.com/flops/happ2xray/main/install.sh | sh
# Either way:
#   INSTALL_DIR=/opt/etc/happ2xray BIN_DIR=/opt/sbin BIN_NAME=happ_watch sh install.sh

set -eu

INSTALL_DIR="${INSTALL_DIR:-/opt/etc/happ2xray}"
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/flops/happ2xray/main}"
BIN_DIR="${BIN_DIR:-/opt/sbin}"
BIN_NAME="${BIN_NAME:-happ_watch}"

# Use whichever of curl/wget is actually available to fetch this script's
# own files -- some minimal/Entware setups ship one but not the other.
if command -v curl >/dev/null 2>&1; then
    DOWNLOADER=curl
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER=wget
else
    echo "error: curl or wget is required" >&2
    exit 1
fi

fetch() {
    # fetch URL DEST
    if [ "$DOWNLOADER" = "curl" ]; then
        curl -fsSL "$1" -o "$2"
    else
        wget -q -O "$2" "$1"
    fi
}

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
    fetch "$REPO_RAW_BASE/$f" "$INSTALL_DIR/$f"
done

chmod +x "$INSTALL_DIR/happ_routing_to_xray.sh" "$INSTALL_DIR/happ_watch.sh" "$INSTALL_DIR/up.sh" "$INSTALL_DIR/down.sh"

if [ ! -f "$INSTALL_DIR/.env" ]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    echo "Created $INSTALL_DIR/.env from the example -- edit it and set XRAY_SUBSCRIPTION_URL."
else
    echo "$INSTALL_DIR/.env already exists, leaving it as-is."
fi

# A thin wrapper command (same idea as /opt/sbin/xkeen) so happ_watch.sh can
# be run as a plain command instead of `bash /opt/etc/happ2xray/happ_watch.sh`.
# The actual INSTALL_DIR path is baked in here, not re-derived at runtime.
if mkdir -p "$BIN_DIR" 2>/dev/null; then
    cat >"$BIN_DIR/$BIN_NAME" <<EOF2
#!/bin/sh
exec bash "$INSTALL_DIR/happ_watch.sh" "\$@"
EOF2
    chmod +x "$BIN_DIR/$BIN_NAME"
    echo "Installed $BIN_DIR/$BIN_NAME (run '$BIN_NAME -watch', '$BIN_NAME -update', etc.)"
else
    echo "warning: could not create $BIN_DIR, skipping the $BIN_NAME command wrapper -- use bash $INSTALL_DIR/happ_watch.sh directly" >&2
fi

cat <<EOF

Installed to $INSTALL_DIR.

Next steps:
  1. Edit $INSTALL_DIR/.env (at least XRAY_SUBSCRIPTION_URL, and XRAY_DIR_PATH
     if your Xray install isn't at /opt/etc/xray).
  2. bash $INSTALL_DIR/happ_routing_to_xray.sh
  3. $BIN_NAME -watch
EOF
