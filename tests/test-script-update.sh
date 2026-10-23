#!/usr/bin/env bash
# All update/download targets are temporary fixtures; no network or system writes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VLESS_TEST_CFG="$TMP/etc"
export VLESS_TEST_SYSTEMD_DIR="$TMP/systemd"
export VLESS_TEST_OPENRC_DIR="$TMP/openrc"
mkdir -p "$VLESS_TEST_CFG" "$VLESS_TEST_SYSTEMD_DIR" "$VLESS_TEST_OPENRC_DIR"
source "$ROOT/vless-server.sh"
_header() { :; }; _line() { :; }; _item() { :; }
_info() { :; }; _ok() { :; }; _warn() { :; }; _err() { :; }
[[ "$(_script_update_ref stable)" == main ]]
[[ "$(_script_update_ref dev)" == dev ]]
if _script_update_ref unknown; then exit 1; fi
select_script_update_channel <<<2
[[ "$SELECTED_SCRIPT_UPDATE_CHANNEL" == dev ]]
select_script_update_channel <<<''
[[ "$SELECTED_SCRIPT_UPDATE_CHANNEL" == stable ]]

curl() {
    local output='' url=''
    while (($#)); do
        case "$1" in
            -o) output="$2"; shift 2 ;;
            --connect-timeout|--max-time) shift 2 ;;
            -sL) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    printf '%s\n' '#!/bin/bash' 'readonly VERSION="3.5.16"' >"$output"
    printf '%s\n' "$url" >"$TMP/fetch-url"
    printf '%s\n' "$output" >"$TMP/staged-path"
}
_verify_github_blob() { printf '%s|%s|%s\n' "$1" "$2" "$3" >"$TMP/blob"; }
download=$(_fetch_script_tmp 5 10 dev)
[[ "$(<"$TMP/fetch-url")" == 'https://raw.githubusercontent.com/mikuuu3981/surge/dev/vless-server.sh' ]]
[[ "$(<"$TMP/blob")" == 'mikuuu3981/surge|dev|vless-server.sh' ]]
rm "$download"
(
    _verify_github_blob() { return 1; }
    if _fetch_script_tmp 5 10 dev; then exit 1; fi
    [[ ! -e "$(<"$TMP/staged-path")" ]]
)
(
    curl() {
        local output=''
        while (($#)); do
            case "$1" in -o) output="$2"; shift 2 ;; *) shift ;; esac
        done
        printf '%s\n' '#!/bin/bash' 'if then' >"$output"
        printf '%s\n' "$output" >"$TMP/staged-path"
    }
    if _fetch_script_tmp 5 10 dev 2>/dev/null; then exit 1; fi
    [[ ! -e "$(<"$TMP/staged-path")" ]]
)
printf '%s\n' 'ok - update channels, verified dev downloads and invalid download cleanup'

current="$TMP/current.sh" remote="$TMP/remote.sh" system="$TMP/system.sh"
reset_scripts() {
    printf '%s\n' '#!/bin/bash' 'readonly VERSION="3.5.16"' 'echo stable' >"$current"
    printf '%s\n' '#!/bin/bash' 'readonly VERSION="3.5.16"' 'echo dev' >"$remote"
    cp "$current" "$system"
    chmod 711 "$current"
    chmod 755 "$remote" "$system"
    rm -f "${current}.bak"
}
_current_script_path() { printf '%s\n' "$current"; }
_system_script_path() { printf '%s\n' "$system"; }
_fetch_script_tmp() {
    printf '%s\n' "${3:-}" >"$TMP/update-ref"
    cp "$remote" "$TMP/staged.sh"
    printf '%s\n' "$TMP/staged.sh"
}
reset_scripts
_script_update_is_available dev "$current" "$remote" 3.5.16
if _script_update_is_available stable "$current" "$remote" 3.5.16; then exit 1; fi
(
    cp "$remote" "$current"
    if _script_update_is_available dev "$current" "$remote" 3.5.16; then exit 1; fi
)
reset_scripts
_update_script_from_channel dev <<<'' >/dev/null
grep -qx 'echo dev' "$current"
grep -qx 'echo dev' "$system"
grep -qx 'echo stable' "${current}.bak"
reset_scripts
_get_latest_script_version() { printf '%s\n' "$3" >"$TMP/version-ref"; printf '%s\n' "${VERSION}.1"; }
printf '%s\n' '#!/bin/bash' "readonly VERSION=\"${VERSION}.1\"" 'echo newer' >"$remote"
_update_script_from_channel stable <<<'' >/dev/null
[[ "$(<"$TMP/version-ref")" == main && "$(<"$TMP/update-ref")" == main ]]
grep -qx 'echo newer' "$current"
printf '%s\n' 'ok - dev detects same-version changes and stable updates use main'

reset_scripts
(
    cp() { [[ "${!#}" != "$system" ]] && command cp "$@"; }
    mv() { [[ "${!#}" != "$system" ]] && command mv "$@"; }
    if _update_script_from_channel dev <<<'' >/dev/null; then exit 1; fi
    grep -qx 'echo stable' "$current"
    grep -qx 'echo stable' "$system"
    grep -qx 'echo stable' "${current}.bak"
    [[ "$(stat -c %a "$current")" == 711 ]]
)
reset_scripts
if _update_script_from_channel dev </dev/null >/dev/null; then exit 1; fi
grep -qx 'echo stable' "$current"
[[ ! -e "${current}.bak" ]]
(
    check_root() { :; }; init_log() { :; }
    do_update() { printf '%s\n' "$1" >"$TMP/cli-channel"; }
    (dispatch_cli --update-dev)
    [[ "$(<"$TMP/cli-channel")" == dev ]]
)
(
    _update_script_from_channel() { return 1; }
    if (do_update dev); then exit 1; fi
)
printf '%s\n' 'ok - failed updates roll back content/permissions and CLI propagates channel/failure'
