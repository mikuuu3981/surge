#!/usr/bin/env bash
# 实际卸载入口的离线回归：配置/JOIN 使用真实生成器，服务、核心和网络均模拟。
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/singbox-vless-uninstall.XXXXXX")
trap 'command rm -rf "$TMP"' EXIT
export VLESS_TEST_CFG="$TMP/etc"
export VLESS_TEST_SYSTEMD_DIR="$TMP/systemd"
export VLESS_TEST_OPENRC_DIR="$TMP/openrc"
mkdir -p "$VLESS_TEST_CFG" "$VLESS_TEST_SYSTEMD_DIR" "$VLESS_TEST_OPENRC_DIR"
source "$ROOT/vless-server.sh"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
_log() { :; }
_header() { :; }
_pause() { :; }
_listen_addr() { printf '%s\n' 127.0.0.1; }
get_connection_addresses() { printf '%s\n' '192.0.2.1|2001:db8::1'; }
get_ip_country() { printf '%s\n' TEST; }

# 即使回归到旧卸载分支，也不能删除宿主 /etc 文件或调用真实系统命令。
unexpected() {
    printf '%s\n' "$*" >>"$TMP/unexpected"
    return 1
}
rm() {
    local arg
    for arg in "$@"; do
        [[ "$arg" == -* ]] && continue
        [[ "$arg" == "$TMP" || "$arg" == "$TMP/"* ]] || { unexpected rm "$@"; return 1; }
    done
    command rm "$@"
}
curl() { unexpected curl "$@"; }
wget() { unexpected wget "$@"; }
nginx() { unexpected nginx "$@"; }
iptables() { unexpected iptables "$@"; }
ip6tables() { unexpected ip6tables "$@"; }
nft() { unexpected nft "$@"; }
ufw() { unexpected ufw "$@"; }
firewall-cmd() { unexpected firewall-cmd "$@"; }
rc-service() { unexpected rc-service "$@"; }
systemctl() {
    [[ "$*" == daemon-reload ]] || { unexpected systemctl "$@"; return 1; }
    printf '%s\n' "$*" >>"$TMP/systemctl"
}
rc-update() { unexpected rc-update "$@"; }
sleep() { :; }

RUNNING=true ENABLED=true HEALTHY=true FAIL=none REMOVE_PORT=42001
sing-box() {
    case "$1" in
        version) printf '%s\n' 'sing-box version 1.14.3' ;;
        check)
            printf '%s\n' "$3" >>"$TMP/checks"
            [[ "$FAIL" != validation ]] || return 1
            jq -e '(.inbounds|length)>0 and (.outbounds|length)>0' "$3" >/dev/null || return 1
            if [[ -n "${VLESS_TEST_SINGBOX_BIN:-}" ]]; then
                "$VLESS_TEST_SINGBOX_BIN" "$@" || return 1
            fi
            touch "$TMP/validated"
            ;;
        *) unexpected sing-box "$@" ;;
    esac
}
svc() {
    printf '%s|%s\n' "$1" "$2" >>"$TMP/services"
    [[ "$2" == vless-singbox ]] || { unexpected svc "$@"; return 1; }
    case "$1" in
        status) [[ "$RUNNING" == true ]] ;;
        enabled) [[ "$ENABLED" == true ]] ;;
        enable) ENABLED=true ;;
        disable) [[ "$ENABLED" == true ]] || return 1; ENABLED=false ;;
        stop) RUNNING=false ;;
        start|restart)
            [[ -f "$TMP/validated" ]] || { unexpected 'start before validation'; return 1; }
            if [[ "$FAIL" == restart ]]; then FAIL=none; RUNNING=false; return 1; fi
            HEALTHY=true
            if [[ "$FAIL" == health ]]; then FAIL=none; HEALTHY=false; fi
            RUNNING=true
            ;;
        *) unexpected svc "$@" ;;
    esac
}
# 保留真实监听轮询；模拟所有监听缺失及恢复，避免启动进程或等待 9 秒。
ss() {
    printf '%s\n' "$*" >>"$TMP/listeners"
    [[ "$RUNNING" == true && "$HEALTHY" == true ]] && printf '%s\n' listening
    return 0
}
# JOIN 已发布后，聚合文件写入失败，必须恢复两个文件。
cat() {
    if [[ "$FAIL" == join && "${1:-}" == "$CFG/"*.join ]]; then
        printf '%s\n' partial-join
        return 1
    fi
    command cat "$@"
}
select_port_to_uninstall() {
    [[ "$1" == vless-singbox ]] || return 1
    SELECTED_PORT="$REMOVE_PORT"
    SELECTED_PROTOCOL_CORE=singbox
}
# 只模拟订阅文件发布；协议枚举与订阅内容仍使用真实实现。
generate_sub_files() {
    printf '%s\n' refresh >>"$TMP/sub-updates"
    gen_v2ray_sub >"$CFG/subscription/v2ray.txt" || return 1
    gen_surge_sub >"$CFG/subscription/surge.conf"
}

