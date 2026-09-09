#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/vless-server.sh"
PASS=0
SKIP=0
REAL_MIHOMO_BIN_SUPPLIED=false
if [[ -n "${VLESS_TEST_MIHOMO_BIN+x}" ]]; then
    REAL_MIHOMO_BIN_SUPPLIED=true
fi
REAL_MIHOMO_BIN="${VLESS_TEST_MIHOMO_BIN:-}"
declare -A MIG_RUNNING MIG_ENABLED

run_test() {
    local name="$1"
    if [[ -n "${VLESS_TEST_ONLY:-}" && "$name" != "$VLESS_TEST_ONLY" ]]; then
        return 0
    fi
    if "$name"; then
        printf 'ok - %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf 'not ok - %s\n' "$name" >&2
        exit 1
    fi
}

skip_test() {
    local name="$1" message="$2"
    if [[ -n "${VLESS_TEST_ONLY:-}" && "$name" != "$VLESS_TEST_ONLY" ]]; then
        return 0
    fi
    printf 'skip - %s\n' "$message"
    SKIP=$((SKIP + 1))
}

new_fixture() {
    TEST_TMP=$(mktemp -d)
    export VLESS_TEST_CFG="$TEST_TMP/etc"
    export VLESS_TEST_MIHOMO_BIN="$TEST_TMP/bin/vless-mihomo"
    export VLESS_TEST_SYSTEMD_DIR="$TEST_TMP/systemd"
    export VLESS_TEST_OPENRC_DIR="$TEST_TMP/openrc"
    export VLESS_TEST_MIHOMO_LOG_FILE="$TEST_TMP/log/mihomo.log"
    export VLESS_TEST_MESSAGES_LOG="$TEST_TMP/log/messages"
    mkdir -p "$VLESS_TEST_CFG" "$(dirname "$VLESS_TEST_MIHOMO_BIN")" \
        "$VLESS_TEST_SYSTEMD_DIR" "$VLESS_TEST_OPENRC_DIR" "$TEST_TMP/log"
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

write_all_mihomo_protocols_db() {
    jq -n '{
      version:"4.0.0", xray:{}, singbox:{}, meta:{},
      mihomo:{
        snell:{port:41001,psk:"v4-one",version:4},
        "snell-v5":{port:51001,psk:"v5-one",version:5},
        "snell-shadowtls":{port:42001,psk:"v4-stls",version:4,sni:"www.microsoft.com",stls_password:"stls-v4"},
        "snell-v5-shadowtls":{port:52001,psk:"v5-stls",version:5,sni:"www.microsoft.com",stls_password:"stls-v5"}
      }
    }' >"$DB_FILE"
}

# Execute the generated discovery function without entering its watchdog loop.
watchdog_services() {
    create_server_scripts
    local runner="$TEST_TMP/watchdog-services.sh" line
    while IFS= read -r line; do
        case "$line" in
            'CFG="/etc/vless-reality"') printf 'CFG=%q\n' "$CFG" >>"$runner" ;;
            'LOG_FILE="/var/log/vless-watchdog.log"') printf 'LOG_FILE=%q\n' "$TEST_TMP/watchdog.log" >>"$runner" ;;
            'log "INFO: Watchdog 启动"') break ;;
            *) printf '%s\n' "$line" >>"$runner" ;;
        esac
    done <"$CFG/watchdog.sh"
    printf '%s\n' 'get_all_services' >>"$runner"
    bash "$runner"
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

test_official_snell_v4_v5_install_update_entrypoints_are_unreachable() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"

    ! declare -F install_snell >/dev/null || return 1
    ! declare -F install_snell_v5 >/dev/null || return 1
    ! declare -F update_snell_v5_core >/dev/null || return 1
    ! declare -F update_snell_v5_core_custom >/dev/null
)

test_core_update_helper_rejects_official_snell_v5() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    _check_core_update_deps() { return 0; }
    _confirm_core_update_version() { return 0; }
    _backup_core_binary() { return 0; }
    _show_changelog_summary() { :; }
    _ok() { :; }
    _err() { :; }
    _warn() { :; }
    _info() { :; }
    svc() { return 1; }
    forbidden_installer() { touch "$TEST_TMP/official-installer-called"; }

    ! _update_core_to_version "Snell v5" stable 5.0.1 vless-snell-v5 forbidden_installer || return 1
    [[ ! -e "$TEST_TMP/official-installer-called" ]]
)

test_mihomo_runtime_metadata_has_no_external_snell_v4_v5_execution() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"

    local protocol
    for protocol in snell snell-v5 snell-shadowtls snell-v5-shadowtls; do
        [[ "${PROTO_SVC[$protocol]:-}" == vless-mihomo ]] || return 1
        [[ "${PROTO_BIN[$protocol]:-}" == vless-mihomo ]] || return 1
        [[ "${PROTO_KIND[$protocol]:-}" == mihomo ]] || return 1
        [[ -z "${PROTO_EXEC[$protocol]:-}" ]] || return 1
        [[ -z "${BACKEND_NAME[$protocol]:-}" ]] || return 1
        [[ -z "${BACKEND_EXEC[$protocol]:-}" ]] || return 1
    done
    [[ -z "${SVC_PROC[vless-snell]:-}" && -z "${SVC_PROC[vless-snell-v5]:-}" &&
       -z "${SVC_PROC[vless-snell-shadowtls]:-}" && -z "${SVC_PROC[vless-snell-v5-shadowtls]:-}" ]]
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

test_mihomo_runtime_metadata_maps_shared_service() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_all_mihomo_protocols_db

    [[ "$(get_mihomo_protocols)" == $'snell\nsnell-v5\nsnell-shadowtls\nsnell-v5-shadowtls' ]] || return 1
    local protocol
    for protocol in snell snell-v5 snell-shadowtls snell-v5-shadowtls; do
        [[ "${PROTO_SVC[$protocol]}" == "vless-mihomo" ]] || return 1
        [[ "${PROTO_BIN[$protocol]}" == "vless-mihomo" ]] || return 1
        [[ "${PROTO_KIND[$protocol]}" == "mihomo" ]] || return 1
    done
    [[ "${SVC_PROC[vless-mihomo]}" == "vless-mihomo" ]]
)

test_mihomo_openrc_status_falls_back_to_shared_process() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    DISTRO=alpine
    rc-service() { return 1; }
    _pgrep() { [[ "$1" == vless-mihomo ]]; }

    svc status vless-mihomo
)

test_watchdog_has_one_validated_mihomo_entry() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_all_mihomo_protocols_db

    create_server_scripts
    [[ -x "$CFG/watchdog.sh" ]] || return 1
    [[ "$(grep -o 'vless-mihomo:vless-mihomo' "$CFG/watchdog.sh" | wc -l)" -eq 1 ]] || return 1
    grep -Fq 'vless-mihomo -t -f "$CFG/mihomo.yaml"' "$CFG/watchdog.sh"
)

# Break caught: treating legacy .xray Snell records as Xray/Mihomo would monitor
# the wrong service, while omitting a ShadowTLS backend would leave it unmonitored.
test_watchdog_discovers_only_legacy_xray_snell_services() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    init_db
    jq -n '{
      version:"4.0.0", singbox:{}, meta:{}, mihomo:{},
      xray:{
        snell:{port:41001,psk:"legacy-v4"},
        "snell-v5":{port:51001,psk:"legacy-v5"},
        "snell-shadowtls":{port:42001,backend_port:42002,psk:"legacy-stls"},
        "snell-v5-shadowtls":{port:52001,backend_port:52002,psk:"legacy-v5-stls"}
      }
    }' >"$DB_FILE"
    local services
    services=$(watchdog_services)
    [[ "$services" == 'vless-snell:snell-server vless-snell-shadowtls:shadow-tls vless-snell-shadowtls-backend:snell-server vless-snell-v5:snell-server-v5 vless-snell-v5-shadowtls:shadow-tls vless-snell-v5-shadowtls-backend:snell-server-v5 ' ]]
)

# Break caught: falling back to the retired frontend/backend services for a new
# .mihomo node would create duplicate ownership of the listener.
test_watchdog_routes_mihomo_records_only_to_shared_service() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_all_mihomo_protocols_db

    [[ "$(watchdog_services)" == 'vless-mihomo:vless-mihomo ' ]]
)

# Break caught: routing a pre-migration record to Mihomo hides logs for its old
# ShadowTLS frontend service; new .mihomo records must not enter this fallback.
test_service_log_menu_routes_legacy_xray_shadowtls_to_old_frontend() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    init_db
    db_add xray snell-shadowtls '{"port":42001,"backend_port":42002,"psk":"legacy"}'
    G= W= NC=
    _header() { :; }
    _line() { :; }
    _err() { :; }
    _pause() { :; }
    journalctl() { printf '%s\n' "$*" >"$TEST_TMP/journalctl.args"; }

    local output
    output=$(show_service_logs <<<"1")
    grep -q 'Snell+ShadowTLS 服务日志' <<<"$output" || return 1
    [[ "$(<"$TEST_TMP/journalctl.args")" == '-u vless-snell-shadowtls --no-pager -n 50' ]]
)

test_mihomo_ports_healthy_requires_every_listener() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_all_mihomo_protocols_db
    ss() {
        cat <<'EOF'
LISTEN 0 4096 0.0.0.0:41001 0.0.0.0:*
LISTEN 0 4096 [::]:51001 [::]:*
LISTEN 0 4096 0.0.0.0:42001 0.0.0.0:*
LISTEN 0 4096 [::]:52001 [::]:*
EOF
    }

    _mihomo_ports_healthy "$DB_FILE" || return 1

    ss() {
        cat <<'EOF'
LISTEN 0 4096 0.0.0.0:41001 0.0.0.0:*
LISTEN 0 4096 [::]:51001 [::]:*
LISTEN 0 4096 0.0.0.0:42001 0.0.0.0:*
EOF
    }
    ! _mihomo_ports_healthy "$DB_FILE"
)

test_create_mihomo_systemd_service_definition() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    DISTRO=debian
    systemctl() { printf '%s\n' "$*" >"$TEST_TMP/systemctl.args"; }

    create_mihomo_service
    local unit="$VLESS_TEST_SYSTEMD_DIR/vless-mihomo.service"
    [[ -f "$unit" ]] || return 1
    grep -Fq "ExecStartPre=$MIHOMO_BIN -t -f $MIHOMO_CONFIG" "$unit" || return 1
    grep -Fq "ExecStart=$MIHOMO_BIN -d $CFG -f $MIHOMO_CONFIG" "$unit" || return 1
    grep -Fq 'Restart=always' "$unit" || return 1
    grep -Fq 'RestartSec=3' "$unit" || return 1
    grep -Fq 'LimitNOFILE=51200' "$unit" || return 1
    [[ "$(<"$TEST_TMP/systemctl.args")" == "daemon-reload" ]]
)

test_create_mihomo_systemd_service_fails_when_unit_write_fails() (
    new_fixture
    trap cleanup_fixture EXIT
    rm -rf "$VLESS_TEST_SYSTEMD_DIR"
    printf '%s\n' not-a-directory >"$VLESS_TEST_SYSTEMD_DIR"
    source "$SCRIPT"
    DISTRO=debian
    systemctl() { touch "$TEST_TMP/daemon-reload-touched"; return 0; }

    if create_mihomo_service 2>/dev/null; then
        return 1
    fi
    [[ ! -e "$TEST_TMP/daemon-reload-touched" ]]
)

test_create_mihomo_openrc_service_definition() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    DISTRO=alpine
    rm -rf "$(dirname "$VLESS_TEST_MIHOMO_LOG_FILE")"

    create_mihomo_service
    local init="$VLESS_TEST_OPENRC_DIR/vless-mihomo"
    [[ -d "$(dirname "$VLESS_TEST_MIHOMO_LOG_FILE")" ]] || return 1
    [[ -x "$init" ]] || return 1
    grep -Fq "command=\"$MIHOMO_BIN\"" "$init" || return 1
    grep -Fq "command_args=\"-d $CFG -f $MIHOMO_CONFIG\"" "$init" || return 1
    grep -Fq 'command_background="yes"' "$init" || return 1
    grep -Fq 'pidfile="/run/vless-mihomo.pid"' "$init" || return 1
    grep -Fq 'need net' "$init" || return 1
    grep -Fq 'output_log="/var/log/vless/mihomo.log"' "$init" || return 1
    grep -Fq 'error_log="/var/log/vless/mihomo.log"' "$init"
)

test_start_services_runs_one_shared_mihomo_core() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    init_db() { :; }
    get_xray_protocols() { :; }
    get_singbox_protocols() { :; }
    get_standalone_protocols() { :; }
    install_mihomo() {
        touch "$MIHOMO_BIN"
        chmod 700 "$MIHOMO_BIN"
        printf '%s\n' install >>"$TEST_TMP/calls"
    }
    generate_mihomo_config() {
        printf '%s\n' '{}' >"$MIHOMO_CONFIG"
        printf '%s\n' generate >>"$TEST_TMP/calls"
    }
    validate_mihomo_config() {
        [[ "$1" == "$MIHOMO_CONFIG" && "$2" == "$MIHOMO_BIN" ]]
        printf '%s\n' validate >>"$TEST_TMP/calls"
    }
    create_mihomo_service() { printf '%s\n' create >>"$TEST_TMP/calls"; }
    _start_core_service() {
        printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >>"$TEST_TMP/start"
    }
    svc() { :; }

    start_services >/dev/null
    [[ "$(<"$TEST_TMP/calls")" == $'install\ngenerate\nvalidate\ncreate' ]] || return 1
    [[ "$(grep -c '^vless-mihomo|vless-mihomo|' "$TEST_TMP/start")" -eq 1 ]] || return 1
    grep -q '|:$' "$TEST_TMP/start"
)

