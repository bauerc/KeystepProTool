#!/usr/bin/env bash
set -e

# Target specific test file/directory if provided, otherwise default to all tests
TARGET_TEST="${1:-tests}"

# Generate a timestamp for the stats artifact
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
STATS_FILE="profile_${TIMESTAMP}.stats"

echo "=================================================="
echo "1. Running Pytest & Profiling on: ${TARGET_TEST}"
echo "=================================================="

# Run pytest inside cProfile via uv
uv run python -m cProfile -o "${STATS_FILE}" -m pytest "${TARGET_TEST}" --durations=10

echo ""
echo "=================================================="
echo "2. Top 20 Functions by Internal Time (tottime)"
echo "   Artifact saved: ${STATS_FILE}"
echo "=================================================="

# Extract top 20 functions by self-time (tottime)
uv run python -c "
import pstats
stats = pstats.Stats('${STATS_FILE}')
stats.strip_dirs()
stats.sort_stats('tottime')
stats.print_stats(20)
"
