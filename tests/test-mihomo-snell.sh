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

write_mihomo_gzip_fixture() {
    local source_file="$TEST_TMP/mihomo-fixture"
    cat >"$source_file" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Mihomo Meta v1.19.28 linux amd64'
EOF
    chmod 700 "$source_file"
    gzip -c "$source_file" >"$TEST_TMP/mihomo-fixture.gz"
}

stub_mihomo_download() {
    local output="" url=""
    while (($#)); do
        case "$1" in
            -o)
                output="$2"
                shift 2
                ;;
            --)
                shift
                url="${1:-}"
                shift
                ;;
            *) shift ;;
        esac
    done
    [[ -n "$output" && -n "$url" ]] || return 1
    cp "$TEST_TMP/mihomo-fixture.gz" "$output"
    printf '%s\n' "$url" >"$TEST_TMP/download-url"
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

test_mihomo_supported_versions() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"

    _is_mihomo_supported_version 1.19.28 || return 1
    ! _is_mihomo_supported_version 1.19.27 || return 1
    ! _is_mihomo_supported_version 1.19.28-alpha || return 1
    _is_mihomo_supported_version 1.19.29-alpha || return 1
)

test_mihomo_asset_names() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"

    [[ "$(_mihomo_asset_name x86_64 1.19.28)" == "mihomo-linux-amd64-compatible-v1.19.28.gz" ]] || return 1
    [[ "$(_mihomo_asset_name aarch64 1.19.28)" == "mihomo-linux-arm64-v1.19.28.gz" ]] || return 1
    [[ "$(_mihomo_asset_name armv7l 1.19.28)" == "mihomo-linux-armv7-v1.19.28.gz" ]] || return 1
    ! _mihomo_asset_name mips 1.19.28 || return 1
)

test_get_mihomo_version_from_managed_binary() (
    new_fixture
    trap cleanup_fixture EXIT
    cat >"$VLESS_TEST_MIHOMO_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Mihomo Meta v1.19.28 linux amd64'
EOF
    chmod 700 "$VLESS_TEST_MIHOMO_BIN"
    source "$SCRIPT"

    [[ "$(_get_mihomo_version)" == "1.19.28" ]] || return 1
    [[ "$(_get_core_version mihomo)" == "1.19.28" ]]
)

test_mihomo_backup_uses_managed_binary_path() (
    new_fixture
    trap cleanup_fixture EXIT
    cat >"$VLESS_TEST_MIHOMO_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Mihomo Meta v1.19.28 linux amd64'
EOF
    chmod 700 "$VLESS_TEST_MIHOMO_BIN"
    source "$SCRIPT"
    _get_core_backup_dir() {
        mkdir -p "$TEST_TMP/backups"
        printf '%s\n' "$TEST_TMP/backups"
    }
    _info() { :; }

    local backup_file
    backup_file=$(_backup_core_binary vless-mihomo) || return 1
    [[ -f "$backup_file" ]] || return 1
    [[ "$(basename "$backup_file")" == vless-mihomo_1.19.28_* ]] || return 1
    cmp -s "$VLESS_TEST_MIHOMO_BIN" "$backup_file"
)

test_mihomo_update_rejects_unsupported_version_before_confirmation() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    _check_core_update_deps() { return 0; }
    _confirm_core_update_version() {
        touch "$TEST_TMP/confirmed"
        return 0
    }
    _test_never_install_mihomo() {
        touch "$TEST_TMP/installed"
        return 0
    }

    if _update_core_to_version "Mihomo" "" "1.19.27" "vless-mihomo" "_test_never_install_mihomo" >/dev/null 2>&1; then
        return 1
    fi
    [[ ! -e "$TEST_TMP/confirmed" ]] || return 1
    [[ ! -e "$TEST_TMP/installed" ]]
)

test_update_mihomo_core_uses_selected_channel_version() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    declare -F update_mihomo_core >/dev/null || return 1
    _get_latest_version() {
        [[ "$1" == "MetaCubeX/mihomo" ]] || return 1
        printf '%s\n' '1.19.28'
    }
    _update_core_to_version() {
        printf '%s\n' "$1|$2|$3|$4|$5" >"$TEST_TMP/update-args"
    }

    update_mihomo_core stable || return 1
    [[ "$(<"$TEST_TMP/update-args")" == "Mihomo|stable|1.19.28|vless-mihomo|install_mihomo" ]]
)

test_update_mihomo_core_custom_rejects_unsupported_version() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    declare -F update_mihomo_core_custom >/dev/null || return 1
    _header() { :; }
    _line() { :; }
    _show_core_versions() { :; }
    _select_version_from_list() { printf '%s\n' '1.19.27'; }
    _update_core_to_version() {
        touch "$TEST_TMP/update-attempted"
        return 0
    }

    if update_mihomo_core_custom >/dev/null 2>&1; then
        return 1
    fi
    [[ ! -e "$TEST_TMP/update-attempted" ]]
)

test_mihomo_async_warming_caches_both_channels() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    mkdir -p "$VERSION_CACHE_DIR"
    curl() {
        printf '%s\n' '[{"tag_name":"v1.19.28","prerelease":false},{"tag_name":"v1.19.29-alpha","prerelease":true}]' '200'
    }

    _update_all_versions_async "$MIHOMO_REPO"
    wait
    [[ "$(<"$VERSION_CACHE_DIR/MetaCubeX_mihomo")" == "1.19.28" ]] || return 1
    [[ "$(<"$VERSION_CACHE_DIR/MetaCubeX_mihomo_prerelease")" == "1.19.29-alpha" ]] || return 1
    [[ ! -e "$VERSION_CACHE_DIR/MetaCubeX_mihomo_unavailable" ]]
)

