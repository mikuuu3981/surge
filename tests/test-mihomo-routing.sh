#!/usr/bin/env bash
# 仅使用临时配置；可选真实内核校验不会启动服务或修改防火墙。
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL_BIN="${VLESS_TEST_MIHOMO_BIN:-}"
export VLESS_TEST_CFG="$TMP/etc"
export VLESS_TEST_MIHOMO_BIN="$TMP/bin/mihomo"
mkdir -p "$VLESS_TEST_CFG" "$TMP/bin"
source "$ROOT/vless-server.sh"
_listen_addr() { printf '%s\n' 127.0.0.1; }
_err() { printf '%s\n' "$*" >&2; }

fixture() {
    jq -n '{xray:{},singbox:{},mihomo:{snell:[{port:41001,psk:"test-only",version:4}]},
        chain_proxy:{nodes:[
            {name:"landing",type:"socks",server:"127.0.0.1",port:1080,username:"test",password:"quote\"pass"},
            {name:"backup",type:"shadowsocks",server:"127.0.0.1",port:1081,method:"aes-128-gcm",password:"test"}
        ]},balancer_groups:[{name:"pool",strategy:"leastPing",nodes:["landing","backup"]}]}' >"$DB_FILE"
}
set_rules() {
    local rules
    rules=$(jq -n "$1")
    jq --argjson rules "$rules" '.routing_rules=$rules' "$DB_FILE" >"$TMP/db"
    mv "$TMP/db" "$DB_FILE"
}
check() { jq -e "$1" "$MIHOMO_CONFIG" >/dev/null; }
real_check() {
    if [[ -n "$REAL_BIN" ]]; then
        "$REAL_BIN" -t -d "$CFG" -f "$MIHOMO_CONFIG" >"$TMP/validate.log" 2>&1 || {
            printf '%s\n' '真实 Mihomo 校验失败:' >&2
            while IFS= read -r line; do printf '%s\n' "$line" >&2; done <"$TMP/validate.log"
            return 1
        }
    fi
}

fixture
generate_mihomo_config
check '.rules == ["MATCH,DIRECT"] and (.listeners | length) == 1'
real_check
printf '%s\n' 'ok - empty rules preserve direct fallback'

set_rules '[
 {type:"custom",outbound:"direct",domains:"safe.example",ip_version:"as_is"},
 {type:"custom",outbound:"block",domains:"bad.example,203.0.113.1,2001:db8::1",ip_version:"as_is"},
 {type:"custom",outbound:"chain:landing",domains:"proxy.example,198.51.100.0/24",ip_version:"ipv4_only"},
 {type:"all",outbound:"chain:backup",ip_version:"as_is"},
 {type:"all",outbound:"direct",ip_version:"ipv4_only"},
 {type:"all",outbound:"chain:landing",ip_version:"ipv6_only"}
]'
generate_mihomo_config
check '.rules == [
 "DOMAIN-SUFFIX,safe.example,direct-as_is",
 "DOMAIN-SUFFIX,bad.example,REJECT",
 "IP-CIDR,203.0.113.1/32,REJECT",
 "IP-CIDR6,2001:db8::1/128,REJECT",
 "AND,((DOMAIN-SUFFIX,proxy.example),(IP-CIDR,0.0.0.0/0)),chain-landing-ipv4_only",
 "AND,((IP-CIDR,198.51.100.0/24),(IP-CIDR,0.0.0.0/0)),chain-landing-ipv4_only",
 "IP-CIDR6,::/0,chain-landing-ipv6_only",
 "IP-CIDR,0.0.0.0/0,direct-ipv4_only",
 "MATCH,chain-backup-as_is","MATCH,DIRECT"]'
check 'any(.proxies[]; .type=="socks5" and .["ip-version"]=="ipv6" and .password=="quote\"pass")'
real_check
printf '%s\n' 'ok - custom domains/IPs, reject, family filters, priority and chain proxies'

set_rules '[{type:"telegram",outbound:"balancer:pool",domains:"geosite:telegram",ip_version:"as_is"},
 {type:"custom",outbound:"block",domains:"geosite:cn,geoip:cn",ip_version:"ipv6_only"},
 {type:"ads",outbound:"block",domains:"geosite:category-ads-all",ip_version:"as_is"}]'
