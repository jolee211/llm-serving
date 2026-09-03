#!/usr/bin/env bash
# Compatibility entry point. The comprehensive verifier is the source of truth.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "$SCRIPT_DIR/verify-zero-cost.sh" "$@"
