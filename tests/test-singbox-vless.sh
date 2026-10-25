#!/usr/bin/env bash
# 临时数据库与配置；不安装软件、不访问真实服务或防火墙。
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/singbox-vless.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export VLESS_TEST_CFG="$TMP/etc"
export VLESS_TEST_SYSTEMD_DIR="$TMP/systemd"
export VLESS_TEST_OPENRC_DIR="$TMP/openrc"
mkdir -p "$VLESS_TEST_CFG" "$VLESS_TEST_SYSTEMD_DIR" "$VLESS_TEST_OPENRC_DIR"
source "$ROOT/vless-server.sh"
_log() { :; }
_listen_addr() { printf '%s\n' 127.0.0.1; }
get_connection_addresses() { printf '%s\n' '192.0.2.1|2001:db8::1'; }
get_ip_country() { printf '%s\n' TEST; }
_header() { :; }
_pause() { :; }
svc() { printf 'unexpected service call: %s\n' "$*" >&2; return 1; }
systemctl() { return 1; }
rc-service() { return 1; }
_ensure_nginx_https_for_reality() { printf '%s\n' "$1" >>"$TMP/nginx-domains"; }
sing-box() {
    if [[ -n "${VLESS_TEST_SINGBOX_BIN:-}" ]]; then "$VLESS_TEST_SINGBOX_BIN" "$@"; return $?; fi
    case "$1" in
        version) printf '%s\n' 'sing-box version 1.14.3' ;;
        check) jq empty "$3" ;;
        *) return 1 ;;
    esac
}
check() { jq -e "$1" "$CFG/singbox.json" >/dev/null; }
rewrite_db() { jq "$1" "$DB_FILE" >"$TMP/db.json"; mv "$TMP/db.json" "$DB_FILE"; }
unchanged_xray() { jq -S '.xray' "$DB_FILE" >"$TMP/current-xray"; cmp "$TMP/xray" "$TMP/current-xray"; }
no_fallback_limits() {
    jq -e '[.singbox | .. | objects | has("reality_fallback_limits")] | all(. == false)' "$DB_FILE" >/dev/null
    check '[.. | objects | keys[] | select(test("reality_fallback_limits|limitFallback|fallback_limits"))] | length == 0'
}

# 当前入口名为 select_vless_reality_implementation；保留对简化入口名的兼容。
SELECT_VLESS_IMPLEMENTATION=select_vless_reality_implementation
if declare -F select_vless_implementation >/dev/null; then
    SELECT_VLESS_IMPLEMENTATION=select_vless_implementation
fi
"$SELECT_VLESS_IMPLEMENTATION" <<<'' >"$TMP/selection"
[[ "$SELECTED_PROTOCOL" == vless ]]
"$SELECT_VLESS_IMPLEMENTATION" <<<2 >"$TMP/selection"
[[ "$SELECTED_PROTOCOL" == vless-singbox ]]
if "$SELECT_VLESS_IMPLEMENTATION" <<<0 >"$TMP/selection"; then
    printf '%s\n' 'return choice unexpectedly succeeded' >&2
    exit 1
fi
[[ -z "$SELECTED_PROTOCOL" ]]
printf '%s\n' 'ok - implementation selector defaults to Xray, selects Sing-box and returns'

(
    _apply_singbox_vless_config() { printf '%s\n' "$1" >"$TMP/generated-record"; }
    for sid in 00123456 12345678; do
        rm -f "$TMP/generated-record"
        gen_vless_singbox_server_config 00000000-0000-4000-8000-000000000002 \
            42001 test-private test-public "$sid" vision.example
        jq -e --arg sid "$sid" '.port==42001 and .uuid=="00000000-0000-4000-8000-000000000002" and
            .private_key=="test-private" and .public_key=="test-public" and .sni=="vision.example" and
            .security_mode=="reality" and .short_id==$sid and (.short_id|type)=="string" and
            ([..|objects|keys[]|select(test("reality_fallback_limits|limitFallback"))]|length)==0' \
            "$TMP/generated-record" >/dev/null
    done
    _apply_singbox_vless_config() { return 1; }
    if gen_vless_singbox_server_config test-uuid 42001 test-private test-public 00123456 vision.example; then
        printf '%s\n' 'generator ignored failed transaction' >&2
        exit 1
    fi
)
printf '%s\n' 'ok - generator dispatches transaction records with string short IDs and no fallback fields'

