#!/usr/bin/env bash
set -e

TARGET_TEST="${1:-tests}"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
STATS_FILE="profile_${TIMESTAMP}.stats"

echo "=================================================="
echo "1. Running Pytest & Profiling on: ${TARGET_TEST}"
echo "=================================================="

uv run python -m cProfile -o "${STATS_FILE}" -m pytest "${TARGET_TEST}" --durations=10

echo ""
echo "=================================================="
echo "2. Top 20 Functions by Internal Time (tottime)"
echo "   Artifact saved: ${STATS_FILE}"
echo "=================================================="

uv run python -c "
import pstats
stats = pstats.Stats('${STATS_FILE}')
stats.strip_dirs()
stats.sort_stats('tottime')
stats.print_stats(20)
"