test_start_services_ignores_legacy_xray_snell_when_mihomo_namespace_empty() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    jq -n '{
      version:"4.0.0", singbox:{}, mihomo:{}, meta:{},
      xray:{snell:{port:41001,psk:"legacy-v4",version:4}}
    }' >"$DB_FILE"
    init_db() { :; }
    install_mihomo() { touch "$TEST_TMP/install-touched"; }
    generate_mihomo_config() { touch "$TEST_TMP/generate-touched"; }
    create_mihomo_service() { touch "$TEST_TMP/create-touched"; }
    _start_core_service() { touch "$TEST_TMP/start-touched"; }
    svc() { printf '%s:%s\n' "$1" "$2" >>"$TEST_TMP/svc"; }
    _info() { :; }
    _err() { :; }
    _warn() { :; }

    start_services >/dev/null
    [[ ! -e "$TEST_TMP/install-touched" ]] || return 1
    [[ ! -e "$TEST_TMP/generate-touched" ]] || return 1
    [[ ! -e "$TEST_TMP/create-touched" ]] || return 1
    [[ ! -e "$TEST_TMP/start-touched" ]] || return 1
    ! grep -q 'vless-mihomo' "$TEST_TMP/svc"
)

test_start_services_does_not_start_mihomo_without_service_definition() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    touch "$MIHOMO_BIN"
    chmod 700 "$MIHOMO_BIN"
    init_db() { :; }
    get_xray_protocols() { :; }
    get_singbox_protocols() { :; }
    get_standalone_protocols() { :; }
    generate_mihomo_config() { printf '%s\n' '{}' >"$MIHOMO_CONFIG"; }
    validate_mihomo_config() { return 0; }
    create_mihomo_service() { return 1; }
    _start_core_service() { touch "$TEST_TMP/start-touched"; }
    svc() { :; }
    _err() { :; }
    _warn() { :; }

    if start_services >/dev/null; then
        return 1
    fi
    [[ ! -e "$TEST_TMP/start-touched" ]]
)

test_mihomo_runtime_consistency_repairs_invalid_or_unhealthy_runtime() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    touch "$MIHOMO_BIN"
    chmod 700 "$MIHOMO_BIN"
    printf '%s\n' '{}' >"$MIHOMO_CONFIG"
    local health_calls=0
    validate_mihomo_config() {
        printf '%s\n' validate >>"$TEST_TMP/calls"
        [[ -f "$1" && "$2" == "$MIHOMO_BIN" ]]
    }
    _mihomo_ports_healthy() {
        health_calls=$((health_calls + 1))
        printf '%s\n' health >>"$TEST_TMP/calls"
        [[ $health_calls -gt 1 ]]
    }
    generate_mihomo_config() {
        printf '%s\n' '{}' >"$MIHOMO_CONFIG"
        printf '%s\n' generate >>"$TEST_TMP/calls"
    }
    create_server_scripts() { printf '%s\n' scripts >>"$TEST_TMP/calls"; }
    create_mihomo_service() { printf '%s\n' service >>"$TEST_TMP/calls"; }
    svc() {
        printf '%s:%s\n' "$1" "$2" >>"$TEST_TMP/svc"
        return 0
    }
    _info() { :; }
    _ok() { :; }

    ensure_mihomo_runtime_consistency
    grep -q '^generate$' "$TEST_TMP/calls" || return 1
    [[ "$(grep -c '^validate$' "$TEST_TMP/calls")" -ge 1 ]] || return 1
    [[ "$(grep -c '^health$' "$TEST_TMP/calls")" -eq 2 ]] || return 1
    grep -q '^restart:vless-mihomo$' "$TEST_TMP/svc"
)

test_mihomo_runtime_consistency_stops_if_service_definition_fails() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    touch "$MIHOMO_BIN" "$MIHOMO_CONFIG"
    chmod 700 "$MIHOMO_BIN"
    validate_mihomo_config() { return 0; }
    _mihomo_ports_healthy() { return 1; }
    generate_mihomo_config() { return 0; }
    create_server_scripts() { return 0; }
    create_mihomo_service() { return 1; }
    svc() { printf '%s:%s\n' "$1" "$2" >>"$TEST_TMP/svc"; return 1; }
    _info() { :; }

    declare -F ensure_mihomo_runtime_consistency >/dev/null || return 1
    ! ensure_mihomo_runtime_consistency
    ! grep -Eq '^(enable|restart|start):' "$TEST_TMP/svc"
)

test_mihomo_runtime_consistency_ignores_empty_namespace() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    jq -n '{
      version:"4.0.0", singbox:{}, mihomo:{}, meta:{},
      xray:{snell:{port:41001,psk:"legacy-v4",version:4}}
    }' >"$DB_FILE"
    touch "$MIHOMO_BIN"
    chmod 700 "$MIHOMO_BIN"
    generate_mihomo_config() { touch "$TEST_TMP/generated"; }
    svc() { touch "$TEST_TMP/service-touched"; }

    declare -F ensure_mihomo_runtime_consistency >/dev/null || return 1
    ensure_mihomo_runtime_consistency
    [[ ! -e "$TEST_TMP/generated" && ! -e "$TEST_TMP/service-touched" ]]
)

test_mihomo_lifecycle_cleanup_stops_shared_service_once() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    DISTRO=alpine
    rc-service() { return 0; }
    svc() { printf '%s:%s\n' "$1" "$2" >>"$TEST_TMP/svc"; }
    cleanup_hy2_nat_rules() { :; }

    stop_services >/dev/null
    force_cleanup
    [[ "$(grep -c '^stop:vless-mihomo$' "$TEST_TMP/svc")" -eq 2 ]]
)

test_set_mihomo_log_level_commits_complete_config() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    printf '%s\n' '{"old":true}' >"$MIHOMO_CONFIG"
    generate_mihomo_config() {
        local db_file="${1:-$DB_FILE}" output_file="${2:-$MIHOMO_CONFIG}"
        jq -n --arg level "$(jq -r '.meta.mihomo_log_level' "$db_file")" '{"log-level":$level,listeners:[1]}' >"$output_file"
    }
    validate_mihomo_config() { jq -e '.listeners | length == 1' "$1" >/dev/null; }
    svc() { [[ "$1:$2" == 'restart:vless-mihomo' ]]; }

    declare -F set_mihomo_log_level >/dev/null || return 1
    set_mihomo_log_level debug
    jq -e '.meta.mihomo_log_level == "debug"' "$DB_FILE" >/dev/null || return 1
    jq -e '.["log-level"] == "debug" and (.listeners | length) == 1' "$MIHOMO_CONFIG" >/dev/null
)

test_set_mihomo_log_level_rolls_back_database_and_config() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    cp "$DB_FILE" "$TEST_TMP/db.before"
    printf '%s\n' '{"old":true}' >"$MIHOMO_CONFIG"
    cp "$MIHOMO_CONFIG" "$TEST_TMP/config.before"
    generate_mihomo_config() { printf '%s\n' '{"new":true}' >"${2:-$MIHOMO_CONFIG}"; }
    validate_mihomo_config() { return 0; }
    local restarts=0
    svc() {
        [[ "$1:$2" == 'restart:vless-mihomo' ]] || return 1
        restarts=$((restarts + 1))
        [[ $restarts -gt 1 ]]
    }

    declare -F set_mihomo_log_level >/dev/null || return 1
    ! set_mihomo_log_level warning
    cmp -s "$DB_FILE" "$TEST_TMP/db.before" || return 1
    cmp -s "$MIHOMO_CONFIG" "$TEST_TMP/config.before" || return 1
    [[ $restarts -eq 2 ]]
)

test_set_mihomo_log_level_rolls_back_on_validation_failure() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    cp "$DB_FILE" "$TEST_TMP/db.before"
    printf '%s\n' '{"old":true}' >"$MIHOMO_CONFIG"
    cp "$MIHOMO_CONFIG" "$TEST_TMP/config.before"
    generate_mihomo_config() { printf '%s\n' '{"new":true}' >"${2:-$MIHOMO_CONFIG}"; }
    validate_mihomo_config() { return 1; }
    svc() { touch "$TEST_TMP/service-touched"; }

    declare -F set_mihomo_log_level >/dev/null || return 1
    ! set_mihomo_log_level debug
    cmp -s "$DB_FILE" "$TEST_TMP/db.before" || return 1
    cmp -s "$MIHOMO_CONFIG" "$TEST_TMP/config.before" || return 1
    [[ ! -e "$TEST_TMP/service-touched" ]]
)

# Break caught: deleting the recovery snapshot or ignoring a failed restore
# would discard the original DB/config after a failed log-level transaction.
test_set_mihomo_log_level_retains_snapshot_when_restore_fails() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    cp "$DB_FILE" "$TEST_TMP/db.before"
    printf '%s\n' '{"old":true}' >"$MIHOMO_CONFIG"
    cp "$MIHOMO_CONFIG" "$TEST_TMP/config.before"
    generate_mihomo_config() { printf '%s\n' '{"new":true}' >"${2:-$MIHOMO_CONFIG}"; }
    validate_mihomo_config() { return 1; }
    local restore_attempts=0
    cp() {
        if [[ "${1:-}" == "-p" && "${2:-}" == "$TEST_TMP/etc/.mihomo-log-level."*"/db.json" && "${3:-}" == "$DB_FILE" ]]; then
            restore_attempts=$((restore_attempts + 1))
            return 1
        fi
        command cp "$@"
    }

    ! set_mihomo_log_level debug || return 1
    [[ $restore_attempts -eq 1 ]] || return 1
    ! cmp -s "$DB_FILE" "$TEST_TMP/db.before" || return 1
    cmp -s "$MIHOMO_CONFIG" "$TEST_TMP/config.before" || return 1
    local snapshot
    snapshot=$(find "$CFG" -maxdepth 1 -type d -name '.mihomo-log-level.*' -print -quit)
    [[ -n "$snapshot" ]] || return 1
    cmp -s "$snapshot/db.json" "$TEST_TMP/db.before" || return 1
    cmp -s "$snapshot/mihomo.yaml" "$TEST_TMP/config.before"
)

test_mihomo_systemd_lifecycle_stops_shared_service_once() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    DISTRO=debian
    systemctl() {
        [[ "$1:$2" == "is-active:--quiet" ]] && return 0
        return 0
    }
    svc() { printf '%s:%s\n' "$1" "$2" >>"$TEST_TMP/svc"; }
    cleanup_hy2_nat_rules() { :; }

    stop_services >/dev/null
    [[ "$(grep -c '^stop:vless-mihomo$' "$TEST_TMP/svc")" -eq 1 ]]
)

test_mihomo_selinux_restore_includes_managed_binary() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    DISTRO=centos
    getenforce() { printf '%s\n' Enforcing; }
    restorecon() { printf '%s\n' "$*" >"$TEST_TMP/restorecon.args"; }
    setsebool() { :; }
    _info() { :; }

    fix_selinux_context
    grep -Fq "$MIHOMO_BIN" "$TEST_TMP/restorecon.args"
)

test_mihomo_status_reports_partial_anomaly_and_missing_ports() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    G= Y= R= C= D= NC=
    svc() { [[ "$1:$2" == 'status:vless-mihomo' ]]; }
    ss() {
        printf '%s\n' \
            'LISTEN 0 4096 0.0.0.0:41001 0.0.0.0:*' \
            'LISTEN 0 4096 0.0.0.0:41002 0.0.0.0:*' \
            'LISTEN 0 4096 0.0.0.0:51001 0.0.0.0:*'
    }
    access_restriction_enabled() { return 1; }

    local output
    output=$(show_status)
    grep -q '部分异常' <<<"$output" || return 1
    grep -q '缺失端口.*52001' <<<"$output" || return 1
    grep -q '已安装 (3个)' <<<"$output"
)

test_mihomo_service_and_protocol_presentations() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    G= Y= R= C= D= W= NC=
    svc() { [[ "$1:$2" == 'status:vless-mihomo' ]]; }
    ss() { mihomo_list_ports "$DB_FILE" | while read -r port; do printf 'LISTEN 0 4096 0.0.0.0:%s 0.0.0.0:*\n' "$port"; done; }
    _line() { :; }

    local services overview installed
    services=$(show_services_status)
    overview=$(show_protocols_overview)
    installed=$(show_all_protocols_info <<<"0")
    grep -q 'Mihomo 服务.*运行中' <<<"$services" || return 1
    grep -q 'Mihomo 协议 (共享服务)' <<<"$overview" || return 1
    grep -q 'Mihomo 协议 (共享服务)' <<<"$installed" || return 1
    grep -q '41001,41002' <<<"$installed"
)

test_service_log_menu_dispatches_one_shared_mihomo_item() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    G= W= NC=
    _header() { :; }
    _line() { :; }
    _err() { :; }
    show_mihomo_diagnostics() { printf '%s\n' diagnostics-opened; }

    local output
    output=$(show_service_logs <<<"1")
    [[ "$(grep -c 'Mihomo 服务日志' <<<"$output")" -eq 1 ]] || return 1
    grep -q 'diagnostics-opened' <<<"$output"
)

