#!/usr/bin/env bash
# 临时配置和模拟服务；不安装软件、不访问真实服务或防火墙。
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP_BASE="${TMPDIR:-/tmp}"
if [[ -z "${TMPDIR:-}" && -d /tmp/opencode && -w /tmp/opencode ]]; then
    TEST_TMP_BASE=/tmp/opencode
fi
TMP=$(mktemp -d "$TEST_TMP_BASE/singbox-snell.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export VLESS_TEST_CFG="$TMP/etc"
export VLESS_TEST_SYSTEMD_DIR="$TMP/systemd"
export VLESS_TEST_OPENRC_DIR="$TMP/openrc"
mkdir -p "$VLESS_TEST_CFG" "$VLESS_TEST_SYSTEMD_DIR" "$VLESS_TEST_OPENRC_DIR"
REAL_BIN="${VLESS_TEST_SINGBOX_BIN:-}"
source "$ROOT/vless-server.sh"
ORIGINAL_CREATE_SINGBOX_SERVICE=$(declare -f create_singbox_service)
ORIGINAL_WAIT_SINGBOX=$(declare -f _wait_for_singbox_ready)
_log() { :; }
_listen_addr() { printf '%s\n' 127.0.0.1; }
get_connection_addresses() { printf '%s\n' '192.0.2.1|2001:db8::1'; }
get_ip_country() { printf '%s\n' TEST; }
_header() { :; }
_pause() { :; }
systemctl() { printf '%s\n' "$*" >>"$TMP/systemctl"; }
create_singbox_service() { printf '%s\n' 'test-service' >"$SYSTEMD_DIR/vless-singbox.service"; }
sing-box() {
    if [[ -n "$REAL_BIN" ]]; then "$REAL_BIN" "$@"; return $?; fi
    case "$1" in
        version) printf '%s\n' 'sing-box version 1.14.3' ;;
        check) jq empty "$3" ;;
        rule-set) cp "$3" "$5" ;;
        *) return 1 ;;
    esac
}
RUNNING=false ENABLED=false FAIL_RESTART=false FAIL_HEALTH=false
svc() {
    printf '%s|%s\n' "$1" "$2" >>"$TMP/services"
    [[ "$2" == vless-singbox ]] || { printf 'unexpected service: %s\n' "$2" >&2; return 1; }
    case "$1" in
        status) [[ "$RUNNING" == true ]] ;;
        enabled) [[ "$ENABLED" == true ]] ;;
        enable) ENABLED=true ;;
        disable) ENABLED=false ;;
        start|restart)
            if [[ "$FAIL_RESTART" == true ]]; then FAIL_RESTART=false; return 1; fi
            RUNNING=true
            ;;
        stop) RUNNING=false ;;
        *) return 1 ;;
    esac
}
_wait_for_singbox_ready() {
    if [[ "$FAIL_HEALTH" == true ]]; then FAIL_HEALTH=false; return 1; fi
    [[ "$RUNNING" == true ]]
}
fixture() {
    jq -n '{xray:{"snell-v6":{port:41000,psk:"officialTestKey123",version:6}},singbox:{},mihomo:{}}' >"$DB_FILE"
    printf '%s\n' official-config >"$CFG/snell-v6.conf"
    printf '%s\n' official-join >"$CFG/snell-v6.join"
    : >"$TMP/services"
    RUNNING=false ENABLED=false
}
record() { jq -nc --argjson port "$1" --arg mode "${2:-default}" '{port:$port,psk:"testonly1234567890",version:6,mode:$mode,tfo:"false"}'; }
check() { jq -e "$1" "$CFG/singbox.json" >/dev/null; }
unchanged_official() {
    [[ "$(<"$CFG/snell-v6.conf")" == official-config && "$(<"$CFG/snell-v6.join")" == official-join ]]
    jq -e '.xray["snell-v6"].port == 41000 and .xray["snell-v6"].psk == "officialTestKey123"' "$DB_FILE" >/dev/null
}

fixture
select_snell_v6_implementation <<<''
[[ "$SELECTED_PROTOCOL" == snell-v6-singbox ]]
select_snell_v6_implementation <<<2
[[ "$SELECTED_PROTOCOL" == snell-v6 ]]
if select_snell_v6_implementation <<<0; then exit 1; fi
[[ "$(protocol_core snell-v6-singbox)" == singbox && "$(protocol_core snell-v6)" == standalone ]]
for version in 1.14.0 1.14.3 1.15.0-alpha.12 2.0.0; do _singbox_supports_snell_version "$version"; done
for version in 1.13.9 1.14.0-alpha.1 garbage ''; do
    if _singbox_supports_snell_version "$version"; then exit 1; fi
