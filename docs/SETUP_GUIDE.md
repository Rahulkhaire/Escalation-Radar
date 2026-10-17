# Setup guide

Commands marked **[ready]** can be pasted as-is. Commands marked **[edit]** need your values. Verify option names against your CLI version with `sf <command> --help`.

## A. Prerequisites

* A Salesforce **Developer Edition** org (https://developer.salesforce.com/signup) or a sandbox. Lightning Experience, Cases (Service features), Change Data Capture and Platform Events must be available. Developer Edition allows a small number of CDC entities; Case is one.
* **Salesforce CLI** (`sf`), Node.js 18+ (only to install the CLI and optional lint), Git, Python 3 (for `scripts/static-check.py`).
* Install the CLI **[ready]**: `npm install --global @salesforce/cli`

## B. Verify tooling

```bash
sf --version                      # [ready] prints the CLI version
scripts/verify-environment.sh     # [ready] checks sf/node/git and whether the org alias is logged in
```

## C. Authenticate

```bash
sf org login web --alias escalation-radar-dev --instance-url https://login.salesforce.com   # [ready] Developer Edition / production
# sandbox: --instance-url https://test.salesforce.com
sf org display --target-org escalation-radar-dev                                              # [ready] confirms username and instance
```
A browser window opens; log in as a System Administrator. Credentials stay in the CLI's local store (`~/.sf`) and are never part of this project.

## D. Deploy

```bash
scripts/deploy.sh escalation-radar-dev    # [ready] runs: sf project deploy start --source-dir force-app ... then assigns ER_Radar_Manager
# or manually:
sf project deploy start --source-dir force-app --target-org escalation-radar-dev --wait 30
```
If the deployment reports errors, see TROUBLESHOOTING.md. The project has **not** been compiled by its author; expect that the first deploy may reveal small issues to fix.

## E. Permission sets

| Permission set | Purpose |
|---|---|
| `ER_Radar_Viewer` | read dashboard and records |
| `ER_Radar_Manager` | viewer + approve/reject + run actions (custom permissions `ER_Approve_Actions`, `ER_Execute_Actions`) |
| `ER_Radar_Admin` | manager + edit Account Tier + delete Integration Logs |

```bash
sf org assign permset --name ER_Radar_Manager --target-org escalation-radar-dev   # [ready] assigns to the logged-in user
sf org assign permset --name ER_Radar_Viewer --target-org escalation-radar-dev --on-behalf-of someone@example.com   # [edit]
```
Users also need ordinary **Case and Account read access** (profile or another permission set). Approvers need access to the Cases they approve (the approval service checks it in user mode).

## F. Confirm Change Data Capture

The deploy includes `ChangeEvents_CaseChangeEvent`. Verify: Setup > Integrations > **Change Data Capture** shows **Case** as selected. If not, add it and save. Then confirm the trigger `ER_CaseChangeTrigger` is active (Setup > Apex Triggers).

## G. Sample data

```bash
sf apex run --file scripts/seed-demo-data.apex --target-org escalation-radar-dev   # [ready] 4 accounts, 8 cases (all tagged [ER Demo])
```
It also runs the **initial assessment batch**, so assessments appear even if CDC is not enabled yet. Optional: set `Case.ER_SLA_Deadline__c` on your own Cases.

## H. Risk configuration (thresholds, weights, SLA)

Setup > Custom Metadata Types > **ER Risk Config** > Manage Records > **Default**. Change weights, thresholds, `Version__c` and SLA policy hours.
**Increment `Version__c` whenever you change rules** (it is stored with every assessment). Weights should sum to 100 (the engine caps the score at 100 and at the sum of weights).
Then reprocess: `sf apex run --file scripts/run-reprocess.apex --target-org escalation-radar-dev` **[ready]**.
Tuning approach: copy ~20 representative Cases, record the category you think each deserves, adjust weights until the engine agrees, and keep a record of the rule version used. The shipped numbers are examples, not validated rules.
Priority/tier fractions are in **ER Risk Factor Map**. SLA: supply `Case.ER_SLA_Deadline__c`, or rely on the per-priority policy hours. If you use Entitlements/Milestones, populate `ER_SLA_Deadline__c` from your milestone target date (a Flow or Apex is out of scope here).

## I. Mock AI provider (default; verifies the product without credentials)

Setup > Custom Metadata Types > **ER Integration Setting** > `AI`: `Enabled` checked, `Provider` = `MOCK`. Assessments with score >= `Min_Score__c` (40) become `AI_Pending`, then `Enriched` with deterministic mock text. Nothing leaves Salesforce.

## J. Real LLM provider (optional)

1. Setup > Security > **Named Credentials** > External Credentials > New. Choose a **Custom** authentication protocol, add a principal, and an authentication parameter holding your API key (e.g. `ApiKey`). Secrets are entered only here.
2. New **Named Credential** `ER_LLM` -> URL = your provider base URL (e.g. `https://api.anthropic.com`), link the External Credential, add a **custom header** carrying the key using the credential formula syntax shown in the setup UI (for Anthropic: header `x-api-key`; the `anthropic-version` header is added by Apex). Exact labels vary by release.
3. Grant **External Credential Principal Access** to a permission set (enable your principal) and assign it to every user that triggers AI calls (see "Who runs the jobs?" below).
4. Edit the `AI` setting: `Provider` = `LLM`, `Model__c` = a model your account can use, `Endpoint_Path__c` (default `/v1/messages`), timeout/payload/token limits.
The adapter uses a Messages-style schema; for other providers adapt `ER_LLMProvider.buildBody/extractText` (see API_AND_INTEGRATIONS.md). Verify with a Case that scores >= 40: audit shows `AI_REQUESTED` then `AI_COMPLETED`; failures appear in Integration Logs.

**Who runs the jobs?** Queueables run as the user who enqueued them. CDC-triggered work runs as **Automated Process** unless you configure a subscriber user (`PlatformEventSubscriberConfig`; template in TROUBLESHOOTING.md). Named Credential principal access is per user via permission sets, so for real LLM/Slack calls create a dedicated **integration user**, give it the permission set with principal access plus `ER_Radar_Admin`, and configure the subscriber to run as that user. Slack executions run as the approving manager (assign principal access to managers) - or accept that Slack executes only for users with access.

## K. Slack (optional, off by default)

1. Create a Slack Incoming Webhook (Slack app settings). The full webhook URL is a secret.
2. Named Credential `ER_Slack`: URL = the webhook URL, no authentication (or per your security policy); grant principal access if you use an External Credential.
3. `ER Integration Setting` > `Slack`: `Enabled` = true, `Provider` = `SLACK` (or `MOCK` to test without Slack), `Min_Category__c` = `HIGH`.
`SEND_SLACK_ALERT` always needs manager approval and is deduplicated per Case and category.

## L. Platform Event subscription

Nothing to configure: the dashboard subscribes with `lightning/empApi`. Users need read access to `ER_Risk_Update__e` (included in all three permission sets). Test: open the dashboard, then run `sf apex run --file scripts/run-reprocess.apex`; a "Live update" message and refresh follow within seconds.

## M. Recovery schedule

```bash
sf apex run --file scripts/schedule-recovery.apex --target-org escalation-radar-dev   # [ready] schedules the recovery batch every 15 minutes
```
Without it, retries scheduled with backoff are not picked up automatically (use **Retry failed AI analyses** in the dashboard or run the batch manually).

## N. Open the app and test the workflow

App Launcher > **Escalation Radar**. Follow docs/DEMO_GUIDE.md.

## O. Tests and validation

```bash
scripts/run-tests.sh escalation-radar-dev        # [ready] sf apex run test --test-level RunLocalTests --code-coverage ...
scripts/validate.sh escalation-radar-dev         # [ready] static check + sf project deploy validate (check-only)
sf apex run test --target-org escalation-radar-dev --test-level RunLocalTests --wait 30   # [ready]
python3 scripts/static-check.py                  # [ready] offline checks, no org
```

## P. Cleanup / uninstall

```bash
sf apex run --file scripts/cleanup-demo-data.apex --target-org escalation-radar-dev   # [ready] deletes [ER Demo] data
```
`Escalation_Audit__c` rows cannot be deleted (by design). To remove the project completely: deactivate/delete the three triggers (`ER_AuditProtectionTrigger` first), delete scheduled jobs (Setup > Scheduled Jobs, "ER Recovery"),
then use a destructive deployment (`destructiveChanges.xml`) or delete the components in Setup. Unassign the permission sets first.
