/**
 * Core assessment pipeline for Cases (deterministic part). Runs in system context (without sharing)
 * because it is invoked by asynchronous jobs (Queueable/Batch) that must assess every monitored Case,
 * independent of any user's record access. Dashboard reads are separately enforced in user mode.
 *
 * Transaction boundary: this class performs queries and DML only (no callouts). AI enrichment happens
 * in a separate asynchronous transaction (ER_AIAnalysisService).
 */
public without sharing class ER_CaseRiskService {
    @TestVisible
    private static Integer aiCooldownMinutes = 5;

    public class Outcome {
        public List<Id> assessmentIds = new List<Id>();
        public List<Id> aiCandidateIds = new List<Id>();
        public Integer scored = 0;
        public Integer deactivated = 0;
        public Integer failed = 0;
    }

    public static Outcome assessCases(Set<Id> caseIds, Map<Id, Long> commitByCase, String correlationId) {
        Outcome out = new Outcome();
        if (caseIds == null || caseIds.isEmpty()) {
            return out;
        }
        String corr = String.isBlank(correlationId) ? ER_Constants.newCorrelationId() : correlationId;
        ER_Config.RiskConfig cfg = ER_Config.getRiskConfig();
        ER_Config.IntegrationSetting aiSetting = ER_Config.ai();
        Boolean aiOn = ER_Config.aiActive();
        Datetime nowTs = Datetime.now();

        Map<Id, Case> cases = new Map<Id, Case>([
            SELECT Id, CaseNumber, Priority, Status, IsClosed, IsEscalated, CreatedDate,
                   ER_SLA_Deadline__c, ER_Reopen_Count__c, Account.ER_Account_Tier__c
            FROM Case
            WHERE Id IN :caseIds
        ]);
        Set<String> idStrings = new Set<String>();
        Set<Id> openIds = new Set<Id>();
        for (Id cid : caseIds) {
            idStrings.add(String.valueOf(cid));
            Case c = cases.get(cid);
            if (c != null && !c.IsClosed) {
                openIds.add(cid);
            }
        }
        Map<String, Risk_Assessment__c> existing = new Map<String, Risk_Assessment__c>();
        for (Risk_Assessment__c ra : [
            SELECT Id, Case_Id__c, Risk_Score__c, Risk_Category__c, Assessment_Status__c, Rule_Version__c,
                   Last_Commit_Number__c, AI_Uplift__c, AI_Completed_At__c
            FROM Risk_Assessment__c
            WHERE Case_Id__c IN :idStrings
        ]) {
            existing.put(ra.Case_Id__c, ra);
        }
        Map<Id, Datetime> lastUpdate = new Map<Id, Datetime>();
        for (AggregateResult ar : [
            SELECT ParentId pid, MAX(CreatedDate) lastDt
            FROM CaseComment
            WHERE ParentId IN :openIds AND IsPublished = true
            GROUP BY ParentId
        ]) {
            lastUpdate.put((Id) ar.get('pid'), (Datetime) ar.get('lastDt'));
        }
        Id bhId = null;
        if (cfg.slaUseBusinessHours) {
            List<BusinessHours> bh = [SELECT Id FROM BusinessHours WHERE IsDefault = true LIMIT 1];
            bhId = bh.isEmpty() ? null : bh[0].Id;
        }

        List<Risk_Assessment__c> toUpsert = new List<Risk_Assessment__c>();
        Set<String> changedKeys = new Set<String>();
        Set<String> deactivatedKeys = new Set<String>();
        Map<String, Decimal> scoreByKey = new Map<String, Decimal>();
        Map<String, String> detailByKey = new Map<String, String>();
        List<ER_AuditService.Entry> audits = new List<ER_AuditService.Entry>();

        for (Id cid : caseIds) {
            String key = String.valueOf(cid);
            Risk_Assessment__c prior = existing.get(key);
            Long commitNum = commitByCase == null ? null : commitByCase.get(cid);
            Case c = cases.get(cid);
            ER_AuditService.Entry req = ER_AuditService.entry('ASSESSMENT_REQUESTED', cid, corr);
            audits.add(req);

            if (c == null || c.IsClosed) {
                if (prior == null) {
                    req.details = c == null ? 'Case not found (deleted or inaccessible); nothing to deactivate.' : 'Case is closed; not monitored.';
                    continue;
                }
                Risk_Assessment__c inactive = new Risk_Assessment__c(
                    Case_Id__c = key,
                    Assessment_Status__c = ER_Constants.AS_INACTIVE,
                    Last_Assessed__c = nowTs,
                    Correlation_Id__c = corr
                );
                inactive.Last_Commit_Number__c = maxCommit(prior, commitNum);
                toUpsert.add(inactive);
                deactivatedKeys.add(key);
                continue;
            }

            ER_SlaCalculator.SlaResult sla = ER_SlaCalculator.compute(c.CreatedDate, c.ER_SLA_Deadline__c, c.Priority, nowTs, cfg, bhId);
            ER_RiskScoringEngine.Input inp = new ER_RiskScoringEngine.Input();
            inp.priority = c.Priority;
            inp.isEscalated = c.IsEscalated;
            inp.isClosed = c.IsClosed;
            inp.createdDate = c.CreatedDate;
            inp.reopenCount = c.ER_Reopen_Count__c == null ? 0 : c.ER_Reopen_Count__c.intValue();
            inp.accountTier = c.Account == null ? null : c.Account.ER_Account_Tier__c;
            inp.lastPublicUpdate = lastUpdate.get(cid);
            inp.now = nowTs;
            inp.slaConsumptionPct = sla.consumptionPct;
            inp.slaSource = sla.source;
            ER_RiskScoringEngine.Result r = ER_RiskScoringEngine.score(inp, cfg);

            Boolean aiEligible = aiOn && r.score >= aiSetting.minScore;
            Boolean cooling = aiEligible && prior != null && prior.AI_Completed_At__c != null && prior.AI_Uplift__c != null &&
                prior.AI_Completed_At__c > nowTs.addMinutes(-aiCooldownMinutes);
            Decimal uplift = cooling ? prior.AI_Uplift__c : 0.0;
            Decimal finalScore = (r.score + uplift > 100 ? Decimal.valueOf(100) : r.score + uplift).setScale(1, RoundingMode.HALF_UP);
            String status = !aiEligible ? ER_Constants.AS_SCORED : (cooling ? ER_Constants.AS_ENRICHED : ER_Constants.AS_AI_PENDING);

            Risk_Assessment__c ra = new Risk_Assessment__c(
                Case__c = c.Id,
                Case_Id__c = key,
                Deterministic_Score__c = r.score,
                AI_Uplift__c = uplift,
                Risk_Score__c = finalScore,
                Risk_Category__c = ER_RiskScoringEngine.categorize(finalScore, cfg),
                Assessment_Status__c = status,
                Rule_Version__c = r.ruleVersion,
                Factors_JSON__c = JSON.serialize(r.factors),
                Explanation__c = ER_AuditService.truncate(r.explanation, 4000),
                SLA_Consumption_Pct__c = sla.consumptionPct,
                SLA_Deadline__c = sla.effectiveDeadline,
                Last_Assessed__c = nowTs,
                Correlation_Id__c = corr,
                Last_Error__c = null,
                Retry_Count__c = 0,
                Next_Retry_At__c = null
            );
            ra.Last_Commit_Number__c = maxCommit(prior, commitNum);
            Boolean changed = prior == null || prior.Risk_Score__c != ra.Risk_Score__c || prior.Risk_Category__c != ra.Risk_Category__c ||
                prior.Assessment_Status__c != ra.Assessment_Status__c || prior.Rule_Version__c != ra.Rule_Version__c;
            if (changed) {
                changedKeys.add(key);
            }
            scoreByKey.put(key, r.score);
            detailByKey.put(key, ER_AuditService.truncate(r.explanation, 1500));
            toUpsert.add(ra);
        }

        List<Risk_Assessment__c> saved = new List<Risk_Assessment__c>();
        List<Risk_Assessment__c> changedSaved = new List<Risk_Assessment__c>();
        Set<Id> forActions = new Set<Id>();
        if (!toUpsert.isEmpty()) {
            List<Database.UpsertResult> results = Database.upsert(toUpsert, Risk_Assessment__c.Case_Id__c, false);
            for (Integer i = 0; i < results.size(); i++) {
                Risk_Assessment__c ra = toUpsert[i];
                String key = ra.Case_Id__c;
                if (!results[i].isSuccess()) {
                    out.failed++;
                    ER_AuditService.Entry fe = ER_AuditService.entry('ASSESSMENT_FAILED', (Id) key, corr);
                    fe.outcome = ER_Constants.OUTCOME_FAILURE;
                    fe.details = ER_AuditService.truncate(results[i].getErrors()[0].getMessage(), 1000);
                    audits.add(fe);
                    continue;
                }
                ra.Id = results[i].getId();
                saved.add(ra);
                out.assessmentIds.add(ra.Id);
                if (deactivatedKeys.contains(key)) {
                    out.deactivated++;
                    ER_AuditService.Entry de = ER_AuditService.entry('ASSESSMENT_DEACTIVATED', (Id) key, corr);
                    de.assessmentId = String.valueOf(ra.Id);
                    de.details = 'Case closed or deleted; assessment marked Inactive.';
                    audits.add(de);
                    changedSaved.add(ra);
                    continue;
                }
                out.scored++;
                ER_AuditService.Entry se = ER_AuditService.entry('DETERMINISTIC_SCORED', (Id) key, corr);
                se.assessmentId = String.valueOf(ra.Id);
                se.outcome = ER_Constants.OUTCOME_SUCCESS;
                se.ruleVersion = ra.Rule_Version__c;
                se.score = scoreByKey.get(key);
                se.details = detailByKey.get(key);
                audits.add(se);
                if (changedKeys.contains(key)) {
                    changedSaved.add(ra);
                }
                if (ra.Assessment_Status__c == ER_Constants.AS_AI_PENDING) {
                    out.aiCandidateIds.add(ra.Id);
                } else {
                    forActions.add(ra.Id);
                }
            }
        }
        ER_AuditService.log(audits);
        // Events are published after the DML above; PublishAfterCommit also defers delivery until commitNum.
        ER_PlatformEventPublisher.publish(changedSaved);
        if (!forActions.isEmpty()) {
            ER_ActionRecommendationService.propose(forActions, corr);
        }
        return out;
    }

    private static Decimal maxCommit(Risk_Assessment__c prior, Long commitNum) {
        Decimal prev = prior == null ? null : prior.Last_Commit_Number__c;
        if (commitNum == null) {
            return prev;
        }
        Decimal c = Decimal.valueOf(commitNum);
        return (prev == null || c > prev) ? c : prev;
    }
}
