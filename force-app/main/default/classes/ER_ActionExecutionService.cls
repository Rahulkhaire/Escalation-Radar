/**
 * Executes an allowlisted action. Everything is revalidated immediately before execution:
 * action actionType allowlist, approval state, executor permission, duplicate-execution guard (row lock + status check),
 * Case visibility and open state. Changes to customer data (Case, CaseComment, Task) use user-mode DML so the
 * executing user's own CRUD/FLS and sharing apply. Updates to the app's own action/audit rows use system mode.
 *
 * Order inside execute(): SOQL -> (Slack callout) -> DML, to respect "no callout after uncommitted DML".
 * The row lock (FOR UPDATE) is held across the Slack callout, which is what blocks concurrent duplicate execution.
 */
public without sharing class ER_ActionExecutionService {
    public static Escalation_Action__c execute(Id actionId) {
        List<Escalation_Action__c> rows = [
            SELECT Id, Case__c, Risk_Assessment__c, Action_Type__c, Draft_Text__c, Target_Queue__c, Requires_Approval__c,
                   Approval_Status__c, Approved_By__c, Execution_Status__c, Risk_Category_At_Proposal__c,
                   Risk_Score_At_Proposal__c, Reason__c, Correlation_Id__c
            FROM Escalation_Action__c
            WHERE Id = :actionId
            FOR UPDATE
        ];
        if (rows.isEmpty()) {
            throw new ER_Exception('Action not found.');
        }
        Escalation_Action__c a = rows[0];
        if (a.Execution_Status__c != ER_Constants.EX_NOT_STARTED) {
            throw new ER_Exception('Action was already processed (status ' + a.Execution_Status__c + ').');
        }
        List<ER_AuditService.Entry> audits = new List<ER_AuditService.Entry>();
        ER_AuditService.Entry attempt = ER_AuditService.entry('ACTION_EXECUTION_ATTEMPTED', a.Case__c, a.Correlation_Id__c);
        attempt.actionId = String.valueOf(a.Id);
        attempt.details = a.Action_Type__c;
        audits.add(attempt);

        String failure = null;
        String skipReason = null;
        Case c = null;
        if (!ER_Constants.ALLOWED_ACTIONS.contains(a.Action_Type__c)) {
            failure = 'Unsupported action actionType.';
        } else if (a.Requires_Approval__c == true) {
            if (a.Approval_Status__c != ER_Constants.APPR_APPROVED || a.Approved_By__c == null) {
                failure = 'Action has not been approved.';
            } else if (!FeatureManagement.checkPermission(ER_Constants.PERM_APPROVE)) {
                failure = 'Executing user is not authorised to run approved actions.';
            }
        } else if (a.Approval_Status__c != ER_Constants.APPR_NOT_REQUIRED) {
            failure = 'Approval state is inconsistent with the approval requirement.';
        } else if (!FeatureManagement.checkPermission(ER_Constants.PERM_EXECUTE)) {
            failure = 'Executing user is not authorised to run actions.';
        }
        if (failure == null) {
            List<Case> cs = [SELECT Id, CaseNumber, Subject, IsClosed, OwnerId FROM Case WHERE Id = :a.Case__c WITH USER_MODE];
            if (cs.isEmpty()) {
                failure = 'Case is not accessible or no longer exists.';
            } else if (cs[0].IsClosed) {
                skipReason = 'Case is closed; action skipped.';
            } else {
                c = cs[0];
            }
        }
        if (failure == null && skipReason == null) {
            try {
                run(a, c);
            } catch (Exception e) {
                failure = ER_AuditService.truncate(e.getMessage(), 1900);
            }
        }

        a.Execution_Date__c = Datetime.now();
        ER_AuditService.Entry result = ER_AuditService.entry(null, a.Case__c, a.Correlation_Id__c);
        result.actionId = String.valueOf(a.Id);
        if (failure != null) {
            a.Execution_Status__c = ER_Constants.EX_FAILED;
            a.Failure_Details__c = failure;
            result.eventType = 'ACTION_FAILED';
            result.outcome = ER_Constants.OUTCOME_FAILURE;
            result.details = a.Action_Type__c + ': ' + failure;
        } else if (skipReason != null) {
            a.Execution_Status__c = ER_Constants.EX_SKIPPED;
            a.Failure_Details__c = skipReason;
            result.eventType = 'ACTION_SKIPPED';
            result.outcome = ER_Constants.OUTCOME_INFO;
            result.details = a.Action_Type__c + ': ' + skipReason;
        } else {
            a.Execution_Status__c = ER_Constants.EX_SUCCEEDED;
            a.Failure_Details__c = null;
            result.eventType = 'ACTION_EXECUTED';
            result.outcome = ER_Constants.OUTCOME_SUCCESS;
            result.details = a.Action_Type__c + ' executed.';
        }
        update a;
        audits.add(result);
        ER_AuditService.log(audits);
        return a;
    }

    private static void run(Escalation_Action__c a, Case c) {
        String actionType = a.Action_Type__c;
        if (actionType == ER_Constants.ACT_DRAFT || actionType == ER_Constants.ACT_NOTE) {
            String header = actionType == ER_Constants.ACT_DRAFT
                ? '[Escalation Radar] DRAFT customer update (NOT sent to the customer):\n'
                : '[Escalation Radar] Internal note:\n';
            CaseComment cc = new CaseComment(ParentId = c.Id, IsPublished = false, CommentBody = ER_AuditService.truncate(header + a.Draft_Text__c, 4000));
            insert as user cc;
        } else if (actionType == ER_Constants.ACT_REVIEW) {
            Id assignee = UserInfo.getUserId();
            if (String.valueOf(c.OwnerId).startsWith('005')) {
                List<User> owners = [SELECT ManagerId FROM User WHERE Id = :c.OwnerId WITH USER_MODE];
                if (!owners.isEmpty() && owners[0].ManagerId != null) {
                    assignee = owners[0].ManagerId;
                }
            }
            Task t = new Task(
                OwnerId = assignee,
                WhatId = c.Id,
                Subject = 'Manager review requested: Case ' + c.CaseNumber,
                Description = ER_AuditService.truncate(a.Reason__c, 1000),
                ActivityDate = Date.today().addDays(1),
                Priority = 'High',
                Status = 'Not Started'
            );
            insert as user t;
        } else if (actionType == ER_Constants.ACT_REASSIGN) {
            String allowed = ER_Config.actions().reassignQueue;
            if (String.isBlank(a.Target_Queue__c) || a.Target_Queue__c != allowed) {
                throw new ER_Exception('Target queue is not the configured, allowlisted queue.');
            }
            List<Group> queues = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :a.Target_Queue__c LIMIT 1];
            if (queues.isEmpty()) {
                throw new ER_Exception('Configured queue was not found.');
            }
            List<QueueSobject> supports = [SELECT Id FROM QueueSobject WHERE QueueId = :queues[0].Id AND SobjectType = 'Case' LIMIT 1];
            if (supports.isEmpty()) {
                throw new ER_Exception('Configured queue does not support Cases.');
            }
            Case upd = new Case(Id = c.Id, OwnerId = queues[0].Id);
            update as user upd;
        } else if (actionType == ER_Constants.ACT_ESCALATE) {
            String flowName = ER_Config.actions().escalationFlow;
            if (String.isNotBlank(flowName)) {
                Flow.Interview fi = Flow.Interview.createInterview(flowName, new Map<String, Object>{ 'caseId' => c.Id });
                fi.start();
            } else {
                Case upd = new Case(Id = c.Id, IsEscalated = true);
                update as user upd;
            }
        } else if (actionType == ER_Constants.ACT_SLACK) {
            String link = URL.getOrgDomainUrl().toExternalForm() + '/lightning/r/Case/' + c.Id + '/view';
            String text = 'Escalation Radar: Case ' + c.CaseNumber + ' is ' + a.Risk_Category_At_Proposal__c + ' risk (score ' +
                a.Risk_Score_At_Proposal__c + '). ' + ER_PiiRedactor.sanitize(c.Subject, 120) + ' ' + link;
            ER_SlackNotificationService.send(c.Id, a.Correlation_Id__c, text);
        } else {
            throw new ER_Exception('Unsupported action actionType.');
        }
    }
}
