#!/usr/bin/env bash
# Tests for generate_hwid: deterministic (device-derived, not random) and
# always fits Remnawave's required x-hwid format.

hwid1="$(generate_hwid)"
hwid2="$(generate_hwid)"
assert_eq "$hwid1" "$hwid2" \
    "generate_hwid: same device -> same value across calls (not random each time)"

assert_jq "$(jq -n --arg h "$hwid1" '$h')" '. | test("^[a-zA-Z0-9=-]{10,64}$")' \
    "generate_hwid: output matches Remnawave's required x-hwid format"

# Falls back to /dev/urandom (still format-valid) when no hash tool is on
# PATH -- isolate PATH to a dir with symlinks for only the non-hash tools
# generate_hwid needs, so sha256sum/md5sum genuinely aren't found rather
# than just assuming this machine lacks them.
fake_bin="$(mktemp -d)"
for bin in bash hostname uname head od tr cat; do
    p="$(command -v "$bin" 2>/dev/null)"
    [[ -n "$p" ]] && ln -sf "$p" "$fake_bin/$bin"
done
hwid_no_hash="$(PATH="$fake_bin" bash -c "$(declare -f generate_hwid); generate_hwid" 2>/dev/null)"
rm -rf "$fake_bin"

assert_jq "$(jq -n --arg h "$hwid_no_hash" '$h')" '. | test("^[a-zA-Z0-9=-]{10,64}$")' \
    "generate_hwid: falls back to a format-valid id when no hash tool is available"