# 合成密钥用于离线配置校验，IP 使用文档保留地址。
jq -n '{xray:{vless:{port:42000,uuid:"00000000-0000-4000-8000-000000000001",
    private_key:"eCtXsJZ27-4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU",
    public_key:"Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo",short_id:"0123456789abcdef",
    sni:"xray.example",security_mode:"reality"}},singbox:{},mihomo:{}} |
    .singbox["vless-singbox"]=(.xray.vless | .port=42001 | .sni="vision.example" |
        .uuid="00000000-0000-4000-8000-000000000002")' >"$DB_FILE"
db_migrate_reality_fallback_limits
jq -e '.xray.vless.reality_fallback_limits != null and
    (.singbox["vless-singbox"] | has("reality_fallback_limits") | not)' "$DB_FILE" >/dev/null
jq -S '.xray' "$DB_FILE" >"$TMP/xray"
[[ "$(protocol_core vless-singbox)" == singbox && "$(protocol_core vless)" == xray ]]
[[ "${PROTO_SVC[vless-singbox]}" == vless-singbox && "${PROTO_BIN[vless-singbox]}" == sing-box ]]
generate_singbox_config
check '(.inbounds | length)==1 and .inbounds[0].type=="vless" and
    .inbounds[0].listen_port==42001 and .inbounds[0].listen=="127.0.0.1" and
    .inbounds[0].users==[{name:"vless-singbox-default",uuid:"00000000-0000-4000-8000-000000000002",flow:"xtls-rprx-vision"}] and
    .inbounds[0].tls.enabled==true and .inbounds[0].tls.server_name=="vision.example" and
    .inbounds[0].tls.reality.enabled==true and
    .inbounds[0].tls.reality.handshake=={server:"vision.example",server_port:443} and
    .inbounds[0].tls.reality.short_id==["0123456789abcdef"] and
    .inbounds[0].tls.reality.private_key=="eCtXsJZ27-4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU"'
no_fallback_limits
unchanged_xray
printf '%s\n' 'ok - object fixture, Vision flow, remote handshake and Xray-only fallback limits'

rewrite_db '.singbox["vless-singbox"] as $first |
    .singbox["vless-singbox"]=[$first,($first | .port=42002 | .sni="second.example" |
        .uuid="00000000-0000-4000-8000-000000000003" | del(.users))] |
    .singbox["snell-v6-singbox"]={port:42003,psk:"testOnly1234567890",version:6,mode:"default"}'
generate_singbox_config
check '(.inbounds|length)==3 and ([.inbounds[].tag]|unique|length)==3 and
    ([.inbounds[]|select(.type=="vless")|.listen_port]|sort)==[42001,42002] and
    any(.inbounds[]; .listen_port==42002 and .users[0].uuid=="00000000-0000-4000-8000-000000000003" and
        .tls.reality.handshake.server=="second.example") and any(.inbounds[];.type=="snell" and .listen_port==42003)'
[[ "$(is_internal_port_occupied 42000)" == vless && "$(is_internal_port_occupied 42002)" == vless-singbox ]]
unchanged_xray
printf '%s\n' 'ok - independent Xray, two VLESS ports and shared Snell listener coexist'

db_add_user singbox vless-singbox alice 00000000-0000-4000-8000-000000000004 0
generate_singbox_config
check 'any(.inbounds[]|select(.listen_port==42001)|.users[]; .uuid=="00000000-0000-4000-8000-000000000004" and .flow=="xtls-rprx-vision")'
db_set_user_enabled singbox vless-singbox alice false
check 'all(.inbounds[]|select(.type=="vless")|.users[]; .uuid!="00000000-0000-4000-8000-000000000004")'
db_set_user_enabled singbox vless-singbox alice true
check 'any(.inbounds[]|select(.listen_port==42001)|.users[]; .uuid=="00000000-0000-4000-8000-000000000004")'
db_del_user singbox vless-singbox alice
generate_singbox_config
check 'all(.inbounds[]|select(.type=="vless")|.users[]; .uuid!="00000000-0000-4000-8000-000000000004")'
unchanged_xray
printf '%s\n' 'ok - user add, disable, enable and delete rebuild Sing-box credentials'

gen_v2ray_sub | base64 -d >"$TMP/v2ray"
gen_clash_sub >"$TMP/clash"
show_all_share_links >"$TMP/links"
for port in 42000 42001 42002; do
    grep -q ":$port?" "$TMP/v2ray"
    grep -q "$port" "$TMP/clash"
    grep -q ":$port?" "$TMP/links"