fixture() {
    local kind="${1:-mixed}"
    FAIL=none RUNNING=true ENABLED=true HEALTHY=true
    DISTRO=debian INSTALL_MODE='' REPLACE_PORT=''
    rm -rf "$CFG" "$SYSTEMD_DIR" "$OPENRC_DIR"
    mkdir -p "$CFG/subscription" "$SYSTEMD_DIR" "$OPENRC_DIR"
    # 合成密钥、文档地址；第二个端口有独立默认凭据和禁用用户。
    jq -n '{xray:{vless:{port:42000,uuid:"00000000-0000-4000-8000-000000000001",
        private_key:"eCtXsJZ27-4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU",
        public_key:"Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo",short_id:"0123456789abcdef",
        sni:"xray.example",security_mode:"reality"}},singbox:{},mihomo:{}} |
        .singbox["vless-singbox"]=[(.xray.vless|.port=42001|.sni="first.example"|
            .uuid="00000000-0000-4000-8000-000000000002"),
            (.xray.vless|.port=42002|.sni="second.example"|.short_id="00123456"|
            .uuid="00000000-0000-4000-8000-000000000003"|
            .users=[{name:"alice",uuid:"00000000-0000-4000-8000-000000000004",enabled:true},
                {name:"disabled",uuid:"00000000-0000-4000-8000-000000000005",enabled:false}])] |
        .singbox["snell-v6-singbox"]={port:42006,psk:"v6Test12345678901",version:6,mode:"default"}' >"$DB_FILE"
    if [[ "$kind" == snell ]]; then
        rewrite_db '.xray={} |
            .singbox.snell={port:42003,psk:"v4Test12345678901",version:4} |
            .singbox["snell-v5"]=[{port:42004,psk:"v5Test12345678901",version:5}] |
            .singbox["snell-shadowtls"]={port:42007,psk:"v4Shadow123456789",version:4,
                stls_password:"shadow-v4-secret",sni:"v4.example"} |
            .singbox["snell-v5-shadowtls"]=[{port:42008,psk:"v5Shadow123456789",version:5,
                stls_password:"shadow-v5-secret",sni:"v5.example"}]'
    elif [[ "$kind" == last ]]; then
        rewrite_db '.singbox={"vless-singbox":.singbox["vless-singbox"][0]}'
    fi
    generate_singbox_config >"$TMP/fixture-output" 2>&1
    if db_exists singbox snell-v6-singbox; then regenerate_singbox_snell_join_info; fi
    regenerate_singbox_snell_v45_join_info
    regenerate_singbox_vless_join_info
    printf '%s\n' server >"$CFG/role"
    printf '%s\n' old-systemd-unit >"$SYSTEMD_DIR/vless-singbox.service"
    printf '%s\n' old-openrc-script >"$OPENRC_DIR/vless-singbox"
    chmod 640 "$SYSTEMD_DIR/vless-singbox.service"
    chmod 750 "$OPENRC_DIR/vless-singbox"
    printf '%s\n' 'DOMAIN=subscription.example' >"$CFG/sub.info"
    printf '%s\n' test-sub-uuid >"$CFG/sub_uuid"
    printf '%s\n' existing-subscription >"$CFG/subscription/sentinel"
    generate_sub_files
    : >"$DB_LOCK_FILE"
    : >"$TMP/services"
    : >"$TMP/checks"
    : >"$TMP/listeners"
    : >"$TMP/sub-updates"
    : >"$TMP/systemctl"
    rm -f "$TMP/validated"
}
rewrite_db() { jq "$1" "$DB_FILE" >"$TMP/db.json"; mv "$TMP/db.json" "$DB_FILE"; }
check() { jq -e "$1" "$CFG/singbox.json" >/dev/null; }
snapshot() {
    rm -rf "$TMP/before"
    mkdir -p "$TMP/before"
    cp -a "$CFG" "$SYSTEMD_DIR" "$OPENRC_DIR" "$TMP/before/"
}
unchanged() {
    diff -r "$TMP/before/etc" "$CFG"
    diff -r "$TMP/before/systemd" "$SYSTEMD_DIR"
    diff -r "$TMP/before/openrc" "$OPENRC_DIR"
    [[ "$(stat -c %a "$SYSTEMD_DIR/vless-singbox.service")" == 640 ]]
    [[ "$(stat -c %a "$OPENRC_DIR/vless-singbox")" == 750 ]]
}
no_service_changes() {
    if grep -Eq '^(stop|disable|enable|start|restart)\|' "$TMP/services"; then
        fail 'preflight failure changed service state'
    fi
}
subscription_updated() {
    [[ "$(<"$CFG/subscription/sentinel")" == existing-subscription ]]
    [[ "$(<"$CFG/sub.info")" == 'DOMAIN=subscription.example' ]]
    [[ "$(<"$CFG/sub_uuid")" == test-sub-uuid ]]
    [[ "$(wc -l <"$TMP/sub-updates")" -eq 1 ]]
}
uninstall_port() {
    REMOVE_PORT="$1"
    local index
    index=$(get_installed_protocols | awk '$0=="vless-singbox" {print NR}')
    [[ -n "$index" ]] || fail 'VLESS missing from real installed protocol list'
    # 不在子 shell 中运行，保留模拟服务的运行/自启状态。
    uninstall_specific_protocol <<<"$index"$'\ny' >"$TMP/output" 2>&1
}
expect_failure() {
    if uninstall_port "$1"; then
        fail "uninstall unexpectedly succeeded ($FAIL)"
    fi
    if grep -Eq '已卸载|卸载成功' "$TMP/output"; then
        fail 'failed uninstall printed success'
    fi
    [[ ! -s "$TMP/sub-updates" ]]
    unchanged
}