test_mihomo_async_warming_marks_unavailable_repository() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    mkdir -p "$VERSION_CACHE_DIR"
    curl() {
        printf '%s\n' '{"message":"Not Found"}' '404'
    }

    _update_all_versions_async "$MIHOMO_REPO"
    wait
    [[ "$(<"$VERSION_CACHE_DIR/MetaCubeX_mihomo_unavailable")" == "not_found" ]]
)

test_show_core_versions_includes_mihomo_channels() (
    new_fixture
    trap cleanup_fixture EXIT
    cat >"$VLESS_TEST_MIHOMO_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Mihomo Meta v1.19.28 linux amd64'
EOF
    chmod 700 "$VLESS_TEST_MIHOMO_BIN"
    source "$SCRIPT"
    W= D= G= C= M= Y= NC=
    mkdir -p "$VERSION_CACHE_DIR"
    printf '%s\n' '1.19.28' >"$VERSION_CACHE_DIR/MetaCubeX_mihomo"
    printf '%s\n' '1.19.29-alpha' >"$VERSION_CACHE_DIR/MetaCubeX_mihomo_prerelease"
    _update_version_cache_async() { :; }
    _update_prerelease_cache_async() { :; }

    local output
    output=$(_show_core_versions mihomo)
    grep -q '^  Mihomo$' <<<"$output" || return 1
    grep -q '当前版本: v1.19.28' <<<"$output" || return 1
    grep -q '稳定版本: v1.19.28' <<<"$output" || return 1
    grep -q '预发布版本: v1.19.29-alpha' <<<"$output"
)

test_core_menu_replaces_snell_v5_with_mihomo() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    W= G= NC=
    _header() { :; }
    _line() { :; }
    _show_core_versions() { :; }
    _item() { printf '%s %s\n' "$1" "$2"; }

    local output
    output=$(update_core_menu <<<"0")
    grep -q '核心版本管理 (Xray/Sing-box/Mihomo/Snell v6)' <<<"$output" || return 1
    ! grep -q 'Snell v5' <<<"$output" || return 1
    grep -q 'Mihomo' <<<"$output"
)

test_install_mihomo_rejects_unsupported_version_before_download() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    declare -F install_mihomo >/dev/null || return 1
    curl() {
        touch "$TEST_TMP/download-attempted"
        return 1
    }

    if install_mihomo stable true 1.19.27 >/dev/null 2>&1; then
        return 1
    fi
    [[ ! -e "$TEST_TMP/download-attempted" ]] || return 1
    [[ ! -e "$VLESS_TEST_MIHOMO_BIN" ]]
)

test_install_mihomo_requires_publisher_verification() (
    new_fixture
    trap cleanup_fixture EXIT
    write_mihomo_gzip_fixture
    export TMPDIR="$TEST_TMP/tmp"
    mkdir -p "$TMPDIR"
    source "$SCRIPT"
    declare -F install_mihomo >/dev/null || return 1
    curl() { stub_mihomo_download "$@"; }
    _verify_github_release_asset() { return 1; }
    export ALLOW_UNVERIFIED_DOWNLOADS=1

    if install_mihomo stable true 1.19.28 >/dev/null 2>&1; then
        return 1
    fi
    [[ ! -e "$VLESS_TEST_MIHOMO_BIN" ]] || return 1
    local -a leftovers
    shopt -s nullglob dotglob
    leftovers=("$TMPDIR"/*)
    ((${#leftovers[@]} == 0))
)

test_install_mihomo_uses_verified_official_asset() (
    new_fixture
    trap cleanup_fixture EXIT
    write_mihomo_gzip_fixture
    source "$SCRIPT"
    declare -F install_mihomo >/dev/null || return 1
    curl() { stub_mihomo_download "$@"; }
    _verify_github_release_asset() {
        printf '%s\n' "$1|$2|$3|$4" >"$TEST_TMP/verify-args"
        [[ "$1" == "MetaCubeX/mihomo" && "$2" == "1.19.28" && -f "$4" ]]
    }

    install_mihomo stable true v1.19.28 >/dev/null 2>&1 || return 1
    [[ "$(<"$TEST_TMP/download-url")" == "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.28/mihomo-linux-amd64-compatible-v1.19.28.gz" ]] || return 1
    [[ "$(<"$TEST_TMP/verify-args")" == "MetaCubeX/mihomo|1.19.28|https://github.com/MetaCubeX/mihomo/releases/download/v1.19.28/mihomo-linux-amd64-compatible-v1.19.28.gz|"* ]] || return 1
    [[ -x "$VLESS_TEST_MIHOMO_BIN" ]] || return 1
    [[ "$(_get_mihomo_version)" == "1.19.28" ]]
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
run_test test_mihomo_supported_versions
run_test test_mihomo_asset_names
run_test test_get_mihomo_version_from_managed_binary
run_test test_mihomo_backup_uses_managed_binary_path
run_test test_mihomo_update_rejects_unsupported_version_before_confirmation
run_test test_update_mihomo_core_uses_selected_channel_version
run_test test_update_mihomo_core_custom_rejects_unsupported_version
run_test test_mihomo_async_warming_caches_both_channels
run_test test_mihomo_async_warming_marks_unavailable_repository
run_test test_show_core_versions_includes_mihomo_channels
run_test test_core_menu_replaces_snell_v5_with_mihomo
run_test test_install_mihomo_rejects_unsupported_version_before_download
run_test test_install_mihomo_requires_publisher_verification
run_test test_install_mihomo_uses_verified_official_asset
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
