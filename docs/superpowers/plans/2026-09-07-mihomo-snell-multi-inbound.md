# Mihomo Snell Multi-Inbound Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Surge's official Snell v4/v5 server processes with one managed Mihomo process that serves multiple independently credentialed Snell and Snell+ShadowTLS listeners while retaining the official Snell v6 server.

**Architecture:** Add a fourth database/core namespace, `.mihomo`, and generate one complete Mihomo config from all Snell v4/v5 records. Treat database mutation, config generation, validation, service restart, and health checks as a transaction; add a one-time transactional migration from legacy `.xray` Snell records. Reuse the repository's core-version, systemd/OpenRC, status, Watchdog, display, subscription, and cleanup patterns without merging Mihomo into Sing-box.

**Tech Stack:** Bash 4.1+, jq, curl, gzip, GitHub Releases API, Mihomo v1.19.28+, systemd/OpenRC, `ss`.

**Spec:** `docs/superpowers/specs/2026-09-07-mihomo-snell-multi-inbound-design.md`

## File structure

- Modify `vless-server.sh`: all production behavior remains in the owning script, following the repository's script-centric structure.
- Create `tests/test-mihomo-snell.sh`: non-root fixture tests for database classification, config generation, version selection, transaction rollback, migration, status helpers, and subscription rendering.
- Modify `README.md`: document Mihomo-backed multi-port Snell v4/v5, built-in ShadowTLS, v6's official core, migration, and core management.

## Global constraints

- Mihomo Snell requires v1.19.28 or newer; v1.19.28 prereleases and every older version are rejected.
- Snell v4/v5 and their ShadowTLS variants use only `/usr/local/bin/vless-mihomo`; only Snell v6 uses Surge's official server.
- Each listener has its own numeric port and PSK. Do not collapse nodes into Mihomo port ranges.
- ShadowTLS is Mihomo's built-in v3 implementation with an independent password and `SNI:443` handshake target.
- SS2022+ShadowTLS remains on the external `shadow-tls` binary and Xray backend.
- Preserve Bash 4.1 compatibility, four-space indentation, quoted expansions, `[[ ... ]]`, `local` variables, `umask 077`, Chinese UI text, and Alpine/systemd behavior.
- Every Mihomo download requires publisher SHA-256 verification; `ALLOW_UNVERIFIED_DOWNLOADS` must not bypass Mihomo verification.
- Leave Snell v6 config, version channels, links, and services unchanged.
- Never run install, migration, firewall, uninstall, or service mutation tests on a production host.

---

### Task 1: Add a sourceable test seam and Mihomo database namespace

**Files:**
- Create: `tests/test-mihomo-snell.sh`
- Modify: `vless-server.sh:44-59, 153-181, 275-445, 3717-3784, 29323-29550`

**Interfaces:**
- Add `protocol_core <protocol>` → prints `xray`, `singbox`, `mihomo`, or `standalone`.
- Add `get_mihomo_protocols` → prints installed Mihomo protocol keys, one per line.
- When sourced for tests only, make paths overridable through `VLESS_TEST_CFG` and `VLESS_TEST_MIHOMO_BIN`; direct production execution always uses fixed system paths.
- Add `dispatch_cli "$@"`; sourcing the script defines functions but does not enter `main_menu`.

- [ ] **Step 1: Write the initial failing shell tests**

Create `tests/test-mihomo-snell.sh` with a small test runner and these first cases:

```bash
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

run_test test_source_does_not_run_cli
run_test test_init_db_has_mihomo_namespace
run_test test_init_db_upgrades_legacy_namespaces
run_test test_protocol_core_classification
printf '%s tests passed\n' "$PASS"
```

- [ ] **Step 2: Run the tests and confirm the source seam fails**

Run:

```bash
timeout 5 bash tests/test-mihomo-snell.sh
```

Expected: non-zero because sourcing `vless-server.sh` currently dispatches `main_menu` and because `init_db` has no `.mihomo` object.

- [ ] **Step 3: Make paths source-safe and add the CLI dispatcher**

Change the configuration constants to preserve production paths while allowing temporary tests:

```bash
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    CFG="${VLESS_TEST_CFG:-/etc/vless-reality}"
    MIHOMO_BIN="${VLESS_TEST_MIHOMO_BIN:-/usr/local/bin/vless-mihomo}"
else
    CFG="/etc/vless-reality"
    MIHOMO_BIN="/usr/local/bin/vless-mihomo"
fi
readonly CFG MIHOMO_BIN
readonly MIHOMO_CONFIG="$CFG/mihomo.yaml"
readonly MIHOMO_MIGRATION_MARKER="$CFG/.mihomo-snell-migrated-v1"
```

