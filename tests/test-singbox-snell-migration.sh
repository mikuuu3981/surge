#!/usr/bin/env bash
# Legacy Snell integration contract. Every file/service operation is sandboxed.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VLESS_TEST_CFG="$TMP/etc"
export VLESS_TEST_SYSTEMD_DIR="$TMP/systemd"
export VLESS_TEST_OPENRC_DIR="$TMP/openrc"
export VLESS_TEST_MIHOMO_BIN="$TMP/bin/vless-mihomo"
export VLESS_TEST_MIHOMO_LOG_FILE="$TMP/log/mihomo.log"
export VLESS_TEST_MESSAGES_LOG="$TMP/log/messages"
mkdir -p "$VLESS_TEST_CFG" "$VLESS_TEST_SYSTEMD_DIR" "$VLESS_TEST_OPENRC_DIR" "$TMP/bin" "$TMP/log"
REAL_BIN="${VLESS_TEST_SINGBOX_BIN:-}"
source "$ROOT/vless-server.sh"
# Legacy migration still names managed binaries literally. Redirect these paths
# in its real snapshot helper and cleanup commands before exercising rollback.
eval "$(declare -f _mihomo_migration_snapshot_path | sed '1s/_mihomo_migration_snapshot_path/_original_snapshot_path/')"
_mihomo_migration_snapshot_path() {
    local path="$3"
    [[ "$path" != /usr/local/bin/* ]] || path="$TMP/bin/${path##*/}"
    _original_snapshot_path "$1" "$2" "$path"
}
rm() {
    local arg
    local -a args=()
    for arg in "$@"; do
        [[ "$arg" != /usr/local/bin/* ]] || arg="$TMP/bin/${arg##*/}"
        args+=("$arg")
    done
    command rm "${args[@]}"
}
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
FAIL_HEALTH=false FAIL_RESTART=false FAIL_CHECK=false FAIL_STOP_SERVICE='' STRICT_MISSING_SERVICE=false
svc() {
    local action="$1" name="$2"
    case "$name" in
        vless-singbox|vless-mihomo|vless-snell|vless-snell-v5|vless-snell-shadowtls|vless-snell-v5-shadowtls|vless-snell-shadowtls-backend|vless-snell-v5-shadowtls-backend) ;;
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
        stop)
            if [[ "$name" == "$FAIL_STOP_SERVICE" ]]; then FAIL_STOP_SERVICE=''; return 1; fi
            if [[ "$STRICT_MISSING_SERVICE" == true && "$name" == vless-singbox &&
                  ! -f "$SYSTEMD_DIR/vless-singbox.service" && ! -f "$OPENRC_DIR/vless-singbox" ]]; then
                return 1
            fi
            RUNNING[$name]=false ;;
        *) return 1 ;;
    esac
}
_wait_for_singbox_ready() {
    if [[ "$FAIL_HEALTH" == true ]]; then FAIL_HEALTH=false; return 1; fi
    [[ "${RUNNING[vless-singbox]:-false}" == true ]]
}
_mihomo_migration_service_state() {
    if [[ "${RUNNING[vless-mihomo]:-false}" == true ]]; then
        printf '%s\n' active
    else
        printf '%s\n' inactive
    fi
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
    FAIL_STOP_SERVICE='' STRICT_MISSING_SERVICE=false
    printf '%s\n' '{"xray":{},"singbox":{},"mihomo":{}}' >"$DB_FILE"
    : >"$TMP/services"
}
if [[ "${VLESS_TEST_MIGRATION_BOUNDARIES_ONLY:-false}" != true ]]; then
reset_fixture
for proto in snell snell-v5 snell-shadowtls snell-v5-shadowtls; do
    [[ "$(protocol_core "$proto")" == singbox ]]
