#!/usr/bin/env bash
# Compatibility entry point: Mihomo Snell management has been retired.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bash "$HERE/test-script-update.sh"
bash "$HERE/test-singbox-snell.sh"
bash "$HERE/test-singbox-snell-migration.sh"
bash "$HERE/test-singbox-instagram.sh"
