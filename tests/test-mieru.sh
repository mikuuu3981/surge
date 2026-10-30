#!/usr/bin/env bash
# Offline Mieru lifecycle, AI routing, cache, subscription and core isolation regressions.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'if [[ $? != 0 ]]; then cat "$TMP"/*check.log 2>/dev/null || :; fi; rm -rf "$TMP"' EXIT
trap 'printf "FAIL at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
export VLESS_TEST_CFG="$TMP/etc" VLESS_TEST_SYSTEMD_DIR="$TMP/systemd" VLESS_TEST_OPENRC_DIR="$TMP/openrc"
export VLESS_TEST_MIHOMO_BIN="${VLESS_TEST_MIHOMO_BIN:-$TMP/bin/vless-mihomo}"
mkdir -p "$VLESS_TEST_CFG" "$VLESS_TEST_SYSTEMD_DIR" "$VLESS_TEST_OPENRC_DIR" "$TMP/bin"
REAL_BIN="${VLESS_TEST_MIHOMO_BIN}"
source "$ROOT/vless-server.sh"
_log() { :; }; _header() { :; }; _line() { :; }; _pause() { :; }
_listen_addr() { printf '127.0.0.1\n'; }
systemctl() { [[ "$*" == daemon-reload ]]; }
RUNNING=false ENABLED=false FAIL_RESTART=false FAIL_HEALTH=false FAIL_CONFIG=false DOWNLOAD_FAIL=false
svc() {
    [[ "$2" == vless-mihomo ]] || { printf 'unexpected service: %s\n' "$*" >&2; return 1; }
    printf '%s\n' "$1" >>"$TMP/service-calls"
    case "$1" in
        status) [[ "$RUNNING" == true ]] ;;
        enabled) [[ "$ENABLED" == true ]] ;;
        enable) ENABLED=true ;;
        disable) ENABLED=false ;;
        start) RUNNING=true ;;
        stop) RUNNING=false ;;
        restart) [[ "$FAIL_RESTART" != true ]] || { FAIL_RESTART=false; RUNNING=false; return 1; }; RUNNING=true ;;
        *) return 1 ;;
    esac
}
eval "$(declare -f _wait_for_mihomo_ready | sed '1s/_wait_for_mihomo_ready/_real_wait_for_mihomo_ready/')"
_wait_for_mihomo_ready() {
    [[ "$FAIL_HEALTH" != true ]] || { FAIL_HEALTH=false; return 1; }
    [[ "$RUNNING" == true ]]
}
eval "$(declare -f validate_mihomo_config | sed '1s/validate_mihomo_config/_real_validate_mihomo_config/')"
validate_mihomo_config() {
    [[ "$FAIL_CONFIG" != true ]] || return 1
    jq empty "$1"
    if [[ -x "$REAL_BIN" ]]; then _real_validate_mihomo_config "$1" >"$TMP/core-check.log" 2>&1; fi
}
curl() {
    local output='' url=''
    while (($#)); do
        case "$1" in
            -o) output="$2"; shift 2 ;;
            https://*) url="$1"; shift ;;
            *) shift ;;
        esac
    done
    [[ "$DOWNLOAD_FAIL" != true ]] || return 1
    printf '%s\n' "$url" >>"$TMP/downloads"
    case "$url" in
        https://ruleset.skk.moe/Clash/non_ip/ai.txt) printf '# fixture\nDOMAIN-SUFFIX,ai.fixture\nDOMAIN-KEYWORD,assistant\n' >"$output" ;;
        https://ruleset.skk.moe/Clash/ip/ai.txt) printf '# fixture\nIP-CIDR,127.0.0.2/32,no-resolve\nIP-CIDR6,2001:db8::/32,no-resolve\n' >"$output" ;;
        *) printf 'unexpected download: %s\n' "$url" >&2; return 1 ;;
    esac
}
get_connection_addresses() { printf '192.0.2.1|2001:db8::1\n'; }
get_ip_country() { printf 'TEST\n'; }
get_all_external_links() { :; }
fixture() {
    jq -n '{xray:{},singbox:{},mihomo:{},routing_rules:[],
        chain_proxy:{nodes:[{name:"landing",type:"socks",server:"127.0.0.1",port:1080,username:"fixture",password:"quote\"pass"}]}}' >"$DB_FILE"
    RUNNING=false ENABLED=false FAIL_CONFIG=false FAIL_RESTART=false FAIL_HEALTH=false
}
fixture
record='{"port":43001,"username":"00123","password":"00123456789","transport":"TCP"}'
touch "$CFG/paused"
_apply_mieru_change add all "$record"
[[ "$RUNNING" == true && "$ENABLED" == true ]]
[[ ! -f "$CFG/paused" ]]
[[ "$(protocol_core mieru)" == mihomo && "$(protocol_subscription_db_core mieru)" == mihomo ]]
jq -e '.listeners[0].users["00123"]=="00123456789" and .listeners[0].transport=="TCP" and .rules==["MATCH,DIRECT"]' "$MIHOMO_CONFIG" >/dev/null
[[ "$(stat -c %a "$MIHOMO_CONFIG")" == 600 ]]
cp "$DB_FILE" "$TMP/saved-db"
cp "$MIHOMO_CONFIG" "$TMP/saved-config"
for failure in config restart health; do
    case "$failure" in config) FAIL_CONFIG=true ;; restart) FAIL_RESTART=true ;; health) FAIL_HEALTH=true ;; esac
    if _apply_mieru_change add all '{"port":43002,"username":"user2","password":"second-password","transport":"UDP"}'; then exit 1; fi
    FAIL_CONFIG=false
    cmp "$DB_FILE" "$TMP/saved-db"
    cmp "$MIHOMO_CONFIG" "$TMP/saved-config"
    [[ "$RUNNING" == true && "$ENABLED" == true ]]
