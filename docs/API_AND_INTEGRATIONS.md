# APIs and integrations

## Configuration (`ER_Integration_Setting__mdt`, records AI / Slack / Actions)

| Field | AI | Slack | Actions |
|---|---|---|---|
| Enabled__c | master switch | master switch | (unused) |
| Provider__c | `MOCK`, `LLM`, `NONE` | `SLACK`, `MOCK` | - |
| Named_Credential__c | developer name, e.g. `ER_LLM` | e.g. `ER_Slack` | - |
| Endpoint_Path__c | `/v1/messages` | blank | - |
| Model__c | model id | - | - |
| Timeout_Ms__c, Max_Payload_Chars__c, Max_Tokens__c, Max_Retries__c | yes | timeout | - |
| Min_Score__c / Max_Uplift__c | AI threshold / cap | - | - |
| Min_Category__c | - | alert threshold | - |
| Reassign_Queue__c, Escalation_Flow__c | - | - | queue developer name; Flow API name |

**No secrets in Custom Metadata.** Keys and webhook URLs live only in External/Named Credentials. Disabling AI (`Enabled__c` false or provider `NONE`) or Slack leaves the core product working.

## LLM provider

* Callout: `POST callout:<Named_Credential__c><Endpoint_Path__c>`, headers `Content-Type: application/json`, `anthropic-version: 2023-06-01` (non-secret; the API key header is injected by the credential). Timeout from settings (1-120 s).
* Request body (Messages-style):
```json
{"model":"<Model__c>","max_tokens":800,"system":"<fixed system prompt>",
 "messages":[{"role":"user","content":"case_data:\n{\"priority\":\"High\",\"account_tier\":\"Strategic\",\"deterministic_score\":64.0,\"risk_category\":\"HIGH\",\"deterministic_factors\":\"...\",\"subject\":\"...\",\"description\":\"...\",\"recent_public_comments\":[\"...\"]}"}]}
```
* Expected response envelope: `{"content":[{"type":"text","text":"<JSON object below>"}]}`. For a different provider (e.g. an OpenAI-compatible chat API), change `buildBody` and `extractText` only; everything downstream is provider-agnostic.
* The model text must be **one JSON object**:
```json
{"summary":"...","risk_explanation":"...","urgency":"LOW|MEDIUM|HIGH","sentiment":"NEGATIVE|NEUTRAL|POSITIVE|UNKNOWN",
 "root_causes":["PRODUCT_DEFECT|CONFIGURATION|INTEGRATION|PERFORMANCE|DATA_QUALITY|ACCESS_PERMISSIONS|TRAINING|BILLING|OTHER"],
 "next_steps":["..."],"suggested_customer_update":"...","confidence":0.0,
 "proposed_actions":["DRAFT_CUSTOMER_UPDATE|REASSIGN_CASE|REQUEST_MANAGER_REVIEW|ESCALATE_CASE|SEND_SLACK_ALERT|ADD_INTERNAL_NOTE"]}
```
Validation (`ER_AIResponseValidator`): required `summary`, `risk_explanation`, `urgency`, `sentiment`; enums upper-cased and checked; lengths capped; `confidence` 0-1; `root_causes` and `proposed_actions` intersected with allowlists (unknown values silently dropped); Markdown code fences tolerated; anything else rejected.

## Error handling and rate limits

| Condition | Result |
|---|---|
| CalloutException (timeout/network) | retryable |
| HTTP 429 | retryable (backoff; `Retry-After` is not parsed for the LLM, it is reported for Slack) |
| HTTP 5xx | retryable |
| HTTP 4xx other | not retryable (check credentials/model) |
| Empty/malformed/invalid JSON or schema violation | not retryable; `AI_Failed`, deterministic result stands |
Retries: `Max_Retries__c` total attempts (default 3), delay 5, 10, 20 minutes (`retryBaseMinutes`). Retries execute when the recovery batch runs (schedule it). Every attempt writes an `Integration_Log__c` row (status, HTTP code, duration, safe message) and audit events. Callout limits: at most 5 callouts per AI job; Apex callout timeout max 120 s per call and cumulative 120 s per transaction, so keep `Timeout_Ms__c` <= 20000.

## Slack

`POST callout:<Named_Credential__c>` with `{"text":"Escalation Radar: Case 00001234 is HIGH risk (score 66.0). <redacted subject> <record link>"}`. 2xx = success; 429 and 5xx are recorded as retryable failures (the action ends `Failed`; re-propose happens after the cooldown or a risk-category increase); others not retryable. Subject text is redacted and truncated. `Provider__c = MOCK` writes a log row and makes no call.

## Mock providers

`ER_MockAIProvider` produces deterministic analyses from keywords (outage, cancel, frustrat, integration...). `ER_TestDataFactory.StubProvider` is a test double. All tests use `HttpCalloutMock` or stubs; none call live services.

## Platform Event schema

`ER_Risk_Update__e`: Case_Id__c, Assessment_Id__c, Risk_Score__c, Risk_Category__c, Assessment_Status__c, Correlation_Id__c. Delivery: at-least-once, retained ~72 hours for replay by external subscribers, per-edition allocation limits apply. The LWC subscribes with replay -1 and treats events as refetch hints.
