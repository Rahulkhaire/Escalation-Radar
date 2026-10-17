# Interview preparation

## One-minute explanation

"Escalation Radar detects Cases likely to breach SLA. A Case change arrives through Change Data Capture to an Apex subscriber, which filters and dedupes, then bounded Queueables score the Case with a configurable deterministic engine and upsert an explainable assessment. Optionally an LLM adds a validated, advisory analysis in a separate transaction. The system proposes allowlisted actions; humans approve high-impact ones; execution is revalidated, idempotent and audited. A Platform Event refreshes an LWC dashboard."

## Architecture decisions (and the honest trade-offs)

* **Apex change-event trigger instead of EMP Connector/Pub/Sub client** - no external infrastructure or credentials; trade-off: runs as Automated Process unless configured, limited retry control.
* **Deterministic score + capped AI uplift** - explainable and testable; AI cannot dominate or act. Trade-off: weights are guesses until tuned on real data.
* **One current assessment per Case (upsert by external id)** - idempotent, cheap to query; history is in the audit trail instead of snapshots.
* **Separate propose / approve / execute** - authorization and revalidation at execution time; trade-off: more moving parts.
* **System-mode services with explicit checks, user-mode for customer data** - shows I understand `with sharing` is not the whole story.
* **Text references in audit** - survive deletes; trade-off: no relationship navigation.

## Governor-limit questions

* *Callouts after DML?* Not allowed; AI work is a separate Queueable doing SOQL -> callouts -> DML. Logs/audits are inserted at the end.
* *Callouts from triggers?* None. The CDC trigger only enqueues.
* *Too many Queueables?* Chunks of 100, max 20 per transaction; overflow to Batch; chain only when `System.AsyncInfo.hasMaxStackDepth()` is false; one enqueue per Batch execute.
* *Bulk safety?* One SOQL for Cases, assessments, comments (aggregate); upsert list with partial success; no SOQL/DML in loops (see `scripts/static-check.py`).
* *120 s callout total?* 5 Cases per AI job, <= 20 s timeout.
* *Row locks?* `FOR UPDATE` on actions; it is held across the Slack callout - a deliberate trade-off to block duplicate execution.

## AI design questions

* *Prompt injection?* Case text is data inside a delimited JSON object, a system prompt says so, the output schema is strict, actions are intersected with an allowlist, and nothing is auto-executed. I would not claim this is injection-proof - the cap and human approval are the real controls.
* *Why not let the LLM score?* Non-determinism, cost, explainability, auditability.
* *Hallucinations?* Advisory fields are labelled; invalid schema is rejected; uplift needs confidence >= 0.5 and is capped.
* *PII?* Regex redaction + minimisation; I state its limits.

## Security questions

* Enforcing authorization server-side (custom permission, row lock, state, Case access, separation of duties) - UI hiding is cosmetic.
* Why read-only permission sets for custom objects (prevent editing approval fields).
* Why `Case__c IN (SELECT Id FROM Case)` in queries (parent sharing).
* What audit immutability I did *not* achieve.

## Integration questions

Named/External Credentials, who the async user is (Automated Process vs integration user), 429/5xx handling and backoff, mocks via `HttpCalloutMock`, disable switches.

## Honest discussion of AI-assisted development

State plainly: this project was generated with an AI assistant from a detailed specification. The assistant could not compile Apex or deploy in its sandbox, so correctness was reviewed by reading and static checks only; I (the developer) must deploy, run the tests, fix issues, and be able to explain every class. Prepare by: reading each service, running the tests in your org, changing a weight and observing the effect, breaking the LLM credential on purpose, and being able to say which parts you verified yourself. Do not present unverified behaviour (for example, a running CDC pipeline) as proven.
