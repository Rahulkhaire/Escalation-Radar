# Changelog

## 1.0.1 - fixes from the first real deployment attempt

The first deploy to a Developer Edition org (reported by the user) failed with 29 errors. Root causes fixed:
* `commit` and `end` are reserved identifiers in Apex: renamed to `commitNum` / `endIdx` (`ER_CaseRiskService`, `ER_CDCProcessingService`, `ER_CDCProcessingServiceTest`). Also renamed `type`, `search`, `offset`, `all` identifiers defensively (LWC filter key `search` is now `searchText`).
* `Decimal.multiply` is not visible to Apex: replaced with `*` in `ER_SlaCalculator`.
* `ER_Radar_Admin`: Salesforce requires Edit permission together with Delete on `Integration_Log__c`; Edit is now granted there (Integration Log only).
* All other errors (invalid dependent classes, missing `ER_DashboardController`, missing trigger dependency) were cascades of the above.
* `scripts/static-check.py` now flags reserved identifiers.
Still unverified: the project has not yet been confirmed to deploy or pass tests; further compile errors may appear once these are cleared.

## 1.0.0 - initial release (unverified in an org)

* Salesforce DX project, API 62.0.
* Data model: `Risk_Assessment__c`, `Escalation_Action__c`, `Escalation_Audit__c`, `Integration_Log__c`, platform event `ER_Risk_Update__e`,
  Custom Metadata `ER_Risk_Config__mdt`, `ER_Risk_Factor_Map__mdt`, `ER_Integration_Setting__mdt`; Case fields `ER_SLA_Deadline__c`, `ER_Reopen_Count__c`; Account field `ER_Account_Tier__c`.
* Deterministic scoring engine, SLA calculator, CDC trigger + processing service, Queueable and Batch workers, recovery schedulable.
* AI adapters (Mock, LLM via Named Credential), response validator, PII redactor, retry/backoff and fallback.
* Action recommendation, approval, execution services; Slack adapter; audit and integration logging.
* LWC dashboard with 10 child components.
* Permission sets (`ER_Radar_Viewer`, `ER_Radar_Manager`, `ER_Radar_Admin`), custom permissions, app, tabs, layouts.
* 10 Apex test classes, test data factory, scripts, offline static checker, CI workflow, documentation set.
* Known: nothing in this release has been compiled, deployed or executed; see `docs/IMPLEMENTATION_STATUS.md`.
