# Escalation Radar - read this first

1. Verify the archive: `sha256sum -c escalation-radar.zip.sha256` (run in the folder containing both files).
2. Unzip: `unzip escalation-radar.zip` - everything extracts into one folder, `escalation-radar/`.
3. **Important:** this project has *not* been compiled, deployed or test-run (no Salesforce CLI or org was available when it was generated). Read `escalation-radar/docs/IMPLEMENTATION_STATUS.md`.
4. Deploy to a Developer Edition org:
   ```bash
   cd escalation-radar
   sf org login web --alias escalation-radar-dev --instance-url https://login.salesforce.com
   scripts/deploy.sh escalation-radar-dev
   sf apex run --file scripts/seed-demo-data.apex --target-org escalation-radar-dev
   scripts/run-tests.sh escalation-radar-dev
   ```
5. Open the **Escalation Radar** app. Full guide: `docs/SETUP_GUIDE.md`. Demo script: `docs/DEMO_GUIDE.md`.
No credentials, tokens or org auth files are included; the default AI provider is a built-in mock.
