# happ2xray

[![test](https://github.com/flops/happ2xray/actions/workflows/test.yml/badge.svg)](https://github.com/flops/happ2xray/actions/workflows/test.yml)

Turns a Remnawave (remna.st) subscription URL into Xray-core config fragments:
reads the Happ client's embedded routing profile, parses the subscription's
proxy links (vless/vmess/trojan/ss), and writes out `dns`, `outbounds`,
`observatory`, and `routing` as separate JSON files you merge into your real
Xray config. A second script watches the subscription for changes and
restarts `xkeen` when it updates.

## Scripts

- **`happ_routing_to_xray.sh`** — fetches the subscription, generates the
  config fragments, and downloads `geoip.dat`/`geosite.dat`.
- **`happ_watch.sh`** — regenerates into a temp dir, diffs against what's
  deployed, and only if something changed: runs `down.sh`, copies the new
  files over, then runs `up.sh`. Also manages a cron job to run itself
  periodically.
- **`up.sh`** — restarts xkeen (`xkeen -restart`). Called by `happ_watch.sh`
  after the file swap, but safe to run standalone too.
- **`down.sh`** — placeholder run before the file swap; currently a no-op
  since `up.sh`'s restart is enough on its own.

## Install

On a router (Keenetic/Entware) or any machine with `curl` or `wget`:

```
curl -fsSL https://raw.githubusercontent.com/flops/happ2xray/main/install.sh | sh
```

No `curl`? Use `wget` instead (the script itself also falls back to `wget`
for its own downloads if `curl` isn't installed):

```
wget -qO- https://raw.githubusercontent.com/flops/happ2xray/main/install.sh | sh
```

Installs `bash`/`jq`/`curl` via `opkg` where available, downloads the
scripts plus `.env.example` into `/opt/etc/happ2xray` (override with
`INSTALL_DIR=...`), creates `.env` from the example if one doesn't already
exist, and installs a `happ_watch` command into `/opt/sbin` (override with
`BIN_DIR=`/`BIN_NAME=`) — the same idea as `/opt/sbin/xkeen` — so you can
run `happ_watch -watch` instead of `bash /opt/etc/happ2xray/happ_watch.sh
-watch`. Safe to re-run — it won't overwrite an existing `.env`.

## Setup

```
cp .env.example .env
```

Edit `.env` and set at least `XRAY_SUBSCRIPTION_URL`. See `.env.example` for
every variable and its default.

## Usage

```
bash happ_routing_to_xray.sh
```

Writes into `configs/` (under `$XRAY_DIR_PATH` if set, else the current
directory):

| File | Merges into config key | Env var override |
| --- | --- | --- |
| `configs/01_dns_happ.json` | `dns` (+ `fakedns`) | `XRAY_DNS_FILE` |
| `configs/02_outbounds_happ.json` | `outbounds` | `XRAY_OUTBOUNDS_FILE` |
| `configs/03_observatory_happ.json` | `observatory` | `XRAY_OBSERVATORY_FILE` |
| `configs/04_routing_happ.json` | `routing` | `XRAY_ROUTING_FILE` |

Plus `dat/geoip.dat` and `dat/geosite.dat`.

Merge them into a full Xray config with:

```
jq -s 'add' configs/[0-9]*.json
```

Or point two or more of the env vars above (or the corresponding script
arguments) at the same path to have the script merge them into one file
itself as it generates them, in that same order — handy if you'd rather
end up with a single combined config than four files to merge yourself.

Set any of the four to an explicit empty string (not just leave it unset)
to skip generating that file entirely — e.g. `XRAY_OBSERVATORY_FILE=` in
`.env` if you don't want an observatory block at all. Leaving a var unset
(or commented out) still falls back to its default as normal; only an
explicit empty value means "skip".

### What's in each fragment

- **outbounds** — one entry per proxy link in the subscription (tagged by
  its `#name`), plus a `direct` (freedom) and `block` (blackhole) outbound.
- **routing** — `direct`/`block` rules point at those outbounds by tag;
  `proxy` rules point at a **balancer** (tag `proxy` by default, see
  `XRAY_BALANCER_TAG`) whose selector covers every parsed proxy outbound,
  using the `leastPing` strategy by default. Rule blocks are ordered per the
  subscription's `RouteOrder` field (default `direct-proxy-block`), with a
  final catch-all rule for anything matching none of the lists: routed to
  `proxy` if the profile's `GlobalProxy` is `"true"`, else `direct`.
- **observatory** — required by `leastPing`: actively probes every proxy
  outbound so the balancer can rank them by latency.
- **dns** — the profile's direct-listed domains resolve via its domestic
  DNS server (skipping fallback), everything else via its remote DNS
  server. Also carries `fakedns` (a sibling top-level key in the same
  file): if the profile's `FakeDNS` is `"true"`, a `"fakedns"` dns server
  entry and a matching IP pool are generated; otherwise `fakedns` is just
  `[]`. Note this still needs sniffing + `destOverride: ["fakedns"]` on
  your own inbound(s) to actually take effect — this project doesn't
  generate inbounds.

### Watching for changes

```
bash happ_watch.sh -watch [MINUTES]   # schedule a periodic check (default 60 min)
bash happ_watch.sh                    # check once; update + restart xkeen only if changed
bash happ_watch.sh -update            # force update, skipping the change check
bash happ_watch.sh -stop              # remove the scheduled check
```

If you don't run xkeen, or want different behavior (a different command,
extra steps, nothing at all), edit `up.sh` directly — it's a few lines.

## Tests

```
bash tests/run.sh
```

A pure bash + jq test suite (no framework, no network calls) covering the
proxy-link parsers, dns/fakedns/routing/outbounds/observatory generation,
and a `bash -n`/`sh -n` syntax check on every script. `happ_routing_to_xray.sh`
is safe to `source` for this: a `BASH_SOURCE`-vs-`$0` guard means sourcing
it only defines its functions, it never fetches anything.

## Requirements

`bash`, `curl`, `jq`, `base64` (coreutils). On Keenetic/Entware:

```
opkg update && opkg install bash jq curl coreutils cron
```

Invoke scripts as `bash happ_routing_to_xray.sh` rather than
`./happ_routing_to_xray.sh` — Entware's bash lives at `/opt/bin/bash`, not
`/usr/bin/bash`, so the `#!/usr/bin/env bash` shebang won't resolve on a bare
router shell.