done
printf '%s\n' 'ok - implementation selection, default and version floor'

_apply_singbox_snell_change add all "$(record 41001)"
_apply_singbox_snell_change add all "$(record 41002 unshaped)"
_apply_singbox_snell_change add all "$(record 41003 unsafe-raw)"
check '(.inbounds | length) == 3 and [.inbounds[].tag] == ["snell-v6-41001","snell-v6-41002","snell-v6-41003"]'
check '[.inbounds[].mode] == ["default","unshaped","unsafe-raw"] and all(.inbounds[]; .type=="snell" and .version==6 and .users==null and .tls==null)'
[[ "$(grep -c '^JOIN_V4=' "$CFG/snell-v6-singbox.join")" == 3 ]]
[[ "$(get_standalone_protocols)" == snell-v6 && "$(get_singbox_protocols)" == snell-v6-singbox ]]
[[ "$RUNNING" == true && "$ENABLED" == true ]]
[[ "$(is_internal_port_occupied 41002)" == snell-v6-singbox ]]
unchanged_official
printf '%s\n' 'ok - three independent Snell listeners coexist with official implementation'

cp "$DB_FILE" "$TMP/before-db"
cp "$CFG/singbox.json" "$TMP/before-config"
for bad in "$(record 41000)" "$(record 41001)" \
    "$(record 41004 | jq '.mode="invalid"')" \
    "$(record 41004 | jq '.psk="short"')" \
    "$(record 41004 | jq '.port=1.5')" \
    "$(record 41004 | jq '.version=5')"; do
    if _apply_singbox_snell_change add all "$bad" 2>"$TMP/error"; then exit 1; fi
    cmp "$DB_FILE" "$TMP/before-db"
    cmp "$CFG/singbox.json" "$TMP/before-config"
done
if _apply_singbox_snell_change replace 49999 "$(record 41004)" 2>"$TMP/error"; then exit 1; fi
printf '%s\n' 'ok - cross-core duplicates and invalid records rejected without changes'

_apply_singbox_snell_change replace 41002 "$(record 41004 default)"
check '[.inbounds[].listen_port] == [41001,41004,41003]'
_apply_singbox_snell_change remove 41004 '{}'
check '[.inbounds[].listen_port] == [41001,41003]'
[[ "$(grep -c '^JOIN_V4=' "$CFG/snell-v6-singbox.join")" == 2 ]]
unchanged_official
printf '%s\n' 'ok - replace/remove rebuild all listeners and JOIN records'

cp "$DB_FILE" "$TMP/before-db"
cp "$CFG/singbox.json" "$TMP/before-config"
cp "$CFG/snell-v6-singbox.join" "$TMP/before-join"
for failure in restart health; do
    if [[ "$failure" == restart ]]; then FAIL_RESTART=true; else FAIL_HEALTH=true; fi
    if _apply_singbox_snell_change add all "$(record 41005)" 2>"$TMP/error"; then exit 1; fi
    cmp "$DB_FILE" "$TMP/before-db"
    cmp "$CFG/singbox.json" "$TMP/before-config"
    cmp "$CFG/snell-v6-singbox.join" "$TMP/before-join"
    [[ "$RUNNING" == true && "$ENABLED" == true ]]
done
unchanged_official
printf '%s\n' 'ok - restart and asynchronous health failure restore DB, config and service'

# 核心拒绝候选配置时不重启，且失败时保留先前 disabled/stopped 状态。
(
    sing-box() {
        if [[ "$1" == version ]]; then printf '%s\n' 'sing-box version 1.14.3'; else return 1; fi
    }
    cp "$TMP/services" "$TMP/before-services"
    if _apply_singbox_snell_change add all "$(record 41005)" 2>"$TMP/error"; then exit 1; fi
    cmp "$DB_FILE" "$TMP/before-db"
    cmp "$CFG/singbox.json" "$TMP/before-config"
    [[ "$(grep -c '^restart\|^start' "$TMP/services")" == "$(grep -c '^restart\|^start' "$TMP/before-services")" ]]
)
(
    RUNNING=false ENABLED=false FAIL_HEALTH=true
    if _apply_singbox_snell_change add all "$(record 41005)" 2>"$TMP/error"; then exit 1; fi
    [[ "$RUNNING" == false && "$ENABLED" == false ]]
    cmp "$DB_FILE" "$TMP/before-db"
    cmp "$CFG/singbox.json" "$TMP/before-config"
)
printf '%s\n' 'ok - core validation failure never restarts and stopped/disabled states survive rollback'

