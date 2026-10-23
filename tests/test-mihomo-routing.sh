#!/usr/bin/env bash
# Shared routing and loopback runtime coverage now live in the Sing-box suite.
set -euo pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/test-singbox-snell.sh"
