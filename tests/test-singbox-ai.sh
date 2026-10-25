#!/usr/bin/env bash
# Offline AI core isolation, full-source compilation and cache regressions.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap '[[ ! -s "$TMP/check-error" ]] || cat "$TMP/check-error" >&2; rm -rf "$TMP"' EXIT
trap 'printf "FAIL at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
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
rc-service() { printf 'unexpected rc-service: %s\n' "$*" >&2; return 1; }
sing-box() {
    if [[ -n "$REAL_BIN" ]]; then
        if [[ "$1" == check ]]; then
            "$REAL_BIN" "$@" >"$TMP/check-error" 2>&1
            return $?
        fi
        "$REAL_BIN" "$@"
        return $?
    fi
    case "$1" in
        version) printf '%s\n' 'sing-box version 1.14.3' ;;
        check) jq empty "$3" ;;
        rule-set)
            case "$2" in
                compile) jq -e '.version==3 and (.rules|length)>0' "$3" >/dev/null && cp "$3" "$5" ;;
                decompile) jq -e '.version==3 and (.rules|length)>0' "$3" >"$5" ;;
                *) return 1 ;;
            esac ;;
        *) return 1 ;;
    esac
}
CURL_FAIL=''
curl() {
    local output='' url='' tag=''
    while (($#)); do
        case "$1" in
            -o) output="$2"; shift 2 ;;
            --connect-timeout|--max-time) shift 2 ;;
            -*) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    case "$url" in
        https://ruleset.skk.moe/sing-box/non_ip/ai.json) tag=skk-ai-non-ip ;;
        https://ruleset.skk.moe/sing-box/ip/ai.json) tag=skk-ai-ip ;;
        *) printf 'unexpected download: %s\n' "$url" >&2; return 1 ;;
    esac
    printf '%s\n' "$tag" >>"$TMP/downloads"
    [[ "$CURL_FAIL" != all && "$CURL_FAIL" != "$tag" && "$output" == "$CFG/"* ]] || return 1
    cp "$TMP/$tag.json" "$output"
}
write_sources() {
    # Include fields that would be lost by flattening into domain/IP lists.
    jq -n '{version:3,rules:[
        {domain_suffix:["ai.example"],domain_keyword:["assistant"],domain_regex:["^chat[0-9]+\\.example$"],port:[443]},
        {type:"logical",mode:"and",rules:[{domain_suffix:["nested.example"]},{network:"tcp",invert:true}]}]}' >"$TMP/skk-ai-non-ip.json"
    jq -n '{version:3,rules:[
        {ip_cidr:["198.51.100.0/24","2001:db8::/32"],port_range:["8000:9000"]},
        {type:"logical",mode:"or",rules:[{ip_cidr:["203.0.113.0/24"]},{ip_cidr:["2001:db8:1::/48"],invert:true}]}]}' >"$TMP/skk-ai-ip.json"
}
fixture() {
    jq -n '{xray:{},mihomo:{},singbox:{snell:{port:43001,psk:"numeric0123456789",version:4}},
        chain_proxy:{nodes:[{name:"landing",type:"socks",server:"127.0.0.1",port:1080,username:"fixture",password:"quote\"pass"}]},
        routing_rules:[]}' >"$DB_FILE"
}
set_rules() {
    jq --argjson rules "$1" '.routing_rules=$rules' "$DB_FILE" >"$TMP/db"
    mv "$TMP/db" "$DB_FILE"
}
check() { jq -e "$1" "$CFG/singbox.json" >/dev/null; }
assert_sources() {
    local tag
    for tag in skk-ai-non-ip skk-ai-ip; do
        cmp "$TMP/$tag.json" "$CFG/ruleset-src/$tag.json"
        [[ -s "$CFG/ruleset/$tag.srs" ]]
        [[ "$(stat -c %a "$CFG/ruleset-src/$tag.json")" == 600 ]]
        [[ "$(stat -c %a "$CFG/ruleset/$tag.srs")" == 600 ]]
    done
}
write_sources
fixture
[[ "${ROUTING_PRESET_NAMES[ai-intl]}" == GeoSite-AI-Xray专属 ]]
[[ "${ROUTING_PRESET_NAMES[singbox-ai]}" == Sukka-AI-Sing-Box专属 ]]
db_add_routing_rule ai-intl chain:xray-only '' as_is
db_add_routing_rule singbox-ai chain:landing '' as_is
db_add_routing_rule custom direct safe.example as_is
[[ "$(db_get_routing_rules all | jq length)" == 3 ]]
[[ "$(db_get_routing_rules | jq length)" == 3 ]]
db_get_routing_rules xray | jq -e 'map(.type)|sort==["ai-intl","custom"]' >/dev/null
db_get_routing_rules singbox | jq -e 'map(.type)|sort==["custom","singbox-ai"]' >/dev/null
db_get_routing_rules mihomo | jq -e 'map(.type)==["custom"]' >/dev/null
gen_xray_routing_rules >"$TMP/xray-rules"
jq -e 'any(.[]; .domain==["geosite:category-ai-!cn"]) and
    all(.[]; ((.outboundTag // "") | contains("landing")) | not)' "$TMP/xray-rules" >/dev/null
# The unavailable Xray-only chain must never enter Sing-box outbound collection.
generate_singbox_config
check 'any(.outbounds[]; .type=="socks" and .server_port==1080 and .password=="quote\"pass") and
    all(.outbounds[]; ((.tag // "") | contains("xray-only")) | not)'
assert_sources
[[ "$(wc -l <"$TMP/downloads")" == 2 ]]
printf '%s\n' 'ok - preset names, all/core filtering and Xray-only chain isolation during Sing-box generation'

(
    # Exercise the real Xray outbound collector; only the unrelated inbound
    # builder and production log directory creation are replaced.
    get_xray_protocols() { printf '%s\n' vless; }
    db_migrate_reality_fallback_limits() { :; }
    add_xray_inbound_v2() { :; }
    mkdir() {
        [[ "$*" != '-p /var/log/xray' ]] || return 0
        command mkdir "$@"
    }
    set_rules "$(jq -nc '[{type:"ai-intl",outbound:"direct",domains:"geosite:category-ai-!cn",ip_version:"as_is"},
        {type:"singbox-ai",outbound:"chain:singbox-only-missing",ip_version:"as_is"}]')"
    # The generator uses an arithmetic post-increment; condition context keeps
    # its successful first increment compatible with this test's errexit.
    if ! generate_xray_config; then exit 1; fi
    jq -e 'any(.routing.rules[]; .domain==["geosite:category-ai-!cn"]) and
        all(.outbounds[]; ((.tag // "") | contains("singbox-only")) | not) and
        all(.routing.rules[]; .rule_set==null)' "$CFG/config.json" >/dev/null
)
printf '%s\n' 'ok - Sing-box-only missing chain is excluded from the Xray outbound collector'

for family in as_is prefer_ipv4 prefer_ipv6 ipv4_only ipv6_only; do
    set_rules "$(jq -nc --arg family "$family" '[{type:"singbox-ai",outbound:"chain:landing",ip_version:$family}]')"
    generate_singbox_config
    version=null
    [[ "$family" != ipv4_only ]] || version=4
    [[ "$family" != ipv6_only ]] || version=6
    jq -e --argjson version "$version" '
        [.route.rules[] | select(.rule_set!=null)] as $rules |
        ($rules|length)==2 and
        ([$rules[].rule_set[]]|sort)==["skk-ai-ip","skk-ai-non-ip"] and
        ([$rules[].outbound]|unique|length)==1 and
        all($rules[]; .ip_version==$version and .ip_cidr==null and .inbound==null) and
        ([.route.rule_set[].tag]|sort)==["skk-ai-ip","skk-ai-non-ip"] and
        all(.route.rule_set[]; .type=="local" and .format=="binary")' "$CFG/singbox.json" >/dev/null
done
[[ "$(wc -l <"$TMP/downloads")" == 2 ]]
printf '%s\n' 'ok - two independent local rule sets, one shared outlet, numeric IP family intersections and fresh-cache reuse'

# Only the expired member refreshes, and generation retains every source field.
touch -d '25 hours ago' "$CFG/ruleset-src/skk-ai-non-ip.json" "$CFG/ruleset/skk-ai-non-ip.srs"
jq '.rules[0].domain_suffix += ["new-ai.example"]' "$TMP/skk-ai-non-ip.json" >"$TMP/new-source"
mv "$TMP/new-source" "$TMP/skk-ai-non-ip.json"
generate_singbox_config
[[ "$(wc -l <"$TMP/downloads")" == 3 ]]
[[ "$(tail -1 "$TMP/downloads")" == skk-ai-non-ip ]]
assert_sources
# Expiration of either file, independently, must trigger a rebuild.
touch -d '25 hours ago' "$CFG/ruleset/skk-ai-ip.srs"
generate_singbox_config
[[ "$(wc -l <"$TMP/downloads")" == 4 ]]
touch -d '25 hours ago' "$CFG/ruleset-src/skk-ai-ip.json"
generate_singbox_config
[[ "$(wc -l <"$TMP/downloads")" == 5 ]]
printf '%s\n' 'ok - configuration rebuild refreshes expired source/binary files independently and preserves complete source JSON'

cp -a "$CFG/ruleset" "$TMP/good-ruleset"
cp -a "$CFG/ruleset-src" "$TMP/good-source"
touch -d '25 hours ago' "$CFG/ruleset/"*.srs "$CFG/ruleset-src/"*.json
CURL_FAIL=all
generate_singbox_config >"$TMP/fallback-output" 2>"$TMP/fallback-error"
diff -r "$TMP/good-ruleset" "$CFG/ruleset"
diff -r "$TMP/good-source" "$CFG/ruleset-src"
CURL_FAIL=''
printf '%s\n' '{"version":3,"rules":[]}' >"$TMP/skk-ai-ip.json"
generate_singbox_config >"$TMP/fallback-output" 2>"$TMP/fallback-error"
diff -r "$TMP/good-ruleset" "$CFG/ruleset"
diff -r "$TMP/good-source" "$CFG/ruleset-src"
write_sources
# Structurally valid JSON that cannot compile must also preserve old caches.
printf '%s\n' '{"version":999,"rules":[{"unknown_field":true}]}' >"$TMP/skk-ai-ip.json"
generate_singbox_config >"$TMP/fallback-output" 2>"$TMP/fallback-error"
diff -r "$TMP/good-ruleset" "$CFG/ruleset"
diff -r "$TMP/good-source" "$CFG/ruleset-src"
write_sources
printf '%s\n' 'ok - failed transport, invalid source and compile failure retain valid independent caches'

for bad_tag in skk-ai-non-ip skk-ai-ip; do
    for failure in missing corrupt; do
        cp "$CFG/singbox.json" "$TMP/before-config"
        cp "$TMP/good-ruleset/$bad_tag.srs" "$CFG/ruleset/$bad_tag.srs"
        if [[ "$failure" == missing ]]; then
            rm "$CFG/ruleset/$bad_tag.srs"
        else
            printf '%s\n' 'invalid binary cache' >"$CFG/ruleset/$bad_tag.srs"
        fi
        CURL_FAIL="$bad_tag"
        if generate_singbox_config >"$TMP/failure-output" 2>"$TMP/failure-error"; then
            printf 'unexpected success with %s %s cache\n' "$failure" "$bad_tag" >&2
            exit 1
        fi
        cmp "$CFG/singbox.json" "$TMP/before-config"
        cp "$TMP/good-ruleset/$bad_tag.srs" "$CFG/ruleset/$bad_tag.srs"
    done
done
CURL_FAIL=''
printf '%s\n' 'ok - missing/corrupt cache plus failed download rejects generation and preserves active configuration'

(
    get_singbox_protocols() { printf '%s\n' snell; }
    get_xray_protocols() { printf '%s\n' vless; }
    _regenerate_singbox_routing_config() { printf '%s\n' singbox >>"$TMP/reloads"; }
    rebuild_and_reload_xray() { printf 'xray %s\n' "$*" >>"$TMP/reloads"; }
    _reload_ai_routing_core singbox-ai
    [[ "$(cat "$TMP/reloads")" == singbox ]]
    _reload_ai_routing_core ai-intl
    [[ "$(tail -1 "$TMP/reloads")" == 'xray silent' ]]
    [[ "$(wc -l <"$TMP/reloads")" == 2 ]]
    get_singbox_protocols() { :; }
    get_xray_protocols() { :; }
    _reload_ai_routing_core singbox-ai
    _reload_ai_routing_core ai-intl
    [[ "$(wc -l <"$TMP/reloads")" == 2 ]]
    if _reload_ai_routing_core custom; then exit 1; fi
)
(
    _item() { printf '%s %s\n' "$1" "$2"; }
    get_singbox_protocols() { printf '%s\n' snell; }
    _add_routing_rule <<<0 >"$TMP/menu"
    grep -Fx '9 GeoSite-AI-Xray专属' "$TMP/menu"
    grep -Fx 's Sukka-AI-Sing-Box专属' "$TMP/menu"
    get_singbox_protocols() { :; }
    _add_routing_rule <<<0 >"$TMP/menu"
    if grep -Fq 'Sukka-AI-Sing-Box专属' "$TMP/menu"; then exit 1; fi
    if _add_routing_rule <<<s >"$TMP/menu"; then exit 1; fi
)
(
    show_routing_status() { :; }
    _reload_ai_routing_core() { printf '%s\n' "$1" >>"$TMP/clear-reloads"; }
    for type in singbox-ai ai-intl; do
        set_rules "$(jq -nc --arg type "$type" '[{type:$type,outbound:"direct",ip_version:"as_is"}]')"
        : >"$TMP/clear-reloads"
        configure_routing_rules <<< $'3\ny\n0' >"$TMP/clear-menu"
        [[ "$(cat "$TMP/clear-reloads")" == "$type" ]]
        [[ "$(db_get_routing_rules | jq length)" == 0 ]]
    done
)
printf '%s\n' 'ok - reload helper core isolation, missing-core no-op, menu labels/availability and affected-core-only clear'

(
    get_singbox_protocols() { printf '%s\n' snell; }
    _select_outbound() { printf '%s\n' chain:landing; }
    _get_outbound_display_name() { printf '%s\n' "$1"; }
    _regenerate_proxy_configs() { printf '%s\n' 'unexpected global reload' >&2; return 1; }
    RELOAD_FAIL=false
    _reload_ai_routing_core() {
        printf '%s\n' "$1" >>"$TMP/edit-reloads"
        [[ "$RELOAD_FAIL" == false ]]
    }
    for type in singbox-ai ai-intl; do
        choice=s
        [[ "$type" != ai-intl ]] || choice=9
        fixture
        : >"$TMP/edit-reloads"
        _add_routing_rule <<< "$choice"$'\n1' >"$TMP/add-menu"
        [[ "$(cat "$TMP/edit-reloads")" == "$type" ]]
        jq -e --arg type "$type" '.routing_rules|length==1 and
            .[0].type==$type and .[0].outbound=="chain:landing" and .[0].ip_version=="ipv4_only"' "$DB_FILE" >/dev/null
        cp "$DB_FILE" "$TMP/before-edit"
        RELOAD_FAIL=true
        if _del_routing_rule <<<1 >"$TMP/delete-menu"; then exit 1; fi
        cmp "$DB_FILE" "$TMP/before-edit"
        RELOAD_FAIL=false
        _del_routing_rule <<<1 >"$TMP/delete-menu"
        [[ "$(db_get_routing_rules | jq length)" == 0 ]]
        cp "$DB_FILE" "$TMP/before-edit"
        RELOAD_FAIL=true
        if _add_routing_rule <<< "$choice"$'\n2' >"$TMP/add-menu"; then exit 1; fi
        cmp "$DB_FILE" "$TMP/before-edit"
        RELOAD_FAIL=false
        [[ "$(sort -u "$TMP/edit-reloads")" == "$type" ]]
        [[ "$(wc -l <"$TMP/edit-reloads")" == 4 ]]
    done
)
printf '%s\n' 'ok - both AI menu add/delete paths reload only their core and restore the complete database on failure'