This prevents root production executions from honoring environment-controlled destination paths.

Wrap the final argument `case` in `dispatch_cli()`, and invoke it only when executed directly:

```bash
dispatch_cli() {
    case "${1:-}" in
        # Preserve every existing branch unchanged.
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    dispatch_cli "$@"
fi
```

The Bash-version guard must also use `return 1` when sourced and `exit 1` when executed, so an unsupported shell cannot terminate a parent test shell unexpectedly.

- [ ] **Step 4: Add core classification and database initialization**

Define:

```bash
MIHOMO_PROTOCOLS="snell snell-v5 snell-shadowtls snell-v5-shadowtls"
STANDALONE_PROTOCOLS="snell-v6 ss2022-shadowtls naive"

protocol_core() {
    local protocol="$1"
    if [[ " $MIHOMO_PROTOCOLS " == *" $protocol "* ]]; then
        echo mihomo
    elif [[ " $SINGBOX_PROTOCOLS " == *" $protocol "* ]]; then
        echo singbox
    elif [[ " $STANDALONE_PROTOCOLS " == *" $protocol "* ]]; then
        echo standalone
    else
        echo xray
    fi
}
```

Initialize new databases with `{xray:{},singbox:{},mihomo:{}}`. When an existing database lacks one of these objects, `init_db` must atomically add the missing empty namespace before returning. Update `register_protocol`, `unregister_protocol`, `is_protocol_installed`, `get_installed_protocols`, `db_get_all_protocols`, and repeated core-selection branches to use `protocol_core`. Implement:

```bash
get_mihomo_protocols() {
    filter_installed "$MIHOMO_PROTOCOLS"
}
```

Extend `check_port_conflict` to iterate `xray`, `singbox`, and `mihomo`, so two Mihomo protocol keys cannot claim the same port.

- [ ] **Step 5: Run the focused and syntax tests**

Run:

```bash
bash tests/test-mihomo-snell.sh
bash -n vless-server.sh
```

Expected: all four tests pass and syntax validation exits zero.

- [ ] **Step 6: Commit the test seam and taxonomy**

```bash
git add vless-server.sh tests/test-mihomo-snell.sh
git commit -m 'Add Mihomo core taxonomy and test seam'
```

---

### Task 2: Generate and validate a complete multi-listener Mihomo config

**Files:**
- Modify: `tests/test-mihomo-snell.sh`
- Modify: `vless-server.sh` near `generate_singbox_config` at current lines 10661-11357

**Interfaces:**
- Add `_validate_mihomo_record <protocol> <json>` → zero only for valid v4/v5 records.
- Add `_build_mihomo_listener <protocol> <json> <listen_addr>` → prints one listener JSON object.
- Add `mihomo_list_ports [db_file]` → prints all Mihomo listener ports, one per line.
- Add `generate_mihomo_config [db_file] [output_file]` → atomically writes JSON-compatible YAML.
- Add `validate_mihomo_config [config_file] [binary]` → invokes `-t -f` after a JSON check.

- [ ] **Step 1: Add failing generator tests**

Append fixture helpers that replace the database with mixed records:

```bash
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
```

Add tests that assert:

```bash
generate_mihomo_config "$DB_FILE" "$TEST_TMP/mihomo.yaml"
jq -e '.listeners | length == 4' "$TEST_TMP/mihomo.yaml" >/dev/null
jq -e '.listeners[] | select(.name == "snell-v4-41002") | .psk == "v4-two" and .version == 4 and .udp == true' "$TEST_TMP/mihomo.yaml" >/dev/null
jq -e '.listeners[] | select(.name == "snell-v5-stls-52001") | .["shadow-tls"].version == 3 and .["shadow-tls"].users[0].password == "stls-secret" and .["shadow-tls"].handshake.dest == "www.microsoft.com:443"' "$TEST_TMP/mihomo.yaml" >/dev/null
```

Add separate rejection cases for duplicate ports across protocol keys, version 6, missing PSK, missing ShadowTLS password, invalid SNI, and a password containing JSON metacharacters.

- [ ] **Step 2: Run the generator tests and confirm they fail**

```bash
bash tests/test-mihomo-snell.sh
```

Expected: non-zero because the allocator/generator functions are missing.

- [ ] **Step 3: Implement record validation and listener construction**

`_validate_mihomo_record` must require:

