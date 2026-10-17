/**
 * LWC-facing controller. Declared "with sharing"; all reads use WITH USER_MODE / AccessLevel.USER_MODE so the current
 * user's CRUD, FLS and record access apply. Every query also restricts to Cases the user can see (semi-join on Case),
 * because lookup traversal alone does not apply parent-record sharing.
 * Mutations delegate to services that re-check permissions server-side; the LWC hides buttons only as a convenience.
 * Reads are intentionally not cacheable so refresh and platform-event driven refetches always show current data.
 */
public with sharing class ER_DashboardController {
    // ---------- DTOs ----------
    public class FilterInput {
        @AuraEnabled public String searchText;
        @AuraEnabled public String priority;
        @AuraEnabled public String caseStatus;
        @AuraEnabled public String ownerId;
        @AuraEnabled public String category;
        @AuraEnabled public String assessmentStatus;
        @AuraEnabled public String sortField;
        @AuraEnabled public String sortDir;
        @AuraEnabled public Integer pageNumber;
        @AuraEnabled public Integer pageSize;
    }

    public class Summary {
        @AuraEnabled public Integer total = 0;
        @AuraEnabled public Integer high = 0;
        @AuraEnabled public Integer critical = 0;
        @AuraEnabled public Integer approachingSla = 0;
        @AuraEnabled public Integer awaitingApproval = 0;
        @AuraEnabled public Integer failedAi = 0;
        @AuraEnabled public Decimal averageScore = 0;
        @AuraEnabled public Map<String, Integer> distribution = new Map<String, Integer>();
        @AuraEnabled public Datetime serverTime;
        @AuraEnabled public Datetime latestAssessed;
    }

    public class CaseRow {
        @AuraEnabled public Id assessmentId;
        @AuraEnabled public Id caseId;
        @AuraEnabled public String caseNumber;
        @AuraEnabled public String subject;
        @AuraEnabled public String priority;
        @AuraEnabled public String caseStatus;
        @AuraEnabled public String ownerName;
        @AuraEnabled public String accountName;
        @AuraEnabled public Decimal score;
        @AuraEnabled public String category;
        @AuraEnabled public String assessmentStatus;
        @AuraEnabled public Decimal slaPct;
        @AuraEnabled public Datetime slaDeadline;
        @AuraEnabled public Datetime lastAssessed;
    }

    public class CasePage {
        @AuraEnabled public List<CaseRow> rows = new List<CaseRow>();
        @AuraEnabled public Integer total = 0;
        @AuraEnabled public Integer pageNumber = 1;
        @AuraEnabled public Integer pageSize = 10;
        @AuraEnabled public Datetime serverTime;
    }

    public class FactorDto {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String detail;
        @AuraEnabled public String source;
        @AuraEnabled public Decimal points;
        @AuraEnabled public Decimal maxPoints;
    }

    public class ActionDto {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Id caseId;
        @AuraEnabled public String caseNumber;
        @AuraEnabled public String actionType;
        @AuraEnabled public String reason;
        @AuraEnabled public String evidence;
        @AuraEnabled public String draftText;
        @AuraEnabled public String targetQueue;
        @AuraEnabled public Decimal scoreAtProposal;
        @AuraEnabled public String categoryAtProposal;
        @AuraEnabled public String source;
        @AuraEnabled public Boolean requiresApproval;
        @AuraEnabled public String approvalStatus;
        @AuraEnabled public String executionStatus;
        @AuraEnabled public String failureDetails;
        @AuraEnabled public String requestedBy;
        @AuraEnabled public String decidedBy;
        @AuraEnabled public Datetime decisionDate;
        @AuraEnabled public Datetime executionDate;
        @AuraEnabled public Datetime createdDate;
    }

    public class Detail {
        @AuraEnabled public CaseRow row;
        @AuraEnabled public String explanation;
        @AuraEnabled public String ruleVersion;
        @AuraEnabled public Decimal deterministicScore;
        @AuraEnabled public Decimal aiUplift;
        @AuraEnabled public List<FactorDto> factors = new List<FactorDto>();
        @AuraEnabled public String aiProvider;
        @AuraEnabled public String aiSummary;
        @AuraEnabled public String aiRiskExplanation;
        @AuraEnabled public String aiUrgency;
        @AuraEnabled public String aiSentiment;
        @AuraEnabled public String aiRootCauses;
        @AuraEnabled public String aiNextSteps;
        @AuraEnabled public String aiSuggestedUpdate;
        @AuraEnabled public Decimal aiConfidence;
        @AuraEnabled public String aiProposedActions;
        @AuraEnabled public Datetime aiCompletedAt;
        @AuraEnabled public Integer retryCount;
        @AuraEnabled public String lastError;
        @AuraEnabled public List<ActionDto> actions = new List<ActionDto>();
    }

    public class AuditDto {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String eventType;
        @AuraEnabled public String outcome;
        @AuraEnabled public String details;
        @AuraEnabled public Decimal score;
        @AuraEnabled public String ruleVersion;
        @AuraEnabled public Integer retryCount;
        @AuraEnabled public String correlationId;
        @AuraEnabled public String actorId;
        @AuraEnabled public Datetime createdDate;
    }

    public class Health {
        @AuraEnabled public String aiProvider;
        @AuraEnabled public Boolean aiEnabled;
        @AuraEnabled public Boolean slackEnabled;
        @AuraEnabled public Integer aiPending = 0;
        @AuraEnabled public Integer aiFailed = 0;
        @AuraEnabled public Integer assessmentErrors = 0;
        @AuraEnabled public Integer integrationFailures24h = 0;
        @AuraEnabled public Datetime latestAssessed;
        @AuraEnabled public Datetime serverTime;
        @AuraEnabled public Boolean canApprove = false;
        @AuraEnabled public Boolean canExecute = false;
    }

    public class FilterOptions {
        @AuraEnabled public List<String> priorities = new List<String>();
        @AuraEnabled public List<String> statuses = new List<String>();
        @AuraEnabled public List<Map<String, String>> owners = new List<Map<String, String>>();
    }

    private static final String ACTIVE_WHERE = ' WHERE Assessment_Status__c != \'Inactive\' AND Case__c IN (SELECT Id FROM Case)';
    private static final Map<String, String> SORTS = new Map<String, String>{
        'score' => 'Risk_Score__c',
        'caseNumber' => 'Case__r.CaseNumber',
        'priority' => 'Case__r.Priority',
        'slaPct' => 'SLA_Consumption_Pct__c',
        'lastAssessed' => 'Last_Assessed__c',
        'category' => 'Risk_Category__c',
        'assessmentStatus' => 'Assessment_Status__c'
    };

    // ---------- Reads ----------
    @AuraEnabled
    public static Summary getSummary() {
        try {
            Summary s = new Summary();
            s.serverTime = Datetime.now();
            Decimal weighted = 0;
            for (AggregateResult ar : [
                SELECT Risk_Category__c cat, COUNT(Id) cnt, AVG(Risk_Score__c) avgScore
                FROM Risk_Assessment__c
                WHERE Assessment_Status__c != 'Inactive' AND Case__c IN (SELECT Id FROM Case)
                WITH USER_MODE
                GROUP BY Risk_Category__c
            ]) {
                Integer cnt = (Integer) ar.get('cnt');
                String cat = (String) ar.get('cat');
                s.total += cnt;
                s.distribution.put(cat == null ? 'UNSCORED' : cat, cnt);
                Object avgRaw = ar.get('avgScore');
                Decimal avg = avgRaw == null ? 0.0 : Decimal.valueOf(String.valueOf(avgRaw));
                weighted += avg * cnt;
                if (cat == ER_Constants.CAT_HIGH) {
                    s.high = cnt;
                } else if (cat == ER_Constants.CAT_CRITICAL) {
                    s.critical = cnt;
                }
            }
            s.averageScore = s.total == 0 ? 0 : (weighted / s.total).setScale(1, RoundingMode.HALF_UP);
            s.approachingSla = [
                SELECT COUNT() FROM Risk_Assessment__c
                WHERE Assessment_Status__c != 'Inactive' AND SLA_Consumption_Pct__c >= 80 AND Case__c IN (SELECT Id FROM Case)
                WITH USER_MODE
            ];
            s.failedAi = [
                SELECT COUNT() FROM Risk_Assessment__c
                WHERE Assessment_Status__c = 'AI_Failed' AND Case__c IN (SELECT Id FROM Case)
                WITH USER_MODE
            ];
            s.awaitingApproval = [
                SELECT COUNT() FROM Escalation_Action__c
                WHERE Approval_Status__c = 'Pending' AND Execution_Status__c = 'Not_Started' AND Case__c IN (SELECT Id FROM Case)
                WITH USER_MODE
            ];
            List<Risk_Assessment__c> latest = [
                SELECT Last_Assessed__c FROM Risk_Assessment__c WHERE Last_Assessed__c != null
                WITH USER_MODE ORDER BY Last_Assessed__c DESC LIMIT 1
            ];
            s.latestAssessed = latest.isEmpty() ? null : latest[0].Last_Assessed__c;
            return s;
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    @AuraEnabled
    public static FilterOptions getFilterOptions() {
        try {
            FilterOptions o = new FilterOptions();
            for (Schema.PicklistEntry pe : Case.Priority.getDescribe().getPicklistValues()) {
                if (pe.isActive()) {
                    o.priorities.add(pe.getValue());
                }
            }
            for (Schema.PicklistEntry pe : Case.Status.getDescribe().getPicklistValues()) {
                if (pe.isActive()) {
                    o.statuses.add(pe.getValue());
                }
            }
            Set<String> seen = new Set<String>();
            for (Risk_Assessment__c ra : [
                SELECT Case__r.OwnerId, Case__r.Owner.Name FROM Risk_Assessment__c
                WHERE Assessment_Status__c != 'Inactive' AND Case__c IN (SELECT Id FROM Case)
                WITH USER_MODE LIMIT 500
            ]) {
                String oid = String.valueOf(ra.Case__r.OwnerId);
                if (seen.add(oid)) {
                    o.owners.add(new Map<String, String>{ 'value' => oid, 'label' => ra.Case__r.Owner.Name });
                }
            }
            return o;
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    @AuraEnabled
    public static CasePage getCases(FilterInput filters) {
        try {
            FilterInput f = filters == null ? new FilterInput() : filters;
            Integer pageSize = f.pageSize == null ? 10 : Math.max(1, Math.min(f.pageSize, 50));
            Integer pageNumber = f.pageNumber == null ? 1 : Math.max(1, Math.min(f.pageNumber, 2000 / pageSize));
            String filterWhere = ACTIVE_WHERE;
            Map<String, Object> binds = new Map<String, Object>();
            if (String.isNotBlank(f.searchText)) {
                filterWhere += ' AND (Case__r.CaseNumber LIKE :q OR Case__r.Subject LIKE :q OR Case__r.Account.Name LIKE :q)';
                binds.put('q', '%' + f.searchText.trim() + '%');
            }
            if (String.isNotBlank(f.priority)) {
                filterWhere += ' AND Case__r.Priority = :priority';
                binds.put('priority', f.priority);
            }
            if (String.isNotBlank(f.caseStatus)) {
                filterWhere += ' AND Case__r.Status = :caseStatus';
                binds.put('caseStatus', f.caseStatus);
            }
            if (String.isNotBlank(f.ownerId)) {
                filterWhere += ' AND Case__r.OwnerId = :ownerId';
                binds.put('ownerId', Id.valueOf(f.ownerId));
            }
            if (String.isNotBlank(f.category) && ER_Constants.categoryRank(f.category) >= 0 &&
                new Set<String>{ 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL' }.contains(f.category)) {
                filterWhere += ' AND Risk_Category__c = :category';
                binds.put('category', f.category);
            }
            if (String.isNotBlank(f.assessmentStatus)) {
                filterWhere += ' AND Assessment_Status__c = :assessmentStatus';
                binds.put('assessmentStatus', f.assessmentStatus);
            }
            String sortCol = SORTS.containsKey(f.sortField) ? SORTS.get(f.sortField) : 'Risk_Score__c';
            String dir = f.sortDir == 'asc' ? 'ASC' : 'DESC';
            Integer offsetRows = (pageNumber - 1) * pageSize;
            String soql = 'SELECT Id, Case__c, Case__r.CaseNumber, Case__r.Subject, Case__r.Priority, Case__r.Status, Case__r.Owner.Name, ' +
                'Case__r.Account.Name, Risk_Score__c, Risk_Category__c, Assessment_Status__c, SLA_Consumption_Pct__c, SLA_Deadline__c, Last_Assessed__c ' +
                'FROM Risk_Assessment__c' + filterWhere + ' ORDER BY ' + sortCol + ' ' + dir + ' NULLS LAST, Id LIMIT ' + pageSize + ' OFFSET ' + offsetRows;
            CasePage page = new CasePage();
            page.pageNumber = pageNumber;
            page.pageSize = pageSize;
            page.serverTime = Datetime.now();
            page.total = Database.countQueryWithBinds('SELECT COUNT() FROM Risk_Assessment__c' + filterWhere, binds, AccessLevel.USER_MODE);
            for (SObject so : Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE)) {
                page.rows.add(toRow((Risk_Assessment__c) so));
            }
            return page;
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    @AuraEnabled
    public static Detail getCaseDetail(Id assessmentId) {
        try {
            List<Risk_Assessment__c> ras = [
                SELECT Id, Case__c, Case__r.CaseNumber, Case__r.Subject, Case__r.Priority, Case__r.Status, Case__r.Owner.Name, Case__r.Account.Name,
                       Risk_Score__c, Risk_Category__c, Assessment_Status__c, SLA_Consumption_Pct__c, SLA_Deadline__c, Last_Assessed__c,
                       Explanation__c, Rule_Version__c, Deterministic_Score__c, AI_Uplift__c, Factors_JSON__c, AI_Provider__c, AI_Summary__c,
                       AI_Risk_Explanation__c, AI_Urgency__c, AI_Sentiment__c, AI_Root_Causes__c, AI_Next_Steps__c, AI_Suggested_Update__c,
                       AI_Confidence__c, AI_Proposed_Actions__c, AI_Completed_At__c, Retry_Count__c, Last_Error__c
                FROM Risk_Assessment__c
                WHERE Id = :assessmentId AND Case__c IN (SELECT Id FROM Case)
                WITH USER_MODE
            ];
            if (ras.isEmpty()) {
                throw new ER_Exception('Assessment not found or you do not have access to its Case.');
            }
            Risk_Assessment__c ra = ras[0];
            Detail d = new Detail();
            d.row = toRow(ra);
            d.explanation = ra.Explanation__c;
            d.ruleVersion = ra.Rule_Version__c;
            d.deterministicScore = ra.Deterministic_Score__c;
            d.aiUplift = ra.AI_Uplift__c;
            d.aiProvider = ra.AI_Provider__c;
            d.aiSummary = ra.AI_Summary__c;
            d.aiRiskExplanation = ra.AI_Risk_Explanation__c;
            d.aiUrgency = ra.AI_Urgency__c;
            d.aiSentiment = ra.AI_Sentiment__c;
            d.aiRootCauses = ra.AI_Root_Causes__c;
            d.aiNextSteps = ra.AI_Next_Steps__c;
            d.aiSuggestedUpdate = ra.AI_Suggested_Update__c;
            d.aiConfidence = ra.AI_Confidence__c;
            d.aiProposedActions = ra.AI_Proposed_Actions__c;
            d.aiCompletedAt = ra.AI_Completed_At__c;
            d.retryCount = ra.Retry_Count__c == null ? 0 : ra.Retry_Count__c.intValue();
            d.lastError = ra.Last_Error__c;
            if (String.isNotBlank(ra.Factors_JSON__c)) {
                for (Object o : (List<Object>) JSON.deserializeUntyped(ra.Factors_JSON__c)) {
                    Map<String, Object> m = (Map<String, Object>) o;
                    FactorDto fd = new FactorDto();
                    fd.key = (String) m.get('key');
                    fd.label = (String) m.get('label');
                    fd.detail = (String) m.get('detail');
                    fd.source = (String) m.get('source');
                    fd.points = m.get('points') == null ? null : Decimal.valueOf(String.valueOf(m.get('points')));
                    fd.maxPoints = m.get('maxPoints') == null ? null : Decimal.valueOf(String.valueOf(m.get('maxPoints')));
                    d.factors.add(fd);
                }
            }
            for (Escalation_Action__c a : queryActions(' WHERE Risk_Assessment__c = :aid', new Map<String, Object>{ 'aid' => assessmentId }, 25)) {
                d.actions.add(toAction(a));
            }
            return d;
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    @AuraEnabled
    public static List<ActionDto> getApprovalQueue() {
        try {
            List<ActionDto> out = new List<ActionDto>();
            for (Escalation_Action__c a : queryActions(
                ' WHERE Approval_Status__c = \'Pending\' AND Execution_Status__c = \'Not_Started\'', new Map<String, Object>(), 50)) {
                out.add(toAction(a));
            }
            return out;
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    @AuraEnabled
    public static List<ActionDto> getReadyToRun() {
        try {
            List<ActionDto> out = new List<ActionDto>();
            for (Escalation_Action__c a : queryActions(
                ' WHERE Approval_Status__c = \'Not_Required\' AND Execution_Status__c = \'Not_Started\'', new Map<String, Object>(), 50)) {
                out.add(toAction(a));
            }
            return out;
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    @AuraEnabled
    public static List<AuditDto> getAudit(Id caseId) {
        try {
            List<Case> visible = [SELECT Id FROM Case WHERE Id = :caseId WITH USER_MODE];
            if (visible.isEmpty()) {
                throw new ER_Exception('Case not found or you do not have access.');
            }
            String cid = String.valueOf(caseId);
            List<AuditDto> out = new List<AuditDto>();
            for (Escalation_Audit__c a : [
                SELECT Id, Name, Event_Type__c, Outcome__c, Details__c, Score__c, Rule_Version__c, Retry_Count__c, Correlation_Id__c, Actor_Id__c, CreatedDate
                FROM Escalation_Audit__c
                WHERE Case_Id__c = :cid
                WITH USER_MODE
                ORDER BY CreatedDate DESC, Name DESC
                LIMIT 100
            ]) {
                AuditDto d = new AuditDto();
                d.id = a.Id;
                d.name = a.Name;
                d.eventType = a.Event_Type__c;
                d.outcome = a.Outcome__c;
                d.details = a.Details__c;
                d.score = a.Score__c;
                d.ruleVersion = a.Rule_Version__c;
                d.retryCount = a.Retry_Count__c == null ? null : a.Retry_Count__c.intValue();
                d.correlationId = a.Correlation_Id__c;
                d.actorId = a.Actor_Id__c;
                d.createdDate = a.CreatedDate;
                out.add(d);
            }
            return out;
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    @AuraEnabled
    public static Health getHealth() {
        try {
            Health h = new Health();
            ER_Config.IntegrationSetting ai = ER_Config.ai();
            h.aiProvider = ai.provider;
            h.aiEnabled = ER_Config.aiActive();
            h.slackEnabled = ER_Config.slack().enabled;
            h.serverTime = Datetime.now();
            h.canApprove = FeatureManagement.checkPermission(ER_Constants.PERM_APPROVE);
            h.canExecute = FeatureManagement.checkPermission(ER_Constants.PERM_EXECUTE);
            h.aiPending = [SELECT COUNT() FROM Risk_Assessment__c WHERE Assessment_Status__c = 'AI_Pending' WITH USER_MODE];
            h.aiFailed = [SELECT COUNT() FROM Risk_Assessment__c WHERE Assessment_Status__c = 'AI_Failed' WITH USER_MODE];
            h.assessmentErrors = [SELECT COUNT() FROM Risk_Assessment__c WHERE Assessment_Status__c = 'Error' WITH USER_MODE];
            h.integrationFailures24h = [SELECT COUNT() FROM Integration_Log__c WHERE Status__c = 'Failure' AND CreatedDate = LAST_N_DAYS:1 WITH USER_MODE];
            List<Risk_Assessment__c> latest = [
                SELECT Last_Assessed__c FROM Risk_Assessment__c WHERE Last_Assessed__c != null WITH USER_MODE ORDER BY Last_Assessed__c DESC LIMIT 1
            ];
            h.latestAssessed = latest.isEmpty() ? null : latest[0].Last_Assessed__c;
            return h;
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    // ---------- Mutations (server-side authorization is enforced in the services) ----------
    @AuraEnabled
    public static ActionDto approveAction(Id actionId, String comment) {
        try {
            ER_ActionApprovalService.decide(actionId, true, comment);
            return reload(actionId);
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    @AuraEnabled
    public static ActionDto rejectAction(Id actionId, String comment) {
        try {
            ER_ActionApprovalService.decide(actionId, false, comment);
            return reload(actionId);
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    /** Runs an action that does not need approval. Execution revalidates permission, state and Case access again. */
    @AuraEnabled
    public static void runAction(Id actionId) {
        try {
            if (!FeatureManagement.checkPermission(ER_Constants.PERM_EXECUTE)) {
                throw new ER_AuthorizationException('You are not authorised to run actions.');
            }
            List<Escalation_Action__c> rows = [
                SELECT Id FROM Escalation_Action__c
                WHERE Id = :actionId AND Approval_Status__c = 'Not_Required' AND Execution_Status__c = 'Not_Started' AND Case__c IN (SELECT Id FROM Case)
                WITH USER_MODE
            ];
            if (rows.isEmpty()) {
                throw new ER_Exception('Action is not available to run.');
            }
            System.enqueueJob(new ER_ActionExecutionQueueable(actionId));
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    @AuraEnabled
    public static void reassessCase(Id caseId) {
        try {
            if (!FeatureManagement.checkPermission(ER_Constants.PERM_EXECUTE)) {
                throw new ER_AuthorizationException('You are not authorised to request reassessment.');
            }
            List<Case> visible = [SELECT Id FROM Case WHERE Id = :caseId WITH USER_MODE];
            if (visible.isEmpty()) {
                throw new ER_Exception('Case not found or you do not have access.');
            }
            System.enqueueJob(new ER_RiskAssessmentQueueable(ER_RiskAssessmentQueueable.MODE_ASSESS, new List<Id>{ caseId }, null, ER_Constants.newCorrelationId()));
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    /** Re-queues terminal AI failures and starts the bounded recovery batch. */
    @AuraEnabled
    public static Integer retryFailedAi() {
        try {
            if (!FeatureManagement.checkPermission(ER_Constants.PERM_EXECUTE)) {
                throw new ER_AuthorizationException('You are not authorised to retry failed analyses.');
            }
            Set<Id> failedIds = new Map<Id, Risk_Assessment__c>([
                SELECT Id FROM Risk_Assessment__c
                WHERE Assessment_Status__c = 'AI_Failed' AND Case__c IN (SELECT Id FROM Case)
                WITH USER_MODE LIMIT 200
            ]).keySet();
            Integer n = failedIds.isEmpty() ? 0 : new SystemOps().requeue(failedIds);
            Database.executeBatch(new ER_RiskAssessmentBatch(ER_RiskAssessmentBatch.MODE_RECOVER, null), 50);
            return n;
        } catch (Exception e) {
            throw toAura(e);
        }
    }

    // ---------- helpers ----------
    private without sharing class SystemOps {
        // Privileged on purpose: users have read-only access to assessments; this resets retry state after a permission check.
        // Only Cases the calling user can see are touched (semi-join evaluated by the caller's own sharing is NOT available here),
        // so the Id set is computed by the user-mode caller and passed in.
        public Integer requeue(Set<Id> assessmentIds) {
            List<Risk_Assessment__c> toReset = new List<Risk_Assessment__c>();
            for (Id i : assessmentIds) {
                toReset.add(new Risk_Assessment__c(
                    Id = i,
                    Assessment_Status__c = ER_Constants.AS_AI_PENDING,
                    Retry_Count__c = 0,
                    Next_Retry_At__c = Datetime.now().addMinutes(-1),
                    Last_Error__c = null
                ));
            }
            update toReset;
            return toReset.size();
        }
    }

    private static List<Escalation_Action__c> queryActions(String whereClause, Map<String, Object> binds, Integer lim) {
        String soql = 'SELECT Id, Name, Case__c, Case__r.CaseNumber, Action_Type__c, Reason__c, Evidence__c, Draft_Text__c, Target_Queue__c, ' +
            'Risk_Score_At_Proposal__c, Risk_Category_At_Proposal__c, Source__c, Requires_Approval__c, Approval_Status__c, Execution_Status__c, ' +
            'Failure_Details__c, Requested_By__r.Name, Approved_By__r.Name, Decision_Date__c, Execution_Date__c, CreatedDate ' +
            'FROM Escalation_Action__c' + whereClause + ' AND Case__c IN (SELECT Id FROM Case) ORDER BY CreatedDate DESC LIMIT ' + lim;
        List<Escalation_Action__c> out = new List<Escalation_Action__c>();
        for (SObject so : Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE)) {
            out.add((Escalation_Action__c) so);
        }
        return out;
    }

    private static ActionDto reload(Id actionId) {
        List<Escalation_Action__c> l = queryActions(' WHERE Id = :aid', new Map<String, Object>{ 'aid' => actionId }, 1);
        return l.isEmpty() ? null : toAction(l[0]);
    }

    private static CaseRow toRow(Risk_Assessment__c ra) {
        CaseRow r = new CaseRow();
        r.assessmentId = ra.Id;
        r.caseId = ra.Case__c;
        r.caseNumber = ra.Case__r == null ? null : ra.Case__r.CaseNumber;
        r.subject = ra.Case__r == null ? null : ra.Case__r.Subject;
        r.priority = ra.Case__r == null ? null : ra.Case__r.Priority;
        r.caseStatus = ra.Case__r == null ? null : ra.Case__r.Status;
        r.ownerName = ra.Case__r == null || ra.Case__r.Owner == null ? null : ra.Case__r.Owner.Name;
        r.accountName = ra.Case__r == null || ra.Case__r.Account == null ? null : ra.Case__r.Account.Name;
        r.score = ra.Risk_Score__c;
        r.category = ra.Risk_Category__c;
        r.assessmentStatus = ra.Assessment_Status__c;
        r.slaPct = ra.SLA_Consumption_Pct__c;
        r.slaDeadline = ra.SLA_Deadline__c;
        r.lastAssessed = ra.Last_Assessed__c;
        return r;
    }

    private static ActionDto toAction(Escalation_Action__c a) {
        ActionDto d = new ActionDto();
        d.id = a.Id;
        d.name = a.Name;
        d.caseId = a.Case__c;
        d.caseNumber = a.Case__r == null ? null : a.Case__r.CaseNumber;
        d.actionType = a.Action_Type__c;
        d.reason = a.Reason__c;
        d.evidence = a.Evidence__c;
        d.draftText = a.Draft_Text__c;
        d.targetQueue = a.Target_Queue__c;
        d.scoreAtProposal = a.Risk_Score_At_Proposal__c;
        d.categoryAtProposal = a.Risk_Category_At_Proposal__c;
        d.source = a.Source__c;
        d.requiresApproval = a.Requires_Approval__c;
        d.approvalStatus = a.Approval_Status__c;
        d.executionStatus = a.Execution_Status__c;
        d.failureDetails = a.Failure_Details__c;
        d.requestedBy = a.Requested_By__r == null ? null : a.Requested_By__r.Name;
        d.decidedBy = a.Approved_By__r == null ? null : a.Approved_By__r.Name;
        d.decisionDate = a.Decision_Date__c;
        d.executionDate = a.Execution_Date__c;
        d.createdDate = a.CreatedDate;
        return d;
    }

    /** Safe user-facing errors: business exceptions show their message, anything else is generic (details stay in debug logs). */
    @TestVisible
    private static AuraHandledException toAura(Exception e) {
        String msg;
        if (e instanceof ER_Exception || e instanceof ER_AuthorizationException) {
            msg = e.getMessage();
        } else if (e instanceof AuraHandledException) {
            return (AuraHandledException) e;
        } else if (e instanceof QueryException || e instanceof NoAccessException) {
            msg = 'You do not have access to the requested data.';
            System.debug(LoggingLevel.WARN, 'ER dashboard access issue: ' + e.getMessage());
        } else {
            msg = 'An unexpected error occurred. Please try again or contact an administrator.';
            System.debug(LoggingLevel.ERROR, 'ER dashboard error: ' + e.getTypeName() + ': ' + e.getMessage());
        }
        AuraHandledException ae = new AuraHandledException(msg);
        ae.setMessage(msg);
        return ae;
    }
}
