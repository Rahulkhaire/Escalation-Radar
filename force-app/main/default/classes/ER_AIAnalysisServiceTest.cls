@IsTest
private class ER_AIAnalysisServiceTest {
    private static Risk_Assessment__c pending(Integer retryCount) {
        Account a = ER_TestDataFactory.account('ER AI ' + retryCount, 'Strategic');
        Case c = ER_TestDataFactory.cases(1, a.Id, 'High', null)[0];
        Risk_Assessment__c ra = ER_TestDataFactory.assessment(c, 'HIGH', 60, ER_Constants.AS_AI_PENDING);
        ra.Retry_Count__c = retryCount;
        update ra;
        return ra;
    }

    private static void configure() {
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        ER_Config.setSettingOverride('AI', ER_TestDataFactory.aiSetting('MOCK', true));
        ER_Config.setSettingOverride('Slack', new ER_Config.IntegrationSetting());
        ER_Config.setSettingOverride('Actions', new ER_Config.IntegrationSetting());
    }

    private static Risk_Assessment__c reload(Id id) {
        return [
            SELECT Id, Assessment_Status__c, Risk_Score__c, Deterministic_Score__c, AI_Uplift__c, Risk_Category__c, AI_Summary__c, AI_Urgency__c,
                   Retry_Count__c, Next_Retry_At__c, Last_Error__c, AI_Proposed_Actions__c
            FROM Risk_Assessment__c WHERE Id = :id
        ];
    }

    @IsTest
    static void successStoresValidatedAnalysisAndCappedUplift() {
        configure();
        Risk_Assessment__c ra = pending(0);
        ER_TestDataFactory.StubProvider stub = new ER_TestDataFactory.StubProvider();
        stub.result = ER_TestDataFactory.analysis('HIGH', 0.8, new List<String>{ ER_Constants.ACT_REVIEW });
        ER_AIAnalysisService.providerOverride = stub;
        Test.startTest();
        ER_AIAnalysisService.analyze(new Set<Id>{ ra.Id }, 'ER-AI1');
        Test.stopTest();
        Risk_Assessment__c r = reload(ra.Id);
        System.assertEquals(ER_Constants.AS_ENRICHED, r.Assessment_Status__c);
        System.assertEquals(5.0, r.AI_Uplift__c);
        System.assertEquals(65.0, r.Risk_Score__c);
        System.assertEquals(60.0, r.Deterministic_Score__c); // deterministic score is never overwritten
        System.assertEquals('Stub summary', r.AI_Summary__c);
        System.assertEquals(1, stub.calls);
        System.assertEquals(1, [SELECT COUNT() FROM Escalation_Audit__c WHERE Event_Type__c = 'AI_COMPLETED']);
        System.assertEquals(1, [SELECT COUNT() FROM Integration_Log__c WHERE Integration__c = 'AI' AND Status__c = 'Success']);
        System.assert([SELECT COUNT() FROM Escalation_Action__c WHERE Risk_Assessment__c = :ra.Id AND Action_Type__c = 'REQUEST_MANAGER_REVIEW'] > 0);
    }

    @IsTest
    static void lowConfidenceOrLowUrgencyAddsNoUplift() {
        ER_Config.IntegrationSetting s = ER_TestDataFactory.aiSetting('MOCK', true);
        System.assertEquals(0.0, ER_AIAnalysisService.computeUplift(ER_TestDataFactory.analysis('HIGH', 0.3, new List<String>()), s));
        System.assertEquals(0.0, ER_AIAnalysisService.computeUplift(ER_TestDataFactory.analysis('HIGH', null, new List<String>()), s));
        System.assertEquals(0.0, ER_AIAnalysisService.computeUplift(ER_TestDataFactory.analysis('LOW', 0.9, new List<String>()), s));
        System.assertEquals(2.5, ER_AIAnalysisService.computeUplift(ER_TestDataFactory.analysis('MEDIUM', 0.9, new List<String>()), s));
    }

    @IsTest
    static void retryableFailureSchedulesBackoff() {
        configure();
        Risk_Assessment__c ra = pending(0);
        ER_TestDataFactory.StubProvider stub = new ER_TestDataFactory.StubProvider();
        stub.toThrow = new ER_IntegrationException('rate limited', true, 429);
        ER_AIAnalysisService.providerOverride = stub;
        ER_AIAnalysisService.analyze(new Set<Id>{ ra.Id }, 'ER-AI2');
        Risk_Assessment__c r = reload(ra.Id);
        System.assertEquals(ER_Constants.AS_AI_PENDING, r.Assessment_Status__c);
        System.assertEquals(1, r.Retry_Count__c);
        System.assert(r.Next_Retry_At__c > Datetime.now());
        System.assertEquals(60.0, r.Risk_Score__c); // deterministic result stands
        System.assertEquals(1, [SELECT COUNT() FROM Escalation_Audit__c WHERE Event_Type__c = 'RETRY_SCHEDULED']);
        System.assertEquals(1, [SELECT COUNT() FROM Integration_Log__c WHERE Integration__c = 'AI' AND Status__c = 'Failure' AND Retryable__c = true]);
    }

