#!/usr/bin/env bash
#
# Fetch a Remnawave (remna.st) subscription URL, pull the Happ client's
# "routing" response header (happ://routing/onadd/<base64 json>), and
# convert the decoded DirectSites/DirectIp/ProxySites/ProxyIp/BlockSites/BlockIp
# lists into an Xray-style routing rules object.
#
# It also downloads the geoip.dat/geosite.dat files the profile points at
# (Geoipurl/Geositeurl) so the geoip:/geosite: rules it produces actually resolve,
# and parses the subscription body's proxy links (vless/vmess/trojan/ss) into
# an Xray-core "outbounds" JSON array. The routing rules that would otherwise
# point at a single "proxy" outbound instead point at a "proxy" balancer whose
# selector covers every outbound tag produced from the subscription.
#
# The "proxy" balancer uses the leastPing strategy, which picks the
# lowest-latency outbound using data from an Observatory block (written to
# OBSERVATORY_FILE) that actively probes every outbound produced above.
#
# JSON output files live under CONFIG_DIR, numbered from 01 in the order
# they must be merged (dns has no dependencies so it's first; outbounds
# before routing's balancer references them; observatory before routing's
# leastPing strategy relies on it): 01_dns_happ.json, 02_outbounds_happ.json,
# 03_observatory_happ.json, 04_routing_happ.json. `jq -s 'add' configs/[0-9]*.json`
# merges them in the right order.
#
# If two or more of DNS_FILE/OUTBOUNDS_FILE/OBSERVATORY_FILE/ROUTES_FILE are
# pointed at the very same path (via args or the XRAY_*_FILE env vars below),
# they're merged into that one file instead of the last write clobbering the
# earlier ones -- set all four to the same path to get one combined config.
#
# Any of those four, if explicitly set to an empty string (as an arg or as
# its XRAY_*_FILE env var), skips generating that file entirely rather than
# falling back to its numbered default -- an unset arg/env var still falls
# back as usual; only an explicit "" means "skip".
#
# The dns block splits resolution the same way routing does: DirectSites
# get resolved via the DomesticDNS* server (skipFallback, so it won't also
# try the remote one), everything else via the RemoteDNS* server. DnsHosts
# passes through as the static "hosts" map. If Happ's FakeDNS is "true", a
# "fakedns" entry and a matching top-level fakedns IP pool are added too
# (your own inbound(s) still need sniffing+destOverride:["fakedns"] for it
# to actually activate -- this project doesn't generate inbounds).
#
# The subscription's proxy links (vless://, vmess://, trojan://, ss://,
# hysteria2:// / hy2://) are parsed in pure bash + jq + coreutils base64
# below -- no python, no eval of remote input. Hysteria2 is emitted as
# Xray-core's protocol "hysteria" (that's its actual name in Xray); its
# obfs/obfs-password (e.g. salamander) isn't representable in Xray-core's
# hysteria transport, so a link using it still gets parsed but logs a
# warning and drops obfuscation rather than silently producing a config
# that a server mandating obfs would simply reject.
#
# Reads a .env file next to this script for:
#   XRAY_SUBSCRIPTION_URL  The subscription URL (required unless passed as $1).
#   XRAY_HWID              Optional. Pins the x-hwid header sent with every
#                          subscription request (Remnawave's "HWID device
#                          limit" feature; must match /^[a-zA-Z0-9=-]{10,64}$/).
#                          If unset, one is derived from this device
#                          (hostname/kernel/MAC, see generate_hwid) once
#                          and cached in SCRIPT_DIR/.hwid for every later run.
#   XRAY_DIR_PATH          Optional. When set (e.g. /opt/etc/xray), the JSON
#                          configs and dat files default into that Xray
#                          installation's configs/ and dat/ subdirectories
#                          instead of the current directory.
#   XRAY_BALANCER_TAG      Optional. Tag name for the balancer/outboundTag
#                          that "proxy"-kind rules route through (default: proxy).
#   XRAY_BALANCER_STRATEGY Optional. Strategy type for that balancer
#                          (default: leastPing).
#   XRAY_PROBE_URL         Optional. Observatory probeUrl used by leastPing
#                          (default: https://www.gstatic.com/generate_204).
#   XRAY_PROBE_INTERVAL    Optional. Observatory probeInterval (default: 10s).
#   XRAY_DNS_FILE          Optional. Same as the DNS_FILE arg below, as an
#                          env var fallback (default: <base>/configs/01_dns_happ.json).
#   XRAY_OUTBOUNDS_FILE    Optional. Same as OUTBOUNDS_FILE (default: <base>/configs/02_outbounds_happ.json).
#   XRAY_OBSERVATORY_FILE  Optional. Same as OBSERVATORY_FILE (default: <base>/configs/03_observatory_happ.json).
#   XRAY_ROUTING_FILE      Optional. Same as ROUTES_FILE (default: <base>/configs/04_routing_happ.json).
#
# Usage: ./happ_routing_to_xray.sh [SUB_URL] [ROUTES_FILE] [DAT_DIR] [OUTBOUNDS_FILE] [OBSERVATORY_FILE] [DNS_FILE]
#   SUB_URL           Subscription URL (default: $XRAY_SUBSCRIPTION_URL from .env)
#   ROUTES_FILE       Where to write the resulting routing JSON (default: $XRAY_ROUTING_FILE, else <base>/configs/04_routing_happ.json)
#   DAT_DIR           Directory to download geoip.dat/geosite.dat into (default: <base>/dat)
#   OUTBOUNDS_FILE    Where to write the resulting outbounds JSON (default: $XRAY_OUTBOUNDS_FILE, else <base>/configs/02_outbounds_happ.json)
#   OBSERVATORY_FILE  Where to write the observatory JSON the balancer needs (default: $XRAY_OBSERVATORY_FILE, else <base>/configs/03_observatory_happ.json)
#   DNS_FILE          Where to write the resulting dns JSON (default: $XRAY_DNS_FILE, else <base>/configs/01_dns_happ.json)
#   (<base> is $XRAY_DIR_PATH from .env if set, otherwise the current directory.
#   Any positional arg, where given, overrides its XRAY_*_FILE env var.)
#
# This file is safe to `source` (e.g. from tests): sourcing only defines the
# functions below, it does not fetch anything or touch the filesystem. The
# fetch-and-generate pipeline only runs when the file is executed directly,
# via the guard at the very bottom.