test_mihomo_diagnostics_menu_and_systemd_logs() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    G= Y= R= C= D= W= NC=
    _header() { :; }
    _line() { :; }
    _item() { printf '%s) %s\n' "$1" "$2"; }
    journalctl() { printf '%s\n' "$*" >"$TEST_TMP/journalctl.args"; }

    local menu
    menu=$(show_mihomo_diagnostics <<<"0")
    grep -q '查看最近 50 行' <<<"$menu" || return 1
    grep -q '实时跟踪日志' <<<"$menu" || return 1
    grep -q '校验完整配置' <<<"$menu" || return 1
    grep -q '启用 debug 日志' <<<"$menu" || return 1
    grep -q '恢复 warning 日志' <<<"$menu" || return 1
    _show_mihomo_logs last
    [[ "$(<"$TEST_TMP/journalctl.args")" == '-u vless-mihomo --no-pager -n 50' ]]
)

test_mihomo_diagnostics_actions_validate_and_change_log_level() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    G= Y= R= C= D= W= NC=
    _header() { :; }
    _line() { :; }
    _item() { :; }
    _pause() { :; }
    _ok() { :; }
    _err() { :; }
    validate_mihomo_config() { printf '%s|%s\n' "$1" "$2" >"$TEST_TMP/validate.args"; }
    set_mihomo_log_level() { printf '%s\n' "$1" >>"$TEST_TMP/levels"; }

    show_mihomo_diagnostics <<<'3' >/dev/null
    [[ "$(<"$TEST_TMP/validate.args")" == "$MIHOMO_CONFIG|$MIHOMO_BIN" ]] || return 1
    show_mihomo_diagnostics <<<'4' >/dev/null
    show_mihomo_diagnostics <<<'5' >/dev/null
    [[ "$(<"$TEST_TMP/levels")" == $'debug\nwarning' ]]
)

test_mihomo_alpine_logs_use_dedicated_file_then_messages_fallback() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    DISTRO=alpine
    printf '%s\n' first second >"$VLESS_TEST_MIHOMO_LOG_FILE"

    local output
    output=$(_show_mihomo_logs last)
    [[ "$output" == $'first\nsecond' ]] || return 1

    rm -f "$VLESS_TEST_MIHOMO_LOG_FILE"
    printf '%s\n' 'unrelated' 'vless-mihomo: fallback line' >"$VLESS_TEST_MESSAGES_LOG"
    output=$(_show_mihomo_logs last)
    [[ "$output" == 'vless-mihomo: fallback line' ]]
)

prepare_mihomo_transaction_fixture() {
    source "$SCRIPT"
    init_db
    TEST_SERVICE_RUNNING=false
    TEST_SERVICE_ENABLED=false
    TEST_FAIL_RESTART=false
    export TEST_FAIL_VALIDATION=false
    export MIHOMO_TX_LOG="$TEST_TMP/svc.log"
    : >"$TEST_TMP/svc.log"
    cat >"$MIHOMO_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' validate >>"$MIHOMO_TX_LOG"
[[ "$1" == "-t" && "$2" == "-f" && -f "$3" ]] || exit 1
[[ "$TEST_FAIL_VALIDATION" == false ]]
EOF
    chmod 700 "$MIHOMO_BIN"
    systemctl() {
        printf 'systemctl:%s\n' "$*" >>"$TEST_TMP/systemctl.log"
    }
    create_mihomo_service() {
        printf '%s\n' create >>"$TEST_TMP/svc.log"
        touch "$SYSTEMD_DIR/vless-mihomo.service"
    }
    svc() {
        local action="$1" name="$2"
        printf '%s:%s\n' "$action" "$name" >>"$TEST_TMP/svc.log"
        [[ "$name" == vless-mihomo ]] || return 1
        case "$action" in
            status) [[ "$TEST_SERVICE_RUNNING" == true ]] ;;
            enabled) [[ "$TEST_SERVICE_ENABLED" == true ]] ;;
            start) TEST_SERVICE_RUNNING=true ;;
            restart)
                if [[ "$TEST_FAIL_RESTART" == true ]]; then
                    TEST_FAIL_RESTART=false
                    return 1
                fi
                TEST_SERVICE_RUNNING=true
                ;;
            stop) TEST_SERVICE_RUNNING=false ;;
            enable) TEST_SERVICE_ENABLED=true ;;
            disable) TEST_SERVICE_ENABLED=false ;;
            *) return 1 ;;
        esac
    }
    _mihomo_ports_healthy() {
        printf '%s\n' health >>"$TEST_TMP/svc.log"
        [[ "$(mihomo_list_ports "$1")" == "$(jq -r '.listeners[].port' "$MIHOMO_CONFIG")" ]]
    }
}

test_mihomo_transaction_adds_multiple_protocol_port_records() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture

    _apply_mihomo_node_change snell add all '{"port":41001,"psk":"v4-one","version":4}' || return 1
    _apply_mihomo_node_change snell add all '{"port":41002,"psk":"v4-two","version":4}' || return 1
    _apply_mihomo_node_change snell-v5 add all '{"port":51001,"psk":"v5-one","version":5}' || return 1

    jq -e '.mihomo.snell == [
        {port:41001,psk:"v4-one",version:4},
        {port:41002,psk:"v4-two",version:4}
    ] and .mihomo["snell-v5"] == [{port:51001,psk:"v5-one",version:5}]' "$DB_FILE" >/dev/null || return 1
    jq -e '(.listeners | length) == 3 and
        ([.listeners[].port] == [41001,41002,51001])' "$MIHOMO_CONFIG" >/dev/null || return 1
    [[ "$(<"$TEST_TMP/svc.log")" == $'status:vless-mihomo\nenabled:vless-mihomo\nvalidate\ncreate\nenable:vless-mihomo\nstart:vless-mihomo\nstatus:vless-mihomo\nhealth\nstatus:vless-mihomo\nenabled:vless-mihomo\nvalidate\nrestart:vless-mihomo\nstatus:vless-mihomo\nhealth\nstatus:vless-mihomo\nenabled:vless-mihomo\nvalidate\nrestart:vless-mihomo\nstatus:vless-mihomo\nhealth' ]]
)

test_mihomo_transaction_replaces_only_selected_port() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    write_mixed_mihomo_db
    generate_mihomo_config
    TEST_SERVICE_RUNNING=true
    : >"$TEST_TMP/svc.log"

    _apply_mihomo_node_change snell replace 41001 '{"port":41001,"psk":"v4-replaced","version":4}' || return 1

    jq -e '.mihomo.snell == [
        {port:41001,psk:"v4-replaced",version:4},
        {port:41002,psk:"v4-two",version:4}
    ] and .mihomo["snell-v5"][0].psk == "v5-one"' "$DB_FILE" >/dev/null || return 1
    jq -e '(.listeners | length) == 4 and
        (.listeners[] | select(.port == 41001).psk) == "v4-replaced"' "$MIHOMO_CONFIG" >/dev/null
)

test_mihomo_transaction_removes_only_selected_port() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    write_mixed_mihomo_db
    generate_mihomo_config
    TEST_SERVICE_RUNNING=true

    _apply_mihomo_node_change snell remove 41002 '{}' || return 1

    jq -e '.mihomo.snell == [{port:41001,psk:"v4-one",version:4}] and
        .mihomo["snell-v5"][0].port == 51001' "$DB_FILE" >/dev/null || return 1
    jq -e '([.listeners[].port] | index(41002)) == null and
        ([.listeners[].port] | index(41001)) != null and
        ([.listeners[].port] | index(51001)) != null' "$MIHOMO_CONFIG" >/dev/null
)

test_mihomo_transaction_removes_final_node_and_shared_service() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    _apply_mihomo_node_change snell add all '{"port":41001,"psk":"v4-one","version":4}' || return 1
    : >"$TEST_TMP/svc.log"

    _apply_mihomo_node_change snell remove all '{}' || return 1

    jq -e '.mihomo == {}' "$DB_FILE" >/dev/null || return 1
    [[ ! -e "$MIHOMO_CONFIG" && ! -e "$SYSTEMD_DIR/vless-mihomo.service" ]] || return 1
    [[ "$TEST_SERVICE_RUNNING" == false ]] || return 1
    [[ "$(<"$TEST_TMP/svc.log")" == $'status:vless-mihomo\nenabled:vless-mihomo\nstop:vless-mihomo\ndisable:vless-mihomo' ]]
)

test_mihomo_transaction_validation_failure_restores_exact_bytes() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    write_mixed_mihomo_db
    generate_mihomo_config
    cp "$DB_FILE" "$TEST_TMP/db.before"
    cp "$MIHOMO_CONFIG" "$TEST_TMP/config.before"
    TEST_SERVICE_RUNNING=true
    TEST_FAIL_VALIDATION=true
    : >"$TEST_TMP/svc.log"

    ! _apply_mihomo_node_change snell add all '{"port":41003,"psk":"never-committed","version":4}' || return 1
    cmp -s "$DB_FILE" "$TEST_TMP/db.before" || return 1
    cmp -s "$MIHOMO_CONFIG" "$TEST_TMP/config.before" || return 1
    [[ "$(<"$TEST_TMP/svc.log")" == $'status:vless-mihomo\nenabled:vless-mihomo\nvalidate' ]]
)

test_mihomo_transaction_restart_failure_restores_and_restarts_previous_state() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    write_mixed_mihomo_db
    generate_mihomo_config
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    cp "$DB_FILE" "$TEST_TMP/db.before"
    cp "$MIHOMO_CONFIG" "$TEST_TMP/config.before"
    TEST_SERVICE_RUNNING=true
    TEST_SERVICE_ENABLED=true
    TEST_FAIL_RESTART=true
    : >"$TEST_TMP/svc.log"

    ! _apply_mihomo_node_change snell-v5 replace 51001 '{"port":51001,"psk":"never-committed","version":5}' || return 1
    cmp -s "$DB_FILE" "$TEST_TMP/db.before" || return 1
    cmp -s "$MIHOMO_CONFIG" "$TEST_TMP/config.before" || return 1
    [[ "$TEST_SERVICE_RUNNING" == true ]] || return 1
    [[ "$(<"$TEST_TMP/svc.log")" == $'status:vless-mihomo\nenabled:vless-mihomo\nvalidate\nrestart:vless-mihomo\nrestart:vless-mihomo' ]]
)

test_mihomo_transaction_enables_existing_disabled_service() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    write_mixed_mihomo_db
    generate_mihomo_config
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    TEST_SERVICE_RUNNING=true
    TEST_SERVICE_ENABLED=false
    : >"$TEST_TMP/svc.log"

    _apply_mihomo_node_change snell add all '{"port":41003,"psk":"v4-three","version":4}' || return 1

    [[ "$TEST_SERVICE_ENABLED" == true ]] || return 1
    grep -q '^enable:vless-mihomo$' "$TEST_TMP/svc.log"
)

test_mihomo_transaction_restores_prior_disabled_state_on_rollback() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    write_mixed_mihomo_db
    generate_mihomo_config
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    TEST_SERVICE_RUNNING=true
    TEST_SERVICE_ENABLED=false
    TEST_FAIL_RESTART=true
    : >"$TEST_TMP/svc.log"

    ! _apply_mihomo_node_change snell add all '{"port":41003,"psk":"rollback","version":4}' || return 1

    [[ "$TEST_SERVICE_ENABLED" == false && "$TEST_SERVICE_RUNNING" == true ]] || return 1
    [[ "$(grep -E '^(enable|disable|restart):' "$TEST_TMP/svc.log")" == $'enable:vless-mihomo\nrestart:vless-mihomo\ndisable:vless-mihomo\nrestart:vless-mihomo' ]]
)

test_mihomo_transaction_retains_snapshot_when_file_restore_fails() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    write_mixed_mihomo_db
    generate_mihomo_config
    TEST_SERVICE_RUNNING=true
    TEST_FAIL_VALIDATION=true
    _mihomo_snapshot_restore() {
        printf '%s\n' "$1" >"$TEST_TMP/failed-snapshot"
        return 1
    }

    ! _apply_mihomo_node_change snell add all '{"port":41003,"psk":"rollback","version":4}' || return 1
    local snapshot
    snapshot=$(<"$TEST_TMP/failed-snapshot")
    [[ -d "$snapshot" && -f "$snapshot/db.json" && -f "$snapshot/mihomo.yaml" ]]
)

test_mihomo_transaction_retains_snapshot_when_service_restore_fails() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    write_mixed_mihomo_db
    generate_mihomo_config
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    TEST_SERVICE_RUNNING=true
    TEST_SERVICE_ENABLED=false
    TEST_FAIL_RESTART=true
    _mihomo_restore_running_state() {
        printf '%s\n' "$1" >"$TEST_TMP/failed-snapshot"
        return 1
    }

    ! _apply_mihomo_node_change snell add all '{"port":41003,"psk":"rollback","version":4}' || return 1
    local snapshot
    snapshot=$(<"$TEST_TMP/failed-snapshot")
    [[ -d "$snapshot" && -f "$snapshot/db.json" && -f "$snapshot/mihomo.yaml" ]]
)