```text
port: integer 1..65535
psk: non-empty string using the script's safe credential validator
version: exactly 4 for snell/snell-shadowtls, exactly 5 for snell-v5/snell-v5-shadowtls
sni and stls_password: required only for *-shadowtls
```

Construct every listener with `jq -n --arg/--argjson`, never string interpolation. Plain listeners contain `name`, `type: "snell"`, `listen`, `port`, `psk`, `version`, and `udp: true`. ShadowTLS listeners additionally contain:

```json
{
  "shadow-tls": {
    "enable": true,
    "version": 3,
    "users": [{"name": "<listener-name>", "password": "<stls-password>"}],
    "handshake": {"dest": "<sni>:443"}
  }
}
```

- [ ] **Step 4: Implement atomic full-config generation**

Build a base object with the validated value from `.meta.mihomo_log_level // "warning"`:

```json
{
  "mode": "rule",
  "log-level": "warning",
  "ipv6": true,
  "listeners": [],
  "rules": ["MATCH,DIRECT"]
}
```

Only `warning` and `debug` are accepted as managed log levels; an invalid stored value falls back to `warning`.

Normalize each protocol value with `if type == "array" then .[] else . end`, reject duplicate ports before writing, and choose `_listen_addr`. Write through `mktemp "${output}.tmp.XXXXXX"`, apply `chmod 600`, run `jq empty`, then `mv` atomically. Return non-zero without changing the old file when there are no valid records or any record is invalid.

Implement external validation as:

```bash
validate_mihomo_config() {
    local config_file="${1:-$MIHOMO_CONFIG}"
    local binary="${2:-$MIHOMO_BIN}"
    jq empty "$config_file" >/dev/null 2>&1 || return 1
    [[ -x "$binary" ]] || return 1
    "$binary" -t -f "$config_file" >/dev/null 2>&1
}
```

- [ ] **Step 5: Run config tests and inspect permissions**

```bash
bash tests/test-mihomo-snell.sh
stat -c '%a' "$(find /tmp -path '*/mihomo.yaml' -print -quit 2>/dev/null)" 2>/dev/null || true
bash -n vless-server.sh
```

Expected: generator cases pass; the test itself must assert generated mode is `600` rather than relying on the optional `stat` diagnostic.

- [ ] **Step 6: Commit config generation**

```bash
git add vless-server.sh tests/test-mihomo-snell.sh
git commit -m 'Generate Mihomo Snell listener configuration'
```

---

### Task 3: Add verified Mihomo installation and full core-version management

**Files:**
- Modify: `tests/test-mihomo-snell.sh`
- Modify: `vless-server.sh:8065-8998, 9077-10427, 29350-29425`

**Interfaces:**
- Add `MIHOMO_REPO="MetaCubeX/mihomo"` and `MIHOMO_MIN_VERSION="1.19.28"`.
- Add `_get_mihomo_version` → normalized current version or `未安装`/`未知`.
- Add `_is_mihomo_supported_version <version>` → enforces the minimum stable feature set.
- Add `_mihomo_asset_name <uname-machine> <version>` → exact GitHub asset basename.
- Add `install_mihomo [channel] [force] [version]`.
- Add `update_mihomo_core [channel]` and `update_mihomo_core_custom`.

- [ ] **Step 1: Add failing version and asset tests**

Add assertions for:

```bash
_is_mihomo_supported_version 1.19.28
! _is_mihomo_supported_version 1.19.27
! _is_mihomo_supported_version 1.19.28-alpha
_is_mihomo_supported_version 1.19.29-alpha
[[ "$(_mihomo_asset_name x86_64 1.19.28)" == "mihomo-linux-amd64-compatible-v1.19.28.gz" ]]
[[ "$(_mihomo_asset_name aarch64 1.19.28)" == "mihomo-linux-arm64-v1.19.28.gz" ]]
[[ "$(_mihomo_asset_name armv7l 1.19.28)" == "mihomo-linux-armv7-v1.19.28.gz" ]]
! _mihomo_asset_name mips 1.19.28
```

Create a fake executable that prints `Mihomo Meta v1.19.28 linux amd64` and assert `_get_mihomo_version` returns `1.19.28` through `VLESS_TEST_MIHOMO_BIN` while the script is sourced.

- [ ] **Step 2: Run focused tests and confirm missing functions**

```bash
bash tests/test-mihomo-snell.sh
```

Expected: non-zero at the Mihomo version helpers.

- [ ] **Step 3: Implement verified `.gz` installation**