done
if _apply_mieru_change add all "$record"; then exit 1; fi
cmp "$DB_FILE" "$TMP/saved-db"
_apply_mieru_change add all '{"port":43002,"username":"user2","password":"second-password","transport":"UDP"}'
_apply_mieru_change replace 43002 '{"port":43003,"username":"user2","password":"second-password","transport":"UDP"}'
jq -e '[.listeners[].port]==[43001,43003]' "$MIHOMO_CONFIG" >/dev/null
printf 'ok - TCP/UDP multi-port installation, replacement, duplicate rejection and rollback\n'

db_add_routing_rule mihomo-ai chain:landing '' as_is
db_add_routing_rule singbox-ai chain:unavailable-singbox '' as_is
db_add_routing_rule ai-intl chain:unavailable-xray '' as_is
db_add_routing_rule all block '' as_is
generate_mihomo_config
jq -e '.proxies[0].password=="quote\"pass" and .rules==["RULE-SET,skk-ai-non-ip,AI-OUT","RULE-SET,skk-ai-ip,AI-OUT","MATCH,DIRECT"] and
    .sniffer.enable and .sniffer["override-destination"]==false' "$MIHOMO_CONFIG" >/dev/null
db_get_routing_rules xray | jq -e 'all(.[];.type!="mihomo-ai")' >/dev/null
db_get_routing_rules singbox | jq -e 'all(.[];.type!="mihomo-ai")' >/dev/null
[[ "$(wc -l <"$TMP/downloads")" == 2 ]]
generate_mihomo_config
[[ "$(wc -l <"$TMP/downloads")" == 2 ]]
touch -t 200001010000 "$CFG"/ruleset/mihomo-*.txt
DOWNLOAD_FAIL=true
generate_mihomo_config
cp "$MIHOMO_CONFIG" "$TMP/old-config"
mv "$CFG/ruleset/mihomo-skk-ai-ip.txt" "$TMP/old-ip"
if generate_mihomo_config; then exit 1; fi
cmp "$MIHOMO_CONFIG" "$TMP/old-config"
mv "$TMP/old-ip" "$CFG/ruleset/mihomo-skk-ai-ip.txt"
DOWNLOAD_FAIL=false
for mode in ipv4_only ipv6_only; do
    db_add_routing_rule mihomo-ai chain:landing '' "$mode"
    generate_mihomo_config
    jq -e '.rules[0]|startswith("AND,((RULE-SET,skk-ai-non-ip),")' "$MIHOMO_CONFIG" >/dev/null
done
db_add_routing_rule mihomo-ai chain:landing '' as_is
: >"$TMP/service-calls"
_reload_ai_routing_core mihomo-ai
[[ "$(rg -c '^restart$' "$TMP/service-calls")" == 1 ]]
printf 'ok - AI core isolation, domain/IP matching, cache reuse/fallback and reload isolation\n'

