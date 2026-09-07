#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/vless-server.sh"
PASS=0

run_test() {
    local name="$1"
    if "$name"; then
        printf 'ok - %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf 'not ok - %s\n' "$name" >&2
        exit 1
    fi
}

new_fixture() {
    TEST_TMP=$(mktemp -d)
    export VLESS_TEST_CFG="$TEST_TMP/etc"
    export VLESS_TEST_MIHOMO_BIN="$TEST_TMP/bin/vless-mihomo"
    mkdir -p "$VLESS_TEST_CFG" "$(dirname "$VLESS_TEST_MIHOMO_BIN")"
}

cleanup_fixture() {
    rm -rf "${TEST_TMP:-}"
}

write_single_mihomo_record() {
    local protocol="$1" record="$2"
    jq -n --arg protocol "$protocol" --argjson record "$record" '{
      version:"4.0.0", xray:{}, singbox:{}, meta:{},
      mihomo:{($protocol):$record}
    }' >"$DB_FILE"
}

write_mixed_mihomo_db() {
    jq -n '{
      version:"4.0.0", xray:{}, singbox:{}, meta:{},
      mihomo:{
        snell:[{port:41001,psk:"v4-one",version:4},{port:41002,psk:"v4-two",version:4}],
        "snell-v5":[{port:51001,psk:"v5-one",version:5}],
        "snell-v5-shadowtls":[{port:52001,psk:"v5-stls",version:5,sni:"www.microsoft.com",stls_password:"stls-secret"}]
      }
    }' >"$DB_FILE"
}

test_source_does_not_run_cli() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    declare -F main_menu >/dev/null
)

test_init_db_has_mihomo_namespace() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    init_db
    jq -e '.mihomo == {} and .xray == {} and .singbox == {}' "$DB_FILE" >/dev/null
)

test_init_db_upgrades_legacy_namespaces() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    printf '%s\n' '{"version":"4.0.0","xray":{},"singbox":{},"meta":{}}' >"$DB_FILE"
    init_db
    jq -e '.mihomo == {} and (.xray | type) == "object" and (.singbox | type) == "object"' "$DB_FILE" >/dev/null
)

test_protocol_core_classification() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    [[ "$(protocol_core snell)" == mihomo ]]
    [[ "$(protocol_core snell-v5-shadowtls)" == mihomo ]]
    [[ "$(protocol_core snell-v6)" == standalone ]]
    [[ "$(protocol_core hy2)" == singbox ]]
    [[ "$(protocol_core vless)" == xray ]]
)

test_legacy_mihomo_records_use_xray_namespace() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    CYAN= YELLOW= GREEN= RED= G= NC=
    init_db
    db_add xray snell '{"port":8388,"psk":"legacy"}'

    [[ "$(protocol_db_core snell)" == xray ]]

    local output
    if output=$(handle_existing_protocol snell mihomo <<<"0"); then
        return 1
    fi
    grep -q '8388' <<<"$output"

    INSTALL_MODE=replace
    REPLACE_PORT=8388
    register_protocol snell '{"port":8388,"psk":"updated"}' >/dev/null
    jq -e '.xray.snell.psk == "updated" and .mihomo.snell == null' "$DB_FILE" >/dev/null

    select_port_to_uninstall snell >/dev/null
    [[ "$SELECTED_PORT" == 8388 ]]

    INSTALL_MODE=
    REPLACE_PORT=
    register_protocol snell-v5 '{"port":8389,"psk":"new"}' >/dev/null
    jq -e '.mihomo["snell-v5"].psk == "new" and .xray["snell-v5"] == null' "$DB_FILE" >/dev/null
)

test_mihomo_list_ports_prints_every_listener_port() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db

    local ports
    ports=$(mihomo_list_ports "$DB_FILE")
    [[ "$ports" == $'41001\n41002\n51001\n52001' ]]
)

test_validate_mihomo_config_checks_json_and_binary_arguments() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    local config="$TEST_TMP/mihomo.yaml"
    local args_file="$TEST_TMP/mihomo.args"
    printf '%s\n' '{"listeners":[]}' >"$config"
    cat >"$VLESS_TEST_MIHOMO_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$MIHOMO_TEST_ARGS_FILE"
