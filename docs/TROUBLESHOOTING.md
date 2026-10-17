# Troubleshooting

## Deployment errors

| Symptom | Likely cause / fix |
|---|---|
| `Invalid type: CaseChangeEvent` / trigger does not save | CDC is not enabled for Case. Deploy the channel member or enable Case in Setup > Change Data Capture, then redeploy the trigger. |
| Field/object not found in Apex | metadata deployed out of order; redeploy whole `force-app`. |
| `Unknown field ... ER_*` on Case/Account | `objects/Case/fields` and `objects/Account/fields` were not deployed (check `.forceignore`). |
| Tab/app errors about `motif` | change the `<motif>` value in `tabs/*.tab-meta.xml` to any valid icon (e.g. `Custom20: Telephone`) - values are not verified against every release. |
| Permission set error: field cannot have permissions | a field became required; remove its `fieldPermissions` block. |
| Custom Metadata record errors | check `customMetadata/*.md-meta.xml` field names match field metadata. |
| Compile errors in Apex | the code was **not compiled by its author**. Fix as reported; common candidates: ternary type mixing, SOQL bind syntax, `EventBus.ChangeEventHeader` member names. Please report fixes in CHANGELOG. |

## Missing permissions

Dashboard says "You do not have access": assign `ER_Radar_Viewer/Manager`, and ensure Case/Account read access. Approve button missing: the Manager set (custom permission `ER_Approve_Actions`) is not assigned. "Not authorised" on approval from API/Apex: same permission.
Tabs missing: assign the permission set; check the app is visible.

## CDC subscription issues

* No assessments appear after changing a Case: check Setup > Change Data Capture lists Case; Setup > Apex Triggers > `ER_CaseChangeTrigger` active; check Integration Logs (`CDC` entries); run `scripts/run-initial-assessment.apex` as a fallback.
* The subscriber runs as Automated Process by default. To run it as a specific user (needed for Named Credential principal access), deploy a `PlatformEventSubscriberConfig` (template below; **unverified**, check metadata docs for your API version):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<PlatformEventSubscriberConfig xmlns="http://soap.sforce.com/2006/04/metadata">
    <batchSize>200</batchSize>
    <masterLabel>ER Case Change Subscriber</masterLabel>
    <platformEventConsumer>ER_CaseChangeTrigger</platformEventConsumer>
    <user>integration.user@yourorg.example</user>
</PlatformEventSubscriberConfig>
```
* Trigger suspended after repeated failures: fix the cause, then resume in Setup > Apex Triggers (suspended-state indicator).
* Gaps: `GAP_*` events are handled; for a long outage (> 3 days) run `run-reprocess.apex`.

## API authentication errors

HTTP 401/403 in Integration Logs: check the External Credential principal, the header formula, **principal access in a permission set assigned to the running user** (Automated Process user cannot get one - use a subscriber user), and the Named Credential URL. HTTP 404: wrong `Endpoint_Path__c`/model.

## Callout failures

"You have uncommitted work pending": DML before a callout - only if code is changed; the shipped design avoids it. Timeouts: reduce payload (`Max_Payload_Chars__c`) or raise `Timeout_Ms__c` (max 120000 per callout, 120 s cumulative). "Unauthorized endpoint": Named Credential missing or name differs from `Named_Credential__c`.

## LWC runtime errors

Blank dashboard: open the browser console; check Apex class access (`ER_DashboardController` in the permission set) and that the Apex methods are deployed. "Live updates unavailable": the user lacks read on `ER_Risk_Update__e`, or the org has empApi restrictions; use Refresh. `lightning-datatable` URL column: ensure `caseUrl` column works with Lightning navigation in your site type.

## Test failures

* `MIXED_DML_OPERATION`: wrap user/permission-set setup in `System.runAs(new User(Id = UserInfo.getUserId()))` (already done in the shipped tests).
* Tests that assign `ER_Radar_Manager` fail if the permission set is not deployed.
* `Standard User` profile missing: change `ER_TestDataFactory.user`.
* Tests involving `Test.enableChangeDataCapture()` require CDC support in the org.
* A failing assertion on exact numbers (e.g. SLA %): timing-sensitive; widen the range.
* If `FeatureManagement.checkPermission` returns false inside a Queueable in tests, execution tests will report Failed - see IMPLEMENTATION_STATUS "Risks".
