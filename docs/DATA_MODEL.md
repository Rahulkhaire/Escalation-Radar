# Data model

All custom objects use **Public Read Only** internal / **Private** external sharing. Users receive **read-only** object and field permissions through
permission sets; all writes happen in Apex services that run in system context after explicit checks. The dashboard restricts every query to Cases
the user can see (`Case__c IN (SELECT Id FROM Case)`) because lookup traversal alone does not apply parent sharing.
Required fields are avoided so field-level security can be granted uniformly. Field API names below are the exact names used in Apex, LWC and tests.

## Risk_Assessment__c (RA-{00000}) - current assessment, one per Case

Purpose: latest deterministic score, factor breakdown and optional AI enrichment. History lives in `Escalation_Audit__c`.
Relationships: `Case__c` Lookup(Case, set null on delete). Unique external id: `Case_Id__c` (Text 18) - used for upsert (idempotency).

| Field | Type | Notes |
|---|---|---|
| Case__c | Lookup(Case) | |
| Case_Id__c | Text(18), unique, external id | key for upsert |
| Risk_Score__c / Deterministic_Score__c / AI_Uplift__c | Number | final = deterministic + capped uplift |
| Risk_Category__c | Picklist | LOW, MEDIUM, HIGH, CRITICAL |
| Assessment_Status__c | Picklist | Scored, AI_Pending, Enriched, AI_Failed, Error, Inactive |
| Rule_Version__c | Text(40) | from `ER_Risk_Config__mdt.Version__c` |
| Factors_JSON__c | Long text | per-factor key, label, points, maxPoints, detail, source |
| Explanation__c | Long text | human-readable reasons |
| SLA_Consumption_Pct__c, SLA_Deadline__c | Number, DateTime | effective SLA used |
| Retry_Count__c, Next_Retry_At__c, Last_Error__c | | AI retry state |
| Last_Assessed__c, Last_Commit_Number__c, Correlation_Id__c | | idempotency + tracing |
| AI_Provider__c, AI_Summary__c, AI_Risk_Explanation__c, AI_Urgency__c, AI_Sentiment__c, AI_Root_Causes__c, AI_Next_Steps__c, AI_Suggested_Update__c, AI_Confidence__c, AI_Proposed_Actions__c, AI_Completed_At__c | | validated AI output only |

## Escalation_Action__c (EA-{00000})

Purpose: one proposed intervention with separate approval and execution state. Lookups: `Case__c`, `Risk_Assessment__c`, `Requested_By__c` (User), `Approved_By__c` (User).
Fields: `Action_Type__c` (restricted picklist of the six allowlisted ids), `Reason__c`, `Evidence__c`, `Draft_Text__c`, `Target_Queue__c`, `Risk_Score_At_Proposal__c`,
`Risk_Category_At_Proposal__c`, `Source__c` (Rules/AI), `AI_Assessment_Ref__c`, `Requires_Approval__c`, `Approval_Status__c` (Not_Required/Pending/Approved/Rejected),
`Decision_Date__c`, `Decision_Comment__c`, `Execution_Status__c` (Not_Started/Executing/Succeeded/Failed/Skipped), `Execution_Date__c`, `Failure_Details__c`, `Correlation_Id__c`.
(`Executing` is reserved in the picklist; the current implementation holds a row lock instead of persisting that state.)

## Escalation_Audit__c (AUD-{000000}) and Integration_Log__c (IL-{000000})

Audit uses **text** references (`Case_Id__c`, `Assessment_Id__c`, `Action_Id__c`, `Actor_Id__c`) so rows survive deletion of the referenced records. Fields: `Event_Type__c`, `Outcome__c`, `Rule_Version__c`,
`Score__c`, `Retry_Count__c`, `Correlation_Id__c`, `Details__c`. Updates and deletes are blocked by `ER_AuditProtectionTrigger`.
Integration log: `Integration__c` (AI/SLACK/CDC/BATCH), `Operation__c`, `Case_Id__c`, `Correlation_Id__c`, `Status__c`, `HTTP_Status__c`, `Duration_Ms__c`, `Error_Message__c`, `Retryable__c`, `Retry_Count__c`.

## Platform event ER_Risk_Update__e

`Case_Id__c`, `Assessment_Id__c`, `Risk_Score__c`, `Risk_Category__c`, `Assessment_Status__c`, `Correlation_Id__c`. High-volume, publish-after-commit.

## Standard object additions

`Case.ER_SLA_Deadline__c` (DateTime, supplied SLA deadline), `Case.ER_Reopen_Count__c` (Number, maintained by `ER_CaseTrigger`), `Account.ER_Account_Tier__c` (Strategic/Enterprise/Standard/Basic).

## Custom Metadata Types

* `ER_Risk_Config__mdt` (record `Default`): `Version__c`, five `Weight_*__c`, `Threshold_Medium/High/Critical__c`, `SLA_Ramp_Start_Pct__c`, `SLA_Hours_High/Medium/Low__c`, `SLA_Use_Business_Hours__c`, `Age_Cap_Hours__c`, `Stale_Update_Hours__c`, `Reopen_Cap__c`, `Approval_Required_Actions__c`.
  The shipped values (35/20/15/15/15; thresholds 25/50/75; SLA hours 8/24/72) are **examples, not validated business rules**.
  If the record is missing, `ER_Config` falls back to the same example values.
* `ER_Risk_Factor_Map__mdt`: `Factor__c` (Priority | AccountTier), `Key__c`, `Fraction__c` (0-1).
* `ER_Integration_Setting__mdt` (records `AI`, `Slack`, `Actions`): see API_AND_INTEGRATIONS.md.

## Indexing

Indexed by default: Ids, lookups, the unique external id `Case_Id__c`, `Name`, `CreatedDate`. No custom indexes were requested; at high volume ask Salesforce Support to index
`Assessment_Status__c` / `Risk_Score__c` if dashboard queries become selective-filter bound.

## Example records

`Risk_Assessment__c`: Case_Id__c=`500...`, Deterministic_Score__c=64.0, AI_Uplift__c=5.0, Risk_Score__c=69.0, Risk_Category__c=HIGH, Rule_Version__c=`1.0.0-example`,
Factors_JSON__c=`[{"key":"SLA","label":"SLA consumption","points":28.0,"maxPoints":35.0,"detail":"SLA is 90.0% consumed (SUPPLIED_DEADLINE).","source":"DETERMINISTIC"}, ...]`.
`Escalation_Action__c`: Action_Type__c=`REASSIGN_CASE`, Requires_Approval__c=true, Approval_Status__c=`Pending`, Execution_Status__c=`Not_Started`.