test_mihomo_transaction_rejects_cross_protocol_duplicate_before_service_mutation() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    _apply_mihomo_node_change snell add all '{"port":41001,"psk":"v4-one","version":4}' || return 1
    cp "$DB_FILE" "$TEST_TMP/db.before"
    cp "$MIHOMO_CONFIG" "$TEST_TMP/config.before"
    : >"$TEST_TMP/svc.log"

    ! _apply_mihomo_node_change snell-v5 add all '{"port":41001,"psk":"duplicate","version":5}' || return 1
    cmp -s "$DB_FILE" "$TEST_TMP/db.before" || return 1
    cmp -s "$MIHOMO_CONFIG" "$TEST_TMP/config.before" || return 1
    ! grep -Eq '^(enable|disable|start|stop|restart):' "$TEST_TMP/svc.log"
)

test_snell_generators_store_only_transactional_mihomo_records() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    init_db
    local calls=""
    : >"$TEST_TMP/build-calls"
    build_config() {
        printf '%s\n' "$*" >>"$TEST_TMP/build-calls"
        jq -n '$ARGS.named' --args "$@"
    }
    _apply_mihomo_node_change() {
        calls+="$1|$2|$3|$(jq -c . <<<"$4")"$'\n'
    }
    _save_join_info() { :; }
    INSTALL_MODE=add
    REPLACE_PORT=all

    gen_snell_server_config v4-key 41001 4 || return 1
    gen_snell_v5_server_config v5-key 51001 5 || return 1
    gen_snell_shadowtls_server_config stls-key 42001 www.microsoft.com stls-secret 4 || return 1

    [[ "$(<"$TEST_TMP/build-calls")" == $'psk v4-key port 41001 version 4\npsk v5-key port 51001 version 5\npsk stls-key port 42001 version 4 sni www.microsoft.com stls_password stls-secret' ]] || return 1
    [[ "$calls" == $'snell|add|all|{}\nsnell-v5|add|all|{}\nsnell-shadowtls|add|all|{}\n' ]] || return 1
    jq -e '.xray == {} and .mihomo == {}' "$DB_FILE" >/dev/null || return 1
    [[ ! -e "$CFG/snell.conf" && ! -e "$CFG/snell-v5.conf" &&
       ! -e "$CFG/snell-shadowtls.conf" && ! -e "$CFG/snell_backend_port" ]]
)

test_release_version_is_rendered_in_header() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"

    local output
    output=$(TERM=dumb _header 2>&1)
    [[ "$output" == *"v3.5.14"* ]]
)

test_validate_mixed_config_with_supplied_real_mihomo() (
    if [[ ! -x "$REAL_MIHOMO_BIN" ]]; then
        printf '%s\n' "real Mihomo binary is not executable: $REAL_MIHOMO_BIN" >&2
        return 1
    fi

    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_mixed_mihomo_db
    generate_mihomo_config "$DB_FILE" "$TEST_TMP/mihomo.yaml"

    validate_mihomo_config "$TEST_TMP/mihomo.yaml" "$REAL_MIHOMO_BIN"
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

write_legacy_migration_db() {
    jq -n '{
      version:"4.0.0", singbox:{}, meta:{}, mihomo:{},
      xray:{
        snell:{port:41001,psk:"v4-key",version:4},
        "snell-v5":[{port:51001,psk:"v5-key",version:5}],
        "snell-shadowtls":{port:42001,psk:"v4-stls",version:4,sni:"www.microsoft.com",stls_password:"v4-secret",snell_backend_port:42002},
        "snell-v5-shadowtls":[{port:52001,psk:"v5-stls",version:5,sni:"www.cloudflare.com",stls_password:"v5-secret",snell_backend_port:52002}],
        "ss2022-shadowtls":{port:62001,password:"ss-key"},
        "snell-v6":{port:61001,psk:"v6-key",version:6}
      }
    }' >"$DB_FILE"
}

test_mihomo_migration_candidate_normalizes_legacy_records() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_legacy_migration_db

    local candidate="$TEST_TMP/candidate.json"
    _build_mihomo_migration_db "$DB_FILE" "$candidate" || return 1
    jq -e '
      (.mihomo.snell | length) == 2 and
      (.mihomo["snell-v5"] | length) == 1 and
      (.mihomo["snell-shadowtls"][0] | .port == 42001 and .psk == "v4-stls" and .version == 4 and .sni == "www.microsoft.com" and .stls_password == "v4-secret" and has("snell_backend_port") | not) and
      (.mihomo["snell-v5-shadowtls"][0] | .port == 52001 and .psk == "v5-stls" and .version == 5 and .sni == "www.cloudflare.com" and .stls_password == "v5-secret" and has("snell_backend_port") | not) and
      (.xray | has("snell") | not and has("snell-v5") | not and has("snell-shadowtls") | not and has("snell-v5-shadowtls") | not) and
      .xray["ss2022-shadowtls"].port == 62001 and .xray["snell-v6"].port == 61001
    ' "$candidate" >/dev/null
    cmp -s "$DB_FILE" <(jq '.' "$DB_FILE") || return 1
)

test_mihomo_migration_candidate_rejects_conflicts_and_deduplicates_match() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_legacy_migration_db
    jq '.mihomo.snell = [{port:41001,psk:"v4-key",version:4}]' "$DB_FILE" >"$TEST_TMP/db.next"
    mv "$TEST_TMP/db.next" "$DB_FILE"
    _build_mihomo_migration_db "$DB_FILE" "$TEST_TMP/match.json" || return 1
    [[ "$(jq '.mihomo.snell | length' "$TEST_TMP/match.json")" == 1 ]] || return 1

    jq '.mihomo.snell = [{port:41001,psk:"different",version:4}]' "$DB_FILE" >"$TEST_TMP/db.next"
    mv "$TEST_TMP/db.next" "$DB_FILE"
    ! _build_mihomo_migration_db "$DB_FILE" "$TEST_TMP/conflict.json" || return 1

    write_legacy_migration_db
    jq '.mihomo["snell-v5"] = [{port:41001,psk:"other",version:5}]' "$DB_FILE" >"$TEST_TMP/db.next"
    mv "$TEST_TMP/db.next" "$DB_FILE"
    ! _build_mihomo_migration_db "$DB_FILE" "$TEST_TMP/port-conflict.json"
)

prepare_migration_runtime_fixture() {
    source "$SCRIPT"
    # Migration fixtures must not race the host /proc while testing rollback state.
    new_mihomo_migration_proc_fixture
    write_legacy_migration_db
    printf '%s\n' '{"old":true}' >"$MIHOMO_CONFIG"
    MIG_RUNNING=([vless-snell]=true [vless-snell-v5]=false [vless-snell-shadowtls]=true [vless-snell-shadowtls-backend]=false [vless-snell-v5-shadowtls]=false [vless-snell-v5-shadowtls-backend]=false [vless-mihomo]=false)
    MIG_ENABLED=([vless-snell]=true [vless-snell-v5]=true [vless-snell-shadowtls]=true [vless-snell-shadowtls-backend]=false [vless-snell-v5-shadowtls]=false [vless-snell-v5-shadowtls-backend]=false [vless-mihomo]=false)
    MIG_FAIL_START=false
    MIG_FAIL_STOP_SERVICE=""
    MIG_FAIL_STOP_MIHOMO=false
    MIG_STOP_MISSING_FAIL=false
    MIG_STATUS_ERROR=false
    : >"$TEST_TMP/migration.log"
    install_mihomo() { printf '%s\n' install >>"$TEST_TMP/migration.log"; touch "$MIHOMO_BIN"; chmod 700 "$MIHOMO_BIN"; }
    validate_mihomo_config() { printf '%s\n' validate >>"$TEST_TMP/migration.log"; return 0; }
    create_mihomo_service() { printf '%s\n' create >>"$TEST_TMP/migration.log"; touch "$SYSTEMD_DIR/vless-mihomo.service"; }
    _mihomo_ports_healthy() { printf '%s\n' health >>"$TEST_TMP/migration.log"; return 0; }
    _cleanup_legacy_snell_resources() { printf '%s\n' "$1" >"$TEST_TMP/cleanup-services"; printf '%s\n' cleanup >>"$TEST_TMP/migration.log"; return 0; }
    svc() {
        local action="$1" name="$2"
        printf '%s:%s\n' "$action" "$name" >>"$TEST_TMP/migration.log"
        case "$action" in
            status) [[ "${MIG_RUNNING[$name]:-false}" == true ]] ;;
            enabled) [[ "${MIG_ENABLED[$name]:-false}" == true ]] ;;
            stop)
                [[ "$name" == vless-mihomo && "${MIG_RUNNING[$name]:-false}" != true && "$MIG_STOP_MISSING_FAIL" == true ]] && return 1
                [[ "$name" == "$MIG_FAIL_STOP_SERVICE" ]] && return 1
                [[ "$name" == vless-mihomo && "$MIG_FAIL_STOP_MIHOMO" == true ]] && return 1
                MIG_RUNNING[$name]=false
                ;;
            start) [[ "$name" == vless-mihomo && "$MIG_FAIL_START" == true ]] && return 1; MIG_RUNNING[$name]=true ;;
            restart) MIG_RUNNING[$name]=true ;;
            enable) MIG_ENABLED[$name]=true ;;
            disable) MIG_ENABLED[$name]=false ;;
            *) return 1 ;;
        esac
    }
    systemctl() {
        if [[ "$1" == show ]]; then
            [[ "$MIG_STATUS_ERROR" == true ]] && return 1
            if [[ "${MIG_RUNNING[vless-mihomo]:-false}" == true ]]; then printf '%s\n' active; else printf '%s\n' inactive; fi
        fi
    }
}

test_mihomo_migration_preflight_validation_keeps_legacy_running() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_migration_runtime_fixture
    cp "$MIHOMO_CONFIG" "$TEST_TMP/config.before"
    validate_mihomo_config() { printf '%s\n' validate >>"$TEST_TMP/migration.log"; return 1; }

    ! migrate_legacy_snell_to_mihomo || return 1
    cmp -s "$MIHOMO_CONFIG" "$TEST_TMP/config.before" || return 1
    [[ "${MIG_RUNNING[vless-snell]}" == true && "${MIG_RUNNING[vless-snell-shadowtls]}" == true ]] || return 1
    ! grep -q '^stop:vless-snell' "$TEST_TMP/migration.log"
)

test_mihomo_migration_cutover_orders_cleanup_last_and_is_idempotent() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_migration_runtime_fixture

    migrate_legacy_snell_to_mihomo || return 1
    jq -e '.mihomo.snell[] | select(.port == 41001 and .psk == "v4-key")' "$DB_FILE" >/dev/null || return 1
    jq -e '([.listeners[].port] | sort) == [41001,42001,51001,52001]' "$MIHOMO_CONFIG" >/dev/null || return 1
    [[ -f "$MIHOMO_MIGRATION_MARKER" && "$(stat -c '%a' "$MIHOMO_MIGRATION_MARKER")" == 600 ]] || return 1
    local stop_line start_line cleanup_line before
    stop_line=$(grep -n '^stop:vless-snell$' "$TEST_TMP/migration.log" | cut -d: -f1)
    start_line=$(grep -n '^start:vless-mihomo$' "$TEST_TMP/migration.log" | cut -d: -f1)
    cleanup_line=$(grep -n '^cleanup$' "$TEST_TMP/migration.log" | cut -d: -f1)
    [[ -n "$stop_line" && -n "$start_line" && -n "$cleanup_line" && "$stop_line" -lt "$start_line" && "$start_line" -lt "$cleanup_line" ]] || return 1
    [[ "$(tail -n1 "$TEST_TMP/migration.log")" == cleanup ]] || return 1
    grep -qx vless-snell "$TEST_TMP/cleanup-services" || return 1
    before=$(cksum "$DB_FILE" "$MIHOMO_CONFIG" "$TEST_TMP/migration.log")
    migrate_legacy_snell_to_mihomo || return 1
    [[ "$(cksum "$DB_FILE" "$MIHOMO_CONFIG" "$TEST_TMP/migration.log")" == "$before" ]]
)

test_mihomo_migration_start_failure_restores_files_and_prior_services() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_migration_runtime_fixture
    cp "$DB_FILE" "$TEST_TMP/db.before"
    cp "$MIHOMO_CONFIG" "$TEST_TMP/config.before"
    MIG_FAIL_START=true

    ! migrate_legacy_snell_to_mihomo || return 1
    cmp -s "$DB_FILE" "$TEST_TMP/db.before" || return 1
    cmp -s "$MIHOMO_CONFIG" "$TEST_TMP/config.before" || return 1
    [[ "${MIG_RUNNING[vless-snell]}" == true && "${MIG_RUNNING[vless-snell-shadowtls]}" == true ]] || return 1
    [[ "${MIG_RUNNING[vless-snell-v5]}" == false && "${MIG_RUNNING[vless-snell-shadowtls-backend]}" == false ]] || return 1
    [[ ! -e "$MIHOMO_MIGRATION_MARKER" ]]
)