gen_surge_sub >"$TMP/surge"
[[ "$(grep -c '= snell,' "$TMP/surge")" == 3 ]]
grep -q 'Snell-v6-official-41000 = snell' "$TMP/surge"
grep -q 'Snell-v6-singbox-41001 = snell.*version=6.*tfo=false' "$TMP/surge"
grep -q 'Snell-v6-singbox-41003 = snell.*mode=unsafe-raw' "$TMP/surge"
show_single_protocol_info snell-v6-singbox false 41003 >"$TMP/info"
grep -q 'unsafe-raw' "$TMP/info"
show_all_share_links >"$TMP/links"
[[ "$(grep -c 'snell://' "$TMP/links")" == 6 ]]
grep -q 'Snell-v6.*singbox-41003' "$TMP/links"
printf '%s\n' 'ok - subscription, details and IPv4/IPv6 sharing include all implementations'

# 分流复用现有规则；预设规则集用本地 source fixture 编译，不访问网络。
jq '.chain_proxy={nodes:[{name:"landing",type:"socks",server:"127.0.0.1",port:1080}]} |
    .routing_rules=[
      {type:"custom",outbound:"block",domains:"blocked.example",ip_version:"as_is"},
      {type:"custom",outbound:"chain:landing",domains:"landing.example",ip_version:"as_is"},
      {type:"custom",outbound:"direct",domains:"198.51.100.0/24,2001:db8::/32",ip_version:"as_is"}
    ]' "$DB_FILE" >"$TMP/db"; mv "$TMP/db" "$DB_FILE"
generate_singbox_config
check 'any(.route.rules[]; .outbound=="block" and .domain_suffix==["blocked.example"]) and
       any(.route.rules[]; .outbound=="chain-landing-prefer-ipv4" and .domain_suffix==["landing.example"]) and
       any(.route.rules[]; .ip_cidr==["198.51.100.0/24","2001:db8::/32"])'
check '.route.final=="direct" and any(.outbounds[]; .tag=="chain-landing-prefer-ipv4" and .domain_resolver.strategy=="prefer_ipv4")'
if [[ -n "$REAL_BIN" ]]; then
    python3 "$ROOT/tests/test-singbox-snell-runtime.py" "$REAL_BIN" "$CFG/singbox.json"
fi
printf '%s\n' 'ok - shared domain/IP routing, reject, chain and modern DNS resolver'

_build_singbox_ruleset() {
    mkdir -p "$CFG/ruleset" "$CFG/ruleset-src"
    local source_file="$CFG/ruleset-src/$1.json"
    if [[ "$1" == geoip-* ]]; then
        printf '%s\n' '{"version":3,"rules":[{"ip_cidr":["198.51.100.0/24"]}]}' >"$source_file"
    else
        printf '%s\n' '{"version":3,"rules":[{"domain_suffix":["fixture.example"]}]}' >"$source_file"
    fi
    sing-box rule-set compile "$source_file" -o "$CFG/ruleset/$1.srs"
}
jq '.balancer_groups=[{name:"pool",strategy:"leastPing",nodes:["landing"]}] |
    .routing_rules=[
      {type:"telegram",outbound:"balancer:pool",domains:"geosite:telegram",ip_version:"as_is"},
      {type:"custom",outbound:"block",domains:"geosite:cn,geoip:cn",ip_version:"ipv6_only"},
      {type:"ads",outbound:"block",domains:"geosite:category-ads-all",ip_version:"as_is"},
      {type:"custom",outbound:"direct",domains:"v4.example",ip_version:"ipv4_only"},
      {type:"custom",outbound:"direct",domains:"v6.example",ip_version:"ipv6_only"},
      {type:"mihomo-instagram",outbound:"chain:missing",domains:"rule-set:yuu-instagram",ip_version:"as_is"}
    ]' "$DB_FILE" >"$TMP/db"; mv "$TMP/db" "$DB_FILE"
