#!/usr/bin/env bash
# Sing-box Snell v4/v5 and built-in ShadowTLS. All service/file operations are sandboxed.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VLESS_TEST_CFG="$TMP/etc"
export VLESS_TEST_SYSTEMD_DIR="$TMP/systemd"
export VLESS_TEST_OPENRC_DIR="$TMP/openrc"
mkdir -p "$VLESS_TEST_CFG" "$VLESS_TEST_SYSTEMD_DIR" "$VLESS_TEST_OPENRC_DIR"
REAL_BIN="${VLESS_TEST_SINGBOX_BIN:-}"
source "$ROOT/vless-server.sh"
_log() { :; }; _header() { :; }; _pause() { :; }
_listen_addr() { printf '%s\n' 127.0.0.1; }
get_connection_addresses() { printf '%s\n' '192.0.2.1|2001:db8::1'; }
get_ip_country() { printf '%s\n' TEST; }
systemctl() { printf '%s\n' "$*" >>"$TMP/systemctl"; }
create_singbox_service() { printf '%s\n' shared-unit >"$SYSTEMD_DIR/vless-singbox.service"; }
ensure_singbox_snell_support() { :; }
sing-box() {
    if [[ "$1" == check && "${FAIL_CHECK:-false}" == true ]]; then return 1; fi
    if [[ -n "$REAL_BIN" ]]; then "$REAL_BIN" "$@"; return $?; fi
    case "$1" in version) printf '%s\n' 'sing-box version 1.14.3' ;; check) jq empty "$3" ;; *) return 1 ;; esac
}
declare -A RUNNING ENABLED
FAIL_HEALTH=false FAIL_RESTART=false FAIL_CHECK=false
svc() {
    local action="$1" name="$2"
    case "$name" in
        vless-singbox) ;;
        *) printf 'unexpected service: %s\n' "$name" >&2; return 1 ;;
    esac
    printf '%s|%s\n' "$action" "$name" >>"$TMP/services"
    case "$action" in
        status) [[ "${RUNNING[$name]:-false}" == true ]] ;;
        enabled) [[ "${ENABLED[$name]:-false}" == true ]] ;;
        enable) ENABLED[$name]=true ;;
        disable) ENABLED[$name]=false ;;
        start|restart)
            if [[ "$name" == vless-singbox && "$FAIL_RESTART" == true ]]; then
                FAIL_RESTART=false
                return 1
            fi
            RUNNING[$name]=true ;;
        stop) RUNNING[$name]=false ;;
        *) return 1 ;;
    esac
}
_wait_for_singbox_ready() {
    if [[ "$FAIL_HEALTH" == true ]]; then FAIL_HEALTH=false; return 1; fi
    [[ "${RUNNING[vless-singbox]:-false}" == true ]]
}
record() {
    jq -nc --argjson port "$1" --argjson version "$2" --arg psk "${3:-1234567890123456}" \
        '{port:$port,version:$version,psk:$psk,tfo:"false"}'
}
change() { _apply_singbox_snell_change "$2" "$3" "$4" "$1"; }
check() { jq -e "$1" "$CFG/singbox.json" >/dev/null; }
reset_fixture() {
    rm -rf "$CFG"/* "$CFG"/.[!.]* "$SYSTEMD_DIR"/* "$OPENRC_DIR"/*
    RUNNING=() ENABLED=() FAIL_HEALTH=false FAIL_RESTART=false FAIL_CHECK=false
    printf '%s\n' '{"xray":{},"singbox":{},"mihomo":{}}' >"$DB_FILE"
    : >"$TMP/services"
}
reset_fixture
for proto in snell snell-v5 snell-shadowtls snell-v5-shadowtls; do
    [[ "$(protocol_core "$proto")" == singbox ]]
done
change snell add all "$(record 42001 4)"
change snell add all "$(record 42002 4 'punctuation+/=._-secret')"
change snell-v5 add all "$(record 42003 5)"
change snell-v6-singbox add all "$(record 42004 6 | jq '.mode="unsafe-raw"')"
check '[.inbounds[] | select(.type=="snell" and .version==5) | .listen_port] == [42001,42002,42003]'
check 'all(.inbounds[] | select(.version==5); .mode==null and .users==null) and any(.inbounds[]; .version==6 and .mode=="unsafe-raw")'
check 'any(.inbounds[]; .psk=="1234567890123456") and any(.inbounds[]; .psk=="punctuation+/=._-secret")'
printf '%s\n' 'ok - v4/v5 server mapping, v6 mode and numeric/punctuation PSKs'

stls=$(record 42005 5 | jq '.sni="www.example.com" | .stls_password="testShadowTLSsecret"')
change snell-v5-shadowtls add all "$stls"
check 'any(.inbounds[]; .type=="shadowtls" and .listen_port==42005 and .version==3 and .detour!=null)'
# Resolve the detour by tag; a loopback socket is intentional, never a public backend.
check '.inbounds as $all | all($all[] | select(.type=="shadowtls"); .detour as $target |
    any($all[]; .tag==$target and .type=="snell" and .version==5 and
        .listen=="127.0.0.1" and (.listen_port|type)=="number" and .listen_port>=0))'
gen_surge_sub >"$TMP/surge"
grep -q '42001.*version=4' "$TMP/surge"
grep -q '42003.*version=5' "$TMP/surge"
grep -q '42004.*version=6.*mode=unsafe-raw' "$TMP/surge"
grep -q '42005.*version=5.*shadow-tls' "$TMP/surge"
printf '%s\n' 'ok - ShadowTLS internal detour uses loopback backend; subscriptions retain client versions'

for name in db config join; do
    case "$name" in db) file="$DB_FILE" ;; config) file="$CFG/singbox.json" ;; join) file="$CFG/snell.join" ;; esac
    cp "$file" "$TMP/before-$name"
done
for failure in health restart; do
    if [[ "$failure" == health ]]; then FAIL_HEALTH=true; else FAIL_RESTART=true; fi
    if change snell replace 42002 "$(record 42007 4)"; then exit 1; fi
    cmp "$DB_FILE" "$TMP/before-db"
    cmp "$CFG/singbox.json" "$TMP/before-config"
    cmp "$CFG/snell.join" "$TMP/before-join"
    [[ "${RUNNING[vless-singbox]}" == true && "${ENABLED[vless-singbox]}" == true ]]
done
for bad in "$(record 42003 4)" "$(record 42007 5)" \
    "$(record 42007 4 | jq '.quic=true')" "$(record 42007 4 | jq '.psk=1234567890123456')"; do
    if change snell add all "$bad"; then exit 1; fi
    cmp "$DB_FILE" "$TMP/before-db"
    cmp "$CFG/singbox.json" "$TMP/before-config"
done
change snell replace 42002 "$(record 42007 4)"
change snell remove 42001 '{}'
check 'any(.inbounds[]; .listen_port==42007) and all(.inbounds[]; .listen_port!=42001 and .listen_port!=42002)'
change snell remove all '{}'
check 'any(.inbounds[]; .listen_port==42003) and any(.inbounds[]; .listen_port==42004)'
[[ "${RUNNING[vless-singbox]}" == true && -f "$SYSTEMD_DIR/vless-singbox.service" ]]
printf '%s\n' 'ok - v4/v5 multi-port replace/remove rollback preserves all shared listeners'
gen_snell_server_config 1234567890123456 42008
gen_snell_v5_server_config 1234567890123456 42009
jq -e 'all(.singbox.snell[]; .psk=="1234567890123456") and
    any(.singbox["snell-v5"][]; .port==42009 and .psk=="1234567890123456")' "$DB_FILE" >/dev/null
printf '%s\n' 'ok - v4/v5 installation generators keep numeric-only PSKs as strings'

# Removing the last Sing-box Snell listener must leave Mieru untouched.
reset_fixture
jq '.mihomo.mieru={port:42301,username:"mieru",password:"fixture-password",transport:"TCP"}' "$DB_FILE" >"$TMP/db"
mv "$TMP/db" "$DB_FILE"
printf '%s\n' mieru-config >"$CFG/mihomo.yaml"
printf '%s\n' mieru-service >"$SYSTEMD_DIR/vless-mihomo.service"
change snell add all "$(record 42302 4)"
change snell remove all '{}'
jq -e '.singbox.snell==null and .mihomo.mieru.port==42301' "$DB_FILE" >/dev/null
[[ "$(<"$CFG/mihomo.yaml")" == mieru-config && "$(<"$SYSTEMD_DIR/vless-mihomo.service")" == mieru-service ]]
printf '%s\n' 'ok - removing the last shared Snell listener preserves Mieru records, configuration and service'

# Multiple ephemeral loopback sockets are not duplicate public ports. Exercise
# both STLS variants and multiple ports, then validate the actual generated JSON.
reset_fixture
for spec in 'snell-shadowtls 42201 4' 'snell-shadowtls 42202 4' 'snell-v5-shadowtls 42203 5'; do
    read -r proto port version <<<"$spec"
    change "$proto" add all "$(record "$port" "$version" 'short-test.psk!' | jq '.sni="www.example.com" | .stls_password="testShadowTLSsecret"')"
done
check '[.inbounds[] | select(.type=="shadowtls")] | length==3'
check '[.inbounds[] | select(.type=="snell" and .listen=="127.0.0.1" and .listen_port==0)] | length==3'
check '.inbounds as $all | all($all[] | select(.type=="shadowtls"); .detour as $target |
    any($all[]; .tag==$target and .listen=="127.0.0.1" and .listen_port==0))'
validate_singbox_config "$CFG/singbox.json"
printf '%s\n' 'ok - multiple ShadowTLS ephemeral loopback backends coexist without duplicate-port rejection'
if [[ -n "$REAL_BIN" ]]; then
    python3 "$ROOT/tests/test-singbox-shadowtls-runtime.py" "$REAL_BIN" "$CFG/singbox.json"
fi

# Retired namespaces must not expose nodes in menus or restart their services.
reset_fixture
jq -n '{xray:{snell:{port:42401},"snell-v5-shadowtls":{port:42402}},
    mihomo:{"snell-v5":{port:42403},"snell-shadowtls":{port:42404}},singbox:{}}' >"$DB_FILE"
cp "$DB_FILE" "$TMP/retired-db"
[[ -z "$(get_installed_protocols)" && -z "$(get_mihomo_protocols)" && -z "$(get_singbox_protocols)" ]]
[[ "$(protocol_active_db_core snell)" == singbox && "$(protocol_uninstall_db_core snell-v5)" == singbox ]]
(
    set +e
    show_status >"$TMP/retired-status"
    [[ -z "$_INSTALLED_CACHE" ]] && grep -q '未安装' "$TMP/retired-status"
)
create_server_scripts
bash -n "$CFG/watchdog.sh"
sed -n '/^get_all_services() {$/,/^}$/p' "$CFG/watchdog.sh" >"$TMP/watchdog-functions"
watchdog_services() { env CFG="$CFG" bash -c 'source "$1"; get_all_services' _ "$TMP/watchdog-functions"; }
[[ -z "$(watchdog_services)" ]]
cmp "$DB_FILE" "$TMP/retired-db"

jq '.xray["snell-v6"]={port:42405} | .xray["ss2022-shadowtls"]={port:42406} |
    .xray.naive={port:42407} | .xray.vless={port:42408} |
    .singbox.snell={port:42409} | .mihomo.mieru={port:42410}' "$DB_FILE" >"$TMP/db"
mv "$TMP/db" "$DB_FILE"
[[ "$(get_installed_protocols)" == $'mieru\nnaive\nsnell\nsnell-v6\nss2022-shadowtls\nvless' ]]
watchdog_services | tr ' ' '\n' | sed '/^$/d' | sort >"$TMP/watched-services"
printf '%s\n' vless-mihomo:vless-mihomo vless-naive:caddy vless-reality:xray \
    vless-singbox:sing-box vless-snell-v6:snell-server-v6 \
    vless-ss2022-shadowtls:shadow-tls vless-ss2022-shadowtls-backend:xray | sort >"$TMP/expected-services"
cmp "$TMP/watched-services" "$TMP/expected-services"
printf '%s\n' 'ok - menus and watchdog ignore retired namespaces and retain current shared and standalone services'