set -euo pipefail

# --- proxy link (vless/vmess/trojan/ss) -> Xray outbound JSON -------------

urldecode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

# Pad a base64 string to a multiple of 4 chars so `base64 -d` doesn't choke.
b64pad() {
    local s="$1"
    local mod=$(( ${#s} % 4 ))
    if (( mod != 0 )); then
        s+="$(printf '%*s' $((4 - mod)) '' | tr ' ' '=')"
    fi
    printf '%s' "$s"
}

b64decode() {
    printf '%s' "$(b64pad "$1")" | base64 -d 2>/dev/null || true
}

# Parse "a=1&b=2" into the caller-provided associative array (by name), without eval.
parse_query() {
    local -n _out="$1"
    local query="$2"
    _out=()
    [[ -z "$query" ]] && return 0
    local pair key val
    local IFS='&'
    for pair in $query; do
        [[ -z "$pair" ]] && continue
        key="${pair%%=*}"
        if [[ "$pair" == *=* ]]; then val="${pair#*=}"; else val=""; fi
        _out["$key"]="$(urldecode "$val")"
    done
}

# Every caller of unique_tag is reached through command substitution
# ($(parse_vless ...) etc.), which forks a subshell -- so an associative
# array mutated here would never be visible to the next call. SEEN_TAGS_FILE
# (set by parse_outbounds, inherited by the fork) is a plain file instead:
# writes to it persist across subshells since they're a filesystem side
# effect, not shell process state.
unique_tag() {
    local base="$1"
    local n=1
    if [[ -n "${SEEN_TAGS_FILE:-}" && -f "$SEEN_TAGS_FILE" ]]; then
        n=$(( $(grep -Fxc -- "$base" "$SEEN_TAGS_FILE") + 1 ))
        printf '%s\n' "$base" >>"$SEEN_TAGS_FILE"
    fi
    if (( n == 1 )); then
        printf '%s' "$base"
    else
        printf '%s (%d)' "$base" "$n"
    fi
}

# Build an Xray streamSettings object from a query-param assoc array (by name)
# plus a fallback host (the server address) used when no host/sni is given.
build_stream_settings() {
    local -n _q="$1"
    local fallback_host="$2"

    local network="${_q[type]:-${_q[net]:-tcp}}"
    [[ "$network" == "splithttp" ]] && network="xhttp"

    local path="${_q[path]:-}"
    [[ -z "$path" && -n "${_q[serviceName]:-}" ]] && path="${_q[serviceName]}"
    [[ -z "$path" ]] && path="/"

    local host="${_q[host]:-}"
    [[ -z "$host" ]] && host="${_q[sni]:-$fallback_host}"

    local mode="${_q[mode]:-auto}"
    local headertype="${_q[headerType]:-}"

    local transport="{}"
    case "$network" in
        ws)
            transport="$(jq -n --arg path "$path" --arg host "$host" '
                {wsSettings: ({path: $path} + (if $host != "" then {headers: {Host: $host}} else {} end))}
            ')"
            ;;
        grpc)
            transport="$(jq -n --arg svc "${path#/}" '{grpcSettings: {serviceName: $svc}}')"
            ;;
        xhttp)
            transport="$(jq -n --arg path "$path" --arg host "$host" --arg mode "$mode" \
                '{xhttpSettings: {path: $path, host: $host, mode: $mode}}')"
            ;;
        tcp)
            if [[ "$headertype" == "http" ]]; then
                transport="$(jq -n --arg path "$path" --arg host "$host" \
                    '{tcpSettings: {header: {type: "http", request: {path: [$path], headers: {Host: [$host]}}}}}')"
            fi
            ;;
    esac

    local security="${_q[security]:-none}"
    local sec="{}"
    case "$security" in
        reality)
            sec="$(jq -n \
                --arg sni "${_q[sni]:-}" --arg fp "${_q[fp]:-chrome}" \
                --arg pbk "${_q[pbk]:-}" --arg sid "${_q[sid]:-}" --arg spx "${_q[spx]:-}" '
                {security: "reality", realitySettings: (
                    {serverName: $sni, fingerprint: $fp, publicKey: $pbk, shortId: $sid}
                    + (if $spx != "" then {spiderX: $spx} else {} end)
                )}
            ')"
            ;;
        tls)
            local alpn="${_q[alpn]:-}"
            local allow_insecure="${_q[allowInsecure]:-}"
            local alpn_json="null"
            [[ -n "$alpn" ]] && alpn_json="$(jq -n --arg a "$alpn" '$a | split(",")')"
            local insecure_bool="false"
            local allow_insecure_lc="${allow_insecure,,}"
            [[ "$allow_insecure" == "1" || "$allow_insecure_lc" == "true" ]] && insecure_bool="true"
            sec="$(jq -n \
                --arg sni "${_q[sni]:-$host}" --arg fp "${_q[fp]:-}" \
                --argjson alpn "$alpn_json" --argjson insecure "$insecure_bool" '
                {security: "tls", tlsSettings: (
                    {serverName: $sni}
                    + (if $alpn != null then {alpn: $alpn} else {} end)
                    + (if $fp != "" then {fingerprint: $fp} else {} end)
                    + (if $insecure then {allowInsecure: true} else {} end)
                )}
            ')"
            ;;
    esac

    jq -n --arg network "$network" --argjson transport "$transport" --argjson sec "$sec" \
        '{network: $network} + $transport + $sec'
}