generate_singbox_config
check '[.route.rule_set[].tag] == ["geoip-cn","geoip-telegram","geosite-category-ads-all","geosite-cn","geosite-telegram"]'
check '.route.rules[0].rule_set==["geosite-telegram"] and .route.rules[1].rule_set==["geoip-telegram"] and
    .route.rules[0].outbound=="balancer-pool" and any(.outbounds[]; .tag=="balancer-pool" and .type=="urltest")'
check 'any(.route.rules[]; .domain_suffix==["v4.example"] and .ip_cidr==["0.0.0.0/0"]) and
    any(.route.rules[]; .domain_suffix==["v6.example"] and .ip_cidr==["::/0"])'
printf '%s\n' 'ok - presets, GeoIP companions, mixed rules, family filters, ads and Instagram isolation'

jq '.routing={warp_mode:"official"} | .routing_rules=[{type:"all",outbound:"warp",ip_version:"as_is"}]' "$DB_FILE" >"$TMP/db"; mv "$TMP/db" "$DB_FILE"
check_cmd() { [[ "$1" == warp-cli ]] || command -v "$1" >/dev/null 2>&1; }
generate_singbox_config
check '.route.rules[0]=={network:"udp",outbound:"direct"} and any(.outbounds[]; .type=="socks" and .server=="127.0.0.1")'
jq '.routing.warp_mode="wgcf"' "$DB_FILE" >"$TMP/db"; mv "$TMP/db" "$DB_FILE"
jq -n '{endpoint:"[2606:4700:d0::1]:2408",address_v4:"172.16.0.2/32",address_v6:"2606:4700:110::2/128",
    private_key:"eCtXsJZ27+4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU=",public_key:"Cr8hWlKvtDt7nrvf+f0brNQQzabAqrjfBvas9pmowjo="}' >"$WARP_CONF_FILE"
generate_singbox_config
check '.endpoints[0].type=="wireguard" and .endpoints[0].peers[0].address=="2606:4700:d0::1" and .route.rules[-1].outbound=="warp"'
printf '%s\n' 'ok - official WARP UDP fallback and WGCF IPv6 endpoint'

# 正常分流修改只重启共享核心；异步启动失败恢复已运行配置。
jq '.routing_rules=[{type:"all",outbound:"direct",ip_version:"as_is"}]' "$DB_FILE" >"$TMP/db"; mv "$TMP/db" "$DB_FILE"
_regenerate_proxy_configs
cp "$CFG/singbox.json" "$TMP/before-config"
jq '.routing_rules=[{type:"custom",outbound:"block",domains:"new.example",ip_version:"as_is"}]' "$DB_FILE" >"$TMP/db"; mv "$TMP/db" "$DB_FILE"
FAIL_HEALTH=true
if _regenerate_singbox_routing_config 2>"$TMP/error"; then exit 1; fi
cmp "$CFG/singbox.json" "$TMP/before-config"
[[ "$RUNNING" == true ]]
printf '%s\n' 'ok - routing update restarts only shared core and rolls back unhealthy startup'

# 不存在的链式出口必须失败，不能覆盖运行配置或重启服务。
cp "$CFG/singbox.json" "$TMP/before-config"
jq '.routing_rules=[{type:"all",outbound:"chain:missing",ip_version:"as_is"}]' "$DB_FILE" >"$TMP/db"; mv "$TMP/db" "$DB_FILE"
cp "$TMP/services" "$TMP/before-services"
if _regenerate_singbox_routing_config 2>"$TMP/error"; then exit 1; fi
cmp "$CFG/singbox.json" "$TMP/before-config"
# status 查询允许；不允许 restart/start。
[[ "$(grep -c '^restart\|^start' "$TMP/services")" == "$(grep -c '^restart\|^start' "$TMP/before-services")" ]]
jq '.routing_rules=[]' "$DB_FILE" >"$TMP/db"; mv "$TMP/db" "$DB_FILE"
_apply_singbox_snell_change remove all '{}'
[[ ! -f "$CFG/singbox.json" && ! -f "$CFG/snell-v6-singbox.join" && "$RUNNING" == false && "$ENABLED" == false ]]
unchanged_official
printf '%s\n' 'ok - last Sing-box listener removal leaves official service/config intact'

