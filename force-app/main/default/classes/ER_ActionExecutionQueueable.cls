/** Executes one action asynchronously (needed because Slack requires a callout after the approval DML). */
public without sharing class ER_ActionExecutionQueueable implements Queueable, Database.AllowsCallouts {
    private final Id actionId;

    public ER_ActionExecutionQueueable(Id actionId) {
        this.actionId = actionId;
    }

    public void execute(QueueableContext qc) {
        try {
            ER_ActionExecutionService.execute(actionId);
        } catch (ER_Exception e) {
            // Duplicate/replayed execution attempts are refused by design; nothing else to do.
            System.debug(LoggingLevel.INFO, 'ER action execution refused: ' + e.getMessage());
        }
    }
}