test_mihomo_migration_cleanup_failure_restores_before_marker() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_migration_runtime_fixture
    cp "$DB_FILE" "$TEST_TMP/db.before"
    cp "$MIHOMO_CONFIG" "$TEST_TMP/config.before"
    _cleanup_legacy_snell_resources() { printf '%s\n' cleanup-failed >>"$TEST_TMP/migration.log"; return 1; }

    ! migrate_legacy_snell_to_mihomo || return 1
    cmp -s "$DB_FILE" "$TEST_TMP/db.before" || return 1
    cmp -s "$MIHOMO_CONFIG" "$TEST_TMP/config.before" || return 1
    [[ "${MIG_RUNNING[vless-snell]}" == true && ! -e "$MIHOMO_MIGRATION_MARKER" ]]
)

test_mihomo_migration_rollback_before_mihomo_exists_restores_legacy_state() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_migration_runtime_fixture
    cp "$DB_FILE" "$TEST_TMP/db.before"
    cp "$MIHOMO_CONFIG" "$TEST_TMP/config.before"
    MIG_RUNNING[vless-snell-v5]=true
    MIG_FAIL_STOP_SERVICE=vless-snell-v5
    MIG_STOP_MISSING_FAIL=true

    ! migrate_legacy_snell_to_mihomo || return 1
    cmp -s "$DB_FILE" "$TEST_TMP/db.before" || return 1
    cmp -s "$MIHOMO_CONFIG" "$TEST_TMP/config.before" || return 1
    [[ "${MIG_RUNNING[vless-snell]}" == true && "${MIG_ENABLED[vless-snell]}" == true ]] || return 1
    [[ "${MIG_RUNNING[vless-snell-v5]}" == true && "${MIG_ENABLED[vless-snell-v5]}" == true ]]
)

test_mihomo_migration_preflight_failure_removes_new_binary() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_migration_runtime_fixture
    [[ ! -e "$MIHOMO_BIN" ]] || return 1
    validate_mihomo_config() { return 1; }

    ! migrate_legacy_snell_to_mihomo || return 1
    [[ ! -e "$MIHOMO_BIN" ]]
)

test_mihomo_migration_preflight_failure_restores_existing_binary() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_migration_runtime_fixture
    printf '%s\n' original-mihomo >"$MIHOMO_BIN"
    chmod 711 "$MIHOMO_BIN"
    cp "$MIHOMO_BIN" "$TEST_TMP/mihomo.before"
    install_mihomo() { printf '%s\n' replacement-mihomo >"$MIHOMO_BIN"; chmod 700 "$MIHOMO_BIN"; }
    validate_mihomo_config() { return 1; }

    ! migrate_legacy_snell_to_mihomo || return 1
    cmp -s "$MIHOMO_BIN" "$TEST_TMP/mihomo.before" || return 1
    [[ "$(stat -c '%a' "$MIHOMO_BIN")" == 711 ]]
)

new_mihomo_migration_proc_fixture() {
    export VLESS_TEST_PROC_ROOT="$TEST_TMP/proc"
    MIHOMO_MIGRATION_PROC_ROOT="$VLESS_TEST_PROC_ROOT"
    mkdir -p "$MIHOMO_MIGRATION_PROC_ROOT"
}

write_mihomo_migration_proc_comm() {
    local pid="$1" comm="$2"
    mkdir -p "$MIHOMO_MIGRATION_PROC_ROOT/$pid"
    printf '%s\n' "$comm" >"$MIHOMO_MIGRATION_PROC_ROOT/$pid/comm"
}

assert_mihomo_migration_process_scan_error() {
    if _mihomo_migration_managed_process_running; then
        return 1
    else
        [[ "$?" -eq 2 ]]
    fi
}

test_mihomo_migration_systemd_inactive_never_scans_processes() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    new_mihomo_migration_proc_fixture
    write_mihomo_migration_proc_comm 101 vless-mihomo
    DISTRO=debian
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    systemctl() { [[ "$1" == show ]] && printf '%s\n' inactive; }

    [[ "$(_mihomo_migration_service_state)" == inactive ]] || return 1
    _mihomo_migration_managed_process_running
)

test_mihomo_migration_manager_unavailable_scans_exact_active_process() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    new_mihomo_migration_proc_fixture
    write_mihomo_migration_proc_comm 101 vless-mihomo
    DISTRO=debian
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    systemctl() { return 127; }

    [[ "$(_mihomo_migration_service_state)" == active ]]
)

test_mihomo_migration_manager_unavailable_complete_process_scan_is_inactive() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    new_mihomo_migration_proc_fixture
    write_mihomo_migration_proc_comm 101 unrelated-process
    write_mihomo_migration_proc_comm 202 another-process
    DISTRO=debian
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    systemctl() { return 127; }

    [[ "$(_mihomo_migration_service_state)" == inactive ]]
)

test_mihomo_migration_process_scan_permission_entry_is_error() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    new_mihomo_migration_proc_fixture
    write_mihomo_migration_proc_comm 101 unrelated-process
    chmod 000 "$MIHOMO_MIGRATION_PROC_ROOT/101/comm"

    assert_mihomo_migration_process_scan_error
)

test_mihomo_migration_process_scan_vanished_entry_is_error() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    new_mihomo_migration_proc_fixture
    mkdir -p "$MIHOMO_MIGRATION_PROC_ROOT/101"

    assert_mihomo_migration_process_scan_error
)

# A first-line-only reader would incorrectly report this as active.
test_mihomo_migration_process_scan_requires_full_comm_content() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    new_mihomo_migration_proc_fixture
    mkdir -p "$MIHOMO_MIGRATION_PROC_ROOT/101"
    printf 'vless-mihomo\nx\n' >"$MIHOMO_MIGRATION_PROC_ROOT/101/comm"

    if _mihomo_migration_managed_process_running; then
        return 1
    else
        [[ "$?" -eq 1 ]]
    fi
)

test_mihomo_migration_process_scan_rejects_pid_directory_symlink() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    new_mihomo_migration_proc_fixture
    mkdir -p "$MIHOMO_MIGRATION_PROC_ROOT/target"
    printf 'unrelated\n' >"$MIHOMO_MIGRATION_PROC_ROOT/target/comm"
    ln -s target "$MIHOMO_MIGRATION_PROC_ROOT/101"

    assert_mihomo_migration_process_scan_error
)

test_mihomo_migration_process_scan_rejects_comm_symlink() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    new_mihomo_migration_proc_fixture
    mkdir -p "$MIHOMO_MIGRATION_PROC_ROOT/101"
    printf 'unrelated\n' >"$MIHOMO_MIGRATION_PROC_ROOT/comm-target"
    ln -s ../comm-target "$MIHOMO_MIGRATION_PROC_ROOT/101/comm"

    assert_mihomo_migration_process_scan_error
)

test_mihomo_migration_process_scan_ignores_numeric_prefix_non_pid_entry() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    new_mihomo_migration_proc_fixture
    mkdir -p "$MIHOMO_MIGRATION_PROC_ROOT/101-not-a-pid"

    if _mihomo_migration_managed_process_running; then
        return 1
    else
        [[ "$?" -eq 1 ]]
    fi
)

test_mihomo_migration_process_scan_empty_root_is_inactive() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    new_mihomo_migration_proc_fixture

    if _mihomo_migration_managed_process_running; then
        return 1
    else
        [[ "$?" -eq 1 ]]
    fi
)

test_mihomo_migration_process_scan_detects_pid_replacement() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    new_mihomo_migration_proc_fixture
    write_mihomo_migration_proc_comm 101 unrelated
    write_mihomo_migration_proc_comm 202 vless-mihomo
    _mihomo_migration_test_proc_observe() {
        [[ "$1" == pid-validated ]] || return 0
        mv "$MIHOMO_MIGRATION_PROC_ROOT/101" "$MIHOMO_MIGRATION_PROC_ROOT/101.old"
        mv "$MIHOMO_MIGRATION_PROC_ROOT/202" "$MIHOMO_MIGRATION_PROC_ROOT/101"
    }

    assert_mihomo_migration_process_scan_error
)

test_mihomo_migration_process_scan_detects_comm_replacement() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    new_mihomo_migration_proc_fixture
    write_mihomo_migration_proc_comm 101 unrelated
    printf 'vless-mihomo\n' >"$MIHOMO_MIGRATION_PROC_ROOT/comm.replacement"
    _mihomo_migration_test_proc_observe() {
        [[ "$1" == comm-read ]] || return 0
        mv "$MIHOMO_MIGRATION_PROC_ROOT/comm.replacement" "$MIHOMO_MIGRATION_PROC_ROOT/101/comm"
    }

    assert_mihomo_migration_process_scan_error
)

test_mihomo_migration_uncertain_process_scan_retains_rollback_snapshot() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_migration_runtime_fixture
    new_mihomo_migration_proc_fixture
    mkdir -p "$MIHOMO_MIGRATION_PROC_ROOT/101"
    DISTRO=alpine
    touch "$OPENRC_DIR/vless-mihomo"
    rc-service() { [[ "$2" == status ]] && return 127; }
    MIG_FAIL_STOP_SERVICE=vless-snell

    ! migrate_legacy_snell_to_mihomo || return 1
    local snapshot
    snapshot=$(find "$CFG" -maxdepth 1 -type d -name '.mihomo-migration.*' -print -quit)
    [[ -n "$snapshot" && -f "$snapshot/services" ]]
)

test_mihomo_migration_service_state_distinguishes_systemd_states() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    DISTRO=debian
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    _pgrep() { return 1; }
    systemctl() {
        [[ "$1" == show ]] || return 1
        printf '%s\n' "${MIG_SYSTEMD_STATE:-inactive}"
    }

    MIG_SYSTEMD_STATE=inactive
    [[ "$(_mihomo_migration_service_state)" == inactive ]] || return 1
    MIG_SYSTEMD_STATE=active
    [[ "$(_mihomo_migration_service_state)" == active ]] || return 1
    systemctl() { return 1; }
    [[ "$(_mihomo_migration_service_state)" == error ]]
)

test_mihomo_migration_service_state_uses_openrc_exit_contract() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    DISTRO=alpine
    touch "$OPENRC_DIR/vless-mihomo"
    _mihomo_migration_managed_process_running() { return 1; }
    rc-service() {
        [[ "$2" == status ]] || return 1
        case "${MIG_OPENRC_STATUS_RC:-3}" in
            0) printf '%s\n' running; return 0 ;;
            3) printf '%s\n' stopped; return 3 ;;
            1) printf '%s\n' 'stopped: manager transport failure'; return 1 ;;
        esac
    }

    MIG_OPENRC_STATUS_RC=0
    [[ "$(_mihomo_migration_service_state)" == active ]] || return 1
    MIG_OPENRC_STATUS_RC=3
    [[ "$(_mihomo_migration_service_state)" == inactive ]] || return 1
    MIG_OPENRC_STATUS_RC=1
    [[ "$(_mihomo_migration_service_state)" == error ]]
)

test_mihomo_migration_exact_process_helper_is_nounset_safe() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    unset SVC_PROC
    declare -A SVC_PROC
    _mihomo_migration_managed_process_running || true
)

test_mihomo_migration_openrc_unavailable_uses_exact_managed_process_only() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    DISTRO=alpine
    touch "$OPENRC_DIR/vless-mihomo"
    rc-service() { [[ "$2" == status ]] && return 127; }
    _mihomo_migration_managed_process_running() { return 0; }
    [[ "$(_mihomo_migration_service_state)" == active ]] || return 1

    _mihomo_migration_managed_process_running() { return 1; }
    _pgrep() { touch "$TEST_TMP/ambiguous-pgrep-called"; return 0; }
    [[ "$(_mihomo_migration_service_state)" == inactive ]] || return 1
    [[ ! -e "$TEST_TMP/ambiguous-pgrep-called" ]]
)

test_mihomo_migration_status_error_retains_snapshot() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_migration_runtime_fixture
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    MIG_STATUS_ERROR=true
    MIG_FAIL_STOP_SERVICE=vless-snell

    ! migrate_legacy_snell_to_mihomo || return 1
    ! grep -q '^stop:vless-mihomo$' "$TEST_TMP/migration.log" || return 1
    local snapshot
    snapshot=$(find "$CFG" -maxdepth 1 -type d -name '.mihomo-migration.*' -print -quit)
    [[ -n "$snapshot" && -f "$snapshot/services" ]]
)

test_mihomo_migration_rollback_propagates_running_mihomo_stop_failure() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_migration_runtime_fixture
    MIG_RUNNING[vless-mihomo]=true
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    MIG_FAIL_STOP_MIHOMO=true
    MIG_FAIL_STOP_SERVICE=vless-snell

    ! migrate_legacy_snell_to_mihomo || return 1
    local snapshot
    snapshot=$(find "$CFG" -maxdepth 1 -type d -name '.mihomo-migration.*' -print -quit)
    [[ -n "$snapshot" && -f "$snapshot/resource-0.path" && -f "$snapshot/services" ]]
)

test_external_shadowtls_detection_checks_ss2022_and_service_references() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    init_db
    jq '.xray["ss2022-shadowtls"] = {port:62001}' "$DB_FILE" >"$TEST_TMP/db.next"
    mv "$TEST_TMP/db.next" "$DB_FILE"
    _external_shadowtls_is_needed || return 1
    jq 'del(.xray["ss2022-shadowtls"])' "$DB_FILE" >"$TEST_TMP/db.next"
    mv "$TEST_TMP/db.next" "$DB_FILE"
    printf '%s\n' 'ExecStart=/usr/local/bin/shadow-tls --v3 server' >"$SYSTEMD_DIR/external-shadowtls.service"
    _external_shadowtls_is_needed
)