# 与另一种共享协议共存时，删除最后一个 Snell 入站不能删除共享服务。
mkdir -p "$CFG/certs/hy2" "$CFG/certs/tuic"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj /CN=fixture.example -keyout "$CFG/certs/server.key" -out "$CFG/certs/server.crt" >/dev/null 2>&1
for proto in hy2 tuic; do
    cp "$CFG/certs/server.key" "$CFG/certs/$proto/server.key"
    cp "$CFG/certs/server.crt" "$CFG/certs/$proto/server.crt"
done
db_add singbox anytls '{"port":41009,"password":"testOnlyAnyTLS","sni":"fixture.example"}'
db_add singbox hy2 '{"port":41010,"password":"testOnlyHY2","sni":"fixture.example"}'
db_add singbox tuic '{"port":41011,"uuid":"76ef3649-d341-4c77-a1a2-18db2ba4c2d9","password":"testOnlyTUIC"}'
_apply_singbox_snell_change add all "$(record 41001)"
_apply_singbox_snell_change remove all '{}'
check '(.inbounds|length)==3 and ([.inbounds[].type] | sort)==["anytls","hysteria2","tuic"]'
[[ "$RUNNING" == true && -f "$SYSTEMD_DIR/vless-singbox.service" && ! -f "$CFG/snell-v6-singbox.join" ]]
unchanged_official
printf '%s\n' 'ok - removing last Snell listener preserves other shared protocols'

# 共享核心重建也兼容其他协议的数组记录，每端口保持原始默认密码。
db_add singbox hy2 '[{"port":41010,"password":"testOnlyHY2","sni":"fixture.example"},
    {"port":41012,"password":"secondHY2secret","sni":"fixture.example"}]'
generate_singbox_config
check 'any(.inbounds[]; .tag=="hy2-in-41010" and any(.users[]; .password=="testOnlyHY2")) and
    any(.inbounds[]; .tag=="hy2-in-41012" and any(.users[]; .password=="secondHY2secret"))'
printf '%s\n' 'ok - existing shared protocol arrays retain all ports and per-port credentials'

gen_singbox_snell_v6_server_config 1234567890123456 41001 unshaped false
jq -e '.singbox["snell-v6-singbox"][0].psk=="1234567890123456"' "$DB_FILE" >/dev/null
printf '%s\n' 'ok - numeric-only PSK stays a string through installation generator'

# 服务模板使用共享进程，OpenRC 语法由 POSIX sh 校验。
(
    eval "$ORIGINAL_CREATE_SINGBOX_SERVICE"
    DISTRO=debian
    create_singbox_service
    grep -q '^ExecStartPre=/usr/local/bin/sing-box check' "$SYSTEMD_DIR/vless-singbox.service"
    grep -q '^ExecStart=/usr/local/bin/sing-box run' "$SYSTEMD_DIR/vless-singbox.service"
    create_watchdog_service
    DISTRO=alpine
    create_singbox_service
    create_watchdog_service
    sh -n "$OPENRC_DIR/vless-singbox"
    sh -n "$OPENRC_DIR/vless-watchdog"
    grep -q '^command="/usr/local/bin/sing-box"' "$OPENRC_DIR/vless-singbox"
)
printf '%s\n' 'ok - systemd/OpenRC shared service templates validate without service execution'

(
    # UI 展示与日志分派不依赖实际服务或外部网络。
    set +e
    set +u
    warp_status() { return 1; }
    svc() { return 0; }
    show_status >"$TMP/status"
    grep -q 'Snell v6 (Sing-box)' "$TMP/status" || exit 1
    grep -q 'Snell v6 (官方)' "$TMP/status" || exit 1
    show_protocols_overview >"$TMP/overview"
    grep -q 41001 "$TMP/overview" || exit 1
    journalctl() { printf '%s\n' "$*" >"$TMP/journal-args"; }
    show_service_logs <<<1 >"$TMP/log-menu"
    grep -q -- '-u vless-singbox' "$TMP/journal-args" || exit 1
    show_service_logs <<<2 >"$TMP/log-menu"
    grep -q -- '-u vless-snell-v6' "$TMP/journal-args" || exit 1
)
printf '%s\n' 'ok - status, overview and logs distinguish official and shared implementations'