gen_clash_sub >"$TMP/sub.yaml"
rg -q '"type":"mieru".*"username":"00123","password":"00123456789","udp":true,"transport":"TCP"' "$TMP/sub.yaml"
rg -q 'TEST-Mieru-43003' "$TMP/sub.yaml"
if [[ -x "$REAL_BIN" ]]; then
    # Extract the Mieru nodes into a local-only validation config; the full client
    # template contains unrelated GEOIP rules that would download a database.
    python3 - "$TMP/sub.yaml" "$TMP/sub-nodes.json" <<'PYTEST'
import json,sys
nodes=[json.loads(line.strip()[2:]) for line in open(sys.argv[1]) if line.strip().startswith('- {')]
json.dump({'proxies':nodes,'rules':['MATCH,DIRECT']},open(sys.argv[2],'w'))
PYTEST
    "$REAL_BIN" -t -d "$TMP" -f "$TMP/sub-nodes.json" >"$TMP/sub-check.log" 2>&1
fi
# Current Sing-box Snell must survive every Mieru port removal below.
jq '.singbox.snell={port:43004,psk:"preserve-snell-key",version:4}' "$DB_FILE" >"$TMP/mixed-db"
mv "$TMP/mixed-db" "$DB_FILE"
printf '%s\n' shared-snell-config >"$CFG/singbox.json"
printf '%s\n' shared-snell-service >"$SYSTEMD_DIR/vless-singbox.service"
jq '.singbox' "$DB_FILE" >"$TMP/singbox-before"
[[ "$(gen_mieru_client_proxy '[2001:db8::1]' "$record" test | jq -r .server)" == 2001:db8::1 ]]
printf 'ok - Mihomo subscription, credential types, IPv6 and current Sing-box Snell coexistence\n'

_apply_mieru_change remove 43003 '{}'
jq -e '[.listeners[].port]==[43001]' "$MIHOMO_CONFIG" >/dev/null
RUNNING=false ENABLED=false
_apply_mieru_change reload
[[ "$RUNNING" == false && "$ENABLED" == false ]]
_apply_mieru_change remove all '{}'
[[ ! -f "$MIHOMO_CONFIG" && ! -f "$SYSTEMD_DIR/vless-mihomo.service" ]]
jq -e '.mihomo.mieru==null and (.routing_rules|length)>0' "$DB_FILE" >/dev/null
jq '.singbox' "$DB_FILE" >"$TMP/singbox-after"
cmp "$TMP/singbox-before" "$TMP/singbox-after"
[[ "$(<"$CFG/singbox.json")" == shared-snell-config && "$(<"$SYSTEMD_DIR/vless-singbox.service")" == shared-snell-service ]]
printf 'ok - per-port removal, stopped-service state and Sing-box Snell resource preservation\n'

(
    fixture
    _select_outbound() { printf 'chain:landing\n'; }
    _apply_mieru_change add all "$record"
    _add_routing_rule <<<'m
3' >"$TMP/menu-add"
    jq -e 'any(.routing_rules[];.type=="mihomo-ai" and .outbound=="chain:landing")' "$DB_FILE" >/dev/null
    _del_routing_rule <<<1
    jq -e '.routing_rules|length==0' "$DB_FILE" >/dev/null
    cp "$DB_FILE" "$TMP/menu-before"
    FAIL_RESTART=true
    if _add_routing_rule <<<'m
3' >"$TMP/menu-failure"; then exit 1; fi
    cmp "$DB_FILE" "$TMP/menu-before"
    printf 'IP-ASN,399358\n' >"$TMP/asn-fixture"
    _mihomo_ai_cache_valid "$TMP/asn-fixture"
    printf 'MATCH,DIRECT\n' >"$TMP/invalid-fixture"
    if _mihomo_ai_cache_valid "$TMP/invalid-fixture"; then exit 1; fi
)
(
    fixture
    select_protocol <<<16 >"$TMP/protocol-menu"
    [[ "$SELECTED_PROTOCOL" == mieru ]]
    install_deps() { :; }; install_mihomo() { :; }
    ask_port() { printf '43002\n'; }; ask_password() { printf 'installer-password\n'; }
    create_server_scripts() { :; }; create_watchdog_service() { :; }
    eval "$(declare -f svc | sed '1s/svc/_node_svc/')"
    svc() { [[ "$2" != vless-watchdog ]] || return 0; _node_svc "$@"; }
    _install_mieru_interactive <<<'installuser
2' >"$TMP/install-menu"
    jq -e '.listeners[0].transport=="UDP" and .listeners[0].users.installuser=="installer-password"' "$MIHOMO_CONFIG" >/dev/null
    [[ -f "$SYSTEMD_DIR/vless-mihomo.service" && "$RUNNING" == true ]]
    jq -e '.listeners[0].port==43002' "$MIHOMO_CONFIG" >/dev/null
)
printf 'ok - install/AI menus, AI failure rollback, ASN acceptance and Mihomo service installation\n'

