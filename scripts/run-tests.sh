#!/usr/bin/env bash
# Runs all local Apex tests in the org with code coverage. Usage: scripts/run-tests.sh [org-alias]
set -euo pipefail
ORG="${1:-escalation-radar-dev}"
cd "$(dirname "$0")/.."
mkdir -p test-results
sf apex run test --target-org "$ORG" --test-level RunLocalTests --code-coverage --result-format human --output-dir test-results --wait 30
