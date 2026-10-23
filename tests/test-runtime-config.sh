#!/usr/bin/env bash
# Temporary proc fixtures only; every service operation is forbidden.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VLESS_TEST_CFG="$TMP/default config"
mkdir -p "$VLESS_TEST_CFG" "$TMP/proc/123" "$TMP/work dir/parts"
source "$ROOT/vless-server.sh"
DISTRO=debian
# Exercise the real PID query helper against a read-only systemctl stub.
systemctl() {
    [[ "$*" == 'show vless-reality --property=MainPID --value' ]] || exit 89
    printf '%s\n' "${MOCK_MAIN_PID:-123}"
}
[[ "$(_runtime_config_service_pid vless-reality)" == 123 ]]
MOCK_MAIN_PID=0
[[ "$(_runtime_config_service_pid vless-reality)" == 0 ]]
MOCK_MAIN_PID=invalid
if _runtime_config_service_pid vless-reality; then exit 1; fi
svc() { echo 'unexpected service operation' >&2; exit 90; }
systemctl() { echo 'unexpected systemctl operation' >&2; exit 91; }
rc-service() { echo 'unexpected OpenRC operation' >&2; exit 92; }
log() { echo 'unexpected logging' >&2; exit 93; }
gen_xray_config() { exit 94; }
gen_singbox_config() { exit 95; }
_runtime_config_proc_root() { printf '%s\n' "$TMP/proc"; }
PID=123
_runtime_config_service_pid() { printf '%s\n' "$PID"; }
ln -s /usr/local/bin/xray "$TMP/proc/123/exe"
ln -s "$TMP/work dir" "$TMP/proc/123/cwd"
printf 'default xray secret\n' >"$CFG/config.json"
printf 'default singbox secret\n' >"$CFG/singbox.json"
long="$TMP/work dir/full config.json"
for ((n=0; n<6000; n++)); do printf 'secret-%06d  keep every byte \\ "\n' "$n"; done >"$long"
printf 'NO-TRAILING-NEWLINE' >>"$long"
printf 'second-file-secret\n' >"$TMP/work dir/second.json"
printf 'part-a-secret\n' >"$TMP/work dir/parts/a.json"
printf 'part-b-secret\n' >"$TMP/work dir/parts/b.json"
printf 'hidden-secret\n' >"$TMP/work dir/parts/.hidden.json"
cmdline() { printf '%s\0' xray run "$@" >"$TMP/proc/123/cmdline"; }
contains() { grep -Fq -- "$1" "$TMP/output"; }
reject() {
    if show_runtime_config "$1" >"$TMP/output"; then
        printf 'expected failure: %s\n' "$2" >&2; exit 1
    fi
    contains "$2"
    if contains 'default xray secret'; then exit 1; fi
}

# Every supported file flag, including equals form, preserves a space in a path.
for flag in -c -config --config; do
    cmdline "$flag" "$long"
    show_runtime_config xray >"$TMP/output"
    python3 - "$long" "$TMP/output" <<'PY'
import pathlib, sys
original, output = (pathlib.Path(p).read_bytes() for p in sys.argv[1:])
assert original in output, 'full original bytes must appear without truncation or masking'
PY
    cmdline "$flag=$long"
    show_runtime_config xray >"$TMP/output"
    contains 'NO-TRAILING-NEWLINE'
done

# Repeated file arguments plus directory arguments display every source.
for flag in -C --config-directory -confdir; do
    for form in separate equals; do
        args=(--config 'full config.json' -c=second.json)
        if [[ "$form" == separate ]]; then args+=("$flag" parts); else args+=("$flag=parts"); fi
        cmdline "${args[@]}"
        show_runtime_config xray >"$TMP/output"
        for text in NO-TRAILING-NEWLINE second-file-secret part-a-secret part-b-secret hidden-secret; do contains "$text"; done
    done
done

# Sing-box uses its own service and managed executable, with the same parser.
ln -sf /usr/local/bin/sing-box "$TMP/proc/123/exe"
_runtime_config_service_pid() { [[ "$1" == vless-singbox ]]; printf '%s\n' "$PID"; }
cmdline --config "$long" -C=parts
show_runtime_config singbox >"$TMP/output"
contains part-b-secret
_runtime_config_service_pid() { printf '%s\n' "$PID"; }
reject xray '不是本脚本管理的'
ln -sf /tmp/unmanaged/xray "$TMP/proc/123/exe"
reject xray '不是本脚本管理的'
ln -sf /usr/local/bin/xray "$TMP/proc/123/exe"

cmdline -c "$TMP/missing.json"
reject xray '无法读取配置文件'
cmdline -C "$TMP/missing directory"
reject xray '无法读取配置目录'
cmdline -config
reject xray '缺少路径'
cmdline --config=
reject xray '缺少路径'
cmdline
reject xray '未指定配置文件'
rm "$TMP/proc/123/cmdline"
reject xray '无法读取进程'

# A non-root child verifies true permission denial even when tests run as root.
cmdline -c "$long"
chmod 755 "$TMP" "$TMP/proc" "$TMP/proc/123" "$TMP/work dir"
chmod 000 "$long"
python3 - "$ROOT/vless-server.sh" "$TMP" <<'PY'
import os, pathlib, pwd, subprocess, sys
script, fixture = sys.argv[1:]
if os.geteuid() == 0:
    user = pwd.getpwnam('nobody')
    os.setgroups([])
    os.setgid(user.pw_gid)
    os.setuid(user.pw_uid)
code = '''source "$1"
_runtime_config_service_pid() { printf '123\\n'; }
root="$2"
_runtime_config_proc_root() { printf '%s/proc\\n' "$root"; }
show_runtime_config xray
'''
result = subprocess.run(['bash', '-c', code, 'test', script, fixture], capture_output=True)
assert result.returncode != 0, 'unreadable file unexpectedly succeeded'
assert '无法读取配置文件'.encode() in result.stdout, result.stderr
assert b'secret-000000' not in result.stdout
PY

PID=0
show_runtime_config xray >"$TMP/output"
contains '未运行'
contains 'default xray secret'
show_runtime_config singbox >"$TMP/output"
contains 'default singbox secret'
PID=999
show_runtime_config xray >"$TMP/output"
contains '未运行'
_runtime_config_service_pid() { return 1; }
reject xray '无法确定'
printf '%s\n' 'ok - complete runtime configs, NUL arguments, directories, stopped services and rejected processes'