# Exercise the real installer with local release artifacts, including SHA-256.
VLESS_TEST_CFG="$TMP/installer/etc" VLESS_TEST_MIHOMO_BIN="$TMP/installer/bin/vless-mihomo" \
    bash -s -- "$ROOT" "$TMP/installer" <<'INSTALLTEST'
set -euo pipefail
ROOT="$1" INSTALL_TMP="$2"
mkdir -p "$VLESS_TEST_CFG" "$(dirname "$VLESS_TEST_MIHOMO_BIN")"
source "$ROOT/vless-server.sh"
_log() { :; }
_get_latest_version() { printf '1.19.33\n'; }
cat >"$INSTALL_TMP/good" <<'CORE'
#!/usr/bin/env bash
[[ "$1" == -v || "$1" == -t ]]
CORE
cat >"$INSTALL_TMP/unsupported" <<'CORE'
#!/usr/bin/env bash
[[ "$1" == -v ]]
CORE
chmod 755 "$INSTALL_TMP/good" "$INSTALL_TMP/unsupported"
gzip -c "$INSTALL_TMP/good" >"$INSTALL_TMP/good.gz"
gzip -c "$INSTALL_TMP/unsupported" >"$INSTALL_TMP/unsupported.gz"
ASSET="$INSTALL_TMP/good.gz" BAD_DIGEST=false RUNNING=false FAIL_RESTART=false
curl() {
    local url='' output='' digest
    while (($#)); do
        case "$1" in -o) output="$2"; shift 2 ;; https://*) url="$1"; shift ;; *) shift ;; esac
    done
    if [[ "$url" == https://api.github.com/* ]]; then
        digest=$(_sha256_file "$ASSET")
        [[ "$BAD_DIGEST" != true ]] || digest=$(printf '%064d' 0)
        jq -n --arg digest "sha256:$digest" '{assets:[{name:"mihomo-linux-amd64-v1-v1.19.33.gz",digest:$digest}]}'
    else
        [[ "$url" == https://github.com/MetaCubeX/mihomo/releases/download/v1.19.33/mihomo-linux-amd64-v1-v1.19.33.gz ]] || return 1
        cp "$ASSET" "$output"
    fi
}
uname() { printf 'x86_64\n'; }
svc() {
    [[ "$2" == vless-mihomo ]] || return 1
    case "$1" in
        status) [[ "$RUNNING" == true ]] ;;
        restart) [[ "$FAIL_RESTART" != true ]] || { FAIL_RESTART=false; return 1; } ;;
        *) return 1 ;;
    esac
}
_wait_for_mihomo_ready() { return 0; }
install_mihomo
cmp "$MIHOMO_BIN" "$INSTALL_TMP/good"
BAD_DIGEST=true
if install_mihomo stable true 1.19.33; then exit 1; fi
cmp "$MIHOMO_BIN" "$INSTALL_TMP/good"
BAD_DIGEST=false ASSET="$INSTALL_TMP/unsupported.gz"
if install_mihomo stable true 1.19.33; then exit 1; fi
cmp "$MIHOMO_BIN" "$INSTALL_TMP/good"
ASSET="$INSTALL_TMP/good.gz" RUNNING=true FAIL_RESTART=true
if update_mihomo_core <<<1.19.33; then exit 1; fi
cmp "$MIHOMO_BIN" "$INSTALL_TMP/good"
printf 'ok - core artifact checksum, unsupported version rejection and update rollback\n'
INSTALLTEST

if [[ -x "$REAL_BIN" ]]; then
    fixture
    jq --argjson record "$record" '.mihomo.mieru=[$record] | .routing_rules=[{type:"mihomo-ai",outbound:"block",ip_version:"as_is"}]' "$DB_FILE" >"$TMP/db"
    mv "$TMP/db" "$DB_FILE"
    generate_mihomo_config
    python3 "$ROOT/tests/test-mieru-loopback.py" "$REAL_BIN" "$MIHOMO_CONFIG" "$TMP"
else
    printf 'skip - real core checks (set VLESS_TEST_MIHOMO_BIN to a Mihomo binary)\n'
fi
