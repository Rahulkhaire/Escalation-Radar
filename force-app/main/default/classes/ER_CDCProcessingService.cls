/**
 * Processes CaseChangeEvent batches delivered to the Apex trigger ER_CaseChangeTrigger (a real, supported
 * Salesforce-native CDC subscriber). Responsibilities: filter risk-relevant changes, collapse duplicates,
 * skip already-applied commits, and hand work to Queueable/Batch jobs. No callouts here.
 *
 * Operational constraints: the trigger runs asynchronously as the Automated Process user (or the user configured
 * in PlatformEventSubscriberConfig), delivers up to 2,000 events per batch, and supports resume checkpoints and
 * retries via EventBus.TriggerContext. Events are retained for 3 days; older gaps are repaired by the reconciliation batch.
 */
public without sharing class ER_CDCProcessingService {
    public class ChangeInput {
        public String changeType;
        public List<String> recordIds = new List<String>();
        public Set<String> changedFields = new Set<String>();
        public Long commitNumber;
    }

    public class Plan {
        public Map<Id, Long> commitByCase = new Map<Id, Long>();
        public Boolean needsFullReconcile = false;
        public Integer ignored = 0;
        public Integer duplicates = 0;
    }

    public static final Set<String> RISK_FIELDS = new Set<String>{
        'Priority', 'Status', 'OwnerId', 'AccountId', 'IsEscalated', 'ER_SLA_Deadline__c', 'ER_Reopen_Count__c'
    };
    @TestVisible
    private static Integer queueableChunkSize = 100;
    @TestVisible
    private static Integer maxQueueablesPerTransaction = 20;
    @TestVisible
    private static Integer maxTriggerRetries = 4;

    public static void processEvents(List<CaseChangeEvent> events) {
        EventBus.TriggerContext ctx = EventBus.TriggerContext.currentContext();
        List<ChangeInput> inputs = new List<ChangeInput>();
        String lastReplay = null;
        for (CaseChangeEvent ev : events) {
            inputs.add(toInput(ev.ChangeEventHeader));
            lastReplay = ev.ReplayId;
        }
        String corr = ER_Constants.newCorrelationId();
        try {
            process(inputs, corr);
            if (Test.isRunningTest()) {
                Plan p = plan(inputs);
                if (!p.commitByCase.isEmpty()) {
                    ER_CaseRiskService.assessCases(p.commitByCase.keySet(), p.commitByCase, corr);
                }
            }
            if (lastReplay != null) {
                ctx.setResumeCheckpoint(lastReplay);
            }
        } catch (Exception e) {
            if (ctx.retries < maxTriggerRetries) {
                throw new EventBus.RetryableException('ER CDC processing failed, retrying: ' + e.getMessage());
            }
            // Retries exhausted: record the failure with the affected Case Ids so reprocessing is possible, then move on.
            Set<String> affected = new Set<String>();
            for (ChangeInput ci : inputs) {
                affected.addAll(ci.recordIds);
            }
            ER_AuditService.logIntegration('CDC', 'processEvents', null, corr, 'Failure', null, null,
                'Retries exhausted: ' + e.getMessage() + ' Cases: ' + String.join(new List<String>(affected), ','), true, ctx.retries);
            if (lastReplay != null) {
                ctx.setResumeCheckpoint(lastReplay);
            }
        }
    }

    public static void process(List<ChangeInput> inputs, String corr) {
        Plan plan = plan(inputs);
        dispatch(plan, corr);
    }

    @TestVisible
    private static ChangeInput toInput(EventBus.ChangeEventHeader h) {
        ChangeInput ci = new ChangeInput();
        ci.changeType = h.getChangeType() != null ? h.getChangeType() : h.changeType;
        List<String> rids = h.getRecordIds() != null ? h.getRecordIds() : h.recordIds;
        ci.recordIds = rids == null ? new List<String>() : rids;
        List<String> cfields = h.getChangedFields() != null ? h.getChangedFields() : (h.changedFields == null ? new List<String>() : new List<String>(h.changedFields));
        ci.changedFields = new Set<String>(cfields);
        ci.commitNumber = h.getCommitNumber() != null ? h.getCommitNumber() : h.commitNumber;
        return ci;
    }

    public static Plan plan(List<ChangeInput> inputs) {
        Plan p = new Plan();
        for (ChangeInput ci : inputs) {
            if (ci.changeType == 'GAP_OVERFLOW') {
                p.needsFullReconcile = true;
                continue;
            }
            Boolean relevant;
            if (ci.changeType == 'UPDATE') {
                relevant = false;
                for (String f : ci.changedFields) {
                    if (RISK_FIELDS.contains(f)) {
                        relevant = true;
                        break;
                    }
                }
            } else {
                // CREATE, DELETE, UNDELETE and GAP_* events always trigger reassessment (or deactivation).
                relevant = true;
            }
            if (!relevant) {
                p.ignored++;
                continue;
            }
            for (String rid : ci.recordIds) {
                Id cid;
                try {
                    cid = (Id) rid;
                } catch (Exception e) {
                    continue;
                }
                Long prev = p.commitByCase.get(cid);
                Long cur = ci.commitNumber;
                if (!p.commitByCase.containsKey(cid) || (cur != null && (prev == null || cur > prev))) {
                    p.commitByCase.put(cid, cur);
                } else {
                    p.duplicates++;
                }
            }
        }
        if (p.commitByCase.isEmpty()) {
            return p;
        }
        // Skip Cases whose latest applied commit is already >= the event commit (redelivery / replay).
        Set<String> keys = new Set<String>();
        for (Id cid : p.commitByCase.keySet()) {
            keys.add(String.valueOf(cid));
        }
        for (Risk_Assessment__c ra : [
            SELECT Case_Id__c, Last_Commit_Number__c FROM Risk_Assessment__c WHERE Case_Id__c IN :keys AND Last_Commit_Number__c != null
        ]) {
            Id cid = (Id) ra.Case_Id__c;
            Long incoming = p.commitByCase.get(cid);
            if (incoming != null && Decimal.valueOf(incoming) <= ra.Last_Commit_Number__c) {
                p.commitByCase.remove(cid);
                p.duplicates++;
            }
        }
        return p;
    }

    private static void dispatch(Plan plan, String corr) {
        if (plan.needsFullReconcile) {
            // A GAP_OVERFLOW means individual changes were lost: reassess every open Case in bounded batches.
            Database.executeBatch(new ER_RiskAssessmentBatch(ER_RiskAssessmentBatch.MODE_REPROCESS, null), 50);
        }
        List<Id> allIds = new List<Id>(plan.commitByCase.keySet());
        Integer jobs = 0;
        Integer idx = 0;
        while (idx < allIds.size() && jobs < maxQueueablesPerTransaction) {
            Integer endIdx = Math.min(idx + queueableChunkSize, allIds.size());
            List<Id> chunk = new List<Id>();
            Map<Id, Long> commits = new Map<Id, Long>();
            for (Integer i = idx; i < endIdx; i++) {
                chunk.add(allIds[i]);
                commits.put(allIds[i], plan.commitByCase.get(allIds[i]));
            }
            System.enqueueJob(new ER_RiskAssessmentQueueable(ER_RiskAssessmentQueueable.MODE_ASSESS, chunk, commits, corr));
            jobs++;
            idx = endIdx;
        }
        if (idx < allIds.size() && !plan.needsFullReconcile) {
            // Too many jobs for one transaction: hand the remainder to a bounded Batch job instead of enqueueing without limit.
            Set<Id> overflow = new Set<Id>();
            for (Integer i = idx; i < allIds.size(); i++) {
                overflow.add(allIds[i]);
            }
            Database.executeBatch(new ER_RiskAssessmentBatch(ER_RiskAssessmentBatch.MODE_REPROCESS, overflow), 50);
        }
    }
}