fixture
snapshot
uninstall_port 42001
jq -e '[.singbox["vless-singbox"][].port]==[42002]' "$DB_FILE" >/dev/null
jq -S 'del(.singbox["vless-singbox"])' "$TMP/before/etc/db.json" >"$TMP/other-before"
jq -S 'del(.singbox["vless-singbox"])' "$DB_FILE" >"$TMP/other-after"
cmp "$TMP/other-before" "$TMP/other-after"
check '(.inbounds|length)==2 and any(.inbounds[];.type=="snell" and .listen_port==42006) and
    any(.inbounds[];.type=="vless" and .listen_port==42002 and .tls.reality.short_id==["00123456"] and
        ([.users[].uuid]|sort)==["00000000-0000-4000-8000-000000000003","00000000-0000-4000-8000-000000000004"] and
        all(.users[];.flow=="xtls-rprx-vision"))'
[[ "$(grep -c '^JOIN_V4=' "$CFG/vless-singbox.join")" -eq 1 ]]
grep -q ':42002?' "$CFG/vless-singbox.join"
if grep -q ':42001?' "$CFG/join.txt"; then fail 'removed VLESS JOIN survived'; fi
cmp "$TMP/before/etc/snell-v6-singbox.join" "$CFG/snell-v6-singbox.join"
[[ "$RUNNING" == true && "$ENABLED" == true && -f "$SYSTEMD_DIR/vless-singbox.service" && -f "$OPENRC_DIR/vless-singbox" ]]
if grep -Eq '^(stop|disable)\|' "$TMP/services"; then fail 'shared service stopped during port removal'; fi
grep -qx 'restart|vless-singbox' "$TMP/services"
subscription_updated
base64 -d "$CFG/subscription/v2ray.txt" >"$TMP/sub-links"
grep -q ':42002?' "$TMP/sub-links"
if grep -q ':42001?' "$TMP/sub-links"; then fail 'subscription retained removed VLESS'; fi
printf '%s\n' 'ok - actual single-port uninstall keeps other VLESS credentials, Snell, shared service and subscription'

# 只剩 Snell 时仍须保留并更新订阅；覆盖 v4/v5/v6 及两种 ShadowTLS。
fixture snell
snapshot
uninstall_port all
jq -e '.singbox|has("vless-singbox")|not' "$DB_FILE" >/dev/null
jq -S 'del(.singbox["vless-singbox"])' "$TMP/before/etc/db.json" >"$TMP/expected-db"
jq -S . "$DB_FILE" >"$TMP/current-db"
cmp "$TMP/expected-db" "$TMP/current-db"
check '(.inbounds|length)==7 and all(.inbounds[];.type!="vless") and
    ([.inbounds[]|select(.listen_port>0)|.listen_port]|sort)==[42003,42004,42006,42007,42008] and
    any(.inbounds[];.listen_port==42006 and .version==6 and .psk=="v6Test12345678901") and
    any(.inbounds[];.listen_port==42007 and .type=="shadowtls" and .users[0].password=="shadow-v4-secret") and
    any(.inbounds[];.listen_port==42008 and .type=="shadowtls" and .users[0].password=="shadow-v5-secret")'
