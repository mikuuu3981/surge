# Final Mihomo Snell fix wave report

Status: implemented and locally verified; final review is intentionally not marked clean.

## TDD record

All fixtures source the script into temporary paths and stub service, binary, listener, and process behavior; no install, service, firewall, migration, uninstall, or network action was run on the host.

| Finding | RED command and result | GREEN command and result |
|---|---|---|
| Critical update transaction | `VLESS_TEST_ONLY=test_mihomo_update_rolls_back_validation_failure bash tests/test-mihomo-snell.sh` before implementation: `not ok - test_mihomo_update_rolls_back_validation_failure`, exit 1 (new binary remained and generic update reported success). | The focused validation, restart/status, missing-listener, and success/no-node tests pass. Full suite: `bash tests/test-mihomo-snell.sh` → `126 tests passed, 1 skipped`. |
| Direct test-log overrides | `VLESS_TEST_ONLY=test_direct_execution_pins_log_paths_but_sourcing_allows_fixtures bash tests/test-mihomo-snell.sh` before implementation: `not ok - test_direct_execution_pins_log_paths_but_sourcing_allows_fixtures`, exit 1. | Same command → `ok ...`, `1 tests passed, 0 skipped`; direct `bash -x ... --help` shows only production paths while sourced fixtures retain overrides. |
| Multi-node join regeneration | `VLESS_TEST_ONLY=test_mihomo_join_files_regenerate_current_transactional_state bash tests/test-mihomo-snell.sh` before implementation: `grep: .../snell.join: No such file or directory`, `not ok`, exit 1. | Same command → `ok ...`, `1 tests passed, 0 skipped`; covers add-two, mixed v5/ShadowTLS, replace, remove-one, protocol-final and global-final cleanup. |
| `/proc` full read | `VLESS_TEST_ONLY=test_mihomo_migration_process_read_failure_is_error_and_retains_snapshot bash tests/test-mihomo-snell.sh` before implementation: `not ok ...`, exit 1. | Same command → `ok ...`, `1 tests passed, 0 skipped`; fixture removes `comm` after identity validation and proves status 2 plus retained migration snapshot. |

## Implementation and rollback design

- Added a Mihomo-only update transaction. It snapshots the exact managed binary (including mode) and original running state before installation. With managed nodes it validates the existing complete config using the new binary, restarts only a formerly running service, then requires `svc status` and `_mihomo_ports_healthy`. Validation, restart, status, or listener failure restores the binary and exact prior running state. Empty `.mihomo` installs/switches without start/restart.
- Direct execution now pins `MIHOMO_LOG_FILE` and `SYSTEM_MESSAGES_LOG` to production paths. The two overrides are evaluated only in the sourced-test branch.
- Added transactional `regenerate_mihomo_join_info`: normalized `.mihomo` records produce one entry per port for v4, v5, and both ShadowTLS variants. It rebuilds `join.txt` from unrelated existing join files plus current Mihomo entries. CRUD snapshots now include these files; join-generation failure triggers the existing DB/config/service rollback. Final node removal removes only stale Mihomo join data and preserves unrelated joins.
- Replaced ambiguous `read -d ''` with a subshell-scoped fixed FD 9 full read through `cat`, explicit open/read/close status checks, a sentinel preserving trailing newlines, and existing before/after identity checks. Any uncertainty returns 2.

## Files

- `vless-server.sh`
- `tests/test-mihomo-snell.sh`
- `.superpowers/sdd/2026-09-07-mihomo-snell-multi-inbound/progress.md`
- `.superpowers/sdd/2026-09-07-mihomo-snell-multi-inbound/final-fix-report.md`

## Verification and self-review

Executed successfully:

```text
bash tests/test-mihomo-snell.sh                    # 126 passed, 1 skipped (real binary not supplied)
bash -n vless-server.sh
bash -n tests/test-mihomo-snell.sh
bash -n nft.sh
bash vless-server.sh --help
git diff --check
```

Reviewed the complete diff for direct-path isolation, Bash 4.1 syntax, fixed-FD scope, update rollback paths, listener-health gating, join credential freshness, aggregate preservation, and snapshot restoration. No production system path was mutated by tests.

## Concerns

- The optional real-Mihomo parser test remains skipped because no executable real Mihomo binary was supplied; this is the existing explicit non-destructive skip.
- Actual systemd/OpenRC daemon execution and network listeners remain VM/container-only checks, per the project constraints.
- Final review must independently assess this commit; this report does not declare it clean.

Commit: `Fix Mihomo final review findings` (this final fix-wave commit).
