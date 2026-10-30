#!/usr/bin/env bash
# Offline Instagram source, candidate configuration and shared-core routing regressions.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap '[[ ! -s "$TMP/check-error" ]] || cat "$TMP/check-error" >&2; rm -rf "$TMP"' EXIT
export VLESS_TEST_CFG="$TMP/etc"
export VLESS_TEST_SYSTEMD_DIR="$TMP/systemd"
export VLESS_TEST_OPENRC_DIR="$TMP/openrc"
mkdir -p "$VLESS_TEST_CFG" "$VLESS_TEST_SYSTEMD_DIR" "$VLESS_TEST_OPENRC_DIR"
REAL_BIN="${VLESS_TEST_SINGBOX_BIN:-}"
source "$ROOT/vless-server.sh"
_log() { :; }; _header() { :; }; _line() { :; }; _pause() { :; }
_listen_addr() { printf '%s\n' 127.0.0.1; }
svc() { printf 'unexpected service operation: %s\n' "$*" >&2; return 1; }
systemctl() { printf 'unexpected systemctl: %s\n' "$*" >&2; return 1; }
sing-box() {
    if [[ -n "$REAL_BIN" ]]; then
        if [[ "$1" == check ]]; then
            "$REAL_BIN" "$@" >"$TMP/check-error" 2>&1
            return $?
        fi
        "$REAL_BIN" "$@"; return $?
    fi
    case "$1" in
        version) printf '%s\n' 'sing-box version 1.14.3' ;;
        check) jq empty "$3" ;;
        rule-set) cp "$3" "$5" ;;
        *) return 1 ;;
    esac
}
# Keep the actual parser/cache code under test. The transport never uses DNS.
CURL_FAIL=false
curl() {
    local output='' url=''
    while (($#)); do
        case "$1" in
            -o) output="$2"; shift 2 ;;
            --connect-timeout|--max-time) shift 2 ;;
            -*) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    printf '%s\n' "$url" >>"$TMP/downloads"
    [[ "$url" == https://raw.githubusercontent.com/Yuu518/Yuu-rules/rule-set/mihomo/geosite/instagram.list ]] || {
        printf 'unexpected download: %s\n' "$url" >&2; return 1;
    }
    [[ "$CURL_FAIL" == false && "$output" == "$CFG/"* ]] || return 1
    cp "$TMP/instagram.list" "$output"
}
write_source() {
    # The upstream source uses +.domain lines. Include CRLF, comments and a
    # duplicate to verify the conversion rather than pre-seeding parsed JSON.
    printf '# fixture\r\n+.instagram.com\r\n+.cdninstagram.com\n+.ig.me\n+.instagram.com\n' >"$TMP/instagram.list"
}
write_source
domains=$(_load_yuu_instagram_domains)
[[ "$domains" == cdninstagram.com,ig.me,instagram.com ]]
[[ "$(stat -c %a "$CFG/yuu-instagram-domains.json")" == 600 ]]
jq -e '.==["cdninstagram.com","ig.me","instagram.com"]' "$CFG/yuu-instagram-domains.json" >/dev/null
_load_yuu_instagram_domains >"$TMP/cached"
[[ "$(wc -l <"$TMP/downloads")" == 1 ]]
touch -t 200001010000 "$CFG/yuu-instagram-domains.json"
CURL_FAIL=true
[[ "$(_load_yuu_instagram_domains 2>"$TMP/cache-error")" == "$domains" ]]
CURL_FAIL=false
cp "$CFG/yuu-instagram-domains.json" "$TMP/good-cache"
printf '%s\n' 'DOMAIN-SUFFIX,instagram.com' >"$TMP/instagram.list"
[[ "$(_load_yuu_instagram_domains 2>"$TMP/cache-error")" == "$domains" ]]
cmp "$CFG/yuu-instagram-domains.json" "$TMP/good-cache"
rm "$CFG/yuu-instagram-domains.json"
if _load_yuu_instagram_domains >"$TMP/invalid" 2>"$TMP/error"; then exit 1; fi
[[ ! -e "$CFG/yuu-instagram-domains.json" ]]
write_source
_load_yuu_instagram_domains >"$TMP/domains"
printf '%s\n' 'ok - Yuu list source, wildcard conversion, cache permissions, offline fallback and invalid-source rejection'