# 健康检查覆盖共享 TCP/UDP 入站；watchdog 不把官方 Snell 误认作 Xray。
(
    eval "$ORIGINAL_WAIT_SINGBOX"
    ss() { printf '%s\n' "$*" >>"$TMP/socket-checks"; printf '%s\n' listening; }
    _wait_for_singbox_ready
    grep -q -- '-lnu sport = :41010' "$TMP/socket-checks"
    grep -q -- '-lnt sport = :41001' "$TMP/socket-checks"
    create_server_scripts
    awk -v cfg="$CFG" '
        $0 == "CFG=\"/etc/vless-reality\"" {print "CFG=\"" cfg "\""; next}
        $0 == "log \"INFO: Watchdog 启动\"" {exit}
        {print}
    ' "$CFG/watchdog.sh" >"$TMP/watchdog-discovery"
    printf '%s\n' get_all_services >>"$TMP/watchdog-discovery"
    services=$(bash "$TMP/watchdog-discovery")
    [[ "$(grep -o 'vless-singbox:sing-box' <<<"$services" | wc -l)" == 1 ]]
    [[ "$services" == *vless-snell-v6:snell-server-v6* && "$services" != *vless-reality* && "$services" != *vless-anytls* ]]
)
printf '%s\n' 'ok - shared TCP/UDP readiness and distinct watchdog service ownership'

# 实际安装入口：实现选择先于已有协议判断，不能进入官方重装清理路径。
(
    set +u
    select_protocol() { SELECTED_PROTOCOL=snell-v6; }
    check_dependencies() { :; }
    ensure_dual_stack_listen() { :; }
    show_install_network_environment() { :; }
    install_deps() { :; }
    ensure_singbox_snell_support() { :; }
    ask_port() { printf '%s\n' 41020; }
    create_server_scripts() { :; }
    create_shortcut() { :; }
    create_watchdog_service() { :; }
    create_service() { printf '%s\n' unexpected >&2; return 1; }
    svc() {
        [[ "$2" == vless-watchdog ]] && return 0
        case "$1" in
            status|enabled) return 0 ;;
            *) [[ "$2" == vless-singbox ]] ;;
        esac
    }
    show_single_protocol_info() { printf '%s|%s|%s\n' "$1" "$2" "$3" >"$TMP/installed-info"; }
    do_install_server <<<'
1
testPSK1234567890
2
2
y'
    [[ "$(<"$TMP/installed-info")" == 'snell-v6-singbox|false|41020' ]]
    jq -e '.singbox["snell-v6-singbox"] | any(.port==41020 and .mode=="unshaped" and .tfo=="false")' "$DB_FILE" >/dev/null
    unchanged_official
)
printf '%s\n' 'ok - full Sing-box installation wizard keeps official config and selects the installed port'

# 实际卸载入口：仅移除选定 Snell 端口，不执行旧订阅清理或触碰官方服务。
(
    get_installed_protocols() { printf '%s\n' snell-v6-singbox; }
    select_port_to_uninstall() { SELECTED_PORT=41020; SELECTED_PROTOCOL_CORE=singbox; }
    uninstall_specific_protocol <<<$'1\ny'
    jq -e '.singbox["snell-v6-singbox"] | all(.port!=41020)' "$DB_FILE" >/dev/null
    unchanged_official
)
printf '%s\n' 'ok - uninstall menu dispatches exact implementation and port'

# 删除官方版只删除官方资源；保留 Sing-box 配置、服务及订阅目录。
(
    set +u
    mkdir -p "$CFG/subscription"
    printf '%s\n' official-unit >"$SYSTEMD_DIR/vless-snell-v6.service"
    cp "$CFG/singbox.json" "$TMP/before-official-remove"
    get_installed_protocols() { printf '%s\n' snell-v6; }
    select_port_to_uninstall() { SELECTED_PORT=all; SELECTED_PROTOCOL_CORE=xray; }
    generate_sub_files() { printf '%s\n' refreshed >"$CFG/subscription/refresh-test"; }
    svc() { [[ "$2" == vless-snell-v6 ]]; }
    uninstall_specific_protocol <<<$'1\ny'
    [[ ! -f "$CFG/snell-v6.conf" && ! -f "$SYSTEMD_DIR/vless-snell-v6.service" && -f "$CFG/subscription/refresh-test" ]]
    cmp "$CFG/singbox.json" "$TMP/before-official-remove"
    [[ -f "$SYSTEMD_DIR/vless-singbox.service" ]]
)
# 恢复仅供后续测试使用的官方 fixture，不调用任何服务。
jq '.xray["snell-v6"]={port:41000,psk:"officialTestKey123",version:6}' "$DB_FILE" >"$TMP/db"
mv "$TMP/db" "$DB_FILE"
printf '%s\n' official-config >"$CFG/snell-v6.conf"
printf '%s\n' official-join >"$CFG/snell-v6.join"
printf '%s\n' 'ok - official uninstall preserves Sing-box listeners, service and subscription'

