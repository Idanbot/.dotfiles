#!/usr/bin/env bash
# Parse workflow semantics rather than depending on inline test filenames.
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
python3 "$ROOT/scripts/ci/contracts.py" "$ROOT"