generate_mihomo_config
check '.rules[0:2] == ["GEOSITE,telegram,balancer-pool-as_is","GEOIP,telegram,balancer-pool-as_is"]'
check '.rules[2:4] == ["AND,((GEOSITE,cn),(IP-CIDR6,::/0)),REJECT","AND,((GEOIP,cn),(IP-CIDR6,::/0)),REJECT"]'
check '."geodata-mode" == true and ."proxy-groups"[0].type == "url-test" and (.proxies|length) == 2'
real_check
printf '%s\n' 'ok - presets, access restriction, geodata and balancer'

# 所有预设类别，包括 Google/Netflix 的额外 GeoIP。
set_rules '[{type:"custom",outbound:"block",ip_version:"as_is",domains:"geosite:category-ai-!cn,geosite:openai,geosite:netflix,geosite:disney,geosite:mytvsuper,geosite:youtube,geosite:spotify,geosite:tiktok,geosite:telegram,geosite:google,geosite:category-ads-all,geoip:google,geoip:netflix"}]'
generate_mihomo_config
real_check
printf '%s\n' 'ok - all preset geodata categories'

jq '.routing={warp_mode:"official"}' "$DB_FILE" >"$TMP/db"; mv "$TMP/db" "$DB_FILE"
set_rules '[{type:"all",outbound:"warp",ip_version:"as_is"}]'
generate_mihomo_config
check '.rules[0]=="NETWORK,UDP,DIRECT" and .rules[-2]=="MATCH,warp-as_is" and .proxies[0].udp==false'
real_check
printf '%s\n' 'ok - official WARP and UDP protection'

jq '.routing.warp_mode="wgcf" | .chain_proxy.nodes[0].via_warp=true' "$DB_FILE" >"$TMP/db"; mv "$TMP/db" "$DB_FILE"
jq -n '{endpoint:"[2606:4700:d0::1]:2408",address_v4:"172.16.0.2/32",address_v6:"2606:4700:110::2/128",
 private_key:"eCtXsJZ27+4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU=",public_key:"Cr8hWlKvtDt7nrvf+f0brNQQzabAqrjfBvas9pmowjo="}' >"$WARP_CONF_FILE"
set_rules '[{type:"all",outbound:"chain:landing",ip_version:"prefer_ipv6"}]'
generate_mihomo_config
check 'any(.proxies[]; .type=="wireguard" and .server=="2606:4700:d0::1" and .ip=="172.16.0.2")'
check 'any(.proxies[]; .["dialer-proxy"]=="warp-as_is") and .rules[0]=="DOMAIN,engage.cloudflareclient.com,DIRECT"'
real_check
printf '%s\n' 'ok - WGCF IPv6 endpoint and WARP dialer'

# 候选数据库必须作为唯一数据源，不得读生产 DB 中的同名旧节点。
jq '.chain_proxy.nodes[0].port=2080' "$DB_FILE" >"$TMP/candidate-db"
generate_mihomo_config "$TMP/candidate-db" "$TMP/candidate-config"
jq -e 'any(.proxies[]; .type=="socks5" and .port==2080)' "$TMP/candidate-config" >/dev/null
printf '%s\n' 'ok - candidate database isolation'

fixture
set_rules '[{type:"custom",outbound:"block",domains:"blocked.example",ip_version:"as_is"},
 {type:"custom",outbound:"chain:landing",domains:"landing.example",ip_version:"as_is"}]'
generate_mihomo_config
if [[ -n "$REAL_BIN" ]]; then
    python3 "$ROOT/tests/test-mihomo-routing-runtime.py" "$REAL_BIN" "$MIHOMO_CONFIG"
fi

set_rules '[{type:"all",outbound:"chain:missing",ip_version:"as_is"}]'
cp "$MIHOMO_CONFIG" "$TMP/previous"
if generate_mihomo_config 2>"$TMP/error"; then exit 1; fi
cmp "$MIHOMO_CONFIG" "$TMP/previous"
printf '%s\n' 'ok - missing outbound rejects generation without overwriting config'

fixture
set_rules '[{type:"all",outbound:"direct",ip_version:"as_is"}]'
get_xray_protocols() { :; }
get_singbox_protocols() { :; }
get_mihomo_protocols() { printf '%s\n' snell; }
_wait_for_mihomo_ready() { return 0; }
validate_mihomo_config() { jq -e 'any(.rules[]; .=="MATCH,direct-as_is")' "$1" >/dev/null; }
svc() { printf '%s %s\n' "$1" "$2" >>"$TMP/services"; }
_regenerate_proxy_configs
[[ "$(<"$TMP/services")" == 'restart vless-mihomo' ]]
printf '%s\n' 'ok - routing changes regenerate and restart Mihomo'