test_install_shadowtls_marks_managed_binary_ownership() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    _map_arch() { printf '%s\n' x86_64-unknown-linux-musl; }
    _install_binary() { touch "$TEST_TMP/shadowtls-installed"; }

    install_shadowtls || return 1
    [[ -f "$CFG/.shadowtls-managed" && "$(stat -c '%a' "$CFG/.shadowtls-managed")" == 600 && -f "$TEST_TMP/shadowtls-installed" ]]
)

test_mihomo_migration_cleanup_preserves_ss2022_v6_and_unmanaged_shadowtls() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_legacy_migration_db
    printf '%s\n' '/usr/local/bin/shadow-tls' >"$TEST_TMP/unit"
    cp "$TEST_TMP/unit" "$SYSTEMD_DIR/other.service"
    rm() { printf '%s\n' "$*" >>"$TEST_TMP/remove.log"; }
    svc() { printf '%s:%s\n' "$1" "$2" >>"$TEST_TMP/service.log"; return 0; }
    systemctl() { :; }

    _external_shadowtls_is_needed || return 1
    _cleanup_legacy_snell_resources || return 1
    ! grep -q 'snell-v6\|ss2022-shadowtls\|/usr/local/bin/shadow-tls' "$TEST_TMP/remove.log" || return 1
    grep -q '/usr/local/bin/snell-server-v5' "$TEST_TMP/remove.log"
)

# Task 7: all consumers must see a compact record stream regardless of whether
# old records are scalar objects or new records are arrays.
test_mihomo_normalized_display_and_subscription_rendering() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    CYAN= YELLOW= GREEN= RED= G= Y= C= D= W= NC=
    write_single_mihomo_record snell '{"port":41001,"psk":"scalar-v4","version":4}'
    [[ "$(db_protocol_configs mihomo snell)" == '{"port":41001,"psk":"scalar-v4","version":4}' ]] || return 1
    write_mixed_mihomo_db
    get_connection_addresses() { printf '%s\n' '203.0.113.9|'; }
    get_ip_country() { printf '%s\n' US; }
    get_all_external_links() { :; }
    _line() { :; }

    [[ "$(db_protocol_configs mihomo snell | wc -l)" -eq 2 ]] || return 1
    [[ "$(db_protocol_configs mihomo snell-v5 | wc -l)" -eq 1 ]] || return 1

    local surge links single
    surge=$(gen_surge_sub)
    grep -Fq 'US-Snell-41001 = snell, 203.0.113.9, 41001, psk=v4-one, version=4' <<<"$surge" || return 1
    grep -Fq 'US-Snell-41002 = snell, 203.0.113.9, 41002, psk=v4-two, version=4' <<<"$surge" || return 1
    grep -Fq 'US-Snell-v5-51001 = snell, 203.0.113.9, 51001, psk=v5-one, version=5' <<<"$surge" || return 1
    grep -Fq 'shadow-tls-password=stls-secret, shadow-tls-sni=www.microsoft.com, shadow-tls-version=3' <<<"$surge" || return 1

    links=$(show_all_share_links)
    grep -Fq '41001' <<<"$links" || return 1
    grep -Fq '41002' <<<"$links" || return 1
    grep -Fq 'shadow-tls-password=stls-secret, shadow-tls-sni=www.microsoft.com, shadow-tls-version=3' <<<"$links" || return 1

    single=$(show_single_protocol_info snell false <<<'2')
    grep -Fq '端口:' <<<"$single" || return 1
    grep -Fq '41002' <<<"$single"
)

# The interactive removal path must use the shared Mihomo transaction, rather
# than treating a Mihomo node as a legacy standalone Snell service.
test_mihomo_protocol_uninstall_is_per_port_and_stops_final_node() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    CYAN= YELLOW= GREEN= RED= G= Y= C= D= W= NC=
    LOG_FILE="$TEST_TMP/vless-server.log"
    write_mixed_mihomo_db
    generate_mihomo_config
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    TEST_SERVICE_RUNNING=true
    TEST_SERVICE_ENABLED=true
    _pause() { :; }

    uninstall_specific_protocol <<<'1
1
y' >/dev/null || return 1
    jq -e '(.mihomo.snell | length) == 1 and .mihomo.snell[0].port == 41002 and .mihomo["snell-v5"][0].port == 51001' "$DB_FILE" >/dev/null || return 1
    [[ "$TEST_SERVICE_RUNNING" == true ]] || return 1
    grep -q '^restart:vless-mihomo$' "$TEST_TMP/svc.log" || return 1

)

test_mihomo_protocol_uninstall_stops_final_node() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    CYAN= YELLOW= GREEN= RED= G= Y= C= D= W= NC=
    LOG_FILE="$TEST_TMP/vless-server.log"
    _apply_mihomo_node_change snell add all '{"port":41001,"psk":"v4-one","version":4}' || return 1
    : >"$TEST_TMP/svc.log"
    _pause() { :; }

    uninstall_specific_protocol <<<'1
y' >/dev/null || return 1
    jq -e '.mihomo == {}' "$DB_FILE" >/dev/null || return 1
    [[ "$TEST_SERVICE_RUNNING" == false && "$TEST_SERVICE_ENABLED" == false ]] || return 1
    [[ ! -e "$MIHOMO_CONFIG" && ! -e "$SYSTEMD_DIR/vless-mihomo.service" ]]
)

write_legacy_snell_display_db() {
    jq -n '{
      version:"4.0.0", singbox:{}, meta:{}, mihomo:{},
      xray:{
        snell:[{port:41001,psk:"legacy-v4-one",version:4},{port:41002,psk:"legacy-v4-two",version:4}],
        "snell-v5":{port:51001,psk:"legacy-v5",version:5},
        "snell-shadowtls":{port:42001,psk:"legacy-stls",version:4,sni:"www.microsoft.com",stls_password:"legacy-secret"},
        vless:{port:443,uuid:"unrelated"},
        "snell-v6":{port:61001,psk:"v6",version:6},
        "ss2022-shadowtls":{port:62001,password:"ss"}
      }
    }' >"$DB_FILE"
}

# Legacy records remain renderable while a migration is pending or has failed.
test_legacy_xray_snell_rendering_normalizes_scalar_and_arrays() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    CYAN= YELLOW= GREEN= RED= G= Y= C= D= W= NC=
    write_legacy_snell_display_db
    get_connection_addresses() { printf '%s\n' '203.0.113.9|'; }
    get_ip_country() { printf '%s\n' US; }
    get_all_external_links() { :; }
    _line() { :; }

    [[ "$(db_protocol_configs xray snell | wc -l)" -eq 2 ]] || return 1
    [[ "$(db_protocol_configs xray snell-v5)" == '{"port":51001,"psk":"legacy-v5","version":5}' ]] || return 1
    local info links surge
    info=$(show_all_protocols_info <<<'0')
    grep -Fq 'Snell 旧版服务' <<<"$info" || return 1
    grep -Fq '41001,41002' <<<"$info" || return 1
    links=$(show_all_share_links)
    grep -Fq '41001' <<<"$links" || return 1
    grep -Fq '51001' <<<"$links" || return 1
    grep -Fq 'shadow-tls-password=legacy-secret, shadow-tls-sni=www.microsoft.com, shadow-tls-version=3' <<<"$links" || return 1
    surge=$(gen_surge_sub)
    grep -Fq 'US-Snell-41001 = snell, 203.0.113.9, 41001, psk=legacy-v4-one, version=4' <<<"$surge" || return 1
    grep -Fq 'US-Snell-v5-51001 = snell, 203.0.113.9, 51001, psk=legacy-v5, version=5' <<<"$surge"
)

# A completed Mihomo copy wins explicitly, so a stale exact legacy copy cannot
# render twice or shadow the active namespace in subscriptions.
test_mihomo_storage_resolution_prefers_migrated_record() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    write_legacy_snell_display_db
    jq '.mihomo.snell = [{port:41001,psk:"legacy-v4-one",version:4}]' "$DB_FILE" >"$TEST_TMP/db.next"
    mv "$TEST_TMP/db.next" "$DB_FILE"
    get_connection_addresses() { printf '%s\n' '203.0.113.9|'; }
    get_ip_country() { printf '%s\n' US; }
    get_all_external_links() { :; }

    [[ "$(protocol_subscription_db_core snell)" == mihomo ]] || return 1
    local surge
    surge=$(gen_surge_sub)
    [[ "$(grep -c 'US-Snell-41001 = snell' <<<"$surge")" -eq 1 ]]
)

prepare_legacy_snell_uninstall_fixture() {
    source "$SCRIPT"
    CYAN= YELLOW= GREEN= RED= G= Y= C= D= W= NC=
    LOG_FILE="$TEST_TMP/vless-server.log"
    write_legacy_snell_display_db
    touch "$SYSTEMD_DIR/vless-snell.service" "$CFG/snell.conf"
    svc() { printf '%s:%s\n' "$1" "$2" >>"$TEST_TMP/svc.log"; }
    systemctl() { printf 'systemctl:%s\n' "$*" >>"$TEST_TMP/systemctl.log"; }
    _pause() { :; }
}

# Removing one legacy array entry must leave its frontend and all unrelated
# records intact; all removal cleans only the selected legacy protocol.
test_legacy_xray_snell_per_port_and_all_uninstall() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_legacy_snell_uninstall_fixture

    uninstall_specific_protocol <<<'1
1
y' >/dev/null || return 1
    jq -e '(.xray.snell | length) == 1 and .xray.snell[0].port == 41002 and .xray["snell-v5"].port == 51001 and .xray.vless.port == 443 and .xray["snell-v6"].port == 61001 and .xray["ss2022-shadowtls"].port == 62001' "$DB_FILE" >/dev/null || return 1
    [[ -f "$SYSTEMD_DIR/vless-snell.service" && -f "$CFG/snell.conf" ]] || return 1
    [[ ! -f "$TEST_TMP/svc.log" ]] || ! grep -Eq '^(stop|disable):vless-snell$' "$TEST_TMP/svc.log" || return 1

    uninstall_specific_protocol <<<'1
y' >/dev/null || return 1
    jq -e 'has("xray") and (.xray | has("snell") | not) and .xray["snell-v5"].port == 51001 and .xray.vless.port == 443' "$DB_FILE" >/dev/null || return 1
    [[ ! -e "$SYSTEMD_DIR/vless-snell.service" && ! -e "$CFG/snell.conf" ]] || return 1
    grep -q '^stop:vless-snell$' "$TEST_TMP/svc.log" || return 1
    grep -q '^disable:vless-snell$' "$TEST_TMP/svc.log" || return 1
    ! grep -q 'vless-snell-v5\|vless-snell-v6\|ss2022-shadowtls' "$TEST_TMP/svc.log"
)

test_legacy_xray_snell_all_uninstall_targets_only_selected_protocol() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_legacy_snell_uninstall_fixture

    uninstall_specific_protocol <<<'1
3
y' >/dev/null || return 1
    jq -e '(.xray | has("snell") | not) and .xray["snell-v5"].port == 51001 and .xray.vless.port == 443 and .xray["snell-v6"].port == 61001 and .xray["ss2022-shadowtls"].port == 62001' "$DB_FILE" >/dev/null || return 1
    grep -q '^stop:vless-snell$' "$TEST_TMP/svc.log" || return 1
    ! grep -q 'vless-snell-v5\|vless-snell-v6\|ss2022-shadowtls' "$TEST_TMP/svc.log"
)

write_mixed_namespace_snell_db() {
    jq -n '{
      version:"4.0.0", singbox:{}, meta:{},
      xray:{snell:[{port:41001,psk:"legacy-only",version:4},{port:41002,psk:"legacy-overlap",version:4}]},
      mihomo:{snell:[{port:42001,psk:"active-only",version:4},{port:41002,psk:"active-overlap",version:4}]}
    }' >"$DB_FILE"
}

prepare_mixed_namespace_snell_uninstall_fixture() {
    prepare_mihomo_transaction_fixture
    CYAN= YELLOW= GREEN= RED= G= Y= C= D= W= NC=
    LOG_FILE="$TEST_TMP/vless-server.log"
    write_mixed_namespace_snell_db
    generate_mihomo_config
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    TEST_SERVICE_RUNNING=true
    TEST_SERVICE_ENABLED=true
    _pause() { :; }
}

# The selected menu port must come from the same active Mihomo namespace that
# the subsequent transaction mutates, never from a stale legacy counterpart.
test_mixed_namespace_uninstall_selects_and_removes_active_mihomo_port() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mixed_namespace_snell_uninstall_fixture

    local selection
    select_port_to_uninstall snell >"$TEST_TMP/selection" <<<'1' || return 1
    selection=$(<"$TEST_TMP/selection")
    [[ "$SELECTED_PORT" == 42001 ]] || return 1
    grep -Fq '42001' <<<"$selection" || return 1
    ! grep -Fq '41001' <<<"$selection" || return 1

    uninstall_specific_protocol <<<'1
1
y' >/dev/null || return 1
    jq -e '(.mihomo.snell | length) == 1 and .mihomo.snell[0].port == 41002 and (.xray.snell | length) == 2 and .xray.snell[0].port == 41001 and .xray.snell[1].port == 41002' "$DB_FILE" >/dev/null || return 1
    jq -e '([.listeners[].port] | sort) == [41002]' "$MIHOMO_CONFIG" >/dev/null || return 1
    grep -q '^restart:vless-mihomo$' "$TEST_TMP/svc.log"
)

