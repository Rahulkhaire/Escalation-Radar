#!/usr/bin/env bash
# Deploys the project and assigns the manager permission set to the current org user.
# Usage: scripts/deploy.sh [org-alias]   (default: escalation-radar-dev)
set -euo pipefail
ORG="${1:-escalation-radar-dev}"
cd "$(dirname "$0")/.."
echo "== Deploying force-app to $ORG =="
sf project deploy start --source-dir force-app --target-org "$ORG" --wait 30
echo "== Assigning ER_Radar_Manager to the deploying user =="
sf org assign permset --name ER_Radar_Manager --target-org "$ORG" || echo "(already assigned or assignment failed - check Setup > Permission Sets)"
cat <<MSG
Next (manual): see docs/SETUP_GUIDE.md
  - confirm Change Data Capture is enabled for Case (Setup > Integrations > Change Data Capture)
  - load demo data:   sf apex run --file scripts/seed-demo-data.apex --target-org $ORG
  - schedule recovery: sf apex run --file scripts/schedule-recovery.apex --target-org $ORG
MSG
