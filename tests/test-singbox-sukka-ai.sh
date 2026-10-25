#!/usr/bin/env bash
# Offline Sukka AI cache/compiler and routing checks; never starts a service.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VLESS_TEST_CFG="$TMP/etc"
export VLESS_TEST_SYSTEMD_DIR="$TMP/systemd"
export VLESS_TEST_OPENRC_DIR="$TMP/openrc"
mkdir -p "$VLESS_TEST_CFG" "$VLESS_TEST_SYSTEMD_DIR" "$VLESS_TEST_OPENRC_DIR"
source "$ROOT/vless-server.sh"
_info() { :; }; _warn() { :; }; _err() { :; }
svc() { echo 'unexpected service operation' >&2; return 1; }
systemctl() { echo 'unexpected systemctl operation' >&2; return 1; }
SINGBOX_CONFIG_BINARY=$(command -v sing-box)
FAIL_DOWNLOAD=false
curl() {
    local output='' url=''
    while (($#)); do
        case "$1" in
            -o) output="$2"; shift 2 ;;
            --connect-timeout|--max-time) shift 2 ;;
            -*) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    printf '%s\n' "$url" >>"$TMP/downloads"
    [[ "$FAIL_DOWNLOAD" == false ]] || return 1
    case "$url" in
        https://ruleset.skk.moe/sing-box/non_ip/ai.json) cp "$TMP/non-ip.json" "$output" ;;
        https://ruleset.skk.moe/sing-box/ip/ai.json) cp "$TMP/ip.json" "$output" ;;
        *) return 1 ;;
    esac
}
printf '%s\n' '{"version":3,"rules":[{"type":"logical","mode":"or","rules":[{"domain_suffix":["ai.example"]},{"domain_keyword":["fixture-ai"]}]}]}' >"$TMP/non-ip.json"
printf '%s\n' '{"version":3,"rules":[{"ip_cidr":["192.0.2.0/24","2001:db8::/32"]}]}' >"$TMP/ip.json"

for family in prefer_ipv4 prefer_ipv6 ipv4_only ipv6_only; do
    jq -n --arg family "$family" '{routing_rules:[
        {type:"custom",domains:"before.example",outbound:"direct"},
        {type:"singbox-ai",domains:"rule-set:ignored",outbound:"chain:landing",ip_version:$family},
        {type:"custom",domains:"after.example",outbound:"direct"}]}' >"$DB_FILE"
    gen_singbox_routing_rules >"$TMP/routes.json"
    jq -e --arg family "$family" '
        length == 4 and .[0].domain_suffix == ["before.example"] and
        .[3].domain_suffix == ["after.example"] and
        .[1].rule_set == ["skk-ai-non-ip"] and .[2].rule_set == ["skk-ai-ip"] and
        all(.[1:3][]; .outbound == ("chain-landing-" + ($family | gsub("_only$";"") | gsub("_";"-"))) and
            (has("ip_cidr") | not) and
            (if $family == "ipv4_only" then .ip_version == 4
             elif $family == "ipv6_only" then .ip_version == 6
             else has("ip_version") | not end))' "$TMP/routes.json" >/dev/null
done

routes=$(cat "$TMP/routes.json")
_ensure_singbox_rulesets_from_routing_rules "$routes"
[[ $(wc -l <"$TMP/downloads") == 2 ]]
cmp "$TMP/non-ip.json" "$CFG/ruleset-src/skk-ai-non-ip.json"
cmp "$TMP/ip.json" "$CFG/ruleset-src/skk-ai-ip.json"
for tag in skk-ai-non-ip skk-ai-ip; do
    _singbox_sukka_ai_cache_valid "$tag"
    [[ $(stat -c %a "$CFG/ruleset/$tag.srs") == 600 ]]
done
_build_singbox_ruleset_defs "$routes" | jq -e 'length == 2 and all(.[]; .type == "local" and .format == "binary")' >/dev/null
defs=$(_build_singbox_ruleset_defs "$routes")
jq -n --argjson rules "$routes" --argjson defs "$defs" '{
    outbounds:[{type:"direct",tag:"direct-prefer-ipv4"},{type:"direct",tag:"chain-landing-ipv6"}],
    route:{rules:$rules,rule_set:$defs}}' >"$TMP/check.json"
"$SINGBOX_CONFIG_BINARY" check -c "$TMP/check.json"
_ensure_singbox_rulesets_from_routing_rules "$routes"
[[ $(wc -l <"$TMP/downloads") == 2 ]]
cp "$CFG/ruleset/skk-ai-non-ip.srs" "$TMP/old.srs"
touch -t 200001010000 "$CFG/ruleset-src/"*.json
FAIL_DOWNLOAD=true
_ensure_singbox_rulesets_from_routing_rules "$routes"
[[ $(wc -l <"$TMP/downloads") == 4 ]]
cmp "$TMP/old.srs" "$CFG/ruleset/skk-ai-non-ip.srs"
FAIL_DOWNLOAD=false
cp "$TMP/non-ip.json" "$TMP/original.json"
printf '%s\n' '{"version":3,"rules":[{"unsupported_field":true}]}' >"$TMP/non-ip.json"
_build_singbox_sukka_ai_ruleset skk-ai-non-ip
cmp "$TMP/original.json" "$CFG/ruleset-src/skk-ai-non-ip.json"
cmp "$TMP/old.srs" "$CFG/ruleset/skk-ai-non-ip.srs"
printf '%s\n' '<html>invalid JSON</html>' >"$TMP/non-ip.json"
_build_singbox_sukka_ai_ruleset skk-ai-non-ip
cmp "$TMP/old.srs" "$CFG/ruleset/skk-ai-non-ip.srs"
cp "$TMP/original.json" "$TMP/non-ip.json"
_ensure_singbox_rulesets_from_routing_rules "$routes"
[[ $(find "$CFG/ruleset" "$CFG/ruleset-src" -name '.*' -type f | wc -l) == 0 ]]
FAIL_DOWNLOAD=true
rm "$CFG/ruleset/skk-ai-ip.srs"
if _ensure_singbox_rulesets_from_routing_rules "$routes"; then exit 1; fi
printf '%s\n' 'invalid binary' >"$CFG/ruleset/skk-ai-ip.srs"
if _ensure_singbox_rulesets_from_routing_rules "$routes"; then exit 1; fi
printf '%s\n' 'ok - separate complete sources, real compilation, adjacent OR routes, address families, TTL, fallback and missing/corrupt cache rejection'
