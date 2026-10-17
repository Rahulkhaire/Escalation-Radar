/**
 * Approve / reject proposed actions. Authorization is enforced here (custom permission, record access, state,
 * separation of duties), not in the UI. The class runs in system context only so that approval fields on
 * Escalation_Action__c can be written while end users keep read-only object permissions.
 */
public without sharing class ER_ActionApprovalService {
    public static Escalation_Action__c decide(Id actionId, Boolean approve, String comment) {
        if (!FeatureManagement.checkPermission(ER_Constants.PERM_APPROVE)) {
            throw new ER_AuthorizationException('You are not authorised to approve or reject actions.');
        }
        List<Escalation_Action__c> rows = [
            SELECT Id, Case__c, Action_Type__c, Approval_Status__c, Execution_Status__c, Requires_Approval__c, Requested_By__c,
                   Correlation_Id__c, Risk_Score_At_Proposal__c
            FROM Escalation_Action__c
            WHERE Id = :actionId
            FOR UPDATE
        ];
        if (rows.isEmpty()) {
            throw new ER_Exception('Action not found.');
        }
        Escalation_Action__c a = rows[0];
        if (!ER_Constants.ALLOWED_ACTIONS.contains(a.Action_Type__c)) {
            throw new ER_Exception('Unsupported action type.');
        }
        if (a.Requires_Approval__c != true || a.Approval_Status__c != ER_Constants.APPR_PENDING || a.Execution_Status__c != ER_Constants.EX_NOT_STARTED) {
            // Replay / double-click / stale UI: the decision has already been made.
            throw new ER_Exception('This action has already been decided or is not awaiting approval.');
        }
        List<Case> visible = [SELECT Id, IsClosed FROM Case WHERE Id = :a.Case__c WITH USER_MODE];
        if (visible.isEmpty()) {
            throw new ER_AuthorizationException('You do not have access to the related Case.');
        }
        if (approve && visible[0].IsClosed) {
            throw new ER_Exception('The Case is closed; the action can no longer be approved.');
        }
        if (a.Requested_By__c == UserInfo.getUserId()) {
            throw new ER_AuthorizationException('Separation of duties: you cannot decide an action you requested.');
        }
        a.Approval_Status__c = approve ? ER_Constants.APPR_APPROVED : ER_Constants.APPR_REJECTED;
        a.Approved_By__c = UserInfo.getUserId();
        a.Decision_Date__c = Datetime.now();
        a.Decision_Comment__c = ER_AuditService.truncate(comment, 255);
        if (!approve) {
            a.Execution_Status__c = ER_Constants.EX_SKIPPED;
        }
        update a;

        ER_AuditService.Entry e = ER_AuditService.entry(approve ? 'ACTION_APPROVED' : 'ACTION_REJECTED', a.Case__c, a.Correlation_Id__c);
        e.actionId = String.valueOf(a.Id);
        e.outcome = ER_Constants.OUTCOME_SUCCESS;
        e.score = a.Risk_Score_At_Proposal__c;
        e.details = a.Action_Type__c + (approve ? ' approved' : ' rejected') + '.';
        ER_AuditService.log(e);

        if (approve) {
            System.enqueueJob(new ER_ActionExecutionQueueable(a.Id));
        }
        return a;
    }
}
