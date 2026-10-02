#!/usr/bin/env bash
# Tests for parse_vless/parse_trojan/parse_vmess/parse_shadowsocks.

# vless + reality + xhttp (shape of a real-world link, values are placeholders).
out="$(parse_vless 'vless://00000000-0000-4000-8000-000000000000@203.0.113.10:443?encryption=none&type=xhttp&path=%2Fapi%2Fads&mode=auto&security=reality&sni=sni.example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=a5#Example%20VLESS')"
assert_json_eq "$out" '{
    "tag": "Example VLESS",
    "protocol": "vless",
    "settings": {
        "vnext": [{
            "address": "203.0.113.10",
            "port": 443,
            "users": [{"id": "00000000-0000-4000-8000-000000000000", "encryption": "none"}]
        }]
    },
    "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"path": "/api/ads", "host": "sni.example.com", "mode": "auto"},
        "security": "reality",
        "realitySettings": {
            "serverName": "sni.example.com", "fingerprint": "chrome",
            "publicKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "shortId": "a5"
        }
    }
}' "parse_vless: reality+xhttp link"

# SIP002-form shadowsocks (userinfo base64-encoded, host:port plaintext).
out="$(parse_shadowsocks 'ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpleGFtcGxlcGFzc3dvcmQ=@203.0.113.20:1234#Example%20SS')"
assert_json_eq "$out" '{
    "tag": "Example SS",
    "protocol": "shadowsocks",
    "settings": {"servers": [{
        "address": "203.0.113.20", "port": 1234,
        "method": "chacha20-ietf-poly1305", "password": "examplepassword"
    }]}
}' "parse_shadowsocks: SIP002 form"

# Legacy full-base64 shadowsocks form: ss://base64(method:password@host:port)#tag
out="$(parse_shadowsocks 'ss://YWVzLTI1Ni1nY206bXlwYXNzd29yZEAxLjIuMy40OjgzODg=#Legacy%20SS')"
assert_json_eq "$out" '{
    "tag": "Legacy SS",
    "protocol": "shadowsocks",
    "settings": {"servers": [{
        "address": "1.2.3.4", "port": 8388,
        "method": "aes-256-gcm", "password": "mypassword"
    }]}
}' "parse_shadowsocks: legacy full-base64 form"

# Trojan + tls + ws.
out="$(parse_trojan 'trojan://mypassword@trojan.example.com:443?security=tls&sni=trojan.example.com&type=ws&host=cdn.example.com&path=%2Ftrojanws#Trojan%20Test')"
assert_json_eq "$out" '{
    "tag": "Trojan Test",
    "protocol": "trojan",
    "settings": {"servers": [{"address": "trojan.example.com", "port": 443, "password": "mypassword"}]},
    "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/trojanws", "headers": {"Host": "cdn.example.com"}},
        "security": "tls",
        "tlsSettings": {"serverName": "trojan.example.com"}
    }
}' "parse_trojan: tls+ws link"

# Vmess (base64 JSON body) + tls + ws + alpn.
out="$(parse_vmess 'vmess://eyJ2IjogIjIiLCAicHMiOiAiVGVzdCBWTWVzcyIsICJhZGQiOiAiZXhhbXBsZS5jb20iLCAicG9ydCI6ICI0NDMiLCAiaWQiOiAiMTIzNC11dWlkIiwgImFpZCI6ICIwIiwgInNjeSI6ICJhdXRvIiwgIm5ldCI6ICJ3cyIsICJ0eXBlIjogIm5vbmUiLCAiaG9zdCI6ICJjZG4uZXhhbXBsZS5jb20iLCAicGF0aCI6ICIvd3MiLCAidGxzIjogInRscyIsICJzbmkiOiAiZXhhbXBsZS5jb20iLCAiYWxwbiI6ICJoMixodHRwLzEuMSJ9')"
assert_json_eq "$out" '{
    "tag": "Test VMess",
    "protocol": "vmess",
    "settings": {"vnext": [{
        "address": "example.com", "port": 443,
        "users": [{"id": "1234-uuid", "alterId": 0, "security": "auto"}]
    }]},
    "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/ws", "headers": {"Host": "cdn.example.com"}},
        "security": "tls",
        "tlsSettings": {"serverName": "example.com", "alpn": ["h2", "http/1.1"]}
    }
}' "parse_vmess: tls+ws+alpn link"