Extend `_install_binary` with a `mihomo` install kind that:

```bash
gzip -dc "$tmp/pkg" >"$tmp/vless-mihomo"
chmod 755 "$tmp/vless-mihomo"
install -m 755 "$tmp/vless-mihomo" "$MIHOMO_BIN"
```

Before download, `install_mihomo` normalizes the chosen version and calls `_is_mihomo_supported_version`. Build the URL from the exact `_mihomo_asset_name` result. Do not honor `ALLOW_UNVERIFIED_DOWNLOADS` for this install kind: `_verify_github_release_asset` failure must remove the temporary directory and return non-zero.

- [ ] **Step 4: Integrate current-version, cache, and update helpers**

Add Mihomo cases to `_get_core_version`, `_get_core_version_with_status`, `_confirm_core_update_version`, `_backup_core_binary`, `_rollback_core_binary`, `_update_core_to_version`, and changelog selection. Ensure backup operations use `$MIHOMO_BIN` rather than assuming `/usr/local/bin/$binary_name` when the logical binary is `vless-mihomo`.

Update `_update_core_versions_async`, `_refresh_core_versions_now`, and main-menu asynchronous warming to fetch stable and prerelease metadata for `MetaCubeX/mihomo` using the existing TTL and unavailable-marker framework.

- [ ] **Step 5: Replace Snell v5 with Mihomo in the core menu**

The version menu heading becomes:

```text
核心版本管理 (Xray/Sing-box/Mihomo/Snell v6)
```

Display current/stable/prerelease Mihomo values, offer stable, prerelease, and specified-version selection, reject unsupported versions before confirmation, show the selected Release changelog after success, and retain only three `vless-mihomo_*` backups. Remove the official Snell v5 install/update entry; leave Snell v6 unchanged.

Add Mihomo to the main header's core version line:

```text
核心: Xray ... | Sing-box ... | Mihomo ...
```

- [ ] **Step 6: Run unit, help, and syntax checks**

```bash
bash tests/test-mihomo-snell.sh
bash vless-server.sh --help
bash -n vless-server.sh
```

Expected: version/asset tests pass; help exits zero without root access.

- [ ] **Step 7: Commit core installation and management**

```bash
git add vless-server.sh tests/test-mihomo-snell.sh
git commit -m 'Add Mihomo core installation and updates'
```

---

### Task 4: Integrate the shared service, runtime status, logs, and Watchdog

**Files:**
- Modify: `tests/test-mihomo-snell.sh`
- Modify: `vless-server.sh:3717-3784, 11359-11420, 12670-13320, 19210-19490, 20208-20362, 22547-22700, 26374-26530`

**Interfaces:**
- Add `create_mihomo_service`.
- Add `ensure_mihomo_runtime_consistency`.
- Add `_mihomo_ports_healthy [db_file]`.
- Add `set_mihomo_log_level <warning|debug>` → transactionally regenerates and restarts the core.
- Register all Mihomo protocols with `PROTO_SVC=vless-mihomo`, `PROTO_BIN=vless-mihomo`, and `PROTO_KIND=mihomo`.

- [ ] **Step 1: Add failing runtime-helper tests**

Add tests with a mixed fixture and function stubs:

```bash
svc() { [[ "$1:$2" == "status:vless-mihomo" ]]; }
_pgrep() { [[ "$1" == vless-mihomo ]]; }
```

Assert that `get_mihomo_protocols` returns all four relevant keys, service metadata maps every key to `vless-mihomo`, and a generated `$CFG/watchdog.sh` contains one `vless-mihomo:vless-mihomo` entry even when four protocol keys exist. Stub `ss` output to test `_mihomo_ports_healthy` success and one-missing-port failure.

- [ ] **Step 2: Run runtime tests and confirm failure**

```bash
bash tests/test-mihomo-snell.sh
```

Expected: missing service metadata, health helper, and Watchdog entry.

- [ ] **Step 3: Create systemd and OpenRC service definitions**

`create_mihomo_service` writes:

```text
$MIHOMO_BIN -d $CFG -f $MIHOMO_CONFIG
```

For systemd, include `ExecStartPre=$MIHOMO_BIN -t -f $MIHOMO_CONFIG`, `Restart=always`, `RestartSec=3`, and `LimitNOFILE=51200`. For OpenRC, use `command_background=yes`, `/run/vless-mihomo.pid`, network dependencies, and log redirection to `/var/log/vless/mihomo.log`. Add `[vless-mihomo]="vless-mihomo"` to `SVC_PROC`.

