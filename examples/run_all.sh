#!/usr/bin/env bash
set -euo pipefail

MIX_ENV="${MIX_ENV:-dev}"

echo "Running FlowStone live examples in MIX_ENV=${MIX_ENV}..."
mix run examples/run_all.exs
