#!/usr/bin/env bash
# Direct tests for build_stream_settings transport types not already
# exercised via the outbound-link fixtures (grpc, tcp+http header).

declare -A q=()
q[type]="grpc"
q[path]="/myservice"
out="$(build_stream_settings q "fallback.example")"
assert_json_eq "$out" '{"network": "grpc", "grpcSettings": {"serviceName": "myservice"}}' \
    "build_stream_settings: grpc uses path (leading slash stripped) as serviceName"

declare -A q2=()
q2[type]="tcp"
q2[headerType]="http"
q2[path]="/masked"
q2[host]="masked.example"
out="$(build_stream_settings q2 "fallback.example")"
assert_json_eq "$out" '{
    "network": "tcp",
    "tcpSettings": {"header": {"type": "http", "request": {"path": ["/masked"], "headers": {"Host": ["masked.example"]}}}}
}' "build_stream_settings: tcp+headerType=http produces an HTTP-masquerade header"

declare -A q3=()
out="$(build_stream_settings q3 "fallback.example")"
assert_json_eq "$out" '{"network": "tcp"}' \
    "build_stream_settings: no params at all defaults to plain tcp, no security"
