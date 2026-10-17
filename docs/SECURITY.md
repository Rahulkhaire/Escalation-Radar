# Security

## Permissions

| Permission set | Objects | Notes |
|---|---|---|
| ER_Radar_Viewer | read: RA, EA, Audit, Integration Log, ER_Risk_Update__e; FLS read | tabs, app, `ER_DashboardController` |
| ER_Radar_Manager | same + custom permissions `ER_Approve_Actions`, `ER_Execute_Actions`; edit `Case.ER_SLA_Deadline__c` | still **no** create/edit/delete on app objects |
| ER_Radar_Admin | manager + edit `Account.ER_Account_Tier__c`, delete Integration Logs | configuration is edited via Custom Metadata (Customize Application) |

Nobody receives create/edit on assessments, actions or audit rows through permission sets; only Apex services write them. This prevents a manager from editing `Approval_Status__c` in the record UI.
Prerequisite not granted here: read access to Case/Account (and edit on Case for actions that modify cases) comes from your profile or other permission sets.

## Sharing and record access

Custom objects: Public Read Only internal / Private external. Dashboard queries add `Case__c IN (SELECT Id FROM Case)` so only Cases the user can see are returned (a lookup alone would leak parent fields). Audit history requires visibility of the Case first.
Note: Public Read Only means any internal user with the object permission can read assessments via reports/APIs, which expose the AI summary text; tighten the OWD to Private plus sharing rules if that is not acceptable.

## CRUD/FLS and system context

* User mode: dashboard reads (`WITH USER_MODE`, `Database.queryWithBinds(..., AccessLevel.USER_MODE)`), Case visibility checks, and Case/CaseComment/Task DML in actions (`insert/update as user`).
* System mode (documented `without sharing` classes): CDC processing, Queueable/Batch assessment, AI analysis persistence, recommendation, approval/execution state, audit/log writes, event publishing, and one privileged requeue helper in the controller (only after a permission check and over IDs the caller can already see).
* `FeatureManagement.checkPermission` backs approval and execution authorization. The LWC hides buttons for convenience only; the server enforces every check (and tests cover unauthorized attempts).

## Approval and execution controls

Custom permission to decide; row lock + state check (replay-safe); Case access in user mode; separation of duties (requester cannot approve own proposal); closed Cases cannot be approved; execution re-checks type allowlist, approval state, executor permission and Case state; reassignment only to the single queue configured in Custom Metadata (and it must support Cases); escalation only through the configured Flow name or `IsEscalated`.

## AI safety

* Case text is untrusted data: wrapped in a `case_data` JSON object, system prompt states it must never be followed, output must be a strict JSON schema.
* Output is validated, length-capped and allowlisted; proposals are suggestions; AI cannot modify fields, build queries, or run Apex.
* Impact limited by design: bounded uplift (default max 5 points); deterministic score stored separately; humans approve high-impact actions.
* Data minimisation: no customer/contact names; regex redaction of e-mail, phone, card-like numbers, SSN-like ids and URLs; length limits. **Redaction is best-effort**: free text can still contain names or secrets. Do not enable a real LLM for data you may not send to that provider.
* Residual risk: a sufficiently deceptive comment could still bias the summary or the urgency (and thereby the capped uplift). Mitigations are human review and the cap.

## Secret management

No secrets in source, labels, Custom Metadata, docs or tests. Keys and webhook URLs belong in External/Named Credentials. `.gitignore` excludes `.env`, `*.key`, `*.pem`, `*.sfdx-auth-url`. `scripts/static-check.py` scans for hard-coded secrets and record Ids (heuristic).

## Audit limitations

`Escalation_Audit__c` is an **application-level audit trail**: read/create permissions only, plus `ER_AuditProtectionTrigger` that rejects update/delete. It is **not tamper-evident or legally immutable**: a user with Customize Application or Modify All Data can disable the trigger or alter data; there is no hashing, signing or external WORM storage. For compliance-grade immutability use Shield Field Audit Trail / event monitoring export to an external immutable store.
Audit and log text avoids secrets and raw comment bodies (AI summaries are stored on the assessment, not in the audit).

## Other

Error messages shown to users are generic except for business-rule messages; stack traces go to debug logs only. Dynamic SOQL uses bind variables and a sort allowlist.
