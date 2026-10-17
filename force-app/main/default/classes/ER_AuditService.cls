/**
 * Writes application-level audit and integration-log rows.
 * Runs in system context (without sharing) on purpose: end users only have read access to
 * audit data, so only this class (and other ER services) can create it.
 * Never pass secrets or raw case comment bodies as details.
 */
public without sharing class ER_AuditService {
    public class Entry {
        public String eventType;
        public String caseId;
        public String assessmentId;
        public String actionId;
        public String actorId;
        public String outcome = ER_Constants.OUTCOME_INFO;
        public String ruleVersion;
        public Decimal score;
        public Integer retryCount;
        public String correlationId;
        public String details;
    }

    public static Entry entry(String eventType, Id caseId, String correlationId) {
        Entry e = new Entry();
        e.eventType = eventType;
        e.caseId = caseId == null ? null : String.valueOf(caseId);
        e.correlationId = correlationId;
        e.actorId = String.valueOf(UserInfo.getUserId());
        return e;
    }

    public static void log(List<Entry> entries) {
        if (entries == null || entries.isEmpty()) {
            return;
        }
        List<Escalation_Audit__c> rows = new List<Escalation_Audit__c>();
        for (Entry e : entries) {
            rows.add(new Escalation_Audit__c(
                Event_Type__c = e.eventType,
                Case_Id__c = e.caseId,
                Assessment_Id__c = e.assessmentId,
                Action_Id__c = e.actionId,
                Actor_Id__c = e.actorId,
                Outcome__c = e.outcome,
                Rule_Version__c = e.ruleVersion,
                Score__c = e.score,
                Retry_Count__c = e.retryCount,
                Correlation_Id__c = e.correlationId,
                Details__c = truncate(e.details, 4000)
            ));
        }
        List<Database.SaveResult> results = Database.insert(rows, false);
        for (Database.SaveResult r : results) {
            if (!r.isSuccess()) {
                // Audit failure must not break business processing; surface in debug logs only.
                System.debug(LoggingLevel.ERROR, 'ER audit insert failed: ' + r.getErrors()[0].getMessage());
            }
        }
    }

    public static void log(Entry e) {
        log(new List<Entry>{ e });
    }

    public static void logIntegration(
        String integration,
        String operation,
        Id caseId,
        String correlationId,
        String status,
        Integer httpStatus,
        Long durationMs,
        String errorMessage,
        Boolean retryable,
        Integer retryCount
    ) {
        insert new Integration_Log__c(
            Integration__c = integration,
            Operation__c = operation,
            Case_Id__c = caseId == null ? null : String.valueOf(caseId),
            Correlation_Id__c = correlationId,
            Status__c = status,
            HTTP_Status__c = httpStatus,
            Duration_Ms__c = durationMs,
            Error_Message__c = truncate(errorMessage, 2000),
            Retryable__c = retryable,
            Retry_Count__c = retryCount
        );
    }

    public static String truncate(String s, Integer max) {
        if (s == null) {
            return null;
        }
        return s.length() <= max ? s : s.substring(0, max);
    }
}
