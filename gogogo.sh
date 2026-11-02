#!/usr/bin/env bash
# Mac Go: checked GitHub publication and receipt-bound local application update.
set -euo pipefail
MACGO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export PYTHONDONTWRITEBYTECODE=1
exec /usr/bin/python3 "$MACGO_ROOT/scripts/release.py" "$@"
