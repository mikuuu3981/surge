#!/usr/bin/env bash
# 仅临时数据库/配置；可选真实内核测试需要预下载的 Instagram MRS 文件。
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL_BIN="${VLESS_TEST_MIHOMO_BIN:-}"
MRS_FIXTURE="${VLESS_TEST_INSTAGRAM_MRS:-}"
export VLESS_TEST_CFG="$TMP/etc"
export VLESS_TEST_MIHOMO_BIN="$TMP/bin/mihomo"
mkdir -p "$VLESS_TEST_CFG" "$TMP/bin"
source "$ROOT/vless-server.sh"
_listen_addr() { printf '%s\n' 127.0.0.1; }
_header() { :; }
_line() { :; }
_pause() { :; }
_info() { :; }
_ok() { :; }
_warn() { printf '%s\n' "$*"; }
_item() { printf '%s %s\n' "$1" "$2"; }
_select_outbound() { printf '%s\n' chain:landing; }
_get_outbound_display_name() { printf '%s\n' "$1"; }

fixture() {
    jq -n '{xray:{},singbox:{},mihomo:{snell:[{port:41001,psk:"test-only",version:4}]},
        chain_proxy:{nodes:[{name:"landing",type:"socks",server:"127.0.0.1",port:1080}]}}' >"$DB_FILE"
}
check() { jq -e "$1" "$MIHOMO_CONFIG" >/dev/null; }
real_check() {
    if [[ -n "$REAL_BIN" ]]; then
        "$REAL_BIN" -t -d "$CFG" -f "$MIHOMO_CONFIG" >"$TMP/validate.log" 2>&1 || {
            while IFS= read -r line; do printf '%s\n' "$line" >&2; done <"$TMP/validate.log"
            return 1
        }
    fi
}

fixture
db_add_routing_rule mihomo-instagram chain:landing '' as_is
generate_mihomo_config
check '.rules==["RULE-SET,yuu-instagram,chain-landing-as_is","MATCH,DIRECT"]'
check '."rule-providers"."yuu-instagram" == {
 type:"http",behavior:"domain",format:"mrs",path:"./rule-providers/yuu-instagram.mrs",
 url:"https://raw.githubusercontent.com/Yuu518/Yuu-rules/rule-set/mihomo/geosite/instagram.mrs",
 interval:86400,proxy:"DIRECT"}'
check 'has("geodata-mode") | not'
[[ "$(db_get_routing_rules xray)" == '[]' ]]
[[ "$(db_get_routing_rules singbox)" == '[]' ]]
[[ -z "$(gen_xray_routing_rules || :)" ]]
[[ -z "$(gen_singbox_routing_rules || :)" ]]
[[ "$(db_get_routing_rules | jq length)" -eq 1 ]]
real_check
printf '%s\n' 'ok - Instagram uses remote domain MRS only in Mihomo, not Xray/Sing-box'

if [[ -n "$REAL_BIN" && -n "$MRS_FIXTURE" ]]; then
    mkdir -p "$CFG/rule-providers"
    cp "$MRS_FIXTURE" "$CFG/rule-providers/yuu-instagram.mrs"
    db_add_routing_rule custom block blocked.example as_is
    generate_mihomo_config
    python3 "$ROOT/tests/test-mihomo-routing-runtime.py" "$REAL_BIN" "$MIHOMO_CONFIG" \
        www.instagram.com scontent.cdninstagram.com ig.me
else
    printf '%s\n' 'skip - Instagram MRS live traffic (set VLESS_TEST_MIHOMO_BIN and VLESS_TEST_INSTAGRAM_MRS)'
fi

for version in ipv4_only ipv6_only; do
    db_add_routing_rule mihomo-instagram chain:landing '' "$version"
    generate_mihomo_config
    family=IP-CIDR,0.0.0.0/0
    [[ "$version" != ipv6_only ]] || family=IP-CIDR6,::/0
    jq -e --arg expected "AND,((RULE-SET,yuu-instagram),($family)),chain-landing-$version" \
        '.rules | index($expected) != null' "$MIHOMO_CONFIG" >/dev/null
    check 'has("rule-providers")'
    real_check
done
printf '%s\n' 'ok - scoped IPv4/IPv6 rules retain their provider'