fixture() {
    jq -n '{xray:{},singbox:{
        snell:[{port:43001,psk:"numeric0123456789",version:4},{port:43002,psk:"legacy+/=._-key",version:4}],
        "snell-v5":{port:43003,psk:"numeric0123456789",version:5},
        "snell-shadowtls":{port:43004,psk:"numeric0123456789",version:4,sni:"www.example.com",stls_password:"tlsFixtureOnly"},
        "snell-v5-shadowtls":[{port:43005,psk:"numeric0123456789",version:5,sni:"www.example.com",stls_password:"tlsFixtureOnly"}],
        "snell-v6-singbox":[{port:43006,psk:"numeric0123456789",version:6,mode:"unshaped"}],
        hy2:{port:43007,password:"hy2FixtureOnly",sni:"fixture.example"}},
        chain_proxy:{nodes:[{name:"landing",type:"socks",server:"127.0.0.1",port:1080,username:"fixture",password:"quote\"pass"}]},
        routing_rules:[]}' >"$DB_FILE"
}
check() { jq -e "$1" "$CFG/singbox.json" >/dev/null; }
assert_sniff_first() {
    jq -e '
        .route.rules[0]=={action:"sniff"} and
        ([.route.rules[] | select(.action=="sniff")] | length)==1
    ' "$1" >/dev/null
}
set_rules() {
    local rules
    rules=$(jq -nc "$1") || return 1
    jq --argjson rules "$rules" '.routing_rules=$rules' "$DB_FILE" >"$TMP/db"
    mv "$TMP/db" "$DB_FILE"
}
expected='["snell-snell-43001","snell-snell-43002","snell-snell-shadowtls-43004","snell-snell-v5-43003","snell-snell-v5-shadowtls-43005"]'
assert_scope() {
    jq -e --argjson expected "$expected" '
        [.[] | select((.domain_suffix // []) | index("instagram.com"))] as $instagram |
        ($instagram | length) > 0 and
        all($instagram[]; (.inbound | sort)==$expected and (.inbound | length)==5) and
        all(.[] | select((.domain_suffix // []) | index("safe.example")); .inbound==null)
    ' "$1" >/dev/null
}
# Certificates stay in the temporary fixture; no installation or service calls.
mkdir -p "$CFG/certs/hy2"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj /CN=fixture.example -keyout "$CFG/certs/hy2/server.key" \
    -out "$CFG/certs/hy2/server.crt" >/dev/null 2>&1

for family in as_is ipv4_only ipv6_only; do
    fixture
    rules=$(jq -nc --arg type singbox-instagram --arg family "$family" '[
        {type:$type,outbound:"chain:landing",domains:"rule-set:yuu-instagram",ip_version:$family},
        {type:"custom",outbound:"direct",domains:"safe.example",ip_version:"as_is"}]')
    set_rules "$rules"
    [[ "$(db_get_routing_rules xray | jq length)" == 1 ]]
    [[ "$(db_get_routing_rules singbox | jq length)" == 2 ]]
    gen_singbox_routing_rules >"$TMP/rules"
    assert_scope "$TMP/rules"
    if [[ "$family" != as_is ]]; then
        cidr=0.0.0.0/0
        [[ "$family" != ipv6_only ]] || cidr=::/0
        jq -e --arg cidr "$cidr" 'all(.[] | select((.domain_suffix // []) | index("instagram.com")); .ip_cidr==[$cidr])' "$TMP/rules" >/dev/null
    fi
    generate_singbox_config
    assert_sniff_first "$CFG/singbox.json"
    jq '.route.rules' "$CFG/singbox.json" >"$TMP/generated-rules"
    assert_scope "$TMP/generated-rules"
    # Match tags from generated inbounds, including detour targets, and
    # reject accidental application to TLS frontends, v6 or Hy2 listeners.
    jq -e --argjson expected "$expected" '.inbounds as $all |
        all($expected[]; . as $tag | any($all[]; .tag==$tag and .type=="snell" and .version==5)) and
        any($all[]; .type=="snell" and .version==6 and .mode=="unshaped") and
        any($all[]; .type=="hysteria2")' "$CFG/singbox.json" >/dev/null
    check 'any(.outbounds[]; .type=="socks" and .password=="quote\"pass")'
done
printf '%s\n' 'ok - Instagram rules target all v4/v5 ports and detours, isolate v6/Hy2, and retain IP family filters'

# A configuration candidate must use its own listener set and chain credentials.
# The active database intentionally has no v4/v5 Snell targets and a different
# landing port; accidentally consulting it would omit scope or use port 2080.
fixture
set_rules "$(jq -nc --arg type singbox-instagram '[{type:$type,outbound:"chain:landing",domains:"rule-set:yuu-instagram",ip_version:"as_is"},{type:"custom",outbound:"direct",domains:"safe.example",ip_version:"as_is"}]')"
cp "$DB_FILE" "$TMP/candidate-db"
jq '.chain_proxy.nodes[0].port=2080 |
    .singbox |= del(.snell,."snell-v5",."snell-shadowtls",."snell-v5-shadowtls")' "$DB_FILE" >"$TMP/active-db"
mv "$TMP/active-db" "$DB_FILE"
cp "$DB_FILE" "$TMP/active-before"
generate_singbox_config "$TMP/candidate-config" "$TMP/candidate-db"
assert_sniff_first "$TMP/candidate-config"
cmp "$DB_FILE" "$TMP/active-before"
jq '.route.rules' "$TMP/candidate-config" >"$TMP/candidate-rules"
assert_scope "$TMP/candidate-rules"
jq -e 'any(.outbounds[]; .type=="socks" and .server_port==1080)' "$TMP/candidate-config" >/dev/null
# Stale Instagram rules cannot collect a missing chain or affect other
# shared listeners after the last v4/v5 listener has been removed.
jq '.chain_proxy.nodes=[]' "$DB_FILE" >"$TMP/db"
mv "$TMP/db" "$DB_FILE"
generate_singbox_config
assert_sniff_first "$CFG/singbox.json"
check 'all(.route.rules[]; ((.domain_suffix // []) | index("instagram.com"))==null) and
    all(.outbounds[]; ((.tag // "") | startswith("chain-")) | not)'
[[ "$(db_get_routing_rules | jq length)" == 2 ]]
[[ "$(db_get_routing_rules singbox | jq length)" == 1 ]]
printf '%s\n' 'ok - Instagram rules use candidate tags/credentials and become inert without v4/v5'

# Shared domains and CIDRs retain their original global scope and fallback.
fixture
set_rules '[{type:"custom",outbound:"block",domains:"bad.example,203.0.113.1,2001:db8::1",ip_version:"as_is"},
    {type:"custom",outbound:"chain:landing",domains:"proxy.example,198.51.100.0/24",ip_version:"ipv4_only"}]'
generate_singbox_config
check '.route.final=="direct" and all(.route.rules[] | select(.action!="sniff"); .inbound==null) and
    any(.route.rules[]; .domain_suffix==["bad.example"] and .outbound=="block") and
    any(.route.rules[]; .ip_cidr==["203.0.113.1","2001:db8::1"] and .outbound=="block") and
    any(.route.rules[]; .domain_suffix==["proxy.example"] and .ip_cidr==["0.0.0.0/0"])'
cp "$CFG/singbox.json" "$TMP/before-config"
set_rules '[{type:"all",outbound:"chain:missing",ip_version:"as_is"}]'
if generate_singbox_config 2>"$TMP/error"; then exit 1; fi
cmp "$CFG/singbox.json" "$TMP/before-config"
printf '%s\n' 'ok - shared domain/IP routing remains global and missing outbounds preserve the active configuration'

fixture
jq '.chain_proxy.nodes=[
    {name:"landing:1",type:"socks",server:"127.0.0.1",port:1080},
    {name:"landing-1",type:"socks",server:"127.0.0.1",port:2080}]' "$DB_FILE" >"$TMP/db"
mv "$TMP/db" "$DB_FILE"
set_rules '[{type:"custom",domains:"one.example",outbound:"chain:landing:1",ip_version:"as_is"},
    {type:"custom",domains:"two.example",outbound:"chain:landing-1",ip_version:"as_is"}]'
generate_singbox_config
check '[.outbounds[] | select(.type=="socks") | .server_port] | sort==[1080,2080]'
check '[.route.rules[] | select(.domain_suffix==["one.example"] or .domain_suffix==["two.example"]) | .outbound] | unique | length==2'
printf '%s\n' 'ok - distinct chain names retain separate targets'

# The current Instagram menu must add/remove only the Sing-box rule and reload.
(
    fixture
    _select_outbound() { printf '%s\n' chain:landing; }
    _regenerate_singbox_routing_config() {
        printf '%s\n' singbox >>"$TMP/menu-reloads"
        generate_singbox_config
    }
    _add_routing_rule <<<$'i\n3' >"$TMP/menu-add"
    jq -e '.routing_rules | length==1 and .[0].type=="singbox-instagram"' "$DB_FILE" >/dev/null
    jq '.route.rules' "$CFG/singbox.json" >"$TMP/menu-rules"
    assert_scope "$TMP/menu-rules"
    _del_routing_rule <<<1 >"$TMP/menu-delete"
    jq -e '.routing_rules | length==0' "$DB_FILE" >/dev/null
    [[ "$(wc -l <"$TMP/menu-reloads")" == 2 ]]
)
printf '%s\n' 'ok - Instagram add/delete menus use the current rule key and reload Sing-box only'