done
grep -q '@\[2001:db8::1\]:42001?' "$TMP/links"
grep -q '@\[2001:db8::1\]:42002?' "$TMP/links"
python3 - "$TMP/v2ray" "$TMP/clash" <<'PY'
import sys
from urllib.parse import parse_qs, urlsplit
links = [urlsplit(line) for line in open(sys.argv[1]).read().splitlines() if line.startswith('vless://')]
assert len(links) == 3, links
for port, uuid, sni in [(42000, '00000000-0000-4000-8000-000000000001', 'xray.example'),
                        (42001, '00000000-0000-4000-8000-000000000002', 'vision.example'),
                        (42002, '00000000-0000-4000-8000-000000000003', 'second.example')]:
    link, = [link for link in links if link.port == port]
    query = parse_qs(link.query)
    assert link.username == uuid
    for key, value in [('security', 'reality'), ('flow', 'xtls-rprx-vision'), ('sni', sni),
                       ('pbk', 'Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo'), ('sid', '0123456789abcdef')]:
        assert query.get(key) == [value], (port, key, query)
clash = open(sys.argv[2]).read()
assert clash.count('type: vless') == 3, clash
assert clash.count('xtls-rprx-vision') == 3, clash
PY
_gen_user_share_link singbox vless-singbox 00000000-0000-4000-8000-000000000004 alice >"$TMP/user-links"
grep -q 'vless://00000000-0000-4000-8000-000000000004@192.0.2.1:42001?' "$TMP/user-links"
printf '%s\n' 'ok - generic/Clash subscriptions, IPv4/IPv6 all-port sharing and user credentials'

printf '%s\n' vision.example >"$CFG/cert_domain"
_is_real_cert() { return 0; }
generate_singbox_config
check 'any(.inbounds[]; .listen_port==42001 and .tls.reality.handshake=={server:"127.0.0.1",server_port:8443}) and
    any(.inbounds[]; .listen_port==42002 and .tls.reality.handshake=={server:"second.example",server_port:443})'
grep -qx vision.example "$TMP/nginx-domains"
rm -f "$TMP/nginx-domains"
_is_real_cert() { return 1; }
generate_singbox_config
check 'any(.inbounds[]; .listen_port==42001 and .tls.reality.handshake=={server:"vision.example",server_port:443})'
[[ ! -f "$TMP/nginx-domains" ]]
db_migrate_reality_fallback_limits
no_fallback_limits
unchanged_xray
sing-box check -c "$CFG/singbox.json"
printf '%s\n' 'ok - matching real certificate selects local 8443; other/self-signed domains keep remote 443'

rewrite_db '.singbox["vless-singbox"] |= map(select(.port!=42001))'
generate_singbox_config
check '(.inbounds|length)==2 and any(.inbounds[];.type=="vless" and .listen_port==42002 and
    .users[0].uuid=="00000000-0000-4000-8000-000000000003") and
    any(.inbounds[];.type=="snell" and .listen_port==42003)'
rewrite_db 'del(.singbox["vless-singbox"])'
generate_singbox_config
check '(.inbounds|length)==1 and .inbounds[0].type=="snell" and .inbounds[0].listen_port==42003'
unchanged_xray
printf '%s\n' 'ok - rebuilding after VLESS port removal preserves remaining ports and shared protocols'

