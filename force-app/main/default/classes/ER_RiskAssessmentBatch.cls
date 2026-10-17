/**
 * Bounded batch processing.
 *  MODE_INITIAL   - open Cases that have no assessment yet (first-time backfill).
 *  MODE_REPROCESS - all open Cases (after a rule/threshold change, or CDC gap repair).
 *  MODE_RECOVER   - assessments in Error, or AI_Pending whose retry time has arrived.
 * Optional explicit Case Id scope overrides the query for INITIAL/REPROCESS.
 * Scope size is controlled by the caller (50 recommended); only one AI Queueable is enqueued per execute().
 */
public without sharing class ER_RiskAssessmentBatch implements Database.Batchable<SObject> {
    public static final String MODE_INITIAL = 'INITIAL';
    public static final String MODE_REPROCESS = 'REPROCESS';
    public static final String MODE_RECOVER = 'RECOVER';
    @TestVisible
    private static Integer staleAiMinutes = 15;

    private final String mode;
    private final Set<Id> scopeIds;
    private final String correlationId;

    public ER_RiskAssessmentBatch(String mode, Set<Id> scopeIds) {
        this.mode = mode;
        this.scopeIds = scopeIds;
        this.correlationId = ER_Constants.newCorrelationId();
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        if (mode == MODE_RECOVER) {
            Datetime nowTs = Datetime.now();
            Datetime stale = nowTs.addMinutes(-staleAiMinutes);
            String errStatus = ER_Constants.AS_ERROR;
            String aiPending = ER_Constants.AS_AI_PENDING;
            return Database.getQueryLocator([
                SELECT Id, Case__c, Case_Id__c, Assessment_Status__c, Retry_Count__c, Next_Retry_At__c
                FROM Risk_Assessment__c
                WHERE Assessment_Status__c = :errStatus
                   OR (Assessment_Status__c = :aiPending AND
                       ((Next_Retry_At__c != null AND Next_Retry_At__c <= :nowTs) OR (Next_Retry_At__c = null AND Last_Assessed__c <= :stale)))
            ]);
        }
        if (scopeIds != null && !scopeIds.isEmpty()) {
            return Database.getQueryLocator([SELECT Id FROM Case WHERE Id IN :scopeIds AND IsClosed = false]);
        }
        if (mode == MODE_INITIAL) {
            return Database.getQueryLocator([
                SELECT Id FROM Case
                WHERE IsClosed = false AND Id NOT IN (SELECT Case__c FROM Risk_Assessment__c WHERE Case__c != null)
            ]);
        }
        return Database.getQueryLocator([SELECT Id FROM Case WHERE IsClosed = false]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        List<Id> aiIds = new List<Id>();
        Set<Id> caseIds = new Set<Id>();
        if (mode == MODE_RECOVER) {
            for (SObject so : scope) {
                Risk_Assessment__c ra = (Risk_Assessment__c) so;
                if (ra.Assessment_Status__c == ER_Constants.AS_ERROR) {
                    if (ra.Case__c != null) {
                        caseIds.add(ra.Case__c);
                    }
                } else {
                    aiIds.add(ra.Id);
                }
            }
        } else {
            caseIds = new Map<Id, SObject>(scope).keySet();
        }
        if (!caseIds.isEmpty()) {
            ER_CaseRiskService.Outcome out = ER_CaseRiskService.assessCases(caseIds, null, correlationId);
            aiIds.addAll(out.aiCandidateIds);
        }
        ER_RiskAssessmentQueueable.enqueueAi(aiIds, correlationId);
    }

    public void finish(Database.BatchableContext bc) {
        ER_AuditService.logIntegration('BATCH', mode, null, correlationId, 'Success', null, null, 'Batch ' + mode + ' finished.', false, 0);
    }
}
