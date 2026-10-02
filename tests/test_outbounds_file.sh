#!/usr/bin/env bash
# Tests for build_outbounds_file_json and build_observatory_json.

OUTBOUNDS='[{"tag": "srv1", "protocol": "vless"}, {"tag": "srv2", "protocol": "shadowsocks"}]'

out="$(build_outbounds_file_json "$OUTBOUNDS")"
assert_json_eq "$out" '{"outbounds": [
    {"tag": "srv1", "protocol": "vless"},
    {"tag": "srv2", "protocol": "shadowsocks"},
    {"tag": "direct", "protocol": "freedom", "settings": {}},
    {"tag": "block", "protocol": "blackhole", "settings": {"response": {"type": "http"}}}
]}' "build_outbounds_file_json: appends direct+block after the parsed proxy outbounds"

# The original outbounds_json variable must stay untouched by the above --
# it's reused for the balancer selector/Observatory subjectSelector and must
# never pick up "direct"/"block".
assert_json_eq "$OUTBOUNDS" '[{"tag": "srv1", "protocol": "vless"}, {"tag": "srv2", "protocol": "shadowsocks"}]' \
    "build_outbounds_file_json: does not mutate its input"

out="$(build_observatory_json "$OUTBOUNDS" "https://example.com/204" "15s")"
assert_json_eq "$out" '{
    "subjectSelector": ["srv1", "srv2"],
    "probeUrl": "https://example.com/204",
    "probeInterval": "15s",
    "enableConcurrency": true
}' "build_observatory_json: subjectSelector covers only the real proxy outbounds, not direct/block"
