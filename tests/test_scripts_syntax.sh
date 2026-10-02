#!/usr/bin/env bash
# Cheap smoke test: every shipped script must at least parse cleanly.

for f in happ_routing_to_xray.sh happ_watch.sh up.sh down.sh; do
    TESTS_RUN=$((TESTS_RUN + 1))
    if bash -n "$PROJECT_DIR/$f" 2>/tmp/happ2xray_syntax_err; then
        echo "ok - $f parses cleanly (bash -n)"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "NOT OK - $f failed bash -n"
        sed 's/^/    /' /tmp/happ2xray_syntax_err
    fi
done
rm -f /tmp/happ2xray_syntax_err

TESTS_RUN=$((TESTS_RUN + 1))
if sh -n "$PROJECT_DIR/install.sh" 2>/tmp/happ2xray_syntax_err; then
    echo "ok - install.sh parses cleanly (sh -n)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "NOT OK - install.sh failed sh -n"
    sed 's/^/    /' /tmp/happ2xray_syntax_err
fi
rm -f /tmp/happ2xray_syntax_err
