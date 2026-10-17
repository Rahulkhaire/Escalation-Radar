# Event subscriber

## What is implemented

Escalation Radar uses the **Salesforce-native Apex subscriber**: the trigger
`force-app/main/default/triggers/ER_CaseChangeTrigger.trigger` subscribes to `CaseChangeEvent`
(Change Data Capture) and delegates to `ER_CDCProcessingService`. No external client and no
EMP Connector are required. The channel member that enables CDC for Case is deployed as
`platformEventChannelMembers/ChangeEvents_CaseChangeEvent.platformEventChannelMember-meta.xml`.

Operational facts (verify them in your org):

* An Apex change-event trigger runs asynchronously, after the originating transaction commits, as the
  **Automated Process** user by default (configurable with a `PlatformEventSubscriberConfig`, not shipped).
* Events are delivered in batches (default up to 2,000); the trigger resumes from a checkpoint
  (`setResumeCheckpoint`) and retries transient failures with `EventBus.RetryableException`
  (limit configured in `ER_CDCProcessingService.maxTriggerRetries`).
* Change events are retained about 3 days. If a subscriber is suspended or falls behind, gaps are
  delivered as `GAP_*` events (handled) or `GAP_OVERFLOW` (handled by a full reprocess batch).
* Daily and hourly platform event delivery allocations apply (see Salesforce docs for your edition).
* Developer Edition can enable CDC for a limited number of entities; Case uses one of them.

## What is *not* implemented

An external streaming client (EMP Connector, Pub/Sub API gRPC client, CometD) is **not** included, because the
requirement is met natively and an external client would add credentials, hosting and failure modes.
If you later need to consume `/data/CaseChangeEvent` or `/event/ER_Risk_Update__e` from outside Salesforce,
use the Pub/Sub API (https://developer.salesforce.com/docs/platform/pub-sub-api/overview), store the last
`replayId` durably, and treat delivery as at-least-once.

## Dashboard subscription

The LWC subscribes to `/event/ER_Risk_Update__e` with `lightning/empApi` (replay `-1`, new events only).
Events are only a hint to refetch; missed events are tolerated because the user can refresh, the component
shows a stale-data banner after 5 minutes or when the subscription errors, and every refresh reads current
state from Salesforce.