split_fragment() {
    # Prints "BEFORE\nFRAGMENT" (fragment empty if none).
    local s="$1"
    if [[ "$s" == *'#'* ]]; then
        printf '%s\n%s\n' "${s%%#*}" "${s#*#}"
    else
        printf '%s\n\n' "$s"
    fi
}

parse_vless() {
    local uri="$1"
    local body="${uri#vless://}"
    local before frag
    { read -r before; read -r frag; } <<<"$(split_fragment "$body")"

    local main="$before" query=""
    if [[ "$main" == *'?'* ]]; then query="${main#*\?}"; main="${main%%\?*}"; fi

    local userinfo="${main%%@*}"
    local hostport="${main#*@}"
    local host="${hostport%:*}"
    local port="${hostport##*:}"

    local -A q=()
    parse_query q "$query"

    local tag_hint; tag_hint="$(urldecode "$frag")"
    [[ -z "$tag_hint" ]] && tag_hint="vless-$host"
    local tag; tag="$(unique_tag "$tag_hint")"

    local stream; stream="$(build_stream_settings q "$host")"

    local user_obj; user_obj="$(jq -n --arg id "$userinfo" --arg enc "${q[encryption]:-none}" --arg flow "${q[flow]:-}" '
        {id: $id, encryption: $enc} + (if $flow != "" then {flow: $flow} else {} end)
    ')"

    jq -n --arg tag "$tag" --arg address "$host" --argjson port "$port" --argjson user "$user_obj" --argjson stream "$stream" '
        {tag: $tag, protocol: "vless",
         settings: {vnext: [{address: $address, port: $port, users: [$user]}]},
         streamSettings: $stream}
    '
}

parse_trojan() {
    local uri="$1"
    local body="${uri#trojan://}"
    local before frag
    { read -r before; read -r frag; } <<<"$(split_fragment "$body")"

    local main="$before" query=""
    if [[ "$main" == *'?'* ]]; then query="${main#*\?}"; main="${main%%\?*}"; fi

    local password="${main%%@*}"
    local hostport="${main#*@}"
    local host="${hostport%:*}"
    local port="${hostport##*:}"

    local -A q=()
    parse_query q "$query"

    local tag_hint; tag_hint="$(urldecode "$frag")"
    [[ -z "$tag_hint" ]] && tag_hint="trojan-$host"
    local tag; tag="$(unique_tag "$tag_hint")"

    local stream; stream="$(build_stream_settings q "$host")"

    jq -n --arg tag "$tag" --arg address "$host" --argjson port "$port" --arg password "$password" --argjson stream "$stream" '
        {tag: $tag, protocol: "trojan",
         settings: {servers: [{address: $address, port: $port, password: $password}]},
         streamSettings: $stream}
    '
}

