/**
 * Turns assessments into PROPOSED actions (never executes anything). Only identifiers in
 * ER_Constants.ALLOWED_ACTIONS are ever created, whatever the source (rules or AI suggestion).
 * Duplicate proposals are suppressed: an open, recently executed or recently rejected action of the same actionType for the same
 * Case blocks a new proposal unless the risk category has risen since.
 */
public without sharing class ER_ActionRecommendationService {
    @TestVisible
    private static Integer cooldownHours = 24;

    public static List<Escalation_Action__c> propose(Set<Id> assessmentIds, String correlationId) {
        List<Escalation_Action__c> created = new List<Escalation_Action__c>();
        if (assessmentIds == null || assessmentIds.isEmpty()) {
            return created;
        }
        String corr = String.isBlank(correlationId) ? ER_Constants.newCorrelationId() : correlationId;
        ER_Config.RiskConfig cfg = ER_Config.getRiskConfig();
        ER_Config.IntegrationSetting slack = ER_Config.slack();
        ER_Config.IntegrationSetting actionSettings = ER_Config.actions();

        List<Risk_Assessment__c> ras = new List<Risk_Assessment__c>();
        Set<Id> caseIds = new Set<Id>();
        for (Risk_Assessment__c ra : [
            SELECT Id, Case__c, Case_Id__c, Risk_Score__c, Risk_Category__c, Assessment_Status__c, Explanation__c, AI_Summary__c,
                   AI_Suggested_Update__c, AI_Next_Steps__c, AI_Proposed_Actions__c, AI_Completed_At__c
            FROM Risk_Assessment__c
            WHERE Id IN :assessmentIds
        ]) {
            if (ra.Case__c == null || ra.Assessment_Status__c == ER_Constants.AS_INACTIVE || ra.Assessment_Status__c == ER_Constants.AS_ERROR) {
                continue;
            }
            if (ER_Constants.categoryRank(ra.Risk_Category__c) < 1) {
                continue;
            }
            ras.add(ra);
            caseIds.add(ra.Case__c);
        }
        if (ras.isEmpty()) {
            return created;
        }

        // Existing proposals that block duplicates: key = caseId|actionType -> highest category rank seen.
        Map<String, Integer> blocking = new Map<String, Integer>();
        Datetime since = Datetime.now().addHours(-cooldownHours);
        List<String> openExec = new List<String>{ ER_Constants.EX_NOT_STARTED, ER_Constants.EX_EXECUTING };
        for (Escalation_Action__c e : [
            SELECT Case__c, Action_Type__c, Risk_Category_At_Proposal__c
            FROM Escalation_Action__c
            WHERE Case__c IN :caseIds AND (Execution_Status__c IN :openExec OR Execution_Date__c >= :since OR Decision_Date__c >= :since)
        ]) {
            String k = String.valueOf(e.Case__c) + '|' + e.Action_Type__c;
            Integer r = ER_Constants.categoryRank(e.Risk_Category_At_Proposal__c);
            if (!blocking.containsKey(k) || blocking.get(k) < r) {
                blocking.put(k, r);
            }
        }

        List<Escalation_Action__c> candidates = new List<Escalation_Action__c>();
        for (Risk_Assessment__c ra : ras) {
            Integer rank = ER_Constants.categoryRank(ra.Risk_Category__c);
            Set<String> aiSet = new Set<String>();
            if (String.isNotBlank(ra.AI_Proposed_Actions__c)) {
                for (String s : ra.AI_Proposed_Actions__c.split(',')) {
                    aiSet.add(s.trim());
                }
            }
            String cat = ra.Risk_Category__c;
            if (rank >= 2) {
                candidates.add(build(ra, ER_Constants.ACT_REVIEW, 'Rules', 'Risk is ' + cat + '; a manager should review this Case.', null, null, cfg, corr));
            } else if (aiSet.contains(ER_Constants.ACT_REVIEW)) {
                candidates.add(build(ra, ER_Constants.ACT_REVIEW, 'AI', 'AI analysis suggests a manager review (risk ' + cat + ').', null, null, cfg, corr));
            }
            if (rank >= 3) {
                candidates.add(build(ra, ER_Constants.ACT_ESCALATE, 'Rules', 'Risk is CRITICAL; escalate through the configured workflow.', null, null, cfg, corr));
            } else if (rank >= 2 && aiSet.contains(ER_Constants.ACT_ESCALATE)) {
                candidates.add(build(ra, ER_Constants.ACT_ESCALATE, 'AI', 'AI analysis suggests escalation (risk ' + cat + ').', null, null, cfg, corr));
            }
            if (String.isNotBlank(ra.AI_Suggested_Update__c)) {
                candidates.add(build(ra, ER_Constants.ACT_DRAFT, 'AI', 'AI drafted a customer update for review.', ra.AI_Suggested_Update__c, null, cfg, corr));
            }
            if (aiSet.contains(ER_Constants.ACT_REASSIGN) && String.isNotBlank(actionSettings.reassignQueue)) {
                candidates.add(build(ra, ER_Constants.ACT_REASSIGN, 'AI', 'AI analysis suggests moving this Case to the configured queue.', null, actionSettings.reassignQueue, cfg, corr));
            }
            if (aiSet.contains(ER_Constants.ACT_NOTE) && String.isNotBlank(ra.AI_Next_Steps__c)) {
                candidates.add(build(ra, ER_Constants.ACT_NOTE, 'AI', 'AI-suggested next steps recorded as an internal note.', ra.AI_Next_Steps__c, null, cfg, corr));
            }
            if (slack.enabled && rank >= ER_Constants.categoryRank(slack.minCategory)) {
                candidates.add(build(ra, ER_Constants.ACT_SLACK, 'Rules', 'Risk ' + cat + ' reached the Slack alert threshold.', null, null, cfg, corr));
            }
        }

        List<Escalation_Action__c> toInsert = new List<Escalation_Action__c>();
        Set<String> seen = new Set<String>();
        for (Escalation_Action__c cand : candidates) {
            if (!ER_Constants.ALLOWED_ACTIONS.contains(cand.Action_Type__c)) {
                continue;
            }
            String k = String.valueOf(cand.Case__c) + '|' + cand.Action_Type__c;
            Integer rank = ER_Constants.categoryRank(cand.Risk_Category_At_Proposal__c);
            if (seen.contains(k) || (blocking.containsKey(k) && blocking.get(k) >= rank)) {
                continue;
            }
            seen.add(k);
            toInsert.add(cand);
        }
        if (toInsert.isEmpty()) {
            return created;
        }
        List<Database.SaveResult> results = Database.insert(toInsert, false);
        List<ER_AuditService.Entry> audits = new List<ER_AuditService.Entry>();
        for (Integer i = 0; i < results.size(); i++) {
            Escalation_Action__c a = toInsert[i];
            ER_AuditService.Entry e = ER_AuditService.entry('ACTION_PROPOSED', a.Case__c, corr);
            e.assessmentId = String.valueOf(a.Risk_Assessment__c);
            e.score = a.Risk_Score_At_Proposal__c;
            if (results[i].isSuccess()) {
                created.add(a);
                e.actionId = String.valueOf(a.Id);
                e.outcome = ER_Constants.OUTCOME_SUCCESS;
                e.details = a.Action_Type__c + ' proposed by ' + a.Source__c + '; ' + (a.Requires_Approval__c ? 'approval required.' : 'no approval required.');
            } else {
                e.outcome = ER_Constants.OUTCOME_FAILURE;
                e.details = a.Action_Type__c + ' proposal failed: ' + ER_AuditService.truncate(results[i].getErrors()[0].getMessage(), 500);
            }
            audits.add(e);
        }
        ER_AuditService.log(audits);
        return created;
    }

    private static Escalation_Action__c build(
        Risk_Assessment__c ra, String actionType, String source, String reason, String draft, String queue, ER_Config.RiskConfig cfg, String corr
    ) {
        Boolean requiresApproval = ER_Constants.ALWAYS_APPROVAL.contains(actionType) || cfg.approvalRequired.contains(actionType);
        String evidence = ra.Explanation__c == null ? '' : ra.Explanation__c;
        if (String.isNotBlank(ra.AI_Summary__c)) {
            evidence += '\nAI summary (advisory): ' + ra.AI_Summary__c;
        }
        return new Escalation_Action__c(
            Case__c = ra.Case__c,
            Risk_Assessment__c = ra.Id,
            Action_Type__c = actionType,
            Reason__c = ER_AuditService.truncate(reason, 255),
            Evidence__c = ER_AuditService.truncate(evidence, 4000),
            Draft_Text__c = ER_AuditService.truncate(draft, 4000),
            Target_Queue__c = queue,
            Risk_Score_At_Proposal__c = ra.Risk_Score__c,
            Risk_Category_At_Proposal__c = ra.Risk_Category__c,
            Source__c = source,
            AI_Assessment_Ref__c = ra.AI_Completed_At__c == null ? null : String.valueOf(ra.Id) + '|' + ra.AI_Completed_At__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
            Requires_Approval__c = requiresApproval,
            Requested_By__c = UserInfo.getUserId(),
            Approval_Status__c = requiresApproval ? ER_Constants.APPR_PENDING : ER_Constants.APPR_NOT_REQUIRED,
            Execution_Status__c = ER_Constants.EX_NOT_STARTED,
            Correlation_Id__c = corr
        );
    }
}
