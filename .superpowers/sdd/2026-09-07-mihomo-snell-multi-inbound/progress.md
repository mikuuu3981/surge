# SDD ledger — plan: docs/superpowers/plans/2026-09-07-mihomo-snell-multi-inbound.md

Worktree: /home/miku/surge/.worktrees/mihomo-snell-multi-inbound
Branch: feature/mihomo-snell-multi-inbound
Start commit: 8aeabaa (plan aa98b42 is an ancestor)

## Task ledger

- [x] Task 1: Add a sourceable test seam and Mihomo database namespace
- [x] Task 2: Generate and validate a complete multi-listener Mihomo config
- [x] Task 3: Add verified Mihomo installation and full core-version management
- [x] Task 4: Integrate the shared service, runtime status, logs, and Watchdog
- [x] Task 5: Convert Snell v4/v5 installation and CRUD to transactional Mihomo nodes
- [x] Task 6: Add automatic transactional migration and ownership-safe cleanup
- [x] Task 7: Complete display, subscriptions, per-port uninstall, and global cleanup
- [x] Task 8: Document the feature and perform release verification

## Pre-flight task/interface scan

All task pairs share `vless-server.sh` and/or `tests/test-mihomo-snell.sh`; the table records the producer/consumer relationship and checks plan compatibility.

| Tasks | Producer → consumer | Finding |
|---|---|---|
| 1 / 2 | Source seam, paths, `.mihomo`, taxonomy → generator fixtures and namespace reads | Compatible; Task 2 builds on Task 1 interfaces. |
| 1 / 3 | Source-safe `MIHOMO_BIN` and taxonomy → version/install helpers | Compatible; test override is source-only, production remains fixed. |
| 1 / 4 | `get_mihomo_protocols`/`protocol_core` → shared-service registration and status | Compatible; one core classification maps many protocols to one service. |
| 1 / 5 | `.mihomo` namespace and port conflict scan → transactional CRUD | Compatible; CRUD uses protocol+port identity. |
| 1 / 6 | Legacy/new namespace separation → migration candidate construction | Compatible; migration moves only four keys. |
| 1 / 7 | Core classification and normalized namespace → display/uninstall routing | Compatible; Task 7 broadens consumers without changing taxonomy. |
| 1 / 8 | Source-safe real-binary override → optional validation test | Compatible; original env value must be captured before fixtures overwrite it. |
| 2 / 3 | Config validation interface → install/update post-install checks | Compatible; install uses verified binary and validates existing config. |
| 2 / 4 | Full generated config and port listing → runtime health/log-level transaction | Compatible; runtime treats config as one shared unit. |
| 2 / 5 | Candidate generation/validation → CRUD transaction commit | Compatible; last-node removal is explicitly handled outside non-empty generation. |
| 2 / 6 | Candidate generation/validation → migration preflight | Compatible; legacy services remain running during validation. |
| 2 / 7 | Normalized listener records → multi-node rendering/uninstall regeneration | Compatible; each listener remains independent. |
| 2 / 8 | Mixed fixture generator → optional real Mihomo validation | Compatible; JSON output is valid YAML input. |
| 3 / 4 | Managed core path/version → service definitions and diagnostics | Compatible; service executes only `vless-mihomo`. |
| 3 / 5 | Supported verified core → transactional node changes | Compatible; install precedes first managed listener. |
| 3 / 6 | Verified installer → migration preflight | Compatible; verification cannot be bypassed. |
| 3 / 7 | Core/cache integration → full uninstall cleanup | Compatible; Task 7 removes managed binary/cache only on full uninstall. |
| 3 / 8 | Asset selection/version checks → temporary real-binary release validation | Compatible; Task 8 does not install or start services. |
| 4 / 5 | Shared service metadata/health helper → CRUD restart and rollback | Compatible; service mutation occurs once per complete config. |
| 4 / 6 | Shared service creation/health → migration cutover/rollback | Compatible; prior legacy service state is separately preserved. |
| 4 / 7 | Runtime status/log/watchdog integration → installed views and cleanup | Compatible; Task 7 completes all user-facing consumers. |
| 4 / 8 | Runtime/core header text → release docs and final verification | Compatible. |
| 5 / 6 | Snapshot/transaction helpers → migration transaction patterns | Compatible; migration additionally snapshots legacy definitions/state. |
| 5 / 7 | `_apply_mihomo_node_change` → per-port uninstall | Compatible; removing one listener preserves and restarts remaining listeners. |
| 5 / 8 | Mixed CRUD config → acceptance checks for independent PSKs/ports | Compatible. |
| 6 / 7 | Migration ownership rules → stale-resource/global cleanup | Compatible; both preserve v6 and externally needed ShadowTLS. |
| 6 / 8 | Migration behavior/tests → release documentation and acceptance review | Compatible. |
| 7 / 8 | Complete display/subscription/uninstall behavior → docs and release verification | Compatible. |

## Per-task internal consistency scan

| Task | Tests/files/interfaces agree? | Finding |
|---|---|---|
| 1 | Yes | Initial tests exercise source seam, namespace upgrade, and taxonomy required by implementation steps. |
| 2 | Yes | Rejection tests correspond to validator constraints; atomic-output and mode requirements are testable in fixtures. |
| 3 | Yes | Minimum-version cases define stable-boundary semantics: 1.19.28 prereleases fail, later-version prereleases may pass. |
| 4 | Yes | Runtime tests isolate service/process/socket effects while generated service/watchdog artifacts remain observable behavior. |
| 5 | Yes | CRUD tests cover exact transaction order, preservation, duplicate rejection, and rollback. |
| 6 | Yes | Candidate tests and cutover-order tests cover preflight-before-stop, rollback, cleanup, and idempotency. |
| 7 | Yes | Normalized iteration feeds rendering and transactional per-port removal; final-node behavior is explicit. |
| 8 | Yes | Metadata/docs follow completed behavior; optional real binary validation is non-destructive and explicit when skipped. |