[[ "$1" == "-t" && "$2" == "-f" && "$3" == "$MIHOMO_TEST_CONFIG" ]]
EOF
    chmod 700 "$VLESS_TEST_MIHOMO_BIN"
    export MIHOMO_TEST_ARGS_FILE="$args_file" MIHOMO_TEST_CONFIG="$config"

    validate_mihomo_config "$config" "$VLESS_TEST_MIHOMO_BIN"
    [[ "$(<"$args_file")" == "-t -f $config" ]]

    rm -f "$args_file"
    printf '%s\n' 'not-json' >"$config"
    if validate_mihomo_config "$config" "$VLESS_TEST_MIHOMO_BIN"; then
        return 1
    fi
    [[ ! -e "$args_file" ]]
)

test_generate_mihomo_config_falls_back_from_invalid_log_level() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_single_mihomo_record "snell" '{"port":41001,"psk":"v4-key","version":4}'
    jq '.meta.mihomo_log_level = "info"' "$DB_FILE" >"$TEST_TMP/db.next"
    mv "$TEST_TMP/db.next" "$DB_FILE"

    generate_mihomo_config "$DB_FILE" "$TEST_TMP/mihomo.yaml"
    jq -e '.["log-level"] == "warning"' "$TEST_TMP/mihomo.yaml" >/dev/null
)

test_generate_mihomo_config_accepts_scalar_record_and_debug_log_level() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_single_mihomo_record "snell-v5" '{"port":51001,"psk":"v5-key","version":5}'
    jq '.meta.mihomo_log_level = "debug"' "$DB_FILE" >"$TEST_TMP/db.next"
    mv "$TEST_TMP/db.next" "$DB_FILE"

    generate_mihomo_config "$DB_FILE" "$TEST_TMP/mihomo.yaml"
    jq -e '.["log-level"] == "debug" and (.listeners | length) == 1 and .listeners[0].name == "snell-v5-51001"' "$TEST_TMP/mihomo.yaml" >/dev/null
)

test_generate_mihomo_config_rejects_empty_listener_set_atomically() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    jq -n '{version:"4.0.0",xray:{},singbox:{},mihomo:{},meta:{}}' >"$DB_FILE"
    local output="$TEST_TMP/mihomo.yaml"
    printf '%s\n' 'existing-config' >"$output"

    if generate_mihomo_config "$DB_FILE" "$output"; then
        return 1
    fi
    [[ "$(<"$output")" == "existing-config" ]]
)

test_generate_mihomo_config_rejects_unsafe_psk() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_single_mihomo_record "snell" '{"port":41001,"psk":"bad\\key","version":4}'

    if generate_mihomo_config "$DB_FILE" "$TEST_TMP/mihomo.yaml"; then
        return 1
    fi
    [[ ! -e "$TEST_TMP/mihomo.yaml" ]]
)

test_generate_mihomo_config_rejects_invalid_ports() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    local record

    for record in \
        '{"port":0,"psk":"v4-key","version":4}' \
        '{"port":65536,"psk":"v4-key","version":4}' \
        '{"port":"41001","psk":"v4-key","version":4}'; do
        write_single_mihomo_record "snell" "$record"
        rm -f "$TEST_TMP/mihomo.yaml"
        if generate_mihomo_config "$DB_FILE" "$TEST_TMP/mihomo.yaml"; then
            return 1
        fi
        [[ ! -e "$TEST_TMP/mihomo.yaml" ]]
    done
)

test_generate_mihomo_config_rejects_json_metacharacters_in_password() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_single_mihomo_record "snell-shadowtls" '{"port":42001,"psk":"v4-key","version":4,"sni":"www.microsoft.com","stls_password":"bad\"password"}'

    if generate_mihomo_config "$DB_FILE" "$TEST_TMP/mihomo.yaml"; then
        return 1
    fi
    [[ ! -e "$TEST_TMP/mihomo.yaml" ]]
)

test_generate_mihomo_config_rejects_invalid_sni() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_single_mihomo_record "snell-v5-shadowtls" '{"port":52001,"psk":"v5-key","version":5,"sni":"bad host/name","stls_password":"stls-secret"}'

    if generate_mihomo_config "$DB_FILE" "$TEST_TMP/mihomo.yaml"; then
        return 1
    fi
    [[ ! -e "$TEST_TMP/mihomo.yaml" ]]
)

