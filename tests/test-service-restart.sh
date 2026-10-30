#!/usr/bin/env bash
# 临时配置与模拟服务；验证菜单重启，不调用系统服务或防火墙。
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VLESS_TEST_CFG="$TMP/etc"
export VLESS_TEST_SYSTEMD_DIR="$TMP/systemd"
export VLESS_TEST_OPENRC_DIR="$TMP/openrc"
mkdir -p "$VLESS_TEST_CFG" "$VLESS_TEST_SYSTEMD_DIR" "$VLESS_TEST_OPENRC_DIR"
source "$ROOT/vless-server.sh"
DISTRO=debian
_log() { :; }
_header() { :; }; _line() { :; }; _item() { :; }; _pause() { :; }
show_protocols_overview() { :; }
get_installed_protocols() { printf '%s\n' hy2; }
get_xray_protocols() { :; }
get_singbox_protocols() { printf '%s\n' hy2; }
get_standalone_protocols() { :; }
init_db() { :; }
check_cmd() { [[ "$1" == sing-box ]]; }
_pgrep() { return 1; }
sleep() { :; }
systemctl() { printf 'unexpected systemctl: %s\n' "$*" >&2; exit 90; }
rc-service() { printf 'unexpected rc-service: %s\n' "$*" >&2; exit 91; }
install_singbox() { printf 'unexpected install\n' >&2; exit 92; }
RUNNING=true
FAIL_GENERATE=false FAIL_RESTART=false FAIL_HEALTH=false FAIL_SERVICE=false
create_singbox_service() {
    printf 'create-service|%s\n' "$RUNNING" >>"$TMP/events"
    [[ "$FAIL_SERVICE" == false ]]
}
generate_singbox_config() {
    printf 'generate|%s\n' "$RUNNING" >>"$TMP/events"
    [[ "$FAIL_GENERATE" == false ]] || return 1
    printf '%s\n' '{"fixture":"new"}' >"${1:-$CFG/singbox.json}"
}
_wait_for_singbox_ready() {
    printf 'health|%s\n' "$RUNNING" >>"$TMP/events"
    if [[ "$FAIL_HEALTH" == true ]]; then FAIL_HEALTH=false; return 1; fi
    [[ "$RUNNING" == true ]]
}
svc() {
    local action="$1" name="$2"
    printf '%s|%s\n' "$action" "$name" >>"$TMP/events"
    [[ "$name" == vless-watchdog ]] && return 0
    [[ "$name" == vless-singbox || "$name" == vless-reality ]] || exit 93
    case "$action" in
        status) [[ "$RUNNING" == true ]] ;;
        enable) return 0 ;;
        restart)
            RUNNING=false
            if [[ "$FAIL_RESTART" == true ]]; then FAIL_RESTART=false; return 1; fi
            RUNNING=true
            ;;
        start) RUNNING=true ;;
        *) printf 'unexpected service action: %s\n' "$*" >&2; exit 94 ;;
    esac
}
stop_services() {
    printf 'stop-all\n' >>"$TMP/events"
    RUNNING=false
}
fixture() {
    RUNNING=true
    FAIL_GENERATE=false FAIL_RESTART=false FAIL_HEALTH=false FAIL_SERVICE=false
    rm -f "$CFG/paused"
    printf '%s\n' '{"fixture":"old"}' >"$CFG/singbox.json"
    cp "$CFG/singbox.json" "$TMP/old.json"
    : >"$TMP/events"
}
restart_menu() { manage_protocol_services >"$TMP/output" 2>&1 <<<$'1\n0'; }
no_pre_stop() { if grep -q '^stop-all$\|^stop|' "$TMP/events"; then exit 1; fi; }
failed_restart() {
    [[ "$RUNNING" == true && ! -e "$CFG/paused" ]]
    no_pre_stop
    cmp "$CFG/singbox.json" "$TMP/old.json"
    grep -q '失败' "$TMP/output"
    if grep -q '所有服务已重启' "$TMP/output"; then exit 1; fi
}

fixture
touch "$CFG/paused"
restart_menu
[[ "$RUNNING" == true && ! -e "$CFG/paused" ]]
no_pre_stop
grep -qx 'generate|true' "$TMP/events"
[[ "$(grep -c '^restart|vless-singbox$' "$TMP/events")" == 1 ]]
jq -e '.fixture=="new"' "$CFG/singbox.json" >/dev/null
grep -q '所有服务已重启' "$TMP/output"
printf '%s\n' 'ok - restart validates while running, restarts through the service manager and clears stale pause state'

for failure in generate service; do
    fixture
    case "$failure" in
        generate) FAIL_GENERATE=true ;;
        service) FAIL_SERVICE=true ;;
    esac
    restart_menu
    failed_restart
    if grep -Eq '^(start|restart)\|vless-singbox$' "$TMP/events"; then exit 1; fi
done
printf '%s\n' 'ok - configuration and service-definition failures leave the running core untouched'

for failure in restart health; do
    fixture
    if [[ "$failure" == restart ]]; then FAIL_RESTART=true; else FAIL_HEALTH=true; fi
    restart_menu
    failed_restart
    [[ "$(grep -c '^restart|vless-singbox$' "$TMP/events")" == 2 ]]
done
printf '%s\n' 'ok - restart and listener failures restore the previous configuration and running service'

fixture
RUNNING=false
touch "$CFG/paused"
restart_menu
[[ "$RUNNING" == true && ! -e "$CFG/paused" ]]
no_pre_stop
grep -qx 'start|vless-singbox' "$TMP/events"
grep -qx 'health|true' "$TMP/events"
printf '%s\n' 'ok - restarting a paused core starts it and checks listener readiness'

fixture
RUNNING=false FAIL_HEALTH=true
restart_menu
grep -q '服务未就绪' "$TMP/output"
if grep -q '所有服务已重启' "$TMP/output"; then exit 1; fi
printf '%s\n' 'ok - a newly started core without ready listeners cannot report restart success'

fixture
if manage_protocol_services >"$TMP/output" 2>&1 </dev/null; then :; fi
[[ ! -s "$TMP/events" && ! -e "$CFG/paused" ]]
printf 2 >"$TMP/incomplete-input"
if manage_protocol_services >"$TMP/output" 2>&1 <"$TMP/incomplete-input"; then :; fi
[[ ! -s "$TMP/events" && ! -e "$CFG/paused" ]]
manage_protocol_services >"$TMP/output" 2>&1 <<<$'2\n0'
[[ "$RUNNING" == false && -f "$CFG/paused" ]]
grep -qx stop-all "$TMP/events"
printf '%s\n' 'ok - EOF and incomplete input do not stop services; explicit stop alone sets the pause marker'

fixture
generate_xray_config() { printf 'generate-xray|%s\n' "$RUNNING" >>"$TMP/events"; }
_start_core_service vless-reality xray vless generate_xray_config >"$TMP/output" 2>&1
[[ "$RUNNING" == true ]]
grep -qx 'restart|vless-reality' "$TMP/events"
printf '%s\n' 'ok - the shared four-argument core starter supports Xray under strict shell options'
