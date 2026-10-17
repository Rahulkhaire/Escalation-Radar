/** Schedules the recovery batch (retry eligible AI work, repair assessments in Error). See docs/SETUP_GUIDE.md. */
public with sharing class ER_RecoverySchedulable implements Schedulable {
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new ER_RiskAssessmentBatch(ER_RiskAssessmentBatch.MODE_RECOVER, null), 50);
    }
}