Pre-flight result: no contradiction found between tasks, Global Constraints, and the design specification. No ruling required before Task 1.

Baseline: PASS — bash -n vless-server.sh; bash -n nft.sh; bash vless-server.sh --help (start 8aeabaa).

Task 1: fix round 1/5 (1 addressed, 0 open — legacy `.xray` Snell namespace fallback; commits d8f9522..740895f)
Task 1: complete (commits 8aeabaa..740895f, review clean)
Task 2: ⚠ resolved — real Mihomo parser validation is explicitly scheduled in Task 8; Task 2 validates the executable boundary with a controlled binary.
Task 2: complete (commits 740895f..43ef3eb, review clean)
Task 3: ⚠ resolved — live release asset/digest availability is an external integration check scheduled with the temporary real-binary validation in Task 8; mandatory digest enforcement is covered now.
Task 3: complete (commits 43ef3eb..4c0960e, review clean)
Task 4: fix round 1/5 (2 addressed, 0 open — unit-write failure propagation; `.mihomo`-only runtime eligibility; commits aa7709b..b63c4c9)
Task 4: ⚠ resolved — actual daemon execution is prohibited on this host and remains an isolation-VM verification item.
Task 4: complete (commits 4c0960e..b63c4c9, review clean)
Task 5: fix round 1/5 (3 addressed, 2 new Important open — remove official v4/v5 execution/update; propagate rollback and retain snapshots; restore enablement; commits f824d50..d6cdd71)
Task 5: fix round 2/5 (2 addressed, 0 open — repair snapshot-retention test; restore namespace-scoped legacy service/log discovery; commits d6cdd71..2edfb45)
Task 5: ⚠ resolved — real daemon/listener execution is prohibited on this host and remains an isolation-VM verification item.
Task 5: complete (commits b63c4c9..2edfb45, review clean)
Task 6: fix round 1/5 (1 addressed, 1 open — snapshot/restore Mihomo binary; missing-service rollback still conflated status; commits 81cfd24..8038fc5)
Task 6: fix round 2/5 (0 fully addressed, 1 open — tri-state manager status added but OpenRC error semantics incomplete; commits 8038fc5..3cb1b03)
Task 6: fix round 3/5 (1 addressed, 2 open — OpenRC 0/3/error fixed; authoritative inactive fallback and proc uncertainty remained; commits 3cb1b03..6a62439)
Task 6: fix round 4/5 (1 addressed, 2 open — manager-unavailable-only fallback fixed; full comm/symlink/read uncertainty remained; commits 6a62439..20ade38)
Task 6: fix round 5/5 (2 addressed, 1 open — full comm/symlink/race handling fixed; read/open failure vs EOF remains; commits 20ade38..07fa8e7)
Task 6: parked — `_mihomo_migration_managed_process_running` conflates `read -d ''` status 1 from expected EOF with an open/read failure — Ruling: this is a real Important migration-rollback edge, but no downstream Task 7/8 interface builds on it; after the five-round breaker it is deferred to the single final whole-branch fix wave. Cost if wrong: when the service manager is unavailable and `/proc/<pid>/comm` becomes unreadable at read time, migration rollback may restore files around a possibly active Mihomo process and consume the snapshot.
Task 6: ⚠ resolved — actual systemd/OpenRC migration execution remains prohibited here and is an isolation-VM verification item.
Task 6: complete (commits 2edfb45..07fa8e7, 1 parked)
Task 7: fix round 1/5 (2 addressed, 1 new Important open — legacy display/uninstall fixed; mixed-namespace selection mismatch found; commits 52ca5ca..9ac7eb4)
Task 7: fix round 2/5 (1 addressed, 0 open — active namespace resolver aligns selection and mutation; commits 9ac7eb4..cb1fd0e)
Task 7: complete (commits 07fa8e7..cb1fd0e, review clean)
Task 8: Ruling: the plan's Step 4 bare `curl` example conflicts with the Global Constraint that every Mihomo download requires publisher SHA-256 verification. Execute equivalent temporary real-binary validation only after publisher digest verification (prefer the production verified install path with source-only temporary destination), never the bare download. Cost if wrong: the exact illustrative command differs, but using it would violate the binding security requirement.
Task 8: fix round 1/5 (2 addressed, 1 Important open — release/comments corrected; skip accounting still collided with status 2; commits 1aa1803..de13e9a)
Task 8: fix round 2/5 (1 addressed, 1 new Important open — status collision fixed; unset and explicit-empty still conflated; commits de13e9a..5e132d5)
Task 8: fix round 3/5 (1 addressed, 0 open — original variable presence tracked separately; commits 5e132d5..d6cedcc)
Task 8: complete (commits cb1fd0e..d6cedcc, review clean)
Final review: fixes required — Critical: Mihomo update post-install validation/service/listener rollback. Important: direct execution honors test log paths; join files stale for multi-node CRUD; parked proc-read ambiguity is real and merge-blocking.

Final fix wave commit: `Fix Mihomo final review findings` (this commit) — added Mihomo post-install binary/service transaction with validation, status and listener rollback; source-only log overrides; transactional normalized multi-port join regeneration; and full `/proc/comm` read-status handling. Tests: `bash tests/test-mihomo-snell.sh` (126 passed, 1 explicit real-binary skip), `bash -n vless-server.sh`, `bash -n tests/test-mihomo-snell.sh`, `bash -n nft.sh`, `bash vless-server.sh --help`, `git diff --check`. Final review not marked clean.
