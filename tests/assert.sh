#!/usr/bin/env bash
#
# Minimal assertion helpers for the test suite. No framework dependency --
# consistent with the rest of this project (pure bash + jq).
# Expects TESTS_RUN/TESTS_FAILED to already be declared by the caller.

# assert_json_eq ACTUAL EXPECTED DESC -- compares two JSON values structurally
# (key order and whitespace don't matter).
assert_json_eq() {
    local actual="$1" expected="$2" desc="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    local a e
    a="$(jq -Sc . 2>/dev/null <<<"$actual")" || a="<invalid JSON: $actual>"
    e="$(jq -Sc . 2>/dev/null <<<"$expected")" || e="<invalid JSON: $expected>"
    if [[ "$a" == "$e" ]]; then
        echo "ok - $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "NOT OK - $desc"
        echo "    expected: $e"
        echo "    actual:   $a"
    fi
}

# assert_eq ACTUAL EXPECTED DESC -- plain string comparison.
assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$actual" == "$expected" ]]; then
        echo "ok - $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "NOT OK - $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
    fi
}

# assert_contains HAYSTACK NEEDLE DESC -- substring match.
assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "ok - $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "NOT OK - $desc"
        echo "    expected to contain: $needle"
        echo "    actual:              $haystack"
    fi
}

# assert_jq JSON FILTER DESC -- asserts a jq boolean filter is true against JSON.
assert_jq() {
    local json="$1" filter="$2" desc="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if jq -e "$filter" >/dev/null 2>&1 <<<"$json"; then
        echo "ok - $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "NOT OK - $desc"
        echo "    filter: $filter"
        echo "    json:   $json"
    fi
}