# Hysteria2: plain TLS (sni falls back to host when unset elsewhere, but
# here it's given explicitly).
out="$(parse_hysteria2 'hysteria2://examplepassword@203.0.113.30:443?sni=hy2.example.com#Example%20Hysteria2' 2>/dev/null)"
assert_json_eq "$out" '{
    "tag": "Example Hysteria2",
    "protocol": "hysteria",
    "settings": {"version": 2, "address": "203.0.113.30", "port": 443},
    "streamSettings": {
        "method": "hysteria",
        "hysteriaSettings": {"version": 2, "auth": "examplepassword"},
        "security": "tls",
        "tlsSettings": {"serverName": "hy2.example.com"}
    }
}' "parse_hysteria2: plain tls link"

# hy2:// alias, insecure + alpn, sni falling back to the server host.
out="$(parse_hysteria2 'hy2://examplepassword@203.0.113.31:443?insecure=1&alpn=h3#Example%20Hy2' 2>/dev/null)"
assert_json_eq "$out" '{
    "tag": "Example Hy2",
    "protocol": "hysteria",
    "settings": {"version": 2, "address": "203.0.113.31", "port": 443},
    "streamSettings": {
        "method": "hysteria",
        "hysteriaSettings": {"version": 2, "auth": "examplepassword"},
        "security": "tls",
        "tlsSettings": {"serverName": "203.0.113.31", "alpn": ["h3"], "allowInsecure": true}
    }
}' "parse_hysteria2: hy2 alias, insecure + alpn, sni defaults to host"

# obfs isn't representable in Xray-core's hysteria transport -- parse_hysteria2
# should still produce a connectable (non-obfuscated) config, but warn on stderr
# rather than silently dropping something the link asked for.
obfs_stderr="$(parse_hysteria2 'hysteria2://examplepassword@203.0.113.32:443?obfs=salamander&obfs-password=secret#Obfs%20Test' 2>&1 1>/dev/null)"
assert_contains "$obfs_stderr" "obfs=salamander" \
    "parse_hysteria2: warns on stderr when the link specifies unsupported obfs"
out="$(parse_hysteria2 'hysteria2://examplepassword@203.0.113.32:443?obfs=salamander&obfs-password=secret#Obfs%20Test' 2>/dev/null)"
assert_json_eq "$(jq '.streamSettings.hysteriaSettings' <<<"$out")" '{"version": 2, "auth": "examplepassword"}' \
    "parse_hysteria2: obfs params are dropped (not fabricated into an unsupported field)"

# parse_outbounds dispatches both scheme spellings to parse_hysteria2.
mixed_links=$'hysteria2://examplepassword@203.0.113.33:443#H2\nhy2://examplepassword@203.0.113.34:443#H2alias'
out="$(printf '%s\n' "$mixed_links" | parse_outbounds 2>/dev/null)"
assert_json_eq "$(jq '[.[].protocol]' <<<"$out")" '["hysteria", "hysteria"]' \
    "parse_outbounds: both hysteria2:// and hy2:// dispatch to the hysteria protocol"

# Duplicate tags get disambiguated across calls within one parse_outbounds
# run (unique_tag's ledger is a temp file set up by parse_outbounds itself --
# every caller is reached via command substitution, which forks a subshell,
# so a plain shell variable/array couldn't survive between calls here).
dup_links=$'vless://aaaa@1.2.3.4:443?encryption=none#Dup\nvless://bbbb@5.6.7.8:443?encryption=none#Dup\nvless://cccc@9.9.9.9:443?encryption=none#Dup'
out="$(printf '%s\n' "$dup_links" | parse_outbounds)"
assert_json_eq "$(jq '[.[].tag]' <<<"$out")" '["Dup", "Dup (2)", "Dup (3)"]' \
    "parse_outbounds: repeated #name fragments get disambiguated as \"Dup\", \"Dup (2)\", \"Dup (3)\""