test_generate_mihomo_config_rejects_missing_shadowtls_password() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_single_mihomo_record "snell-shadowtls" '{"port":42001,"psk":"v4-key","version":4,"sni":"www.microsoft.com"}'

    if generate_mihomo_config "$DB_FILE" "$TEST_TMP/mihomo.yaml"; then
        return 1
    fi
    [[ ! -e "$TEST_TMP/mihomo.yaml" ]]
)

test_generate_mihomo_config_rejects_missing_psk() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_single_mihomo_record "snell-v5" '{"port":51001,"version":5}'

    if generate_mihomo_config "$DB_FILE" "$TEST_TMP/mihomo.yaml"; then
        return 1
    fi
    [[ ! -e "$TEST_TMP/mihomo.yaml" ]]
)

test_generate_mihomo_config_rejects_version_six() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_single_mihomo_record "snell" '{"port":41001,"psk":"v6-key","version":6}'
    local output="$TEST_TMP/mihomo.yaml"

    if generate_mihomo_config "$DB_FILE" "$output"; then
        return 1
    fi
    [[ ! -e "$output" ]]
)

test_generate_mihomo_config_rejects_duplicate_ports_atomically() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    jq -n '{
      version:"4.0.0", xray:{}, singbox:{}, meta:{},
      mihomo:{
        snell:{port:41001,psk:"v4-one",version:4},
        "snell-v5":{port:41001,psk:"v5-one",version:5}
      }
    }' >"$DB_FILE"
    local output="$TEST_TMP/mihomo.yaml"
    printf '%s\n' 'existing-config' >"$output"

    if generate_mihomo_config "$DB_FILE" "$output"; then
        return 1
    fi
    [[ "$(<"$output")" == "existing-config" ]]
)

test_generate_mihomo_config_builds_complete_mixed_config() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    _listen_addr() { printf '%s\n' "127.0.0.1"; }

    local output="$TEST_TMP/mihomo.yaml"
    generate_mihomo_config "$DB_FILE" "$output"

    jq -e '
      .mode == "rule" and .["log-level"] == "warning" and .ipv6 == true and
      .rules == ["MATCH,DIRECT"] and (.listeners | length) == 4 and
      ([.listeners[].listen] | unique) == ["127.0.0.1"]
    ' "$output" >/dev/null
    jq -e '.listeners[] | select(.name == "snell-v4-41002") | .psk == "v4-two" and .version == 4 and .udp == true' "$output" >/dev/null
    jq -e '.listeners[] | select(.name == "snell-v5-stls-52001") | .["shadow-tls"].version == 3 and .["shadow-tls"].users[0].password == "stls-secret" and .["shadow-tls"].handshake.dest == "www.microsoft.com:443"' "$output" >/dev/null
    [[ "$(stat -c '%a' "$output")" == "600" ]]
)

run_test test_source_does_not_run_cli
run_test test_init_db_has_mihomo_namespace
run_test test_init_db_upgrades_legacy_namespaces
run_test test_protocol_core_classification
run_test test_legacy_mihomo_records_use_xray_namespace
run_test test_mihomo_list_ports_prints_every_listener_port
run_test test_generate_mihomo_config_builds_complete_mixed_config
run_test test_generate_mihomo_config_rejects_duplicate_ports_atomically
run_test test_generate_mihomo_config_rejects_version_six
run_test test_generate_mihomo_config_rejects_missing_psk
run_test test_generate_mihomo_config_rejects_missing_shadowtls_password
run_test test_generate_mihomo_config_rejects_invalid_sni
run_test test_generate_mihomo_config_rejects_json_metacharacters_in_password
run_test test_generate_mihomo_config_rejects_invalid_ports
run_test test_generate_mihomo_config_rejects_unsafe_psk
run_test test_generate_mihomo_config_rejects_empty_listener_set_atomically
run_test test_generate_mihomo_config_accepts_scalar_record_and_debug_log_level
run_test test_generate_mihomo_config_falls_back_from_invalid_log_level
run_test test_validate_mihomo_config_checks_json_and_binary_arguments
printf '%s tests passed\n' "$PASS"