parse_vmess() {
    local uri="$1"
    local body="${uri#vmess://}"
    body="${body%%#*}"

    local json; json="$(b64decode "$body")"
    if [[ -z "$json" ]] || ! jq -e . >/dev/null 2>&1 <<<"$json"; then
        echo "warning: failed to decode vmess payload as JSON" >&2
        return 0
    fi

    local address; address="$(jq -r '.add // ""' <<<"$json")"
    local tag_hint; tag_hint="$(jq -r '.ps // ""' <<<"$json")"
    [[ -z "$tag_hint" ]] && tag_hint="vmess-$address"
    local tag; tag="$(unique_tag "$tag_hint")"

    local -A q=()
    q[type]="$(jq -r '.net // "tcp"' <<<"$json")"
    local vpath; vpath="$(jq -r '.path // ""' <<<"$json")"; [[ -n "$vpath" ]] && q[path]="$vpath"
    local vhost; vhost="$(jq -r '.host // ""' <<<"$json")"; [[ -n "$vhost" ]] && q[host]="$vhost"
    local vhtype; vhtype="$(jq -r '.type // ""' <<<"$json")"
    [[ -n "$vhtype" && "$vhtype" != "none" ]] && q[headerType]="$vhtype"
    if [[ "$(jq -r '.tls // ""' <<<"$json")" == "tls" ]]; then
        q[security]="tls"
        local vsni vfp valpn
        vsni="$(jq -r '.sni // ""' <<<"$json")"; [[ -n "$vsni" ]] && q[sni]="$vsni"
        vfp="$(jq -r '.fp // ""' <<<"$json")"; [[ -n "$vfp" ]] && q[fp]="$vfp"
        valpn="$(jq -r '.alpn // ""' <<<"$json")"; [[ -n "$valpn" ]] && q[alpn]="$valpn"
    fi

    local stream; stream="$(build_stream_settings q "$address")"

    jq --arg tag "$tag" --argjson stream "$stream" '
        {tag: $tag, protocol: "vmess",
         settings: {vnext: [{
            address: .add,
            port: (.port | tonumber),
            users: [{id: .id, alterId: ((.aid // 0) | tonumber), security: (.scy // "auto")}]
         }]},
         streamSettings: $stream}
    ' <<<"$json"
}

parse_shadowsocks() {
    local uri="$1"
    local body="${uri#ss://}"
    local rest frag
    { read -r rest; read -r frag; } <<<"$(split_fragment "$body")"

    local method password hostport
    if [[ "$rest" == *'@'* ]]; then
        local userinfo="${rest%%@*}"
        hostport="${rest#*@}"
        hostport="${hostport%%\?*}"
        local decoded; decoded="$(b64decode "$userinfo")"
        if [[ "$decoded" == *:* ]]; then
            method="${decoded%%:*}"
            password="${decoded#*:}"
        else
            method="${userinfo%%:*}"
            password="${userinfo#*:}"
        fi
    else
        local rest_noquery="${rest%%\?*}"
        local decoded; decoded="$(b64decode "$rest_noquery")"
        local userinfo="${decoded%@*}"
        hostport="${decoded##*@}"
        method="${userinfo%%:*}"
        password="${userinfo#*:}"
    fi

    local host="${hostport%:*}"
    local port="${hostport##*:}"

    local tag_hint; tag_hint="$(urldecode "$frag")"
    [[ -z "$tag_hint" ]] && tag_hint="ss-$host"
    local tag; tag="$(unique_tag "$tag_hint")"

    jq -n --arg tag "$tag" --arg address "$host" --argjson port "$port" --arg method "$method" --arg password "$password" '
        {tag: $tag, protocol: "shadowsocks",
         settings: {servers: [{address: $address, port: $port, method: $method, password: $password}]}}
    '
}

# Hysteria2's QUIC transport always runs over TLS -- there's no "security"
# choice to make, so this always emits a tlsSettings block (sni/insecure/
# alpn/fp from the query params, falling back to the server host for sni).
build_hysteria_security_settings() {
    local -n _q="$1"
    local fallback_host="$2"

    local alpn="${_q[alpn]:-}"
    local alpn_json="null"
    [[ -n "$alpn" ]] && alpn_json="$(jq -n --arg a "$alpn" '$a | split(",")')"

    local allow_insecure="${_q[insecure]:-}"
    local allow_insecure_lc="${allow_insecure,,}"
    local insecure_bool="false"
    [[ "$allow_insecure" == "1" || "$allow_insecure_lc" == "true" ]] && insecure_bool="true"

    jq -n \
        --arg sni "${_q[sni]:-$fallback_host}" --arg fp "${_q[fp]:-}" \
        --argjson alpn "$alpn_json" --argjson insecure "$insecure_bool" '
        {security: "tls", tlsSettings: (
            {serverName: $sni}
            + (if $alpn != null then {alpn: $alpn} else {} end)
            + (if $fp != "" then {fingerprint: $fp} else {} end)
            + (if $insecure then {allowInsecure: true} else {} end)
        )}
    '
}

# vless-style userinfo@host:port parsing, but the userinfo is a plain auth
# password (no uuid/encryption) and the protocol is always TLS. Handles both
# the hysteria2:// and hy2:// scheme spellings (caller strips either prefix).
#
# Xray-core's hysteria transport has no field for obfuscation (obfs/
# obfs-password, e.g. salamander) -- a link using it is parsed and still
# produces a connectable (non-obfuscated) config, but a server that mandates
# obfs will reject it, so this warns rather than silently dropping it.
parse_hysteria2() {
    local uri="$1"
    local body="${uri#*://}"
    local before frag
    { read -r before; read -r frag; } <<<"$(split_fragment "$body")"

    local main="$before" query=""
    if [[ "$main" == *'?'* ]]; then query="${main#*\?}"; main="${main%%\?*}"; fi

    local auth="${main%%@*}"
    local hostport="${main#*@}"
    local host="${hostport%:*}"
    local port="${hostport##*:}"

    local -A q=()
    parse_query q "$query"

    local tag_hint; tag_hint="$(urldecode "$frag")"
    [[ -z "$tag_hint" ]] && tag_hint="hysteria2-$host"
    local tag; tag="$(unique_tag "$tag_hint")"

    if [[ -n "${q[obfs]:-}" ]]; then
        echo "warning: hysteria2 link '$tag_hint' uses obfs=${q[obfs]}, which Xray-core's hysteria transport does not support -- generating it without obfuscation" >&2
    fi

    local security; security="$(build_hysteria_security_settings q "$host")"

    jq -n --arg tag "$tag" --arg address "$host" --argjson port "$port" --arg auth "$(urldecode "$auth")" --argjson security "$security" '
        {tag: $tag, protocol: "hysteria",
         settings: {version: 2, address: $address, port: $port},
         streamSettings: ({method: "hysteria", hysteriaSettings: {version: 2, auth: $auth}} + $security)}
    '
}

# Reads proxy links (one per line) on stdin, prints an Xray outbounds JSON array on stdout.
parse_outbounds() {
    local outbounds="[]"
    local line scheme obj

    SEEN_TAGS_FILE="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$SEEN_TAGS_FILE'" RETURN

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" ]] && continue
        [[ "$line" != *"://"* ]] && continue

        scheme="${line%%://*}"
        scheme="${scheme,,}"

        case "$scheme" in
            vless)  obj="$(parse_vless "$line")" ;;
            trojan) obj="$(parse_trojan "$line")" ;;
            vmess)  obj="$(parse_vmess "$line")" ;;
            ss)     obj="$(parse_shadowsocks "$line")" ;;
            hysteria2|hy2) obj="$(parse_hysteria2 "$line")" ;;
            *)
                echo "warning: skipping unsupported scheme '$scheme'" >&2
                continue
                ;;
        esac

        [[ -z "$obj" ]] && continue
        outbounds="$(jq --argjson o "$obj" '. + [$o]' <<<"$outbounds")"
    done

    jq . <<<"$outbounds"
}

