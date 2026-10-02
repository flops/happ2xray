#!/usr/bin/env bash
#
# Test runner. Sources happ_routing_to_xray.sh for its functions (the
# BASH_SOURCE==0 guard in that file means sourcing it never fetches
# anything or touches the filesystem), then sources every tests/test_*.sh
# file and runs it. Exits non-zero if any assertion failed.
#
# Usage: bash tests/run.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"

# shellcheck source=assert.sh
source "$TESTS_DIR/assert.sh"
# shellcheck source=../happ_routing_to_xray.sh
source "$PROJECT_DIR/happ_routing_to_xray.sh"

# The script above sets -euo pipefail on itself; relax that for the runner
# so a failing assertion doesn't abort the whole suite -- each test file
# controls its own pass/fail bookkeeping via TESTS_RUN/TESTS_FAILED instead.
set +e +u

TESTS_RUN=0
TESTS_FAILED=0

for test_file in "$TESTS_DIR"/test_*.sh; do
    echo "--- $(basename "$test_file") ---"
    # shellcheck disable=SC1090
    source "$test_file"
done

echo
echo "$TESTS_RUN tests, $TESTS_FAILED failed"
exit $(( TESTS_FAILED > 0 ? 1 : 0 ))