# 普通全局规则仍然进入三个内核；专属规则的出口不会被其他内核收集。
fixture
db_add_routing_rule mihomo-instagram chain:landing '' as_is
db_add_routing_rule custom direct safe.example as_is
db_add_routing_rule all direct '' as_is
[[ "$(db_get_routing_rules xray | jq length)" -eq 2 ]]
[[ "$(db_get_routing_rules singbox | jq length)" -eq 2 ]]
generate_mihomo_config
check '.rules==["DOMAIN-SUFFIX,safe.example,direct-as_is",
 "RULE-SET,yuu-instagram,chain-landing-as_is","MATCH,direct-as_is","MATCH,DIRECT"]'
xray=$(gen_xray_routing_rules)
singbox=$(gen_singbox_routing_rules)
jq -e 'any(.[]; .domain==["domain:safe.example"]) and
 all(.[]; .outboundTag | startswith("chain-") | not)' <<<"$xray" >/dev/null
jq -e 'any(.[]; .domain_suffix==["safe.example"]) and
 all(.[]; .outbound | startswith("chain-") | not)' <<<"$singbox" >/dev/null
printf '%s\n' 'ok - shared rules keep original behavior while Instagram remains scoped'

jq '.routing_rules=[]' "$DB_FILE" >"$TMP/candidate-db"
generate_mihomo_config "$TMP/candidate-db" "$TMP/candidate-config"
jq -e 'has("rule-providers") | not' "$TMP/candidate-config" >/dev/null
printf '%s\n' 'ok - provider generation uses candidate DB, not production DB'

db_del_routing_rule mihomo-instagram by_type
generate_mihomo_config
check 'has("rule-providers") | not'
printf '%s\n' 'ok - removing Instagram removes the unused provider'

# 菜单在无 Mihomo 安装时不展示/不接受专属选项，也不修改数据库。
(
    fixture
    get_mihomo_protocols() { :; }
    _regenerate_proxy_configs() { printf shared >>"$TMP/regenerate"; }
    _regenerate_mihomo_routing_config() { printf mihomo >>"$TMP/regenerate"; }
    cp "$DB_FILE" "$TMP/before"
    if ! _add_routing_rule <<<'i' >"$TMP/menu"; then exit 1; fi
    ! grep -q '^i ' "$TMP/menu"
    grep -q '请先安装 Mihomo 协议' "$TMP/menu"
    cmp "$TMP/before" "$DB_FILE"
    [[ ! -f "$TMP/regenerate" ]]
    # 卸载 Mihomo 后留下的专属规则仍可删除，不应启动任何内核。
    db_add_routing_rule mihomo-instagram chain:landing '' as_is
    _del_routing_rule <<<'1' >"$TMP/menu" || exit 1
    [[ "$(db_get_routing_rules)" == '[]' && ! -f "$TMP/regenerate" ]]
)
printf '%s\n' 'ok - Instagram requires Mihomo, but stale rules can be removed without it'

# 添加、覆盖和删除仅重建 Mihomo；节点/全局规则优先级保持不变。
(
    fixture
    get_mihomo_protocols() { printf '%s\n' snell; }
    _regenerate_proxy_configs() { printf '%s\n' shared >>"$TMP/regenerate"; }
    _regenerate_mihomo_routing_config() { printf '%s\n' mihomo >>"$TMP/regenerate"; }
    _add_routing_rule <<<$'i\n3' >"$TMP/menu" || exit 1
    grep -q '^i Instagram/INS (仅 Mihomo)' "$TMP/menu"
    jq -e '.routing_rules[0].type=="mihomo-instagram" and .routing_rules[0].outbound=="chain:landing"' "$DB_FILE" >/dev/null
    _add_routing_rule <<<$'I\n1\ny' >"$TMP/menu" || exit 1
    jq -e '(.routing_rules|length)==1 and .routing_rules[0].ip_version=="ipv4_only"' "$DB_FILE" >/dev/null
    _del_routing_rule <<<'1' >"$TMP/menu" || exit 1
    [[ "$(db_get_routing_rules)" == '[]' ]]
    [[ "$(<"$TMP/regenerate")" == $'mihomo\nmihomo\nmihomo' ]]
)
printf '%s\n' 'ok - Instagram add/overwrite/delete regenerate Mihomo only'