done
change snell add all "$(record 42001 4)"
change snell add all "$(record 42002 4 'legacy+/=._-secret')"
change snell-v5 add all "$(record 42003 5)"
change snell-v6-singbox add all "$(record 42004 6 | jq '.mode="unsafe-raw"')"
check '[.inbounds[] | select(.type=="snell" and .version==5) | .listen_port] == [42001,42002,42003]'
check 'all(.inbounds[] | select(.version==5); .mode==null and .users==null) and any(.inbounds[]; .version==6 and .mode=="unsafe-raw")'
check 'any(.inbounds[]; .psk=="1234567890123456") and any(.inbounds[]; .psk=="legacy+/=._-secret")'
printf '%s\n' 'ok - v4/v5 server mapping, v6 mode and numeric/punctuation PSKs'

stls=$(record 42005 5 | jq '.sni="www.example.com" | .stls_password="legacyShadowTLSsecret" | .snell_backend_port=42006')
change snell-v5-shadowtls add all "$stls"
check 'any(.inbounds[]; .type=="shadowtls" and .listen_port==42005 and .version==3 and .detour!=null)'
# Resolve the detour by tag; a loopback socket is intentional, never a public backend.
check '.inbounds as $all | all($all[] | select(.type=="shadowtls"); .detour as $target |
    any($all[]; .tag==$target and .type=="snell" and .version==5 and
        .listen=="127.0.0.1" and (.listen_port|type)=="number" and .listen_port>=0))'
check 'all(.inbounds[]; .listen_port!=42006)'
gen_surge_sub >"$TMP/surge"
grep -q '42001.*version=4' "$TMP/surge"
grep -q '42003.*version=5' "$TMP/surge"
grep -q '42004.*version=6.*mode=unsafe-raw' "$TMP/surge"
grep -q '42005.*version=5.*shadow-tls' "$TMP/surge"
if grep -q 42006 "$TMP/surge"; then exit 1; fi
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
printf '%s\n' 'ok - legacy multi-port replace/remove rollback preserves all shared listeners'
gen_snell_server_config 1234567890123456 42008
gen_snell_v5_server_config 1234567890123456 42009
jq -e 'all(.singbox.snell[]; .psk=="1234567890123456") and
    any(.singbox["snell-v5"][]; .port==42009 and .psk=="1234567890123456")' "$DB_FILE" >/dev/null
printf '%s\n' 'ok - v4/v5 installation generators keep numeric-only PSKs as strings'
fi

# Migration entry is deliberately explicit: missing migration must fail, not skip.
MIGRATE=${VLESS_TEST_SNELL_MIGRATION_FUNCTION:-migrate_legacy_snell_to_singbox}
declare -F "$MIGRATE" >/dev/null || { printf 'missing migration entry: %s\n' "$MIGRATE" >&2; exit 1; }
legacy_fixture() {
    reset_fixture
    jq -n '{xray:{snell:{port:42101,psk:"old+/=._-PSK",version:4,tfo:"false",users:[{name:"metadata",password:"must-not-auth"}]},
        "snell-shadowtls":{port:42102,psk:"1234567890123456",version:4,sni:"www.example.com",stls_password:"unchangedTLS",snell_backend_port:42103}},
        mihomo:{"snell-v5":[{port:42104,psk:"preserveMihomoKey",version:5}]},
        singbox:{"snell-v6-singbox":[{port:42105,psk:"existingV6secret",version:6,mode:"unshaped"}]}}' >"$DB_FILE"
    printf '%s\n' legacy-config >"$CFG/snell.conf"
    printf '%s\n' legacy-join >"$CFG/snell.join"
    printf '%s\n' legacy-mihomo >"$CFG/mihomo.yaml"
    printf '%s\n' legacy-unit >"$SYSTEMD_DIR/vless-mihomo.service"
    RUNNING[vless-mihomo]=true ENABLED[vless-mihomo]=true
    RUNNING[vless-snell]=true ENABLED[vless-snell]=true
}
if [[ "${VLESS_TEST_MIGRATION_BOUNDARIES_ONLY:-false}" != true ]]; then
legacy_fixture
"$MIGRATE"
jq -e '[.singbox.snell[]] | any(.port==42101 and .psk=="old+/=._-PSK" and .tfo=="false" and .users[0].name=="metadata")' "$DB_FILE" >/dev/null
jq -e '.singbox["snell-shadowtls"][] | .psk=="1234567890123456" and .stls_password=="unchangedTLS"' "$DB_FILE" >/dev/null
jq -e '.singbox["snell-v5"][] | .psk=="preserveMihomoKey"' "$DB_FILE" >/dev/null
jq -e '.xray.snell==null and .mihomo["snell-v5"]==null' "$DB_FILE" >/dev/null
check 'any(.inbounds[]; .version==6 and .mode=="unshaped") and all(.inbounds[] | select(.type=="snell"); .users==null)'
cp "$DB_FILE" "$TMP/migrated-db"
"$MIGRATE"
cmp "$DB_FILE" "$TMP/migrated-db"
printf '%s\n' 'ok - old Xray/Mihomo migration retains credentials/metadata, v6 mode and is idempotent'

