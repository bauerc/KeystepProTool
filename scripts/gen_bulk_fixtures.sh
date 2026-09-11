#!/usr/bin/env bash
# Rewrite the two bulk fixtures from the Swift plan. Run after tools/gen_bulk_plan.swift or a change
# to the pool gate, then review the diff before committing it.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

generator=swift/.build/gen_bulk_fixtures
mkdir -p "$(dirname "$generator")"
swiftc swift/Sources/KSPKit/*.swift swift/Sources/KSPTape/*.swift tools/gen_bulk_fixtures.swift \
    -o "$generator"
"$generator"