# `all` is likewise derived from the active list and may never delete the
# stale .xray counterpart that migration/cleanup still owns.
test_mixed_namespace_uninstall_all_targets_active_mihomo_only() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mixed_namespace_snell_uninstall_fixture

    local selection
    select_port_to_uninstall snell >"$TEST_TMP/selection" <<<'3' || return 1
    selection=$(<"$TEST_TMP/selection")
    [[ "$SELECTED_PORT" == all ]] || return 1
    grep -Fq '42001' <<<"$selection" || return 1
    ! grep -Fq '41001' <<<"$selection" || return 1

    uninstall_specific_protocol <<<'1
3
y' >/dev/null || return 1
    jq -e '(.mihomo | has("snell") | not) and (.xray.snell | length) == 2 and .xray.snell[0].port == 41001 and .xray.snell[1].port == 41002' "$DB_FILE" >/dev/null || return 1
    [[ "$TEST_SERVICE_RUNNING" == false && "$TEST_SERVICE_ENABLED" == false ]] || return 1
    [[ ! -e "$MIHOMO_CONFIG" && ! -e "$SYSTEMD_DIR/vless-mihomo.service" ]]
)

# Full cleanup only touches managed Mihomo resources under the fixture paths.
test_force_cleanup_removes_managed_mihomo_resources() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    DISTRO=debian
    mkdir -p "$VERSION_CACHE_DIR" "$TEST_TMP/backups"
    touch "$MIHOMO_BIN" "$MIHOMO_CONFIG" "$MIHOMO_MIGRATION_MARKER" \
        "$SYSTEMD_DIR/vless-mihomo.service" "$VERSION_CACHE_DIR/MetaCubeX_mihomo" \
        "$VERSION_CACHE_DIR/MetaCubeX_mihomo_prerelease" "$TEST_TMP/backups/vless-mihomo_1.19.28_test"
    _get_core_backup_dir() { printf '%s\n' "$TEST_TMP/backups"; }
    svc() { printf '%s:%s\n' "$1" "$2" >>"$TEST_TMP/svc.log"; }
    systemctl() { :; }
    cleanup_hy2_nat_rules() { :; }

    force_cleanup
    [[ ! -e "$MIHOMO_BIN" && ! -e "$MIHOMO_CONFIG" && ! -e "$MIHOMO_MIGRATION_MARKER" ]] || return 1
    [[ ! -e "$SYSTEMD_DIR/vless-mihomo.service" ]] || return 1
    [[ ! -e "$VERSION_CACHE_DIR/MetaCubeX_mihomo" && ! -e "$TEST_TMP/backups/vless-mihomo_1.19.28_test" ]] || return 1
    grep -q '^disable:vless-mihomo$' "$TEST_TMP/svc.log"
)

test_direct_execution_pins_log_paths_but_sourcing_allows_fixtures() (
    new_fixture
    trap cleanup_fixture EXIT
    source "$SCRIPT"
    [[ "$MIHOMO_LOG_FILE" == "$VLESS_TEST_MIHOMO_LOG_FILE" && "$SYSTEM_MESSAGES_LOG" == "$VLESS_TEST_MESSAGES_LOG" ]] || return 1

    local trace
    trace=$(VLESS_TEST_MIHOMO_LOG_FILE="$TEST_TMP/redirected.log" \
        VLESS_TEST_MESSAGES_LOG="$TEST_TMP/redirected.messages" \
        bash -x "$SCRIPT" --help 2>&1) || return 1
    [[ "$trace" == *"MIHOMO_LOG_FILE=/var/log/vless/mihomo.log"* &&
       "$trace" == *"SYSTEM_MESSAGES_LOG=/var/log/messages"* ]] || return 1
    [[ "$trace" != *"MIHOMO_LOG_FILE=$TEST_TMP/redirected.log"* &&
       "$trace" != *"SYSTEM_MESSAGES_LOG=$TEST_TMP/redirected.messages"* ]]
)

prepare_mihomo_update_fixture() {
    source "$SCRIPT"
    init_db
    jq '.mihomo = {snell:[{port:41001,psk:"v4-one",version:4}]}' "$DB_FILE" >"$TEST_TMP/db" && mv "$TEST_TMP/db" "$DB_FILE"
    printf '%s\n' '{"listeners":[{"port":41001}]}' >"$MIHOMO_CONFIG"
    printf '%s\n' old-mihomo >"$MIHOMO_BIN"
    chmod 711 "$MIHOMO_BIN"
    UPDATE_RUNNING=true
    UPDATE_MANAGER_STATE=active
    UPDATE_MANAGER_ERROR_AFTER=0
    UPDATE_MANAGER_ERROR_AT=""
    UPDATE_FAIL=""
    DISTRO=debian
    touch "$SYSTEMD_DIR/vless-mihomo.service"
    : >"$TEST_TMP/update-status-count"
    : >"$TEST_TMP/update-manager-count"
    : >"$TEST_TMP/update-svc.log"
    _check_core_update_deps() { return 0; }
    _confirm_core_update_version() { return 0; }
    _get_core_backup_dir() { mkdir -p "$TEST_TMP/backups"; printf '%s\n' "$TEST_TMP/backups"; }
    _show_changelog_summary() { :; }
    LOG_FILE="$TEST_TMP/vless-server.log";
    systemctl() {
        [[ "$1" == show ]] || return 1
        local count=0
        [[ -s "$TEST_TMP/update-manager-count" ]] && count=$(<"$TEST_TMP/update-manager-count")
        count=$((count + 1))
        printf '%s\n' "$count" >"$TEST_TMP/update-manager-count"
        if [[ "$UPDATE_MANAGER_ERROR_AFTER" -gt 0 && "$count" -ge "$UPDATE_MANAGER_ERROR_AFTER" ]] ||
           [[ " $UPDATE_MANAGER_ERROR_AT " == *" $count "* ]]; then
            return 1
        fi
        case "$UPDATE_MANAGER_STATE" in
            active|inactive) printf '%s\n' "$UPDATE_MANAGER_STATE" ;;
            error) return 1 ;;
            *) return 1 ;;
        esac
    }
    svc() {
        printf '%s\n' "$1" >>"$TEST_TMP/update-svc.log"
        case "$1" in
            status)
                local count=0
                [[ -f "$TEST_TMP/update-status-count" ]] && count=$(<"$TEST_TMP/update-status-count")
                count=$((count + 1))
                printf '%s\n' "$count" >"$TEST_TMP/update-status-count"
                [[ "$UPDATE_RUNNING" == true && "$UPDATE_FAIL" != status ]]
                ;;
            restart) [[ "$UPDATE_FAIL" != restart ]] || return 1; UPDATE_RUNNING=true; UPDATE_MANAGER_STATE=active ;;
            start) [[ "$UPDATE_FAIL" != start ]] || return 1; UPDATE_RUNNING=true; UPDATE_MANAGER_STATE=active ;;
            stop) UPDATE_RUNNING=false; UPDATE_MANAGER_STATE=inactive ;;
            *) return 1 ;;
        esac
    }
    install_update_mihomo() {
        touch "$TEST_TMP/update-install-called"
        printf '%s\n' new-mihomo >"$MIHOMO_BIN"
        chmod 755 "$MIHOMO_BIN"
    }
    validate_mihomo_config() { [[ "$UPDATE_FAIL" != validation ]]; }
    _mihomo_ports_healthy() {
        touch "$TEST_TMP/update-ports-checked"
        [[ "$UPDATE_FAIL" != ports ]]
    }
}

test_mihomo_update_service_state_distinguishes_active_inactive_and_error() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_update_fixture

    UPDATE_MANAGER_STATE=active
    [[ "$(_mihomo_service_state)" == active ]] || return 1
    UPDATE_MANAGER_STATE=inactive
    [[ "$(_mihomo_service_state)" == inactive ]] || return 1
    UPDATE_MANAGER_STATE=error
    [[ "$(_mihomo_service_state)" == error ]]
)

test_mihomo_update_service_state_uses_openrc_exit_contract() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_update_fixture
    DISTRO=alpine
    rm -f "$SYSTEMD_DIR/vless-mihomo.service"
    touch "$OPENRC_DIR/vless-mihomo"
    _mihomo_migration_managed_process_running() { touch "$TEST_TMP/update-proc-fallback-called"; return 0; }
    rc-service() {
        [[ "$1" == vless-mihomo && "$2" == status ]] || return 1
        return "$UPDATE_OPENRC_STATUS_RC"
    }

    UPDATE_OPENRC_STATUS_RC=0
    [[ "$(_mihomo_service_state)" == active ]] || return 1
    UPDATE_OPENRC_STATUS_RC=3
    [[ "$(_mihomo_service_state)" == inactive ]] || return 1
    UPDATE_OPENRC_STATUS_RC=1
    [[ "$(_mihomo_service_state)" == error ]] || return 1
    [[ ! -e "$TEST_TMP/update-proc-fallback-called" ]]
)

test_mihomo_update_status_query_error_aborts_before_mutation() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_update_fixture
    cp -p "$MIHOMO_BIN" "$TEST_TMP/binary.before"
    cp -p "$MIHOMO_CONFIG" "$TEST_TMP/config.before"
    cp -p "$DB_FILE" "$TEST_TMP/db.before"
    UPDATE_MANAGER_STATE=error

    ! _update_core_to_version Mihomo stable 1.19.29 vless-mihomo install_update_mihomo || return 1
    cmp -s "$MIHOMO_BIN" "$TEST_TMP/binary.before" || return 1
    cmp -s "$MIHOMO_CONFIG" "$TEST_TMP/config.before" || return 1
    cmp -s "$DB_FILE" "$TEST_TMP/db.before" || return 1
    [[ "$(stat -c '%a' "$MIHOMO_BIN")" == 711 && "$UPDATE_RUNNING" == true ]] || return 1
    [[ ! -e "$TEST_TMP/update-install-called" && ! -s "$TEST_TMP/update-svc.log" ]] || return 1
    ! compgen -G "$CFG/.mihomo-update.*" >/dev/null
)

test_mihomo_update_post_restart_authoritative_error_rolls_back_and_retains_snapshot() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_update_fixture
    UPDATE_MANAGER_ERROR_AT="2 4"

    ! _update_core_to_version Mihomo stable 1.19.29 vless-mihomo install_update_mihomo || return 1
    [[ "$(<"$MIHOMO_BIN")" == old-mihomo && "$(stat -c '%a' "$MIHOMO_BIN")" == 711 ]] || return 1
    [[ "$UPDATE_RUNNING" == true && "$(grep -c '^restart$' "$TEST_TMP/update-svc.log")" -eq 2 ]] || return 1
    [[ ! -e "$TEST_TMP/update-ports-checked" ]] || return 1
    compgen -G "$CFG/.mihomo-update.*" >/dev/null
)

test_mihomo_update_inactive_validation_rollback_does_not_mutate_service() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_update_fixture
    UPDATE_RUNNING=false
    UPDATE_MANAGER_STATE=inactive
    UPDATE_FAIL=validation

    ! _update_core_to_version Mihomo stable 1.19.29 vless-mihomo install_update_mihomo || return 1
    [[ "$(<"$MIHOMO_BIN")" == old-mihomo && "$UPDATE_RUNNING" == false ]] || return 1
    ! grep -Eq '^(start|restart|stop)$' "$TEST_TMP/update-svc.log"
)

test_mihomo_update_rollback_state_confirmation_error_retains_snapshot() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_update_fixture
    UPDATE_FAIL=ports
    UPDATE_MANAGER_ERROR_AFTER=2

    ! _update_core_to_version Mihomo stable 1.19.29 vless-mihomo install_update_mihomo || return 1
    [[ "$(<"$MIHOMO_BIN")" == old-mihomo && "$UPDATE_RUNNING" == true ]] || return 1
    compgen -G "$CFG/.mihomo-update.*" >/dev/null
)

test_mihomo_update_rolls_back_validation_failure() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_update_fixture
    UPDATE_FAIL=validation
    ! _update_core_to_version Mihomo stable 1.19.29 vless-mihomo install_update_mihomo || return 1
    [[ "$(<"$MIHOMO_BIN")" == old-mihomo && "$(stat -c '%a' "$MIHOMO_BIN")" == 711 && "$UPDATE_RUNNING" == true ]]
)

test_mihomo_update_rolls_back_startup_and_status_failures() (
    local mode
    for mode in restart status; do
        (   new_fixture
            trap cleanup_fixture EXIT
            prepare_mihomo_update_fixture
            UPDATE_FAIL="$mode"
            ! _update_core_to_version Mihomo stable 1.19.29 vless-mihomo install_update_mihomo || exit 1
            [[ "$(<"$MIHOMO_BIN")" == old-mihomo && "$UPDATE_RUNNING" == true ]]
        ) || return 1
    done
)

test_mihomo_update_rolls_back_missing_listener() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_update_fixture
    UPDATE_FAIL=ports
    ! _update_core_to_version Mihomo stable 1.19.29 vless-mihomo install_update_mihomo || return 1
    [[ "$(<"$MIHOMO_BIN")" == old-mihomo && "$UPDATE_RUNNING" == true ]]
)

