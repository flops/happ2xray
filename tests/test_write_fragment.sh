#!/usr/bin/env bash
# Tests for write_fragment: fresh write vs. merging when multiple fragments
# target the same path within one run.

tmp_dir="$(mktemp -d)"

out_a="$tmp_dir/a.json"
write_fragment "$out_a" '{"dns": {"servers": ["1.1.1.1"]}}'
assert_json_eq "$(cat "$out_a")" '{"dns": {"servers": ["1.1.1.1"]}}' \
    "write_fragment: first write to a fresh path writes it verbatim"

out_b="$tmp_dir/shared.json"
write_fragment "$out_b" '{"dns": {"servers": ["1.1.1.1"]}}'
write_fragment "$out_b" '{"routing": {"domainStrategy": "AsIs"}}'
assert_json_eq "$(cat "$out_b")" '{"dns": {"servers": ["1.1.1.1"]}, "routing": {"domainStrategy": "AsIs"}}' \
    "write_fragment: second write to the same path merges instead of clobbering the first"

out_c="$tmp_dir/shared3.json"
write_fragment "$out_c" '{"dns": {"a": 1}}'
write_fragment "$out_c" '{"outbounds": [1, 2]}'
write_fragment "$out_c" '{"routing": {"b": 2}}'
assert_json_eq "$(cat "$out_c")" '{"dns": {"a": 1}, "outbounds": [1, 2], "routing": {"b": 2}}' \
    "write_fragment: three merges in a row all accumulate into one object"

# Two independent paths each get their own fresh write, no cross-contamination.
out_d1="$tmp_dir/d1.json"
out_d2="$tmp_dir/d2.json"
write_fragment "$out_d1" '{"dns": {}}'
write_fragment "$out_d2" '{"routing": {}}'
assert_json_eq "$(cat "$out_d1")" '{"dns": {}}' \
    "write_fragment: distinct paths don't merge with each other"
assert_json_eq "$(cat "$out_d2")" '{"routing": {}}' \
    "write_fragment: distinct paths don't merge with each other (second path)"

rm -rf "$tmp_dir"
