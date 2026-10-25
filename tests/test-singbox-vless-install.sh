#!/usr/bin/env bash
# 安装失败注入；服务、核心和网络均为模拟实现。
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VLESS_TEST_CFG="$TMP/etc"
export VLESS_TEST_SYSTEMD_DIR="$TMP/systemd"
export VLESS_TEST_OPENRC_DIR="$TMP/openrc"
mkdir -p "$VLESS_TEST_CFG" "$VLESS_TEST_SYSTEMD_DIR" "$VLESS_TEST_OPENRC_DIR"
source "$ROOT/vless-server.sh"
_log() { :; }
systemctl() { :; }
RUNNING=true ENABLED=true FAIL=none
svc() {
    [[ "$2" == vless-singbox ]] || return 1
    case "$1" in
        status) [[ "$RUNNING" == true ]] ;;
        enabled) [[ "$ENABLED" == true ]] ;;
        enable) ENABLED=true ;;
        disable) ENABLED=false ;;
        stop) RUNNING=false ;;
        start|restart)
            if [[ "$FAIL" == restart ]]; then FAIL=none; return 1; fi
            RUNNING=true ;;
        *) return 1 ;;
    esac
}
_wait_for_singbox_ready() {
    if [[ "$FAIL" == health ]]; then FAIL=none; return 1; fi
    [[ "$RUNNING" == true ]]
}
generate_singbox_config() {
    [[ "$FAIL" != validation ]] || return 1
    jq '{inbounds:[.singbox["vless-singbox"]]}' "$DB_FILE" >"$1"
}
regenerate_singbox_vless_join_info() { printf '%s\n' new-join >"$CFG/vless-singbox.join"; }
create_singbox_service() { printf '%s\n' new-unit >"$SYSTEMD_DIR/vless-singbox.service"; }
fixture() {
    INSTALL_MODE='' REPLACE_PORT=''
    printf '%s\n' '{"xray":{"vless":{"port":41000}},"singbox":{"hy2":{"port":41001}}}' >"$DB_FILE"
    printf '%s\n' old-config >"$CFG/singbox.json"
    printf '%s\n' old-unit >"$SYSTEMD_DIR/vless-singbox.service"
    printf '%s\n' old-join >"$CFG/vless-singbox.join"
    printf '%s\n' old-global-join >"$CFG/join.txt"
    printf '%s\n' old-role >"$CFG/role"
    cp "$DB_FILE" "$TMP/before-db"
    RUNNING=true ENABLED=true
}
record='{"port":41002,"uuid":"bf000d23-0752-40b4-affe-68f7707a9661","private_key":"test","public_key":"test","short_id":"1234","sni":"example.com","security_mode":"reality"}'
for failure in validation restart health; do
    fixture
    FAIL="$failure"
    if _apply_singbox_vless_config "$record"; then
        printf 'unexpected success: %s\n' "$failure" >&2
        exit 1
    fi
    cmp "$DB_FILE" "$TMP/before-db"
    [[ "$(cat "$CFG/singbox.json")" == old-config ]]
    [[ "$(cat "$CFG/vless-singbox.join")" == old-join ]]
    [[ "$(cat "$CFG/join.txt")" == old-global-join ]]
    [[ "$(cat "$CFG/role")" == old-role ]]
    [[ "$(cat "$SYSTEMD_DIR/vless-singbox.service")" == old-unit ]]
    [[ "$RUNNING" == true && "$ENABLED" == true ]]
done
printf '%s\n' 'ok - validation, restart and health failures restore existing shared service and records'
fixture
RUNNING=false ENABLED=false FAIL=health
if _apply_singbox_vless_config "$record"; then exit 1; fi
[[ "$RUNNING" == false && "$ENABLED" == false ]]
cmp "$DB_FILE" "$TMP/before-db"
printf '%s\n' 'ok - stopped and disabled service stays stopped and disabled on failure'
fixture
FAIL=none
_apply_singbox_vless_config "$record"
jq -e '.xray.vless.port==41000 and .singbox.hy2.port==41001 and .singbox["vless-singbox"][0].port==41002' "$DB_FILE" >/dev/null
[[ "$RUNNING" == true && "$ENABLED" == true ]]
[[ "$(cat "$CFG/vless-singbox.join")" == new-join ]]
[[ "$(cat "$CFG/role")" == server ]]
printf '%s\n' 'ok - successful installation retains other cores and shared listeners'
cp "$DB_FILE" "$TMP/success-db"
duplicate=$(jq '.port=41000' <<<"$record")
if _apply_singbox_vless_config "$duplicate"; then exit 1; fi
cmp "$DB_FILE" "$TMP/success-db"
INSTALL_MODE=replace REPLACE_PORT=49999
if _apply_singbox_vless_config "$record"; then exit 1; fi
cmp "$DB_FILE" "$TMP/success-db"
INSTALL_MODE=add REPLACE_PORT=''
second=$(jq '.port=41003' <<<"$record")
_apply_singbox_vless_config "$second"
INSTALL_MODE=replace REPLACE_PORT=41002
replacement=$(jq '.port=41004' <<<"$record")
_apply_singbox_vless_config "$replacement"
jq -e '[.singbox["vless-singbox"][].port]==[41004,41003]' "$DB_FILE" >/dev/null
printf '%s\n' 'ok - cross-core conflicts and missing targets fail; adding and replacing retains other ports'