- [ ] **Step 4: Add lifecycle and self-repair integration**

In `start_services`, process Mihomo once after Sing-box: install the core if absent, generate/validate config, create the shared service, and call `_start_core_service`. In `stop_services`, pause/resume, global restart, force cleanup, SELinux restore, and complete uninstall, add the shared service exactly once.

`ensure_mihomo_runtime_consistency` mirrors Sing-box repair but requires both `validate_mihomo_config` and `_mihomo_ports_healthy`; it must not start a service when `.mihomo` is empty.

- [ ] **Step 5: Add status, service-management, logs, and Watchdog presentation**

Extend the one-pass `show_status` jq output with `MIHOMO:` and `.mihomo` ports. Add `mihomo_running`, include Mihomo protocol keys in aggregate counts, and report `部分异常` plus missing ports if service status succeeds but listener checks fail.

Add a “Mihomo 服务” block to `show_services_status`, a “Mihomo 协议 (共享服务)” group to installed-protocol views, and one Mihomo item to service logs. systemd uses `journalctl -u vless-mihomo`; Alpine reads `/var/log/vless/mihomo.log` and falls back to `/var/log/messages`. The Mihomo diagnostics submenu offers: show the last 50 lines, follow logs, run `validate_mihomo_config`, enable debug logging, and restore warning logging. `set_mihomo_log_level` writes `.meta.mihomo_log_level`, regenerates/validates the complete config, restarts the service, and rolls the DB/config back if restart fails.

Generate one Watchdog entry when `.mihomo` has at least one key. Before restarting Mihomo, the generated Watchdog must run `vless-mihomo -t -f "$CFG/mihomo.yaml"`; invalid config is logged and not restarted repeatedly.

- [ ] **Step 6: Run runtime tests and Bash validation**

```bash
bash tests/test-mihomo-snell.sh
bash -n vless-server.sh
```

Expected: service metadata, one-entry Watchdog, status-helper, and config-repair tests pass.

- [ ] **Step 7: Commit runtime integration**

```bash
git add vless-server.sh tests/test-mihomo-snell.sh
git commit -m 'Integrate Mihomo service runtime status'
```

---

### Task 5: Convert Snell v4/v5 installation and CRUD to transactional Mihomo nodes

**Files:**
- Modify: `tests/test-mihomo-snell.sh`
- Modify: `vless-server.sh:6090-6200, 11485-11625, 12145-12172, 12412-12464, 12563-12585, 20936-22540`

**Interfaces:**
- Add `_mihomo_snapshot_create` → prints temporary snapshot directory.
- Add `_mihomo_snapshot_restore <directory>`.
- Add `_apply_mihomo_node_change <protocol> <add|replace|remove> <old-port|all> <record-json>`.
- Change `gen_snell_server_config`, `gen_snell_v5_server_config`, and `gen_snell_shadowtls_server_config` to store Mihomo records without official config files.

- [ ] **Step 1: Add failing transactional CRUD tests**

Using temp `CFG`, fake Mihomo validation, and stubbed `svc`, add these cases:

```text
add snell:41001, then add snell:41002 with different PSKs -> both remain
add snell-v5:51001 -> mixed config has all three listeners
replace snell:41001 -> only that record changes
remove snell:41002 -> other listeners remain
validation failure -> DB and mihomo.yaml byte-for-byte match their snapshots
service restart failure -> DB/config restore and previous service state is restarted
cross-protocol duplicate port -> rejected before service mutation
```

Make the `svc` stub append actions to `$TEST_TMP/svc.log` so tests can assert ordering.

- [ ] **Step 2: Run CRUD tests and confirm failure**

```bash
bash tests/test-mihomo-snell.sh
```

Expected: `_apply_mihomo_node_change` is missing and current Snell generators write `.xray` plus official config files.

- [ ] **Step 3: Implement the database/config/service transaction**

The helper must perform this exact order:

```text
snapshot DB, config, and prior running state
apply add/replace/remove to .mihomo
build candidate config
validate candidate with Mihomo
atomically commit candidate
create/enable service if needed
restart/start service
check svc status and every configured port
on any failure: restore DB/config, restore previous running state, return non-zero
on success: remove snapshot, return zero
```

For removal of the final node, stop/disable `vless-mihomo`, remove its config and service definition, and treat that as a successful transaction.

- [ ] **Step 4: Convert Snell record generators**

`gen_snell_server_config` and `gen_snell_v5_server_config` build only:

