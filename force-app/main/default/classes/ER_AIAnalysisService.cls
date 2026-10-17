/**
 * AI enrichment worker logic. Transaction shape (required by the platform): queries -> callouts -> DML.
 * AI output is validated, bounded and advisory only: it can add a capped uplift to the deterministic score and
 * suggest allowlisted action identifiers. It never edits Cases, constructs queries or executes anything.
 * When the provider is disabled, unavailable or returns invalid data, the deterministic result stands.
 */
public without sharing class ER_AIAnalysisService {
    @TestVisible
    private static ER_AIProvider providerOverride;
    @TestVisible
    private static Integer retryBaseMinutes = 5;

    public static void analyze(Set<Id> assessmentIds, String correlationId) {
        if (assessmentIds == null || assessmentIds.isEmpty()) {
            return;
        }
        String corr = String.isBlank(correlationId) ? ER_Constants.newCorrelationId() : correlationId;
        ER_Config.IntegrationSetting s = ER_Config.ai();
        ER_Config.RiskConfig cfg = ER_Config.getRiskConfig();
        String pendingStatus = ER_Constants.AS_AI_PENDING;
        List<Risk_Assessment__c> pending = [
            SELECT Id, Case__c, Case_Id__c, Deterministic_Score__c, Risk_Score__c, Risk_Category__c, Assessment_Status__c,
                   Explanation__c, Retry_Count__c
            FROM Risk_Assessment__c
            WHERE Id IN :assessmentIds AND Assessment_Status__c = :pendingStatus
        ];
        if (pending.isEmpty()) {
            return;
        }
        ER_AIProvider provider = resolveProvider(s);
        Set<Id> caseIds = new Set<Id>();
        for (Risk_Assessment__c ra : pending) {
            if (ra.Case__c != null) {
                caseIds.add(ra.Case__c);
            }
        }
        Map<Id, Case> cases = new Map<Id, Case>([
            SELECT Id, Subject, Description, Priority, Account.ER_Account_Tier__c FROM Case WHERE Id IN :caseIds
        ]);
        Map<Id, List<String>> comments = loadComments(caseIds);

        List<Risk_Assessment__c> updates = new List<Risk_Assessment__c>();
        List<Risk_Assessment__c> eventSource = new List<Risk_Assessment__c>();
        List<ER_AuditService.Entry> audits = new List<ER_AuditService.Entry>();
        List<Integration_Log__c> logs = new List<Integration_Log__c>();
        Set<Id> terminal = new Set<Id>();
        Datetime nowTs = Datetime.now();

        // ---- Phase 1: callouts (no DML allowed before this loop finishes) ----
        for (Risk_Assessment__c ra : pending) {
            Risk_Assessment__c upd = new Risk_Assessment__c(Id = ra.Id, Correlation_Id__c = corr);
            Case c = cases.get(ra.Case__c);
            if (provider == null || c == null) {
                upd.Assessment_Status__c = c == null ? ER_Constants.AS_INACTIVE : ER_Constants.AS_SCORED;
                upd.Last_Error__c = c == null ? 'Case no longer available.' : 'AI analysis is disabled; deterministic result used.';
                upd.Next_Retry_At__c = null;
                updates.add(upd);
                eventSource.add(copyForEvent(ra, upd));
                if (c != null) {
                    terminal.add(ra.Id);
                }
                continue;
            }
            ER_AuditService.Entry reqEntry = ER_AuditService.entry('AI_REQUESTED', ra.Case__c, corr);
            reqEntry.assessmentId = String.valueOf(ra.Id);
            reqEntry.details = 'Provider ' + provider.name() + '; payload limited to ' + s.maxPayloadChars + ' chars; PII redaction applied.';
            audits.add(reqEntry);

            Integer attempt = (ra.Retry_Count__c == null ? 0 : ra.Retry_Count__c.intValue()) + 1;
            Long t0 = System.currentTimeMillis();
            try {
                ER_AIAnalysis a = provider.analyze(buildRequest(ra, c, comments.get(c.Id), corr, s));
                Long dur = System.currentTimeMillis() - t0;
                Decimal uplift = computeUplift(a, s);
                Decimal det = ra.Deterministic_Score__c == null ? 0.0 : ra.Deterministic_Score__c;
                Decimal finalScore = (det + uplift > 100 ? Decimal.valueOf(100) : det + uplift).setScale(1, RoundingMode.HALF_UP);
                upd.AI_Uplift__c = uplift;
                upd.Risk_Score__c = finalScore;
                upd.Risk_Category__c = ER_RiskScoringEngine.categorize(finalScore, cfg);
                upd.Assessment_Status__c = ER_Constants.AS_ENRICHED;
                upd.AI_Provider__c = a.provider;
                upd.AI_Summary__c = a.summary;
                upd.AI_Risk_Explanation__c = a.riskExplanation;
                upd.AI_Urgency__c = a.urgency;
                upd.AI_Sentiment__c = a.sentiment;
                upd.AI_Root_Causes__c = ER_AuditService.truncate(String.join(a.rootCauses, ','), 255);
                upd.AI_Next_Steps__c = ER_AuditService.truncate(String.join(a.nextSteps, '\n'), 4000);
                upd.AI_Suggested_Update__c = a.suggestedCustomerUpdate;
                upd.AI_Confidence__c = a.confidence;
                upd.AI_Proposed_Actions__c = ER_AuditService.truncate(String.join(a.proposedActions, ','), 255);
                upd.AI_Completed_At__c = nowTs;
                upd.Retry_Count__c = 0;
                upd.Last_Error__c = null;
                upd.Next_Retry_At__c = null;
                terminal.add(ra.Id);
                ER_AuditService.Entry done = ER_AuditService.entry('AI_COMPLETED', ra.Case__c, corr);
                done.assessmentId = String.valueOf(ra.Id);
                done.outcome = ER_Constants.OUTCOME_SUCCESS;
                done.score = finalScore;
                done.details = 'Validated AI response stored. Urgency ' + a.urgency + ', uplift ' + uplift + ' (cap ' + s.maxUplift + '), provider ' + a.provider + '.';
                audits.add(done);
                logs.add(log(ra, corr, 'Success', 200, dur, null, false, attempt - 1));
            } catch (ER_IntegrationException ie) {
                Long dur = System.currentTimeMillis() - t0;
                recordFailure(ra, upd, ie.getMessage(), ie.retryable, ie.statusCode, dur, attempt, s, corr, nowTs, audits, logs, terminal);
            } catch (ER_AIValidationException ve) {
                Long dur = System.currentTimeMillis() - t0;
                recordFailure(ra, upd, ve.getMessage(), false, null, dur, attempt, s, corr, nowTs, audits, logs, terminal);
            } catch (Exception ex) {
                Long dur = System.currentTimeMillis() - t0;
                recordFailure(ra, upd, 'Unexpected AI processing error: ' + ex.getTypeName(), false, null, dur, attempt, s, corr, nowTs, audits, logs, terminal);
            }
            updates.add(upd);
            eventSource.add(copyForEvent(ra, upd));
        }

        // ---- Phase 2: DML ----
        List<Database.SaveResult> results = Database.update(updates, false);
        List<Risk_Assessment__c> toPublish = new List<Risk_Assessment__c>();
        Set<Id> okTerminal = new Set<Id>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                toPublish.add(eventSource[i]);
                if (terminal.contains(updates[i].Id)) {
                    okTerminal.add(updates[i].Id);
                }
            } else {
                ER_AuditService.Entry fe = ER_AuditService.entry('AI_RESULT_SAVE_FAILED', null, corr);
                fe.assessmentId = String.valueOf(updates[i].Id);
                fe.outcome = ER_Constants.OUTCOME_FAILURE;
                fe.details = ER_AuditService.truncate(results[i].getErrors()[0].getMessage(), 1000);
                audits.add(fe);
            }
        }
        Database.insert(logs, false);
        ER_AuditService.log(audits);
        ER_PlatformEventPublisher.publish(toPublish);
        if (!okTerminal.isEmpty()) {
            ER_ActionRecommendationService.propose(okTerminal, corr);
        }
    }

    private static void recordFailure(
        Risk_Assessment__c ra,
        Risk_Assessment__c upd,
        String message,
        Boolean retryable,
        Integer httpStatus,
        Long durationMs,
        Integer attempt,
        ER_Config.IntegrationSetting s,
        String corr,
        Datetime nowTs,
        List<ER_AuditService.Entry> audits,
        List<Integration_Log__c> logs,
        Set<Id> terminal
    ) {
        Boolean willRetry = retryable && attempt < s.maxRetries;
        upd.Retry_Count__c = attempt;
        upd.Last_Error__c = ER_AuditService.truncate(message, 255);
        if (willRetry) {
            Integer minutes = retryBaseMinutes * Math.pow(2, attempt - 1).intValue();
            upd.Assessment_Status__c = ER_Constants.AS_AI_PENDING;
            upd.Next_Retry_At__c = nowTs.addMinutes(minutes);
        } else {
            upd.Assessment_Status__c = ER_Constants.AS_AI_FAILED;
            upd.Next_Retry_At__c = null;
            terminal.add(ra.Id);
        }
        ER_AuditService.Entry fail = ER_AuditService.entry('AI_FAILED', ra.Case__c, corr);
        fail.assessmentId = String.valueOf(ra.Id);
        fail.outcome = ER_Constants.OUTCOME_FAILURE;
        fail.retryCount = attempt;
        fail.details = message + (willRetry ? ' Retry scheduled.' : ' No further retries; deterministic result stands.');
        audits.add(fail);
        if (willRetry) {
            ER_AuditService.Entry retry = ER_AuditService.entry('RETRY_SCHEDULED', ra.Case__c, corr);
            retry.assessmentId = String.valueOf(ra.Id);
            retry.retryCount = attempt;
            retry.details = 'Next attempt not before ' + upd.Next_Retry_At__c.formatGmt('yyyy-MM-dd HH:mm:ss') + ' UTC.';
            audits.add(retry);
        }
        logs.add(log(ra, corr, 'Failure', httpStatus, durationMs, message, retryable, attempt));
    }

    private static Integration_Log__c log(
        Risk_Assessment__c ra, String corr, String status, Integer http, Long dur, String err, Boolean retryable, Integer retries
    ) {
        return new Integration_Log__c(
            Integration__c = 'AI',
            Operation__c = 'analyze',
            Case_Id__c = ra.Case_Id__c,
            Correlation_Id__c = corr,
            Status__c = status,
            HTTP_Status__c = http,
            Duration_Ms__c = dur,
            Error_Message__c = ER_AuditService.truncate(err, 2000),
            Retryable__c = retryable,
            Retry_Count__c = retries
        );
    }

    private static Risk_Assessment__c copyForEvent(Risk_Assessment__c ra, Risk_Assessment__c upd) {
        return new Risk_Assessment__c(
            Id = ra.Id,
            Case_Id__c = ra.Case_Id__c,
            Risk_Score__c = upd.Risk_Score__c == null ? ra.Risk_Score__c : upd.Risk_Score__c,
            Risk_Category__c = upd.Risk_Category__c == null ? ra.Risk_Category__c : upd.Risk_Category__c,
            Assessment_Status__c = upd.Assessment_Status__c,
            Correlation_Id__c = upd.Correlation_Id__c
        );
    }

    @TestVisible
    private static Decimal computeUplift(ER_AIAnalysis a, ER_Config.IntegrationSetting s) {
        Decimal cap = s.maxUplift == null ? 0.0 : s.maxUplift;
        if (a.confidence == null || a.confidence < 0.5) {
            return 0.0;
        }
        if (a.urgency == 'HIGH') {
            return cap;
        }
        if (a.urgency == 'MEDIUM') {
            return (cap / 2).setScale(1, RoundingMode.HALF_UP);
        }
        return 0.0;
    }

    private static ER_AIRequest buildRequest(Risk_Assessment__c ra, Case c, List<String> cmts, String corr, ER_Config.IntegrationSetting s) {
        ER_AIRequest req = new ER_AIRequest();
        req.caseId = c.Id;
        req.correlationId = corr;
        req.priority = c.Priority;
        req.accountTier = c.Account == null ? null : c.Account.ER_Account_Tier__c;
        req.deterministicScore = ra.Deterministic_Score__c;
        req.riskCategory = ra.Risk_Category__c;
        req.factorSummary = ER_PiiRedactor.sanitize(ra.Explanation__c, 800);
        req.subject = ER_PiiRedactor.sanitize(c.Subject, 200);
        req.description = ER_PiiRedactor.sanitize(c.Description, 1500);
        if (cmts != null) {
            req.recentComments = cmts;
        }
        return req;
    }

    private static Map<Id, List<String>> loadComments(Set<Id> caseIds) {
        Map<Id, List<String>> out = new Map<Id, List<String>>();
        for (CaseComment cc : [
            SELECT ParentId, CommentBody FROM CaseComment WHERE ParentId IN :caseIds AND IsPublished = true ORDER BY CreatedDate DESC LIMIT 200
        ]) {
            List<String> l = out.get(cc.ParentId);
            if (l == null) {
                l = new List<String>();
                out.put(cc.ParentId, l);
            }
            if (l.size() < 3) {
                l.add(ER_PiiRedactor.sanitize(cc.CommentBody, 400));
            }
        }
        return out;
    }

    private static ER_AIProvider resolveProvider(ER_Config.IntegrationSetting s) {
        if (providerOverride != null) {
            return providerOverride;
        }
        if (!s.enabled) {
            return null;
        }
        if (s.provider == 'MOCK') {
            return new ER_MockAIProvider();
        }
        if (s.provider == 'LLM') {
            return new ER_LLMProvider(s);
        }
        return null;
    }
}
