#!/usr/bin/env bash
# Tests for build_dns_json / build_fakedns_json.

HAPP_SPLIT_DNS='{
    "DomesticDNSDomain": "https://doh.domestic.example/dns-query",
    "DomesticDNSIP": "198.51.100.53",
    "RemoteDNSDomain": "https://doh.remote.example/dns-query",
    "RemoteDNSIP": "203.0.113.53",
    "DirectSites": ["domain:direct1.example", "domain:direct2.example"],
    "FakeDNS": "false"
}'
out="$(build_dns_json "$HAPP_SPLIT_DNS")"
assert_json_eq "$out" '{
    "hosts": {},
    "servers": [
        {"address": "https://doh.domestic.example/dns-query", "domains": ["domain:direct1.example", "domain:direct2.example"], "skipFallback": true},
        "https://doh.remote.example/dns-query"
    ]
}' "build_dns_json: DirectSites scoped to domestic server, remote as default fallback"

out="$(build_fakedns_json "$HAPP_SPLIT_DNS")"
assert_json_eq "$out" '[]' "build_fakedns_json: empty array when FakeDNS is false"

HAPP_NO_DIRECT='{
    "DomesticDNSDomain": "https://domestic/dns-query",
    "RemoteDNSDomain": "https://remote/dns-query",
    "FakeDNS": "false"
}'
out="$(build_dns_json "$HAPP_NO_DIRECT")"
assert_json_eq "$out" '{"hosts": {}, "servers": ["https://remote/dns-query"]}' \
    "build_dns_json: no scoped entry at all when DirectSites is absent/empty"

HAPP_FAKEDNS='{
    "DomesticDNSDomain": "https://domestic/dns-query",
    "RemoteDNSDomain": "https://remote/dns-query",
    "DirectSites": ["domain:direct.example"],
    "FakeDNS": "true"
}'
out="$(build_dns_json "$HAPP_FAKEDNS")"
assert_json_eq "$out" '{
    "hosts": {},
    "servers": [
        "fakedns",
        {"address": "https://domestic/dns-query", "domains": ["domain:direct.example"], "skipFallback": true},
        "https://remote/dns-query"
    ]
}' "build_dns_json: FakeDNS true prepends \"fakedns\", domestic scoped entry still present"

out="$(build_fakedns_json "$HAPP_FAKEDNS")"
assert_jq "$out" '(length == 2) and (.[0].ipPool == "198.18.0.0/15") and (.[1].ipPool == "fc00::/18")' \
    "build_fakedns_json: emits the standard v4+v6 pools when FakeDNS is true"

HAPP_DNSHOSTS='{"DnsHosts": {"example.com": "1.2.3.4"}, "RemoteDNSIP": "9.9.9.9", "FakeDNS": "false"}'
out="$(build_dns_json "$HAPP_DNSHOSTS")"
assert_json_eq "$out" '{"hosts": {"example.com": "1.2.3.4"}, "servers": ["9.9.9.9"]}' \
    "build_dns_json: DnsHosts passes through verbatim, falls back to plain IP when *Domain is empty"