```bash
build_config psk "$psk" port "$port" version "$version"
```

`gen_snell_shadowtls_server_config` builds only:

```bash
build_config psk "$psk" port "$port" version "$version" \
    sni "$sni" stls_password "$stls_password"
```

Neither function writes `snell.conf`, `snell-v5.conf`, backend config, or `snell_backend_port`. Each hands the record to `_apply_mihomo_node_change` using `INSTALL_MODE` and `REPLACE_PORT`.

- [ ] **Step 5: Restructure the interactive flow around the final protocol key**

For v4/v5, defer `handle_existing_protocol` until after the user chooses ShadowTLS. Resolve the target key before asking for a port:

```text
snell + no ShadowTLS       -> snell
snell-v5 + no ShadowTLS    -> snell-v5
snell + ShadowTLS          -> snell-shadowtls
snell-v5 + ShadowTLS       -> snell-v5-shadowtls
```

Then call `handle_existing_protocol "$target_protocol" mihomo`. Do not install `snell-server`, `snell-server-v5`, or external `shadow-tls`. Do not ask for or display an internal backend port. Keep the current v6 branch and official installer unchanged.

After `_apply_mihomo_node_change` succeeds, avoid a second non-transactional restart in the generic tail of `do_install_server`; update subscriptions and show the newly selected port normally.

- [ ] **Step 6: Run CRUD, syntax, and help checks**

```bash
bash tests/test-mihomo-snell.sh
bash -n vless-server.sh
bash vless-server.sh --help
```

Expected: all transaction cases pass; no v4/v5 install path calls official Snell or external ShadowTLS installers.

- [ ] **Step 7: Commit Mihomo-backed Snell installation**

```bash
git add vless-server.sh tests/test-mihomo-snell.sh
git commit -m 'Run Snell v4 and v5 listeners on Mihomo'
```

---

### Task 6: Add automatic transactional migration and ownership-safe cleanup

**Files:**
- Modify: `tests/test-mihomo-snell.sh`
- Modify: `vless-server.sh:1733-1772, 11485-11721, 12700-13062, 20714-20917, 29323-29340`

**Interfaces:**
- Add `_build_mihomo_migration_db <source-db> <candidate-db>`.
- Add `_legacy_snell_service_names`.
- Add `_cleanup_legacy_snell_resources`.
- Add `_external_shadowtls_is_needed`.
- Add `migrate_legacy_snell_to_mihomo`.

- [ ] **Step 1: Add failing migration-candidate tests**

Create fixture databases for:

```text
.xray.snell as one object
.xray.snell-v5 as an array
.xray.snell-shadowtls with snell_backend_port
.xray.snell-v5-shadowtls with snell_backend_port
.xray.ss2022-shadowtls present
.snell-v6 present
```

Assert `_build_mihomo_migration_db`:

```text
normalizes all four v4/v5 keys into .mihomo arrays
preserves port/psk/version/sni/stls_password
removes snell_backend_port from migrated records
removes only the four migrated keys from .xray
leaves ss2022-shadowtls and snell-v6 untouched
merges without duplicating an existing .mihomo protocol+port record
fails if an existing same-key/same-port record has different credentials
fails if two different Mihomo protocol keys claim the same port
```

- [ ] **Step 2: Add failing migration-order and rollback tests**

Stub `install_mihomo`, `validate_mihomo_config`, `svc`, `_mihomo_ports_healthy`, and `_cleanup_legacy_snell_resources`, logging every call. Test:

```text
validation failure never stops a legacy service
successful validation stops legacy services before starting Mihomo
Mihomo start failure restores the old DB/config and only previously running services
success writes .mihomo-snell-migrated-v1 and calls cleanup last
second invocation with the marker performs no mutation
```

Also assert `_external_shadowtls_is_needed` returns true when `.xray["ss2022-shadowtls"]` exists or any systemd/OpenRC service file references `/usr/local/bin/shadow-tls`.

- [ ] **Step 3: Run migration tests and confirm failure**

```bash
bash tests/test-mihomo-snell.sh
```

Expected: migration helpers are missing.

- [ ] **Step 4: Implement candidate construction and preflight**

`migrate_legacy_snell_to_mihomo` returns immediately when the marker exists or none of the four legacy keys exists. Otherwise it:

```text
records legacy running/enabled states
creates temporary DB/config/service snapshots under CFG
installs a supported Mihomo
builds a candidate DB without touching DB_FILE
builds and validates candidate config while legacy services still run
```