[[ ! -f "$CFG/vless-singbox.join" && "$RUNNING" == true && "$ENABLED" == true ]]
for protocol in snell snell-v5 snell-v6-singbox snell-shadowtls snell-v5-shadowtls; do
    cmp "$TMP/before/etc/$protocol.join" "$CFG/$protocol.join"
done
if grep -q '^VLESS_SINGBOX_' "$CFG/join.txt"; then fail 'all-port removal retained VLESS JOIN'; fi
[[ -f "$SYSTEMD_DIR/vless-singbox.service" && -f "$OPENRC_DIR/vless-singbox" ]]
if grep -Eq '^(stop|disable)\|' "$TMP/services"; then fail 'remaining Snell service stopped'; fi
subscription_updated
[[ "$(grep -c '= snell,' "$CFG/subscription/surge.conf")" -eq 5 ]]
printf '%s\n' 'ok - all-port uninstall preserves Snell v4/v5/v6, ShadowTLS, JOIN files and Snell-only subscription'

fixture
snapshot
FAIL=validation
expect_failure 42001
[[ -s "$TMP/checks" && "$RUNNING" == true && "$ENABLED" == true ]]
no_service_changes
printf '%s\n' 'ok - core validation rejection returns failure without service changes or lost config/credentials'

for distro in debian alpine; do
    for failure in restart health; do
        fixture
        DISTRO="$distro"
        snapshot
        FAIL="$failure"
        expect_failure 42001
        [[ "$RUNNING" == true && "$ENABLED" == true && "$HEALTHY" == true ]]
        grep -qx 'restart|vless-singbox' "$TMP/services"
        grep -qx 'start|vless-singbox' "$TMP/services"
        [[ "$failure" != health || -s "$TMP/listeners" ]]
    done
done
printf '%s\n' 'ok - restart and missing-listener failures restore running/enabled service, both service definitions and files'

for state in true false; do
    fixture
    RUNNING=false ENABLED="$state"
    touch "$CFG/paused"
    uninstall_port all
    [[ "$RUNNING" == false && "$ENABLED" == "$state" && -f "$CFG/paused" ]]
    no_service_changes
    subscription_updated
done
printf '%s\n' 'ok - successful uninstall preserves paused services and their enabled/disabled states'

fixture
RUNNING=false ENABLED=false
snapshot
FAIL=validation
expect_failure all
[[ "$RUNNING" == false && "$ENABLED" == false ]]
no_service_changes
printf '%s\n' 'ok - failed validation keeps a stopped and disabled service unchanged'

# OpenRC 未加入 runlevel 时 rc-update del 会失败；回滚不能重复取消自启。
(
    fixture
    DISTRO=alpine ENABLED=false
    snapshot
    create_singbox_service() { return 1; }
    touch "$TMP/validated"
    expect_failure all
    [[ "$RUNNING" == true && "$ENABLED" == false ]]
    if grep -q '^disable|' "$TMP/services"; then fail 'rollback disabled an already disabled OpenRC service'; fi
)
printf '%s\n' 'ok - OpenRC service creation failure restores a running service without repeating disable'

for port in 42001 all; do
    fixture
    snapshot
    FAIL=join
    expect_failure "$port"
    [[ "$RUNNING" == true && "$ENABLED" == true ]]
    no_service_changes
done
printf '%s\n' 'ok - JOIN aggregation failures restore DB, per-protocol/aggregate credentials and return no success'

# 最后一个共享协议才删除两个临时服务定义；Xray 仍安装，订阅继续发布。
for distro in debian alpine; do
    fixture last
    DISTRO="$distro"
    uninstall_port all
    jq -e '.singbox=={} and .xray.vless.port==42000' "$DB_FILE" >/dev/null
    [[ "$RUNNING" == false && "$ENABLED" == false ]]
    [[ ! -f "$CFG/singbox.json" && ! -f "$CFG/vless-singbox.join" ]]
    [[ ! -f "$SYSTEMD_DIR/vless-singbox.service" && ! -f "$OPENRC_DIR/vless-singbox" ]]
    grep -qx 'stop|vless-singbox' "$TMP/services"
    grep -qx 'disable|vless-singbox' "$TMP/services"
    if grep -Eq '^(start|restart)\|' "$TMP/services"; then fail 'last removal started empty shared core'; fi
    [[ ! -s "$TMP/checks" ]]
    subscription_updated
done
[[ ! -f "$TMP/unexpected" ]] || fail "unexpected host/network operation: $(<"$TMP/unexpected")"
printf '%s\n' 'ok - only final shared-protocol removal stops/disables and removes temporary systemd/OpenRC services'