for failure in conflict check health restart; do
    legacy_fixture
    if [[ "$failure" == conflict ]]; then
        jq '.singbox.snell=[{port:42101,psk:"differentExistingKey",version:4}]' "$DB_FILE" >"$TMP/db"
        mv "$TMP/db" "$DB_FILE"
    elif [[ "$failure" == check ]]; then
        FAIL_CHECK=true
    elif [[ "$failure" == restart ]]; then
        FAIL_RESTART=true
    else
        FAIL_HEALTH=true
    fi
    cp "$DB_FILE" "$TMP/legacy-db"
    cp "$CFG/snell.join" "$TMP/legacy-join"
    if "$MIGRATE"; then printf 'migration accepted %s\n' "$failure" >&2; exit 1; fi
    cmp "$DB_FILE" "$TMP/legacy-db"
    cmp "$CFG/snell.join" "$TMP/legacy-join"
    [[ "$(<"$CFG/snell.conf")" == legacy-config && "$(<"$CFG/mihomo.yaml")" == legacy-mihomo ]]
    [[ "$(<"$SYSTEMD_DIR/vless-mihomo.service")" == legacy-unit ]]
    [[ "${RUNNING[vless-mihomo]}" == true && "${ENABLED[vless-mihomo]}" == true ]]
    [[ "${RUNNING[vless-snell]}" == true && "${ENABLED[vless-snell]}" == true ]]
    if [[ "$failure" == conflict || "$failure" == check ]]; then
        if grep -Eq '^(stop|start|restart)\|' "$TMP/services"; then exit 1; fi
    fi
done
printf '%s\n' 'ok - migration conflicts/check failures never stop services; startup failures restore legacy files, DB and services'
fi

# Pause defers the migration entirely, including core preparation and service
# queries. Keep legacy ownership so resuming can retry the original records.
legacy_fixture
touch "$CFG/paused"
cp "$DB_FILE" "$TMP/paused-db"
cp "$CFG/snell.join" "$TMP/paused-join"
(
    _prepare_singbox_snell_migration_core() { printf '%s\n' unexpected >"$TMP/prepared-while-paused"; return 1; }
    "$MIGRATE"
)
cmp "$DB_FILE" "$TMP/paused-db"
cmp "$CFG/snell.join" "$TMP/paused-join"
[[ -f "$CFG/paused" && ! -e "$TMP/prepared-while-paused" && ! -s "$TMP/services" ]]
[[ "$(<"$CFG/mihomo.yaml")" == legacy-mihomo && "$(<"$CFG/snell.conf")" == legacy-config ]]
printf '%s\n' 'ok - paused migration defers all database, core and service changes'

# Existing stopped/disabled shared and legacy services are an intentional state,
# not a reason to enable or start the newly consolidated shared service.
legacy_fixture
printf '%s\n' existing-shared-unit >"$SYSTEMD_DIR/vless-singbox.service"
for service in vless-singbox vless-mihomo vless-snell vless-snell-shadowtls vless-snell-shadowtls-backend; do
    RUNNING[$service]=false ENABLED[$service]=false
done
"$MIGRATE"
jq -e 'any(.singbox.snell[]; .port==42101) and .xray.snell==null' "$DB_FILE" >/dev/null
[[ "${RUNNING[vless-singbox]}" == false && "${ENABLED[vless-singbox]}" == false ]]
if grep -Eq '^(start|restart|enable)\|' "$TMP/services"; then exit 1; fi
printf '%s\n' 'ok - migration preserves an existing stopped and disabled shared service'