A missing network, asset digest, binary, required field, or config validation must remove temporary candidates and leave the old runtime untouched.

- [ ] **Step 5: Implement cutover, rollback, and immediate cleanup**

After preflight:

```text
stop only legacy v4/v5 and Snell ShadowTLS frontend/backend services
atomically install candidate DB/config
create and start vless-mihomo
check service and every migrated port
```

On failure, restore every snapshot and exact prior service state. On success, remove legacy units/OpenRC files, `snell.conf`, `snell-v5.conf`, both Snell ShadowTLS configs, `/usr/local/bin/snell-server`, and `/usr/local/bin/snell-server-v5`; preserve all v6 resources.

Delete `/usr/local/bin/shadow-tls` only when `_external_shadowtls_is_needed` is false and `$CFG/.shadowtls-managed` proves ownership. Update `install_shadowtls` to write that mode-600 marker for future installs. Always preserve SS2022+ShadowTLS services/configuration.

Write `$MIHOMO_MIGRATION_MARKER` only after health checks and cleanup succeed, set mode `600`, then delete temporary backups.

- [ ] **Step 6: Invoke migration before the main menu**

In `main_menu`, call migration after `init_db` and `db_migrate_to_multiuser`, before runtime-consistency repair and version-cache warming:

```bash
if ! migrate_legacy_snell_to_mihomo; then
    _warn "Snell v4/v5 自动迁移未完成，旧服务已保留或恢复"
fi
ensure_singbox_runtime_consistency 2>/dev/null || true
ensure_mihomo_runtime_consistency 2>/dev/null || true
```

Do not invoke this migration in cron-only CLI branches.

- [ ] **Step 7: Run migration and regression checks**

```bash
bash tests/test-mihomo-snell.sh
bash -n vless-server.sh
bash vless-server.sh --help
```

Expected: all migration order, rollback, idempotency, ownership, SS2022, and v6 preservation cases pass.

- [ ] **Step 8: Commit migration**

```bash
git add vless-server.sh tests/test-mihomo-snell.sh
git commit -m 'Migrate legacy Snell listeners to Mihomo'
```

---

### Task 7: Complete display, subscriptions, per-port uninstall, and global cleanup

**Files:**
- Modify: `tests/test-mihomo-snell.sh`
- Modify: `vless-server.sh:6838-6893, 19210-20092, 20365-20917, 23973-24490, 26378-26530`

**Interfaces:**
- Add `db_protocol_configs <core> <protocol>` → emits normalized compact records, one per line.
- Add `gen_snell_surge_line` support for a unique node suffix and existing ShadowTLS fields.
- Route Mihomo per-port deletion through `_apply_mihomo_node_change`.

- [ ] **Step 1: Add failing normalized iteration and rendering tests**

Test `db_protocol_configs` against one object and an array. Stub address/country helpers, capture rendering output, and assert two same-version nodes produce two distinct Surge lines containing their respective ports and PSKs.

For ShadowTLS, assert each line includes:

```text
version=4 or version=5
shadow-tls-password=<that listener's password>
shadow-tls-sni=<that listener's SNI>
shadow-tls-version=3
```

Add an uninstall test where removing `snell:41001` leaves `snell:41002` and `snell-v5:51001` in DB/config and keeps `vless-mihomo` running. Removing the final Mihomo record must stop/disable the service.

- [ ] **Step 2: Run rendering/uninstall tests and confirm failure**

```bash
bash tests/test-mihomo-snell.sh
```

Expected: display and subscription loops currently search only `.xray`/`.singbox`, and uninstall has no Mihomo branch.

- [ ] **Step 3: Normalize all protocol iteration**

Add `.mihomo` to:

```text
get_installed_protocols and grouped protocol summaries
show_all_protocols_info
show_all_share_links
show_single_protocol_info
generated Base64/Surge subscriptions
join-info lookup
service-log selection
port-selection and protocol uninstall
```

Use `db_protocol_configs` rather than direct `.port` access wherever a protocol can be an array. Names must include at least the port, for example `US-Snell-v5-51001`, to avoid duplicate Surge proxy names.

- [ ] **Step 4: Implement transactional Mihomo uninstall**

`select_port_to_uninstall` uses `protocol_core`. A Mihomo branch invokes `_apply_mihomo_node_change <protocol> remove <selected-port> '{}'`; `all` removes the whole protocol key in one transaction. If other Mihomo records remain, regenerate/validate/restart once. If none remain, stop/disable the shared service and remove only Mihomo config/unit files; keep the binary for core management unless full uninstall was selected.

