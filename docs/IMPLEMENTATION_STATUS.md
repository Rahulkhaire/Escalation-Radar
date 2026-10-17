# Implementation status

Date of generation: 2026-10-16. Updated 2026-10-17 (1.0.1) after the first real deployment attempt reported 29 compile/metadata errors, now fixed (see CHANGELOG). **Environment limits:** no Salesforce CLI (`sf: not found`), no network, no authenticated org. Therefore **nothing was compiled, deployed or run in Salesforce.**

## Completed (written)

* Salesforce DX structure (API 62.0), 4 custom objects, 1 platform event, 3 custom metadata types with default records, Case/Account fields, CDC channel member, custom permissions, 3 permission sets, app, 5 tabs, 4 layouts.
* 31 production Apex classes + 3 triggers + 11 LWC components (see directory tree); deterministic engine, SLA calculator, CDC subscriber, Queueable/Batch/Schedulable, AI adapters + validator + redactor, action services, Slack adapter, audit.
* 10 test classes + factory (~85 test methods).
* Scripts (`deploy`, `validate`, `run-tests`, `verify-environment`, seed/cleanup/recovery Apex), offline static checker, GitHub workflow, 12 documents.

## Checks actually executed (offline)

| Check | Result |
|---|---|
| All XML files well-formed (`xmllint`) | pass |
| All JSON files valid | pass |
| LWC JavaScript syntax (Node `new Function`, decorators stripped) | pass (0 errors) |
| `scripts/static-check.py`: meta files present, brace/paren balance, no placeholder markers, no hard-coded secrets/Ids, custom field/object names used in Apex exist in metadata, permission-set classes exist | pass (heuristic only) |
| Apex compilation | **not run** |
| Salesforce deployment validation | **not run** |
| Apex tests | **not run - 0 passed, 0 failed, 0 executed** |
| LWC lint / Jest / prettier | **not run** (no npm packages available offline) |

## Not implemented / incomplete (explicit)

* **No Salesforce Flow is shipped.** Escalation can invoke a Flow whose API name you put in `Actions.Escalation_Flow__c` (input variable `caseId`); otherwise it sets `Case.IsEscalated = true`.
* No Named Credential / External Credential metadata is shipped (secrets and org-specific URLs); configure in Setup. The `namedCredentials/` directory from the spec is therefore absent (documented deviation).
* No auto-execution of low-impact actions; they are run by a user (`Run action`). `Execution_Status__c = Executing` is a reserved picklist value (a row lock is used instead).
* Business-hours SLA uses the org's default business hours only. Entitlement/Milestone integration is not implemented (supply `ER_SLA_Deadline__c`).
* No Slack interactive approvals; Slack is outbound only.
* No LWC Jest tests; no screenshots.
* Case-comment-based signal only: "recent communication" = latest published CaseComment (emails are not considered).
* Dashboard shows the first 2,000 rows maximum per filter (SOQL OFFSET limit).
* Audit is application-level, not tamper-evident.

## Manual setup still required

CDC verification; permission set assignment; seed or backfill; `schedule-recovery.apex`; subscriber user config for real credentials; External/Named Credentials for LLM and Slack; reassign queue and optional Flow in `Actions` setting; Case/Account access for users.

## Known risks / defects to expect on first deployment

1. **Compile or metadata errors are likely to exist somewhere** (never compiled). Highest-risk spots: `ER_CDCProcessingService` (change-event header API), `ER_DashboardController` dynamic SOQL, tab `motif` values, layout/permission-set metadata, `platformEventChannelMembers`.
2. `FeatureManagement.checkPermission` is relied on inside Queueable execution (runs as the enqueuing user). If it behaves differently, approved actions end `Failed`.
3. Automated Process user cannot use Named Credential principals; real LLM calls from CDC-driven jobs need a subscriber user.
4. Test assumptions: `Standard User` profile, `ER_Radar_Manager` permission set, CDC test API, queueable-from-batch execution in tests (assertions are intentionally tolerant there).
5. Public Read Only OWD on the custom objects exposes assessment text to any user with object read; see SECURITY.md.
6. Row lock held during the Slack callout can cause `UNABLE_TO_LOCK_ROW` for concurrent attempts (they fail safely).
7. The AI queue chain depth is limited in Developer Edition; leftovers rely on the recovery batch being scheduled.
