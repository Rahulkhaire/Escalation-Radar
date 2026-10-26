/**
 * Asynchronous worker. MODE_ASSESS: deterministic scoring (queries + DML, no callouts).
 * MODE_AI: AI enrichment (callouts first, DML last) for a small bounded group of assessments, chaining for the remainder.
 * The two phases are separate transactions on purpose: Salesforce forbids callouts after uncommitted DML.
 */
public without sharing class ER_RiskAssessmentQueueable implements Queueable, Database.AllowsCallouts {
    public static final String MODE_ASSESS = 'ASSESS';
    public static final String MODE_AI = 'AI';
    @TestVisible
    private static Integer aiChunkSize = 5;

    private final String mode;
    private final List<Id> ids;
    private final Map<Id, Long> commits;
    private final String correlationId;

    public ER_RiskAssessmentQueueable(String mode, List<Id> ids, Map<Id, Long> commits, String correlationId) {
        this.mode = mode;
        this.ids = ids;
        this.commits = commits;
        this.correlationId = correlationId;
    }

    public void execute(QueueableContext qc) {
        if (mode == MODE_ASSESS) {
            ER_CaseRiskService.Outcome out = ER_CaseRiskService.assessCases(new Set<Id>(ids), commits, correlationId);
            if (!out.aiCandidateIds.isEmpty()) {
                enqueueAi(out.aiCandidateIds, correlationId);
            }
            return;
        }
        List<Id> current = new List<Id>();
        List<Id> rest = new List<Id>();
        for (Id i : ids) {
            if (current.size() < aiChunkSize) {
                current.add(i);
            } else {
                rest.add(i);
            }
        }
        ER_AIAnalysisService.analyze(new Set<Id>(current), correlationId);
        // Chain only if the platform allows it; leftovers stay AI_Pending and are picked up by the recovery batch.
        if (!rest.isEmpty() && !atMaxStackDepth()) {
            System.enqueueJob(new ER_RiskAssessmentQueueable(MODE_AI, rest, null, correlationId));
        }
    }

    public static void enqueueAi(List<Id> assessmentIds, String correlationId) {
        if (assessmentIds == null || assessmentIds.isEmpty()) {
            return;
        }
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs() || atMaxStackDepth()) {
            return; // remain AI_Pending; the recovery batch will pick them up
        }
        System.enqueueJob(new ER_RiskAssessmentQueueable(MODE_AI, assessmentIds, null, correlationId));
    }

    /**
     * System.AsyncInfo.hasMaxStackDepth() throws when called outside Queueable/Finalizer execution
     * (for example from Batch execute(), Execute Anonymous or tests). Outside a Queueable there is no chain to protect, so report false.
     * During tests, chaining is restricted by the platform unless AsyncOptions is used, so return true.
     */
    private static Boolean atMaxStackDepth() {
        if (Test.isRunningTest()) {
            return true;
        }
        try {
            if (System.AsyncInfo.hasMaxStackDepth()) {
                return System.AsyncInfo.getCurrentQueueableStackDepth() >= System.AsyncInfo.getMaximumQueueableStackDepth();
            }
            return false;
        } catch (Exception e) {
            return false;
        }
    }
}
