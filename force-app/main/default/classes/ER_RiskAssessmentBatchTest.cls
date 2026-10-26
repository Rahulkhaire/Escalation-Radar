@IsTest
private class ER_RiskAssessmentBatchTest {
    private static void configure() {
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        ER_Config.setSettingOverride('AI', ER_TestDataFactory.aiSetting('NONE', false));
        ER_Config.setSettingOverride('Slack', new ER_Config.IntegrationSetting());
        ER_Config.setSettingOverride('Actions', new ER_Config.IntegrationSetting());
    }

    @IsTest
    static void initialBackfillAssessesOnlyUnassessedOpenCases() {
        configure();
        Account a = ER_TestDataFactory.account('ER Batch', 'Standard');
        List<Case> cs = ER_TestDataFactory.cases(5, a.Id, 'Medium', null);
        ER_TestDataFactory.assessment(cs[0], 'LOW', 5, 'Scored');
        Test.startTest();
        Database.executeBatch(new ER_RiskAssessmentBatch(ER_RiskAssessmentBatch.MODE_INITIAL, null), 50);
        Test.stopTest();
        System.assertEquals(5, [SELECT COUNT() FROM Risk_Assessment__c WHERE Case__c IN :cs]);
    }

    @IsTest
    static void reprocessUpdatesExistingAssessmentsWithoutDuplicates() {
        configure();
        Account a = ER_TestDataFactory.account('ER Batch2', 'Strategic');
        List<Case> cs = ER_TestDataFactory.cases(3, a.Id, 'High', null);
        for (Case c : cs) {
            ER_TestDataFactory.assessment(c, 'LOW', 10, 'Scored');
        }
        Test.startTest();
        Database.executeBatch(new ER_RiskAssessmentBatch(ER_RiskAssessmentBatch.MODE_REPROCESS, null), 50);
        Test.stopTest();
        System.assertEquals(3, [SELECT COUNT() FROM Risk_Assessment__c WHERE Case__c IN :cs]);
    }

    @IsTest
    static void recoverRepairsAssessmentsInErrorState() {
        configure();
        Account a = ER_TestDataFactory.account('ER Batch3', 'Basic');
        Case c = ER_TestDataFactory.cases(1, a.Id, 'Low', null)[0];
        ER_TestDataFactory.assessment(c, 'LOW', 0, ER_Constants.AS_ERROR);
        Test.startTest();
        Database.executeBatch(new ER_RiskAssessmentBatch(ER_RiskAssessmentBatch.MODE_RECOVER, null), 50);
        Test.stopTest();
        System.assertEquals(ER_Constants.AS_SCORED, [SELECT Assessment_Status__c FROM Risk_Assessment__c WHERE Case__c = :c.Id].Assessment_Status__c);
    }

    @IsTest
    static void explicitScopeLimitsTheBatch() {
        configure();
        Account a = ER_TestDataFactory.account('ER Batch4', 'Basic');
        List<Case> cs = ER_TestDataFactory.cases(3, a.Id, 'Low', null);
        Test.startTest();
        Database.executeBatch(new ER_RiskAssessmentBatch(ER_RiskAssessmentBatch.MODE_REPROCESS, new Set<Id>{ cs[0].Id }), 50);
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Risk_Assessment__c WHERE Case__c IN :cs]);
    }

    @IsTest
    static void schedulableStartsRecoveryBatch() {
        configure();
        Test.startTest();
        String jobId = System.schedule('ER recovery test', '0 0 3 * * ?', new ER_RecoverySchedulable());
        Test.stopTest();
        System.assertNotEquals(null, jobId);
    }
}
