#!/usr/bin/env bash
# Check-only deployment (nothing is saved to the org) running all local tests.
# Usage: scripts/validate.sh [org-alias]
set -euo pipefail
ORG="${1:-escalation-radar-dev}"
cd "$(dirname "$0")/.."
python3 scripts/static-check.py
sf project deploy validate --source-dir force-app --target-org "$ORG" --test-level RunLocalTests --wait 60
