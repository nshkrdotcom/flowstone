#!/usr/bin/env bash
set -euo pipefail

MIX_ENV="${MIX_ENV:-dev}"

echo "Running FlowStone live examples in MIX_ENV=${MIX_ENV}..."
echo "Includes parallel_branches_example.exs for parallel branch joins."
mix run examples/run_all.exs
