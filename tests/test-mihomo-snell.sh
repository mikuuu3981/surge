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

run_test test_source_does_not_run_cli
run_test test_init_db_has_mihomo_namespace
run_test test_init_db_upgrades_legacy_namespaces
run_test test_protocol_core_classification
run_test test_legacy_mihomo_records_use_xray_namespace
printf '%s tests passed\n' "$PASS"