declare -A WRITTEN_FRAGMENT_FILES=()

# Writes a JSON object (as a string) to a file. If this exact path was
# already written earlier in the same run -- e.g. two of DNS_FILE/
# OUTBOUNDS_FILE/OBSERVATORY_FILE/ROUTES_FILE were set to the same path to
# build one combined config -- merges into the existing content (shallow
# top-level merge) instead of overwriting it, so earlier fragments aren't
# clobbered. Call sites run dns, then outbounds, then observatory, then
# routing, so that's the merge order when paths coincide.
write_fragment() {
    local path="$1" json="$2"
    if [[ -n "${WRITTEN_FRAGMENT_FILES[$path]:-}" ]]; then
        local merged
        merged="$(jq -s '.[0] + .[1]' "$path" <(printf '%s' "$json"))"
        printf '%s\n' "$merged" >"$path"
    else
        printf '%s\n' "$json" >"$path"
        WRITTEN_FRAGMENT_FILES["$path"]=1
    fi
}

# Derives a stable id from actual device characteristics instead of pure
# randomness: hostname, kernel release/arch (uname -r/-m), and the first
# real NIC's MAC address (read straight from sysfs -- no extra command,
# and the closest thing to an actual hardware id available here). Every
# piece is a BusyBox-standard applet or a plain /sys read, so this needs
# no opkg packages beyond what the rest of the script already requires.
# Hashed down to a fixed-length hex string so it reliably fits Remnawave's
# required x-hwid format regardless of how long the raw inputs are.
generate_hwid() {
    local mac="" f
    for f in /sys/class/net/*/address; do
        [[ -r "$f" ]] || continue
        read -r mac <"$f" 2>/dev/null
        [[ -n "$mac" && "$mac" != "00:00:00:00:00:00" ]] && break
        mac=""
    done

    local seed
    seed="$(hostname 2>/dev/null)|$(uname -r 2>/dev/null)|$(uname -m 2>/dev/null)|$mac"

    local hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        hash="$(printf '%s' "$seed" | sha256sum | cut -c1-32)"
    elif command -v md5sum >/dev/null 2>&1; then
        hash="$(printf '%s' "$seed" | md5sum | cut -c1-32)"
    fi

    # Fall back to /dev/urandom only if the device-derived seed somehow
    # produced nothing usable (e.g. no hash tool and no readable /sys).
    if [[ "${#hash}" -lt 10 ]]; then
        hash="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi

    printf '%s' "$hash"
}

# --- happ_json (decoded routing profile) -> Xray config fragments ----------

# Prints the (unwrapped) "dns" object. Takes the decoded happ routing JSON.
build_dns_json() {
    local happ_json="$1"
    jq '
        def dns_addr(domain; ip): (domain // "") as $d | if $d != "" then $d else ip end;
        . as $root
        | {
            hosts: ($root.DnsHosts // {}),
            servers: (
                (if ($root.FakeDNS // "false") == "true" then ["fakedns"] else [] end)
                + (if ($root.DirectSites // []) != [] then
                    [{
                        address: dns_addr($root.DomesticDNSDomain; $root.DomesticDNSIP),
                        domains: $root.DirectSites,
                        skipFallback: true
                    }]
                else [] end)
                + [dns_addr($root.RemoteDNSDomain; $root.RemoteDNSIP)]
            )
        }
    ' <<<"$happ_json"
}

# Prints the (unwrapped) "fakedns" array. Takes the decoded happ routing JSON.
build_fakedns_json() {
    local happ_json="$1"
    jq '
        if (.FakeDNS // "false") == "true" then
            [{ipPool: "198.18.0.0/15", poolSize: 65535}, {ipPool: "fc00::/18", poolSize: 65535}]
        else
            []
        end
    ' <<<"$happ_json"
}

# Prints {"outbounds": [...parsed proxy outbounds..., direct, block]}.
# Takes the parsed proxy outbounds JSON array (not the happ routing JSON).
build_outbounds_file_json() {
    local outbounds_json="$1"
    jq -n --argjson outbounds "$outbounds_json" '
        {outbounds: ($outbounds + [
            {tag: "direct", protocol: "freedom", settings: {}},
            {tag: "block", protocol: "blackhole", settings: {response: {type: "http"}}}
        ])}
    '
}

# Prints the (unwrapped) "observatory" object. Takes the parsed proxy
# outbounds JSON array (not the happ routing JSON).
build_observatory_json() {
    local outbounds_json="$1" probe_url="$2" probe_interval="$3"
    jq --arg probeUrl "$probe_url" --arg probeInterval "$probe_interval" '{
        subjectSelector: map(.tag),
        probeUrl: $probeUrl,
        probeInterval: $probeInterval,
        enableConcurrency: true
    }' <<<"$outbounds_json"
}

# Prints the (unwrapped) "routing" object: direct/proxy/block rules ordered
# per RouteOrder, plus a GlobalProxy-driven port:0-65535 catch-all.
build_routes_json() {
    local happ_json="$1" outbounds_json="$2" strategy="$3" balancer_tag="$4"
    jq \
        --argjson outbounds "$outbounds_json" \
        --arg strategy "$strategy" \
        --arg balancerTag "$balancer_tag" \
        '
        . as $root
        | ($outbounds | map(.tag)) as $proxy_tags
        | {direct: "direct", proxy: $balancerTag, block: "block"} as $tag
        | ($root.RouteOrder // "direct-proxy-block" | split("-")) as $order
        | (($root.GlobalProxy // "false") == "true") as $global_proxy
        | (if $global_proxy then {balancerTag: $balancerTag} else {outboundTag: "direct"} end) as $catch_all_target
        | {
            domainStrategy: ($root.DomainStrategy // "AsIs"),
            balancers: [
                {tag: $balancerTag, selector: $proxy_tags, strategy: {type: $strategy}}
            ],
            rules: (
                (
                    $order
                    | map(
                        . as $kind
                        | (
                            if $kind == "direct" then {domain: $root.DirectSites, ip: $root.DirectIp}
                            elif $kind == "proxy" then {domain: $root.ProxySites, ip: $root.ProxyIp}
                            elif $kind == "block" then {domain: $root.BlockSites, ip: $root.BlockIp}
                            else {domain: [], ip: []}
                            end
                        ) as $lists
                        | (if $kind == "proxy" then {balancerTag: $tag[$kind]} else {outboundTag: $tag[$kind]} end) as $target
                        | [
                            (if ($lists.domain // []) != [] then [({type: "field", domain: $lists.domain} + $target)] else [] end),
                            (if ($lists.ip // []) != [] then [({type: "field", ip: $lists.ip} + $target)] else [] end)
                        ]
                        | add
                    )
                    | add
                )
                + [({type: "field", port: "0-65535"} + $catch_all_target)]
            )
        }
    ' <<<"$happ_json"
}

# --- main pipeline -----------------------------------------------------------

main() {
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Parse KEY=VALUE lines from .env directly instead of `source`-ing it, so a
    # stray malformed line (e.g. a comment missing its leading #) is just
    # skipped instead of being executed as a shell command.
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        local line key val
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            line="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
            key="${line%%=*}"
            key="${key%"${key##*[![:space:]]}"}"
            val="${line#*=}"
            if [[ "$val" == \"*\" && "$val" == *\" ]]; then
                val="${val:1:-1}"
            elif [[ "$val" == \'*\' && "$val" == *\' ]]; then
                val="${val:1:-1}"
            fi
            [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            export "$key=$val"
        done <"$SCRIPT_DIR/.env"
    fi

    local SUB_URL="${1:-${XRAY_SUBSCRIPTION_URL:-}}"
    if [[ -z "$SUB_URL" ]]; then
        echo "error: no subscription URL given and XRAY_SUBSCRIPTION_URL is not set in .env" >&2
        exit 1
    fi

    # Remnawave's "HWID device limit" feature requires the client to send an
    # x-hwid header (must match /^[a-zA-Z0-9=-]{10,64}$/) on every request to
    # the subscription URL, or it 404s once that feature is enabled for this
    # user. The HWID must stay stable across runs -- Remnawave counts/tracks
    # devices by it, so a value that changed every run would burn through
    # the device limit. XRAY_HWID in .env pins an explicit value (e.g. one
    # tied to your actual device/HWID link); otherwise one is derived once
    # from this device (see generate_hwid) and cached in SCRIPT_DIR/.hwid for
    # every run after that to reuse, so it survives things like a kernel
    # version bump that would otherwise shift the derived value.
    local HWID="${XRAY_HWID:-}"
    if [[ -z "$HWID" ]]; then
        local hwid_file="$SCRIPT_DIR/.hwid"
        if [[ -f "$hwid_file" ]]; then
            HWID="$(<"$hwid_file")"
        else
            HWID="$(generate_hwid)"
            printf '%s' "$HWID" >"$hwid_file"
        fi
    fi
    local HWID_CURL_ARGS=(
        -H "x-hwid: $HWID"
        -H "x-device-os: Linux"
        -H "x-device-model: happ2xray"
        -A "happ2xray/1.0"
    )

    local BASE_DIR
    if [[ -n "${XRAY_DIR_PATH:-}" ]]; then
        BASE_DIR="$XRAY_DIR_PATH"
    else
        BASE_DIR="."
    fi
    local CONFIG_DIR="$BASE_DIR/configs"

    # For each of these, an arg/env var that's unset falls back to the next
    # layer (arg -> env var -> numbered default), same as before. But one
    # that's explicitly set to "" is taken at face value -- an empty path
    # means "don't generate this file at all" (see the write_fragment guards
    # below), not "fall back to the default". ${N+x}/${VAR+x} expands to a
    # non-empty string iff the parameter is set, even to "", unlike ${N:-x}
    # which can't tell "unset" apart from "set but empty".
    local DAT_DIR="${3:-$BASE_DIR/dat}"

    local OUTPUT_FILE
    if [[ -n "${2+x}" ]]; then
        OUTPUT_FILE="$2"
    elif [[ -n "${XRAY_ROUTING_FILE+x}" ]]; then
        OUTPUT_FILE="$XRAY_ROUTING_FILE"
    else
        OUTPUT_FILE="$CONFIG_DIR/04_routing_happ.json"
    fi

    local OUTBOUNDS_FILE
    if [[ -n "${4+x}" ]]; then
        OUTBOUNDS_FILE="$4"
    elif [[ -n "${XRAY_OUTBOUNDS_FILE+x}" ]]; then
        OUTBOUNDS_FILE="$XRAY_OUTBOUNDS_FILE"
    else
        OUTBOUNDS_FILE="$CONFIG_DIR/02_outbounds_happ.json"
    fi

    local OBSERVATORY_FILE
    if [[ -n "${5+x}" ]]; then
        OBSERVATORY_FILE="$5"
    elif [[ -n "${XRAY_OBSERVATORY_FILE+x}" ]]; then
        OBSERVATORY_FILE="$XRAY_OBSERVATORY_FILE"
    else
        OBSERVATORY_FILE="$CONFIG_DIR/03_observatory_happ.json"
    fi

    local DNS_FILE
    if [[ -n "${6+x}" ]]; then
        DNS_FILE="$6"
    elif [[ -n "${XRAY_DNS_FILE+x}" ]]; then
        DNS_FILE="$XRAY_DNS_FILE"
    else
        DNS_FILE="$CONFIG_DIR/01_dns_happ.json"
    fi

    local BALANCER_TAG="${XRAY_BALANCER_TAG:-proxy}"
    local BALANCER_STRATEGY="${XRAY_BALANCER_STRATEGY:-leastPing}"
    local PROBE_URL="${XRAY_PROBE_URL:-https://www.gstatic.com/generate_204}"
    local PROBE_INTERVAL="${XRAY_PROBE_INTERVAL:-10s}"

    [[ -n "$OUTPUT_FILE" ]] && mkdir -p "$(dirname "$OUTPUT_FILE")"
    [[ -n "$OUTBOUNDS_FILE" ]] && mkdir -p "$(dirname "$OUTBOUNDS_FILE")"
    [[ -n "$OBSERVATORY_FILE" ]] && mkdir -p "$(dirname "$OBSERVATORY_FILE")"
    [[ -n "$DNS_FILE" ]] && mkdir -p "$(dirname "$DNS_FILE")"

    for bin in curl jq base64; do
        command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' is required but not installed" >&2; exit 1; }
    done

    # 1. Grab response headers only (HEAD is enough; Remnawave computes the
    #    routing header without needing the full subscription body).
    local headers
    headers="$(curl -sSI "${HWID_CURL_ARGS[@]}" "$SUB_URL")"

    local routing_header
    routing_header="$(printf '%s\n' "$headers" | grep -i '^routing:' | head -n1 | cut -d' ' -f2- | tr -d '\r')"

    if [[ -z "$routing_header" ]]; then
        echo "error: no 'routing' header found in response from $SUB_URL" >&2
        exit 1
    fi

    # 2. Strip the happ://routing/onadd/ scheme and base64-decode the payload.
    local b64_payload="${routing_header#happ://routing/onadd/}"
    local happ_json
    happ_json="$(printf '%s' "$b64_payload" | base64 -d 2>/dev/null)"

    if ! jq -e . >/dev/null 2>&1 <<<"$happ_json"; then
        echo "error: failed to decode routing payload as JSON" >&2
        exit 1
    fi

    # 2b. dns + fakedns.
    local dns_json fakedns_json
    dns_json="$(build_dns_json "$happ_json")"
    fakedns_json="$(build_fakedns_json "$happ_json")"

    if [[ -n "$DNS_FILE" ]]; then
        write_fragment "$DNS_FILE" "$(jq -n --argjson dns "$dns_json" --argjson fakedns "$fakedns_json" '{dns: $dns, fakedns: $fakedns}')"
        echo "DNS written to $DNS_FILE" >&2
    else
        echo "DNS generation skipped (empty file path)" >&2
    fi

    # 3. Fetch the subscription body itself (the base64 list of proxy links) and
    #    convert each vless/vmess/trojan/ss entry into an Xray outbound object.
    local sub_body
    sub_body="$(curl -fsSL "${HWID_CURL_ARGS[@]}" "$SUB_URL" | base64 -d 2>/dev/null)"

    if [[ -z "$sub_body" ]]; then
        echo "error: subscription body at $SUB_URL was empty or not base64" >&2
        exit 1
    fi

    local outbounds_json
    outbounds_json="$(printf '%s\n' "$sub_body" | parse_outbounds)"

    # "direct"/"block" are appended only to the file written out -- $outbounds_json
    # itself (used below for the balancer's selector and the Observatory's
    # subjectSelector) stays limited to the real proxy outbounds parsed above.
    if [[ -n "$OUTBOUNDS_FILE" ]]; then
        write_fragment "$OUTBOUNDS_FILE" "$(build_outbounds_file_json "$outbounds_json")"
        echo "Outbounds written to $OUTBOUNDS_FILE" >&2
    else
        echo "Outbounds generation skipped (empty file path)" >&2
    fi

    # 3b. Build the Observatory block the "proxy" balancer's leastPing strategy
    #     needs: it actively probes every outbound tag and ranks them by latency.
    local observatory_json
    observatory_json="$(build_observatory_json "$outbounds_json" "$PROBE_URL" "$PROBE_INTERVAL")"

    if [[ -n "$OBSERVATORY_FILE" ]]; then
        write_fragment "$OBSERVATORY_FILE" "$(jq -n --argjson observatory "$observatory_json" '{observatory: $observatory}')"
        echo "Observatory written to $OBSERVATORY_FILE" >&2
    else
        echo "Observatory generation skipped (empty file path)" >&2
    fi

    # 4. Convert Happ's Direct/Proxy/Block site & IP lists into Xray routing
    #    rules, honoring the order declared in RouteOrder (e.g. "direct-proxy-block").
    #    "proxy" rules point at a "proxy" balancer (built above) that fans out
    #    across every outbound parsed from the subscription, instead of a single
    #    hardcoded outbound tag. A final port:0-65535 catch-all rule covers
    #    traffic matching none of the lists above, per Happ's GlobalProxy field
    #    ("true" -> proxy, else direct).
    local routes_json
    routes_json="$(build_routes_json "$happ_json" "$outbounds_json" "$BALANCER_STRATEGY" "$BALANCER_TAG")"
    routes_json="$(jq -n --argjson routing "$routes_json" '{routing: $routing}')"

    if [[ -n "$OUTPUT_FILE" ]]; then
        write_fragment "$OUTPUT_FILE" "$routes_json"
        echo "Routes written to $OUTPUT_FILE" >&2
    else
        echo "Routes generation skipped (empty file path)" >&2
    fi

    # 5. Download the geoip.dat/geosite.dat assets the profile references, so
    #    the geoip:/geosite: entries in the rules above have something to match against.
    local geoip_url geosite_url
    geoip_url="$(jq -r '.Geoipurl // ""' <<<"$happ_json")"
    geosite_url="$(jq -r '.Geositeurl // ""' <<<"$happ_json")"

    if [[ -n "$geoip_url" || -n "$geosite_url" ]]; then
        mkdir -p "$DAT_DIR"
    fi

    # Xray's plain geoip:/geosite: rule syntax always resolves against files
    # literally named geoip.dat/geosite.dat in the asset dir, regardless of what
    # the source URL is named -- so the destination names are fixed, not derived
    # from the URL.
    local pair url name dest
    for pair in "$geoip_url:geoip.dat" "$geosite_url:geosite.dat"; do
        url="${pair%:*}"
        name="${pair##*:}"
        [[ -n "$url" ]] || continue
        dest="$DAT_DIR/$name"
        echo "Downloading $url -> $dest" >&2
        curl -fsSL "$url" -o "$dest"
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