    @IsTest
    static void retryLimitMakesFailureTerminal() {
        configure();
        Risk_Assessment__c ra = pending(2); // third attempt reaches maxRetries = 3
        ER_TestDataFactory.StubProvider stub = new ER_TestDataFactory.StubProvider();
        stub.toThrow = new ER_IntegrationException('still down', true, 503);
        ER_AIAnalysisService.providerOverride = stub;
        ER_AIAnalysisService.analyze(new Set<Id>{ ra.Id }, 'ER-AI3');
        Risk_Assessment__c r = reload(ra.Id);
        System.assertEquals(ER_Constants.AS_AI_FAILED, r.Assessment_Status__c);
        System.assertEquals(3, r.Retry_Count__c);
        System.assertEquals(null, r.Next_Retry_At__c);
    }

    @IsTest
    static void invalidAiOutputFailsWithoutRetry() {
        configure();
        Risk_Assessment__c ra = pending(0);
        ER_TestDataFactory.StubProvider stub = new ER_TestDataFactory.StubProvider();
        stub.toThrow = new ER_AIValidationException('AI response was not valid JSON.');
        ER_AIAnalysisService.providerOverride = stub;
        ER_AIAnalysisService.analyze(new Set<Id>{ ra.Id }, 'ER-AI4');
        Risk_Assessment__c r = reload(ra.Id);
        System.assertEquals(ER_Constants.AS_AI_FAILED, r.Assessment_Status__c);
        System.assertEquals(null, r.AI_Summary__c);
    }

    @IsTest
    static void disabledAiFallsBackToDeterministicResult() {
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        ER_Config.setSettingOverride('AI', ER_TestDataFactory.aiSetting('NONE', false));
        ER_Config.setSettingOverride('Slack', new ER_Config.IntegrationSetting());
        ER_Config.setSettingOverride('Actions', new ER_Config.IntegrationSetting());
        Risk_Assessment__c ra = pending(0);
        ER_AIAnalysisService.analyze(new Set<Id>{ ra.Id }, 'ER-AI5');
        System.assertEquals(ER_Constants.AS_SCORED, reload(ra.Id).Assessment_Status__c);
    }

    @IsTest
    static void unexpectedExceptionIsContained() {
        configure();
        Risk_Assessment__c ra = pending(0);
        ER_TestDataFactory.StubProvider stub = new ER_TestDataFactory.StubProvider();
        stub.toThrow = new NullPointerException();
        ER_AIAnalysisService.providerOverride = stub;
        ER_AIAnalysisService.analyze(new Set<Id>{ ra.Id }, 'ER-AI6');
        System.assertEquals(ER_Constants.AS_AI_FAILED, reload(ra.Id).Assessment_Status__c);
    }

    @IsTest
    static void queueableProcessesAiModeInBoundedChunks() {
        configure();
        ER_RiskAssessmentQueueable.aiChunkSize = 1;
        Risk_Assessment__c a1 = pending(0);
        Risk_Assessment__c a2 = pending(0);
        ER_TestDataFactory.StubProvider stub = new ER_TestDataFactory.StubProvider();
        stub.result = ER_TestDataFactory.analysis('LOW', 0.9, new List<String>());
        ER_AIAnalysisService.providerOverride = stub;
        Test.startTest();
        System.enqueueJob(new ER_RiskAssessmentQueueable(ER_RiskAssessmentQueueable.MODE_AI, new List<Id>{ a1.Id, a2.Id }, null, 'ER-AI7'));
        Test.stopTest();
        // Only the first chunk is guaranteed in a test (chaining depth is limited); the remainder stays AI_Pending for recovery.
        System.assertEquals(ER_Constants.AS_ENRICHED, reload(a1.Id).Assessment_Status__c);
        System.assert(new Set<String>{ ER_Constants.AS_ENRICHED, ER_Constants.AS_AI_PENDING }.contains(reload(a2.Id).Assessment_Status__c));
    }

    @IsTest
    static void recoveryBatchPicksUpDueRetries() {
        configure();
        Risk_Assessment__c ra = pending(1);
        ra.Next_Retry_At__c = Datetime.now().addMinutes(-1);
        update ra;
        ER_TestDataFactory.StubProvider stub = new ER_TestDataFactory.StubProvider();
        stub.result = ER_TestDataFactory.analysis('LOW', 0.9, new List<String>());
        ER_AIAnalysisService.providerOverride = stub;
        Test.startTest();
        Database.executeBatch(new ER_RiskAssessmentBatch(ER_RiskAssessmentBatch.MODE_RECOVER, null), 50);
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Integration_Log__c WHERE Integration__c = 'BATCH' AND Operation__c = 'RECOVER']);
        System.assert(new Set<String>{ ER_Constants.AS_ENRICHED, ER_Constants.AS_AI_PENDING }.contains(reload(ra.Id).Assessment_Status__c));
    }
}
