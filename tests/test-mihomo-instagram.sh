#!/usr/bin/env bash
# Compatibility entry point for the retired Mihomo Instagram suite.
set -euo pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/test-singbox-instagram.sh"
