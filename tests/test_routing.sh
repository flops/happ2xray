#!/usr/bin/env bash
# Tests for build_routes_json: RouteOrder sequencing, the GlobalProxy
# catch-all, and the configurable balancer tag.

OUTBOUNDS='[{"tag": "srv1"}]'

HAPP_DEFAULT_ORDER='{
    "DirectSites": ["domain:direct.example"],
    "ProxySites": ["domain:proxy.example"],
    "BlockSites": ["domain:block.example"]
}'
out="$(build_routes_json "$HAPP_DEFAULT_ORDER" "$OUTBOUNDS" "leastPing" "proxy")"
assert_json_eq "$(jq '[.rules[] | (.outboundTag // .balancerTag)]' <<<"$out")" \
    '["direct", "proxy", "block", "direct"]' \
    "build_routes_json: default RouteOrder (direct-proxy-block) with a trailing direct catch-all"

HAPP_CUSTOM_ORDER='{
    "RouteOrder": "block-proxy-direct",
    "DirectSites": ["domain:direct.example"],
    "ProxySites": ["domain:proxy.example"],
    "BlockSites": ["domain:block.example"]
}'
out="$(build_routes_json "$HAPP_CUSTOM_ORDER" "$OUTBOUNDS" "leastPing" "proxy")"
assert_json_eq "$(jq '[.rules[].domain[0]?] | map(select(. != null))' <<<"$out")" \
    '["domain:block.example", "domain:proxy.example", "domain:direct.example"]' \
    "build_routes_json: custom RouteOrder reorders the domain-rule blocks accordingly"

HAPP_GLOBAL_PROXY='{"GlobalProxy": "true", "DirectSites": ["domain:direct.example"]}'
out="$(build_routes_json "$HAPP_GLOBAL_PROXY" "$OUTBOUNDS" "leastPing" "proxy")"
assert_json_eq "$(jq '.rules[-1]' <<<"$out")" \
    '{"type": "field", "port": "0-65535", "balancerTag": "proxy"}' \
    "build_routes_json: GlobalProxy=true makes the catch-all a balancerTag"
assert_json_eq "$(jq '.rules[0]' <<<"$out")" \
    '{"type": "field", "domain": ["domain:direct.example"], "outboundTag": "direct"}' \
    "build_routes_json: explicit DirectSites still outrank the GlobalProxy catch-all"

HAPP_NO_GLOBAL_PROXY='{}'
out="$(build_routes_json "$HAPP_NO_GLOBAL_PROXY" "$OUTBOUNDS" "leastPing" "proxy")"
assert_json_eq "$(jq '.rules[-1]' <<<"$out")" \
    '{"type": "field", "port": "0-65535", "outboundTag": "direct"}' \
    "build_routes_json: GlobalProxy absent defaults the catch-all to outboundTag direct"

out="$(build_routes_json "$HAPP_NO_GLOBAL_PROXY" "$OUTBOUNDS" "random" "warp")"
assert_json_eq "$(jq '.balancers' <<<"$out")" \
    '[{"tag": "warp", "selector": ["srv1"], "strategy": {"type": "random"}}]' \
    "build_routes_json: custom balancer tag and strategy both flow through"

HAPP_PROXY_RULE='{"ProxySites": ["domain:proxy.example"]}'
out="$(build_routes_json "$HAPP_PROXY_RULE" "$OUTBOUNDS" "leastPing" "warp")"
assert_json_eq "$(jq '.rules[] | select(.domain == ["domain:proxy.example"])' <<<"$out")" \
    '{"type": "field", "domain": ["domain:proxy.example"], "balancerTag": "warp"}' \
    "build_routes_json: proxy-kind rules use balancerTag with the custom tag, not outboundTag"
