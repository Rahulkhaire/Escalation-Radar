# 5-minute interview demo

Prerequisites: deployed, `ER_Radar_Manager` assigned, demo data seeded, AI provider `MOCK`, a **second user** who will "request" actions is not needed (automation is the requester).
Rehearse once first; the project has not been run by its author.

## Script

| Time | Do | Say |
|---|---|---|
| 0:00 | Open **Escalation Radar** app | "Support leaders need to see which Cases are about to breach SLA and why, not just a list." |
| 0:30 | Point at KPIs and the risk distribution; click the CRITICAL bar | "Scoring is deterministic: five weighted factors from Custom Metadata, max 100, thresholds configurable." |
| 1:15 | Open *Details* on the outage case | "Every point is explained: SLA 9x% consumed, High priority, Strategic tier. The rule version is stored with the score." |
| 2:00 | Show the AI panel | "AI is advisory: validated JSON, capped uplift, labelled estimates. Mock provider here; the same interface calls an LLM through a Named Credential." |
| 2:45 | Approval queue: approve `REASSIGN_CASE` (queue configured) or `SEND_SLACK_ALERT` (mock) | "The model proposes, a human approves, a separate service executes after revalidating permissions and Case state." |
| 3:30 | Audit history | "Application-level audit trail; I would not call it tamper-evident." |
| 4:00 | Edit a Case priority to High in another tab | "CDC -> Apex subscriber -> Queueable -> upsert -> Platform Event -> the dashboard refreshes. Events are at-least-once, so the UI refetches truth." |
| 4:30 | Health panel | "Failures are visible and recoverable." |

## Scenarios and expected results

1. **Outage case** (High, Strategic, SLA deadline in 30 min): CRITICAL or HIGH; AI mock urgency HIGH; proposed Review, Escalate (approval), Draft, Slack (if enabled).
2. **Invoice sync** (High, Enterprise, public comment present): HIGH; fresher communication lowers the age/communication factor.
3. **Reopened report case**: reopen factor > 0 (the seed closes and reopens it).
4. **Low-priority training question** (Basic tier, no SLA): LOW, no actions.
5. **Escalated shipment case**: `IsEscalated` forces full priority points.
Exact numbers depend on when you seed (age and SLA move with time).

## Failure recovery demonstration

1. Set the AI setting to `LLM` with a bad Named Credential (or an unreachable model) and reprocess: `sf apex run --file scripts/run-reprocess.apex`.
2. Show: assessment still scored; status `AI_Pending` with a retry time, then `AI_Failed` after 3 attempts; Integration Log rows with HTTP codes; audit `AI_FAILED`/`RETRY_SCHEDULED`.
3. Fix the setting back to `MOCK`, click **Retry failed AI analyses** (or run the recovery batch): status becomes `Enriched`.
4. Double-approve an action from two browser tabs: the second attempt is rejected as already decided.