# 完整安装入口保留真实协议选择、已有实例处理、配置生成及事务；所有系统操作均模拟。
(
    set +u
    DISTRO=debian
    _line() { :; }
    _dline() { :; }
    _item() { :; }
    _info() { :; }
    _ok() { :; }
    check_dependencies() { :; }
    ensure_dual_stack_listen() { :; }
    show_install_network_environment() { :; }
    install_deps() { :; }
    install_singbox() { printf '%s\n' singbox >>"$TMP/wizard-installers"; }
    forbidden_xray() { printf '%s\n' "$*" >>"$TMP/wizard-forbidden"; return 1; }
    install_xray() { forbidden_xray install_xray; }
    xray() { forbidden_xray xray "$@"; }
    gen_server_config() { forbidden_xray gen_server_config; }
    generate_xray_config() { forbidden_xray generate_xray_config; }
    create_service() { forbidden_xray create_service "$@"; }
    start_services() { forbidden_xray start_services; }
    gen_uuid() { printf '%s\n' 00000000-0000-4000-8000-000000000005; }
    gen_sid() { printf '%s\n' 00123456; }
    gen_sni() { printf '%s\n' vision.example; }
    gen_singbox_reality_keys() {
        printf '%s\n' '{"private_key":"eCtXsJZ27-4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU","public_key":"Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo"}'
    }
    setup_cert_and_nginx() { [[ "$1" == vless ]]; CERT_DOMAIN=''; }
    ask_sni_config() { printf '%s\n' vision.example; }
    gen_self_cert() { [[ "$1" == vision.example ]]; }
    create_server_scripts() { :; }
    create_watchdog_service() { :; }
    create_shortcut() { :; }
    create_singbox_service() { printf '%s\n' test-service >"$SYSTEMD_DIR/vless-singbox.service"; }
    _wait_for_singbox_ready() { [[ "$WIZARD_RUNNING" == true ]]; }
    svc() {
        printf '%s|%s\n' "$1" "$2" >>"$TMP/wizard-services"
        if [[ "$2" == vless-watchdog ]]; then
            [[ "$1" == enable || "$1" == start ]]
            return
        fi
        [[ "$2" == vless-singbox ]] || { forbidden_xray svc "$@"; return 1; }
        case "$1" in
            status) [[ "$WIZARD_RUNNING" == true ]] ;;
            enabled) [[ "$WIZARD_ENABLED" == true ]] ;;
            enable) WIZARD_ENABLED=true ;;
            start|restart) WIZARD_RUNNING=true ;;
            *) return 1 ;;
        esac
    }
    ask_port() { [[ "$1" == vless-singbox ]]; printf '%s\n' "$WIZARD_PORT"; }
    show_single_protocol_info() { printf '%s|%s|%s\n' "$1" "$2" "$3" >"$TMP/wizard-info"; }
    rewrite_db '.singbox={}'
    rm -f "$CFG/cert_domain" "$CFG/sub.info" "$CFG/singbox.json" "$CFG/vless-singbox.join"
    WIZARD_RUNNING=false WIZARD_ENABLED=false WIZARD_PORT=42010
    INSTALL_MODE='' REPLACE_PORT=''
    do_install_server <<<$'1\n1\n2\ny' >"$TMP/wizard-first"
    [[ "$(cat "$TMP/wizard-info")" == 'vless-singbox|false|42010' ]]
    [[ "$WIZARD_RUNNING" == true && "$WIZARD_ENABLED" == true ]]
    jq -e '.singbox["vless-singbox"] | length==1 and .[0].port==42010 and .[0].short_id=="00123456"' "$DB_FILE" >/dev/null
    unchanged_xray

    WIZARD_PORT=42011
    do_install_server <<<$'1\n1\n2\n1\ny' >"$TMP/wizard-add"
    [[ "$(cat "$TMP/wizard-info")" == 'vless-singbox|false|42011' ]]
    jq -e '[.singbox["vless-singbox"][].port]==[42010,42011]' "$DB_FILE" >/dev/null
    unchanged_xray

    WIZARD_PORT=42012
    do_install_server <<<$'1\n1\n2\n2\n1\ny' >"$TMP/wizard-replace"
    [[ "$(cat "$TMP/wizard-info")" == 'vless-singbox|false|42012' ]]
    jq -e '[.singbox["vless-singbox"][].port]==[42012,42011]' "$DB_FILE" >/dev/null
    unchanged_xray

    # 已有实例选择返回必须在依赖安装和服务操作之前结束。
    cp "$DB_FILE" "$TMP/wizard-before-return-db"
    cp "$TMP/wizard-services" "$TMP/wizard-before-return-services"
    if do_install_server <<<$'1\n1\n2\n0' >"$TMP/wizard-return"; then exit 1; fi
    cmp "$DB_FILE" "$TMP/wizard-before-return-db"
    cmp "$TMP/wizard-services" "$TMP/wizard-before-return-services"
    [[ "$(wc -l <"$TMP/wizard-installers")" -eq 3 && ! -f "$TMP/wizard-forbidden" ]]
    grep -qx 'start|vless-singbox' "$TMP/wizard-services"
    grep -qx 'restart|vless-singbox' "$TMP/wizard-services"
)
printf '%s\n' 'ok - full REALITY Sing-box wizard selects core before existing-instance checks and avoids Xray'