test_mihomo_update_running_success_and_no_node_install() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_update_fixture
    _update_core_to_version Mihomo stable 1.19.29 vless-mihomo install_update_mihomo || return 1
    [[ "$(<"$MIHOMO_BIN")" == new-mihomo && "$UPDATE_RUNNING" == true ]] || return 1
    grep -qx restart "$TEST_TMP/update-svc.log" || return 1

    UPDATE_RUNNING=false
    UPDATE_MANAGER_STATE=inactive
    : >"$TEST_TMP/update-svc.log"
    _update_core_to_version Mihomo stable 1.19.30 vless-mihomo install_update_mihomo || return 1
    [[ "$(<"$MIHOMO_BIN")" == new-mihomo ]] || return 1
    ! grep -Eq '^(start|restart|stop)$' "$TEST_TMP/update-svc.log" || return 1

    jq '.mihomo = {}' "$DB_FILE" >"$TEST_TMP/db" && mv "$TEST_TMP/db" "$DB_FILE"
    : >"$TEST_TMP/update-svc.log"
    _update_core_to_version Mihomo stable 1.19.31 vless-mihomo install_update_mihomo || return 1
    [[ "$(<"$MIHOMO_BIN")" == new-mihomo ]] &&
        ! grep -Eq '^(start|restart|stop)$' "$TEST_TMP/update-svc.log"
)

test_mihomo_join_files_regenerate_current_transactional_state() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_mihomo_transaction_fixture
    get_connection_addresses() { printf '%s\n' '203.0.113.9|'; }
    get_ip_suffix() { :; }
    printf '%s\n' unrelated >"$CFG/vless.join"
    _apply_mihomo_node_change snell add all '{"port":41001,"psk":"v4-one","version":4}' || return 1
    _apply_mihomo_node_change snell add all '{"port":41002,"psk":"v4-two","version":4}' || return 1
    _apply_mihomo_node_change snell-v5 add all '{"port":51001,"psk":"v5-one","version":5}' || return 1
    _apply_mihomo_node_change snell-shadowtls add all '{"port":42001,"psk":"stls-one","version":4,"sni":"www.example.com","stls_password":"stls-secret"}' || return 1
    grep -Fq '41001' "$CFG/snell.join" && grep -Fq 'v4-one' "$CFG/snell.join" || return 1
    grep -Fq '41002' "$CFG/snell.join" && grep -Fq 'v4-two' "$CFG/snell.join" || return 1
    grep -Fq '51001' "$CFG/snell-v5.join" && grep -Fq 'v5-one' "$CFG/snell-v5.join" || return 1
    grep -Fq '42001' "$CFG/snell-shadowtls.join" && grep -Fq 'stls-secret' "$CFG/snell-shadowtls.join" && grep -Fq 'www.example.com' "$CFG/snell-shadowtls.join" || return 1
    grep -Fq unrelated "$CFG/join.txt" && grep -Fq 41002 "$CFG/join.txt" || return 1

    _apply_mihomo_node_change snell replace 41001 '{"port":41001,"psk":"v4-replaced","version":4}' || return 1
    grep -Fq v4-replaced "$CFG/snell.join" && ! grep -Fq v4-one "$CFG/snell.join" || return 1
    _apply_mihomo_node_change snell remove 41002 '{}' || return 1
    ! grep -Fq 41002 "$CFG/snell.join" && ! grep -Fq 41002 "$CFG/join.txt" || return 1
    _apply_mihomo_node_change snell remove all '{}' || return 1
    [[ ! -e "$CFG/snell.join" && -f "$CFG/join.txt" ]] || return 1
    grep -Fq unrelated "$CFG/join.txt" && ! grep -Fq 41001 "$CFG/join.txt" || return 1
    _apply_mihomo_node_change snell-v5 remove all '{}' || return 1
    _apply_mihomo_node_change snell-shadowtls remove all '{}' || return 1
    [[ ! -e "$CFG/snell-v5.join" && ! -e "$CFG/snell-shadowtls.join" ]] || return 1
    [[ "$(<"$CFG/join.txt")" == unrelated && -f "$CFG/vless.join" ]]
)

test_mihomo_migration_process_read_failure_is_error_and_retains_snapshot() (
    new_fixture
    trap cleanup_fixture EXIT
    prepare_migration_runtime_fixture
    new_mihomo_migration_proc_fixture
    write_mihomo_migration_proc_comm 101 unrelated
    DISTRO=alpine
    touch "$OPENRC_DIR/vless-mihomo"
    rc-service() { [[ "$2" == status ]] && return 127; }
    _mihomo_migration_test_proc_observe() {
        [[ "$1" == comm-read-opening ]] || return 0
        mv "$MIHOMO_MIGRATION_PROC_ROOT/101/comm" "$MIHOMO_MIGRATION_PROC_ROOT/101/comm.gone"
    }
    # Fail after preflight so the process read happens while rollback decides whether
    # it can safely stop Mihomo; uncertainty must retain the migration snapshot.
    MIG_FAIL_STOP_SERVICE=vless-snell
    ! migrate_legacy_snell_to_mihomo || return 1
    assert_mihomo_migration_process_scan_error || return 1
    local snapshot
    snapshot=$(find "$CFG" -maxdepth 1 -type d -name '.mihomo-migration.*' -print -quit)
    [[ -n "$snapshot" && -f "$snapshot/services" ]]
)

run_test test_source_does_not_run_cli
run_test test_direct_execution_pins_log_paths_but_sourcing_allows_fixtures
run_test test_mihomo_update_service_state_distinguishes_active_inactive_and_error
run_test test_mihomo_update_service_state_uses_openrc_exit_contract
run_test test_mihomo_update_status_query_error_aborts_before_mutation
run_test test_mihomo_update_post_restart_authoritative_error_rolls_back_and_retains_snapshot
run_test test_mihomo_update_inactive_validation_rollback_does_not_mutate_service
run_test test_mihomo_update_rollback_state_confirmation_error_retains_snapshot
run_test test_mihomo_update_rolls_back_validation_failure
run_test test_mihomo_update_rolls_back_startup_and_status_failures
run_test test_mihomo_update_rolls_back_missing_listener
run_test test_mihomo_update_running_success_and_no_node_install
run_test test_mihomo_join_files_regenerate_current_transactional_state
run_test test_mihomo_migration_process_read_failure_is_error_and_retains_snapshot
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
run_test test_official_snell_v4_v5_install_update_entrypoints_are_unreachable
run_test test_core_update_helper_rejects_official_snell_v5
run_test test_mihomo_runtime_metadata_has_no_external_snell_v4_v5_execution
run_test test_install_mihomo_rejects_unsupported_version_before_download
run_test test_install_mihomo_requires_publisher_verification
run_test test_install_mihomo_uses_verified_official_asset
run_test test_init_db_has_mihomo_namespace
run_test test_init_db_upgrades_legacy_namespaces
run_test test_protocol_core_classification
run_test test_legacy_mihomo_records_use_xray_namespace
run_test test_mihomo_list_ports_prints_every_listener_port
run_test test_mihomo_runtime_metadata_maps_shared_service
run_test test_mihomo_openrc_status_falls_back_to_shared_process
run_test test_watchdog_has_one_validated_mihomo_entry
run_test test_watchdog_discovers_only_legacy_xray_snell_services
run_test test_watchdog_routes_mihomo_records_only_to_shared_service
run_test test_service_log_menu_routes_legacy_xray_shadowtls_to_old_frontend
run_test test_mihomo_ports_healthy_requires_every_listener
run_test test_create_mihomo_systemd_service_definition
run_test test_create_mihomo_systemd_service_fails_when_unit_write_fails
run_test test_create_mihomo_openrc_service_definition
run_test test_start_services_runs_one_shared_mihomo_core
run_test test_start_services_ignores_legacy_xray_snell_when_mihomo_namespace_empty
run_test test_start_services_does_not_start_mihomo_without_service_definition
run_test test_mihomo_runtime_consistency_repairs_invalid_or_unhealthy_runtime
run_test test_mihomo_runtime_consistency_stops_if_service_definition_fails
run_test test_mihomo_runtime_consistency_ignores_empty_namespace
run_test test_mihomo_lifecycle_cleanup_stops_shared_service_once
run_test test_set_mihomo_log_level_commits_complete_config
run_test test_set_mihomo_log_level_rolls_back_database_and_config
run_test test_set_mihomo_log_level_rolls_back_on_validation_failure
run_test test_set_mihomo_log_level_retains_snapshot_when_restore_fails
run_test test_mihomo_systemd_lifecycle_stops_shared_service_once
run_test test_mihomo_selinux_restore_includes_managed_binary
run_test test_mihomo_status_reports_partial_anomaly_and_missing_ports
run_test test_mihomo_service_and_protocol_presentations
run_test test_service_log_menu_dispatches_one_shared_mihomo_item
run_test test_mihomo_diagnostics_menu_and_systemd_logs
run_test test_mihomo_diagnostics_actions_validate_and_change_log_level
run_test test_mihomo_alpine_logs_use_dedicated_file_then_messages_fallback
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
run_test test_mihomo_transaction_adds_multiple_protocol_port_records
run_test test_mihomo_transaction_replaces_only_selected_port
run_test test_mihomo_transaction_removes_only_selected_port
run_test test_mihomo_transaction_removes_final_node_and_shared_service
run_test test_mihomo_transaction_validation_failure_restores_exact_bytes
run_test test_mihomo_transaction_restart_failure_restores_and_restarts_previous_state
run_test test_mihomo_transaction_enables_existing_disabled_service
run_test test_mihomo_transaction_restores_prior_disabled_state_on_rollback
run_test test_mihomo_transaction_retains_snapshot_when_file_restore_fails
run_test test_mihomo_transaction_retains_snapshot_when_service_restore_fails
run_test test_mihomo_transaction_rejects_cross_protocol_duplicate_before_service_mutation
run_test test_snell_generators_store_only_transactional_mihomo_records
run_test test_release_version_is_rendered_in_header
if [[ "$REAL_MIHOMO_BIN_SUPPLIED" == false ]]; then
    skip_test test_validate_mixed_config_with_supplied_real_mihomo "real Mihomo binary not supplied"
else
    run_test test_validate_mixed_config_with_supplied_real_mihomo
fi
run_test test_validate_mihomo_config_checks_json_and_binary_arguments
run_test test_mihomo_migration_candidate_normalizes_legacy_records
run_test test_mihomo_migration_candidate_rejects_conflicts_and_deduplicates_match
run_test test_mihomo_migration_preflight_validation_keeps_legacy_running
run_test test_mihomo_migration_cutover_orders_cleanup_last_and_is_idempotent
run_test test_mihomo_migration_start_failure_restores_files_and_prior_services
run_test test_mihomo_migration_cleanup_failure_restores_before_marker
run_test test_mihomo_migration_rollback_before_mihomo_exists_restores_legacy_state
run_test test_mihomo_migration_preflight_failure_removes_new_binary
run_test test_mihomo_migration_preflight_failure_restores_existing_binary
run_test test_mihomo_migration_systemd_inactive_never_scans_processes
run_test test_mihomo_migration_manager_unavailable_scans_exact_active_process
run_test test_mihomo_migration_manager_unavailable_complete_process_scan_is_inactive
run_test test_mihomo_migration_process_scan_permission_entry_is_error
run_test test_mihomo_migration_process_scan_vanished_entry_is_error
run_test test_mihomo_migration_process_scan_requires_full_comm_content
run_test test_mihomo_migration_process_scan_rejects_pid_directory_symlink
run_test test_mihomo_migration_process_scan_rejects_comm_symlink
run_test test_mihomo_migration_process_scan_ignores_numeric_prefix_non_pid_entry
run_test test_mihomo_migration_process_scan_empty_root_is_inactive
run_test test_mihomo_migration_process_scan_detects_pid_replacement
run_test test_mihomo_migration_process_scan_detects_comm_replacement
run_test test_mihomo_migration_uncertain_process_scan_retains_rollback_snapshot
run_test test_mihomo_migration_service_state_distinguishes_systemd_states
run_test test_mihomo_migration_service_state_uses_openrc_exit_contract
run_test test_mihomo_migration_exact_process_helper_is_nounset_safe
run_test test_mihomo_migration_openrc_unavailable_uses_exact_managed_process_only
run_test test_mihomo_migration_status_error_retains_snapshot
run_test test_mihomo_migration_rollback_propagates_running_mihomo_stop_failure
run_test test_external_shadowtls_detection_checks_ss2022_and_service_references
run_test test_install_shadowtls_marks_managed_binary_ownership
run_test test_mihomo_migration_cleanup_preserves_ss2022_v6_and_unmanaged_shadowtls
run_test test_mihomo_normalized_display_and_subscription_rendering
run_test test_mihomo_protocol_uninstall_is_per_port_and_stops_final_node
run_test test_mihomo_protocol_uninstall_stops_final_node
run_test test_legacy_xray_snell_rendering_normalizes_scalar_and_arrays
run_test test_mihomo_storage_resolution_prefers_migrated_record
run_test test_legacy_xray_snell_per_port_and_all_uninstall
run_test test_legacy_xray_snell_all_uninstall_targets_only_selected_protocol
run_test test_mixed_namespace_uninstall_selects_and_removes_active_mihomo_port
run_test test_mixed_namespace_uninstall_all_targets_active_mihomo_only
run_test test_force_cleanup_removes_managed_mihomo_resources
printf '%s tests passed, %s skipped\n' "$PASS" "$SKIP"
