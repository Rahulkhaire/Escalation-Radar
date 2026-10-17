#!/usr/bin/env bash
# Checks local tooling. Read-only; changes nothing. Usage: scripts/verify-environment.sh [org-alias]
set -u
ORG="${1:-escalation-radar-dev}"
ok=0
check() { if command -v "$1" >/dev/null 2>&1; then echo "OK   $1: $($1 $2 2>&1 | head -1)"; else echo "MISSING $1 - $3"; ok=1; fi; }
check sf --version "install: npm install --global @salesforce/cli"
check node --version "install Node.js 18+ (only needed for sf and optional lint)"
check git --version "optional"
if command -v sf >/dev/null 2>&1; then
  if sf org display --target-org "$ORG" >/dev/null 2>&1; then
    echo "OK   org '$ORG' is authenticated"
  else
    echo "NOTE org '$ORG' not authenticated. Run: sf org login web --alias $ORG --instance-url https://login.salesforce.com"
    ok=1
  fi
fi
exit $ok
