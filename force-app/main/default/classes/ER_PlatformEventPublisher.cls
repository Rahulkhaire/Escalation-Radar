/**
 * Publishes ER_Risk_Update__e. The event is defined with PublishAfterCommit, so subscribers
 * are only notified if the surrounding transaction commits. Delivery is at-least-once and
 * not ordered across subscribers; the dashboard treats events as a hint to refetch.
 */
public without sharing class ER_PlatformEventPublisher {
    public static Integer publish(List<Risk_Assessment__c> assessments) {
        if (assessments == null || assessments.isEmpty()) {
            return 0;
        }
        List<ER_Risk_Update__e> events = new List<ER_Risk_Update__e>();
        for (Risk_Assessment__c a : assessments) {
            events.add(new ER_Risk_Update__e(
                Case_Id__c = a.Case_Id__c,
                Assessment_Id__c = a.Id == null ? null : String.valueOf(a.Id),
                Risk_Score__c = a.Risk_Score__c,
                Risk_Category__c = a.Risk_Category__c,
                Assessment_Status__c = a.Assessment_Status__c,
                Correlation_Id__c = a.Correlation_Id__c
            ));
        }
        List<Database.SaveResult> results = EventBus.publish(events);
        Integer ok = 0;
        for (Database.SaveResult r : results) {
            if (r.isSuccess()) {
                ok++;
            } else {
                System.debug(LoggingLevel.ERROR, 'ER platform event publish failed: ' + r.getErrors()[0].getMessage());
            }
        }
        return ok;
    }
}