- [ ] **Step 5: Complete full uninstall and stale-official cleanup**

`do_uninstall` and `force_cleanup` remove `vless-mihomo`, `$MIHOMO_CONFIG`, `$MIHOMO_MIGRATION_MARKER`, managed `/usr/local/bin/vless-mihomo`, version-cache entries, and backups according to existing full-uninstall policy. Keep `/usr/local/bin/shadow-tls` when SS2022+ShadowTLS or any non-Snell service still references it. Keep official Snell v6 behavior unchanged.

Remove obsolete v4/v5 official-core version display/update calls and stale service metadata after migration support no longer needs them; retain only constants/helpers required to identify and clean legacy resources.

- [ ] **Step 6: Run display, uninstall, and full regression tests**

```bash
bash tests/test-mihomo-snell.sh
bash -n vless-server.sh
bash -n nft.sh
bash vless-server.sh --help
```

Expected: multiple distinct nodes render, ShadowTLS fields are complete, per-port deletion is isolated, and all syntax/help checks pass.

- [ ] **Step 7: Commit user-facing integration**

```bash
git add vless-server.sh tests/test-mihomo-snell.sh
git commit -m 'Complete Mihomo Snell management flows'
```

---

### Task 8: Document the feature and perform release verification

**Files:**
- Modify: `README.md`
- Modify: `vless-server.sh:18-31, 36-44`
- Modify: `tests/test-mihomo-snell.sh`

**Interfaces:**
- Bump script version from `3.5.13` to `3.5.14`.
- Add an optional real-binary test controlled by `VLESS_TEST_MIHOMO_BIN`.

- [ ] **Step 1: Add a real Mihomo validation case to the test script**

Capture `REAL_MIHOMO_BIN="${VLESS_TEST_MIHOMO_BIN:-}"` before fixtures assign their fake binary path. When `REAL_MIHOMO_BIN` points to an executable, generate the mixed fixture and assert:

```bash
validate_mihomo_config "$TEST_TMP/mihomo.yaml" "$REAL_MIHOMO_BIN"
```

When the original variable is unset, print one explicit `skip - real Mihomo binary not supplied` line rather than silently passing.

- [ ] **Step 2: Update script metadata and README**

Update the architecture comment to state that Mihomo manages Snell v4/v5 multi-listeners and built-in ShadowTLS, while official Snell serves only v6. Set `VERSION="3.5.14"`.

Add a concise README section covering:

```text
Snell v4/v5 use Mihomo v1.19.28+
multiple ports may use different PSKs and versions in one process
Snell+ShadowTLS uses Mihomo's built-in v3
Snell v6 remains official
legacy v4/v5 installations migrate automatically with rollback
Mihomo appears in core version management and runtime status
```

- [ ] **Step 3: Run the complete local regression suite**

```bash
bash tests/test-mihomo-snell.sh
bash -n vless-server.sh
bash -n nft.sh
bash vless-server.sh --help
git diff --check
```

Expected: all tests pass, both scripts parse, help exits zero, and there are no whitespace errors.

- [ ] **Step 4: Validate a generated fixture with real Mihomo in a temporary directory**

On AMD64:

```bash
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/mihomo.gz" \
  https://github.com/MetaCubeX/mihomo/releases/download/v1.19.28/mihomo-linux-amd64-compatible-v1.19.28.gz
gzip -dc "$tmp/mihomo.gz" >"$tmp/vless-mihomo"
chmod 755 "$tmp/vless-mihomo"
VLESS_TEST_MIHOMO_BIN="$tmp/vless-mihomo" bash tests/test-mihomo-snell.sh
```

For ARM64 or ARMv7, substitute the exact asset returned by `_mihomo_asset_name`. This command only downloads to a temporary directory and runs config validation; it must not install or start services.

Expected: the real-binary config-validation test passes.

- [ ] **Step 5: Review the final diff against every acceptance criterion**

Confirm explicitly:

```text
two ports with different PSKs survive one generated config
v4, v5, and built-in ShadowTLS coexist
v6 remains on snell-server-v6
SS2022+ShadowTLS still uses external shadow-tls
migration rollback and idempotency tests pass
runtime status, logs, Watchdog, and core version menu include Mihomo
all downloaded Mihomo assets require verified SHA-256 digests
```

- [ ] **Step 6: Commit documentation and release metadata**

```bash
git add README.md vless-server.sh tests/test-mihomo-snell.sh
git commit -m 'Release v3.5.14'
```