# Fail after at least one legacy stop. There is no shared unit yet, and the
# manager accurately rejects stopping a nonexistent unit. Rollback must still
# restore every legacy service stopped earlier in the transaction.
legacy_fixture
for service in vless-snell vless-snell-shadowtls vless-snell-shadowtls-backend; do
    printf 'original-%s\n' "$service" >"$SYSTEMD_DIR/$service.service"
    RUNNING[$service]=true ENABLED[$service]=true
done
STRICT_MISSING_SERVICE=true
FAIL_STOP_SERVICE=vless-snell-shadowtls
cp "$DB_FILE" "$TMP/partial-stop-db"
if "$MIGRATE"; then printf '%s\n' 'migration accepted legacy stop failure' >&2; exit 1; fi
cmp "$DB_FILE" "$TMP/partial-stop-db"
grep -q '^stop|vless-snell$' "$TMP/services"
grep -q '^stop|vless-snell-shadowtls$' "$TMP/services"
grep -Eq '^(start|restart)\|vless-snell$' "$TMP/services"
[[ ! -e "$SYSTEMD_DIR/vless-singbox.service" && ! -e "$OPENRC_DIR/vless-singbox" ]]
[[ "${RUNNING[vless-singbox]:-false}" == false && "${ENABLED[vless-singbox]:-false}" == false ]]
for service in vless-mihomo vless-snell vless-snell-shadowtls vless-snell-shadowtls-backend; do
    [[ "${RUNNING[$service]}" == true && "${ENABLED[$service]}" == true ]]
done
for service in vless-snell vless-snell-shadowtls vless-snell-shadowtls-backend; do
    [[ "$(<"$SYSTEMD_DIR/$service.service")" == "original-$service" ]]
done
[[ "$(<"$CFG/snell.conf")" == legacy-config && "$(<"$CFG/snell.join")" == legacy-join &&
   "$(<"$CFG/mihomo.yaml")" == legacy-mihomo ]]
printf '%s\n' 'ok - partial legacy stop failure restores services and files without a shared service definition'

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

# Exercise the real uninstall menu following a failed migration, with the
# selected owner still in Xray. Unrelated shared and legacy records must survive.
legacy_fixture
FAIL_CHECK=true
if "$MIGRATE"; then exit 1; fi
FAIL_CHECK=false
jq '.singbox' "$DB_FILE" >"$TMP/uninstall-shared-before"
jq '.xray["snell-shadowtls"]' "$DB_FILE" >"$TMP/uninstall-shadowtls-before"
printf '%s\n' legacy-snell-unit >"$SYSTEMD_DIR/vless-snell.service"
(
    get_installed_protocols() { printf '%s\n' snell; }
    select_port_to_uninstall() { SELECTED_PORT=42101; SELECTED_PROTOCOL_CORE=xray; }
    # Keep the menu's unrelated subscription cleanup out of this fixture.
    is_protocol_installed() { [[ "$1" == vless-ws ]]; }
    generate_sub_files() { :; }
    uninstall_specific_protocol <<<$'1\ny'
)
jq -e '.xray.snell==null and .mihomo["snell-v5"][0].psk=="preserveMihomoKey"' "$DB_FILE" >/dev/null
[[ ! -e "$CFG/snell.conf" && ! -e "$CFG/snell.join" && ! -e "$SYSTEMD_DIR/vless-snell.service" ]]
jq '.singbox' "$DB_FILE" >"$TMP/uninstall-shared-after"
jq '.xray["snell-shadowtls"]' "$DB_FILE" >"$TMP/uninstall-shadowtls-after"
cmp "$TMP/uninstall-shared-before" "$TMP/uninstall-shared-after"
cmp "$TMP/uninstall-shadowtls-before" "$TMP/uninstall-shadowtls-after"
printf '%s\n' 'ok - failed migration leaves Xray-owned Snell uninstallable through the menu'
