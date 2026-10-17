# Escalation Radar

An AI-assisted support-leadership command center for Salesforce. It watches Cases through **Change Data Capture**,
scores SLA-breach risk with a **deterministic, explainable, configurable engine**, optionally enriches the result with a
**validated LLM analysis**, proposes **allowlisted actions**, and lets a manager **approve or reject** them from a Lightning dashboard.
Every important step is audited.

> **Status: built and statically checked, not yet deployed or test-run.** The project was produced in an environment with no Salesforce CLI and no org.
> Apex has not been compiled and no test has been executed. Read [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) before demoing,
> and run `scripts/validate.sh` against your Developer Edition org first.

## Features

* Deterministic risk score (0-100) from 5 weighted factors (SLA, priority, reopen count, account tier, age and communication). Weights, thresholds, SLA policy and factor mappings are **Custom Metadata**; each assessment stores per-factor points and the rule version.
* CDC pipeline: `CaseChangeEvent` Apex trigger -> filter, dedupe by commit number, bounded Queueable jobs; Batch Apex for backfill, reprocessing and recovery.
* AI enrichment behind an interface: **Mock provider** (no key needed) and a Named-Credential **LLM provider**. Strict schema validation, PII redaction, prompt-injection containment, retries with backoff, deterministic fallback. AI can add at most a small, capped uplift and can never act.
* Action framework: six allowlisted actions, separate propose / approve / execute steps, mandatory approval for reassignment and Slack, revalidation before execution, replay and duplicate protection.
* `ER_Risk_Update__e` Platform Event (publish-after-commit) driving live dashboard refresh; stale-data and recovery behaviour documented.
* LWC dashboard (`escalationRadarDashboard` + 10 child components): KPIs, distribution, filters, search, sort, pagination, case detail with factor breakdown, AI panel, action panel, approval queue, audit history, health panel; loading/empty/error/stale states; keyboard-accessible.
* Optional Slack adapter (disabled by default, mock available).
* Audit trail, integration log, permission sets, 10 Apex test classes (about 85 test methods, 260 assertion calls; **none executed yet**).

## Screenshots

_No screenshots exist yet (the dashboard has not been run in an org). After deployment, capture and place them in `docs/screenshots/` and link them here:_
`dashboard-overview.png`, `case-detail.png`, `approval-queue.png`.

## Architecture overview

```
Case change ──CDC──> ER_CaseChangeTrigger ──> ER_CDCProcessingService (filter, dedupe, chunk)
                                   │
                                   ▼  Queueable (ASSESS)           ┌── Batch (INITIAL / REPROCESS / RECOVER)
                         ER_CaseRiskService ── upsert Risk_Assessment__c, audit, publish ER_Risk_Update__e
                                   │  score >= AI threshold
                                   ▼  Queueable (AI, callouts first, DML last)
                         ER_AIAnalysisService ── provider (Mock | LLM) ── validator ── store, uplift, audit
                                   ▼
                         ER_ActionRecommendationService ──> Escalation_Action__c (Pending / Not_Required)
 Manager (LWC) ──> ER_DashboardController ──> ER_ActionApprovalService ──> Queueable ──> ER_ActionExecutionService
```
Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Technology stack

Salesforce DX (API 62.0), Apex (Queueable, Batch, Schedulable, triggers), LWC, Change Data Capture, Platform Events, Custom Metadata Types,
Named/External Credentials, user-mode SOQL/DML, `lightning/empApi`, Salesforce CLI (`sf`). No third-party JavaScript libraries.

## Quick start

```bash
sf --version
sf org login web --alias escalation-radar-dev --instance-url https://login.salesforce.com
scripts/deploy.sh escalation-radar-dev          # deploy + assign ER_Radar_Manager to you
sf apex run --file scripts/seed-demo-data.apex --target-org escalation-radar-dev
sf apex run test --target-org escalation-radar-dev --test-level RunLocalTests --wait 30
```
Open the **Escalation Radar** app from the App Launcher. Full steps: [docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md). The default AI provider is `MOCK`, so no external credentials are needed.

## Demo workflow

See [docs/DEMO_GUIDE.md](docs/DEMO_GUIDE.md) (5-minute script, scenarios, failure-recovery demo).

## Limitations (summary)

Not compiled or executed by the author's tooling; the first deployment may need small fixes. Named Credentials, External Credentials, the Slack webhook, the CDC subscriber user,
and the recovery schedule are manual setup. Business-hours SLA uses the org default hours only. No Salesforce Flow is shipped (the escalation action can invoke a Flow you configure).
The audit trail is application-level, not tamper-evident. Full list: [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md).
