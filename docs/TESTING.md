# Testing

> **No test has been executed by the author's tooling.** The numbers below describe what exists, not results.

## Commands

```bash
sf apex run test --target-org escalation-radar-dev --test-level RunLocalTests --wait 30      # all tests
sf apex run test --target-org escalation-radar-dev --class-names ER_RiskScoringEngineTest --wait 10   # one class
scripts/run-tests.sh escalation-radar-dev        # with --code-coverage, results in ./test-results
scripts/validate.sh escalation-radar-dev         # offline checks + check-only deployment with local tests
python3 scripts/static-check.py                  # offline structure/hygiene checks (no org)
```

## Unit tests (Apex)

10 test classes + `ER_TestDataFactory`; no `SeeAllData`; HTTP via `HttpCalloutMock`; AI via `StubProvider` or the mock provider; configuration via `ER_Config` test overrides.

| Class | Covers |
|---|---|
| ER_RiskScoringEngineTest | max score 100, empty input, SLA ramp, category boundaries (24.9/25/49.9/50/74.9/75), reopen/priority/tier/escalation, age+staleness, SLA calculator sources |
| ER_CaseRiskServiceTest | scoring + stored factors/rule version/SLA %, AI-pending marking, idempotent reprocessing, commit numbers, closed/deleted -> Inactive, tier change, null fields, 200-Case bulk, reopen counter trigger |
| ER_CDCProcessingServiceTest | relevant vs ignored changes, delete/undelete/gap/overflow, duplicate commits, queueable dispatch, overflow to batch, real `CaseChangeEvent` via `Test.enableChangeDataCapture()` |
| ER_AIResponseValidatorTest, ER_LLMProviderTest | schema validation, enum/allowlist, injected instructions, redaction, HTTP 200/429/503/401, timeout, malformed body, missing config, mock determinism |
| ER_AIAnalysisServiceTest | success + capped uplift, uplift rules, retry backoff, retry limit, invalid output, disabled fallback, unexpected exception, queueable chunking, recovery batch |
| ER_ActionServicesTest | approve+execute+audit, replay, reject, unauthorized, separation of duties, closed Case, execution without approval, duplicate execution, missing execute permission, reassignment allowlist + success, Slack success/429/disabled/mock/timeout, recommendation allowlist, approval gating, de-duplication, cooldown after rejection |
| ER_RiskAssessmentBatchTest | INITIAL, REPROCESS idempotency, RECOVER, explicit scope, schedulable |
| ER_DashboardControllerTest | KPIs, filter/search/sort/page, sort-injection fallback, detail factors, approval queue flow, unauthorized users, run action, audit/health, retry-failed, reassess, safe errors |
| ER_AuditAndEventTest | audit immutability trigger, truncation, integration log, event publication |

~85 test methods, ~260 assertion calls.

## What cannot be fully tested in Apex (verify in the org)

* Real CDC delivery latency, subscriber user, replay/resume checkpoint behaviour, `GAP_*` events (only plan logic and one synthetic delivery are tested).
* LWC rendering, `lightning/empApi` subscription, keyboard navigation and accessibility.
* Named/External Credential authentication, real LLM/Slack responses, certificate/IP restrictions.
* `FeatureManagement.checkPermission` inside Queueable jobs (tests rely on it; verify with a real approver).
* Flow-based escalation (`Escalation_Flow__c`), business-hours SLA, Queue assignment rules, Entitlements.
* Queueable chaining depth in production vs the test limit; governor behaviour at real volume; platform event allocations.
* Coverage percentage (unknown until run; target >= 85% on non-test classes).

## Manual validation checklist

1. Deploy, assign permission set, seed data; KPIs show 8 cases; distribution populated.
2. Change a Case priority; within ~1 minute the assessment and event-driven refresh update (CDC working).
3. Open a case detail: each factor shows points; AI panel labelled advisory; actions listed.
4. Approve a reassignment (configure a queue first); verify owner changed, audit events, Integration Log; try approving again (rejected).
5. Log in as a viewer: approve buttons hidden **and** a direct Apex call is rejected.
6. Break the LLM (wrong credential): AI fails, retry scheduled, score still present; run recovery.
7. Disable AI and Slack: dashboard still works.
8. Run reprocess twice: still one assessment per Case.

## Known limitations

No LWC Jest tests; no UI automation; no load test. Test data relies on the `Standard User` profile and the shipped permission sets existing in the org.