# 升级二进制和配置在同一事务中恢复，测试目标也限制在临时目录。
mkdir -p "$TMP/bin"
_core_binary_path() { printf '%s\n' "$TMP/bin/sing-box"; }
printf '%s\n' old-binary >"$TMP/bin/sing-box"
fake_update() {
    printf '%s\n' new-binary >"$TMP/bin/sing-box"
    printf '%s\n' new-config >"$CFG/singbox.json"
}
cp "$CFG/singbox.json" "$TMP/before-config"
for failure in restart health; do
    if [[ "$failure" == restart ]]; then FAIL_RESTART=true; else FAIL_HEALTH=true; fi
    if _update_singbox_core_to_version stable 1.14.3 fake_update 2>"$TMP/error"; then exit 1; fi
    [[ "$(<"$TMP/bin/sing-box")" == old-binary && "$RUNNING" == true ]]
    cmp "$CFG/singbox.json" "$TMP/before-config"
done
(
    RUNNING=false
    _update_singbox_core_to_version stable 1.14.3 fake_update
    [[ "$RUNNING" == false && "$(<"$TMP/bin/sing-box")" == new-binary ]]
)
cp "$TMP/before-config" "$CFG/singbox.json"
printf '%s\n' 'ok - core upgrade restores binary/config on restart failure and preserves stopped state'
(
    fake_download_failure() { return 1; }
    cp "$TMP/services" "$TMP/pre-download-services"
    if _update_singbox_core_to_version stable 1.14.3 fake_download_failure 2>"$TMP/error"; then exit 1; fi
    [[ "$RUNNING" == true ]]
    [[ "$(grep -Ec '^(start|restart|stop)\|' "$TMP/services")" == "$(grep -Ec '^(start|restart|stop)\|' "$TMP/pre-download-services")" ]]
)
printf '%s\n' 'ok - download/preflight failure leaves the running shared core uninterrupted'

# 待安装核心的版本/能力不满足时，安装器不能先替换原二进制。
(
    cat >"$TMP/bin/unsupported" <<'EOF'
#!/bin/sh
case "$1" in
    version) echo 'sing-box version 1.13.9' ;;
    *) exit 1 ;;
esac
EOF
    printf '%s\n' old-binary >"$TMP/bin/sing-box"
    cp "$CFG/singbox.json" "$TMP/pre-stage-config"
    if _install_checked_singbox_binary "$TMP/bin/unsupported" 2>"$TMP/error"; then exit 1; fi
    [[ "$(<"$TMP/bin/sing-box")" == old-binary ]]
    cmp "$CFG/singbox.json" "$TMP/pre-stage-config"
    cp /bin/sleep "$TMP/bin/executing"
    "$TMP/bin/executing" 30 &
    pid=$!
    _replace_singbox_binary /bin/true "$TMP/bin/executing"
    kill -0 "$pid"
    kill "$pid"
    wait "$pid" 2>/dev/null || true
    "$TMP/bin/executing"
)
printf '%s\n' 'ok - unsupported staged core cannot replace working files; running inode replacement is atomic'

# 旧核心降级必须在任何服务停止之前拒绝。
db_add singbox snell-v6-singbox "$(record 41001)"
_check_core_update_deps() { :; }
_confirm_core_update_version() { printf '%s\n' unexpected >>"$TMP/confirm"; return 1; }
if _update_core_to_version Sing-box stable 1.13.9 vless-singbox forbidden_installer 2>"$TMP/error"; then exit 1; fi
[[ ! -f "$TMP/confirm" ]]
if install_singbox stable true 1.13.9 2>"$TMP/error"; then exit 1; fi
printf '%s\n' 'ok - downgrade protection applies to custom and managed versions'