cp "$MIHOMO_CONFIG" "$TMP/previous"
set_rules '[{type:"all",outbound:"direct",ip_version:"ipv6_only"}]'
validate_mihomo_config() { return 1; }
if _regenerate_proxy_configs 2>"$TMP/error"; then exit 1; fi
cmp "$MIHOMO_CONFIG" "$TMP/previous"
[[ "$(wc -l <"$TMP/services")" -eq 1 ]]
printf '%s\n' 'ok - validation failure preserves active config and does not restart'

# 配置可通过 -t 且服务健康，也必须同步旧版本写死的全部直连规则。
fixture
set_rules '[{type:"custom",outbound:"block",domains:"blocked.example",ip_version:"as_is"}]'
generate_mihomo_config
jq '.rules=["MATCH,DIRECT"] | .proxies=[]' "$MIHOMO_CONFIG" >"$TMP/old"
mv "$TMP/old" "$MIHOMO_CONFIG"
printf '#!/bin/sh\nexit 0\n' >"$MIHOMO_BIN"
chmod 700 "$MIHOMO_BIN"
get_mihomo_runtime_protocols() { printf '%s\n' snell; }
is_paused() { return 1; }
_mihomo_ports_healthy() { return 0; }
validate_mihomo_config() { return 0; }
svc() { printf '%s %s\n' "$1" "$2" >>"$TMP/services"; }
ensure_mihomo_runtime_consistency
check '.rules[0]=="DOMAIN-SUFFIX,blocked.example,REJECT"'
printf '%s\n' 'ok - healthy legacy direct-only configuration is synchronized on startup'

cp "$MIHOMO_CONFIG" "$TMP/previous"
set_rules '[{type:"all",outbound:"direct",ip_version:"ipv6_only"}]'
svc() {
    if [[ ! -f "$TMP/restart-failed" ]]; then touch "$TMP/restart-failed"; return 1; fi
    return 0
}
if _regenerate_proxy_configs; then exit 1; fi
cmp "$MIHOMO_CONFIG" "$TMP/previous"
printf '%s\n' 'ok - restart failure restores old configuration'

svc() { return 0; }
_wait_for_mihomo_ready() {
    if [[ ! -f "$TMP/ready-failed" ]]; then touch "$TMP/ready-failed"; return 1; fi
    return 0
}
if _regenerate_proxy_configs; then exit 1; fi
cmp "$MIHOMO_CONFIG" "$TMP/previous"
printf '%s\n' 'ok - asynchronous startup failure also restores old configuration'

fixture
printf '%s\n' prefer_ipv6 >"$CFG/direct_ip_version"
generate_mihomo_config
check '.rules==["MATCH,direct-default"] and .proxies[0]."ip-version"=="ipv6-prefer"'
real_check
printf '%s\n' 'ok - default direct IP preference is applied without routing rules'

fixture
rm -f "$CFG/direct_ip_version"
jq '.chain_proxy.nodes=[
 {name:"landing:1",type:"socks",server:"127.0.0.1",port:1080},
 {name:"landing-1",type:"socks",server:"127.0.0.1",port:2080}]' "$DB_FILE" >"$TMP/db"
mv "$TMP/db" "$DB_FILE"
set_rules '[{type:"custom",domains:"one.example",outbound:"chain:landing:1",ip_version:"as_is"},
 {type:"custom",domains:"two.example",outbound:"chain:landing-1",ip_version:"as_is"}]'
generate_mihomo_config
check '(.proxies|length)==2 and .rules[0]=="DOMAIN-SUFFIX,one.example,chain-landing:1-as_is"'
real_check
printf '%s\n' 'ok - colon-containing node names do not collide with hyphenated names'

# 非 none 的 VLESS encryption 必须保留，不能生成可校验但无法连接的普通 VLESS。
fixture
jq '.chain_proxy.nodes=[{name:"encrypted",type:"vless",server:"127.0.0.1",port:1080,
 uuid:"11111111-1111-4111-8111-111111111111",encryption:"test-encryption",security:"none"}]' "$DB_FILE" >"$TMP/db"
mv "$TMP/db" "$DB_FILE"
gen_mihomo_chain_outbound encrypted encrypted dual >"$TMP/outbound"
jq -e '.encryption=="test-encryption"' "$TMP/outbound" >/dev/null
printf '%s\n' 'ok - VLESS encryption is not silently discarded'

if [[ -z "$REAL_BIN" ]]; then printf '%s\n' 'skip - real kernel validation (set VLESS_TEST_MIHOMO_BIN)'; fi
