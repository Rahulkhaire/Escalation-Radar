@IsTest
private class ER_CaseRiskServiceTest {
    @TestSetup
    static void setup() {
        Account strategic = ER_TestDataFactory.account('ER Strategic', 'Strategic');
        ER_TestDataFactory.cases(2, strategic.Id, 'High', Datetime.now().addHours(2));
    }

    private static void configure(Boolean aiOn) {
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        ER_Config.setSettingOverride('AI', ER_TestDataFactory.aiSetting(aiOn ? 'MOCK' : 'NONE', aiOn));
        ER_Config.setSettingOverride('Slack', new ER_Config.IntegrationSetting());
        ER_Config.setSettingOverride('Actions', new ER_Config.IntegrationSetting());
    }

    private static Map<Id, Risk_Assessment__c> assessmentsByCase() {
        Map<Id, Risk_Assessment__c> m = new Map<Id, Risk_Assessment__c>();
        for (Risk_Assessment__c ra : [
            SELECT Id, Case__c, Case_Id__c, Risk_Score__c, Deterministic_Score__c, Risk_Category__c, Assessment_Status__c, Rule_Version__c,
                   Factors_JSON__c, Explanation__c, Last_Commit_Number__c, SLA_Consumption_Pct__c
            FROM Risk_Assessment__c
        ]) {
            m.put(ra.Case__c, ra);
        }
        return m;
    }

    @IsTest
    static void scoresCaseStoresFactorsAndRuleVersion() {
        configure(false);
        Case c = [SELECT Id FROM Case LIMIT 1];
        Test.setCreatedDate(c.Id, Datetime.now().addHours(-18)); // 18h elapsed of a 20h supplied window = 90%
        Case reloaded = [SELECT Id, ER_SLA_Deadline__c FROM Case WHERE Id = :c.Id];
        reloaded.ER_SLA_Deadline__c = Datetime.now().addHours(2);
        update reloaded;
        Test.startTest();
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        ER_CaseRiskService.Outcome out = ER_CaseRiskService.assessCases(new Set<Id>{ c.Id }, null, 'ER-T1');
        Test.stopTest();
        System.assertEquals(1, out.scored);
        Risk_Assessment__c ra = assessmentsByCase().get(c.Id);
        System.assertNotEquals(null, ra);
        System.assertEquals('test-1.0', ra.Rule_Version__c);
        System.assertEquals(ER_Constants.AS_SCORED, ra.Assessment_Status__c);
        System.assertEquals(ra.Deterministic_Score__c, ra.Risk_Score__c);
        System.assert(ra.SLA_Consumption_Pct__c > 85 && ra.SLA_Consumption_Pct__c < 95, 'SLA pct ' + ra.SLA_Consumption_Pct__c);
        List<Object> factors = (List<Object>) JSON.deserializeUntyped(ra.Factors_JSON__c);
        System.assertEquals(5, factors.size());
        System.assert(ra.Explanation__c.contains('SLA is'));
        Integer audits = [SELECT COUNT() FROM Escalation_Audit__c WHERE Case_Id__c = :String.valueOf(c.Id) AND Event_Type__c = 'DETERMINISTIC_SCORED'];
        System.assertEquals(1, audits);
    }

    @IsTest
    static void aiEligibleCasesAreMarkedPendingAndReturned() {
        configure(true);
        Case c = [SELECT Id FROM Case LIMIT 1];
        ER_CaseRiskService.Outcome out = ER_CaseRiskService.assessCases(new Set<Id>{ c.Id }, null, 'ER-T2');
        System.assertEquals(1, out.aiCandidateIds.size());
        System.assertEquals(ER_Constants.AS_AI_PENDING, assessmentsByCase().get(c.Id).Assessment_Status__c);
    }

    @IsTest
    static void reprocessingIsIdempotentOneAssessmentPerCase() {
        configure(false);
        Set<Id> ids = new Map<Id, Case>([SELECT Id FROM Case]).keySet();
        ER_CaseRiskService.assessCases(ids, null, 'ER-T3');
        ER_CaseRiskService.assessCases(ids, null, 'ER-T3b');
        System.assertEquals(ids.size(), [SELECT COUNT() FROM Risk_Assessment__c]);
    }

    @IsTest
    static void commitNumbersOnlyMoveForward() {
        configure(false);
        Case c = [SELECT Id FROM Case LIMIT 1];
        ER_CaseRiskService.assessCases(new Set<Id>{ c.Id }, new Map<Id, Long>{ c.Id => 100L }, 'ER-T4');
        ER_CaseRiskService.assessCases(new Set<Id>{ c.Id }, new Map<Id, Long>{ c.Id => 50L }, 'ER-T4b');
        System.assertEquals(100, assessmentsByCase().get(c.Id).Last_Commit_Number__c);
    }

    @IsTest
    static void closedAndDeletedCasesBecomeInactive() {
        configure(false);
        List<Case> cs = [SELECT Id FROM Case];
        ER_CaseRiskService.assessCases(new Map<Id, Case>(cs).keySet(), null, 'ER-T5');
        cs[0].Status = 'Closed';
        update cs[0];
        Id deletedId = cs[1].Id;
        delete cs[1];
        ER_CaseRiskService.Outcome out = ER_CaseRiskService.assessCases(new Set<Id>{ cs[0].Id, deletedId }, null, 'ER-T5b');
        System.assertEquals(2, out.deactivated);
        for (Risk_Assessment__c ra : [SELECT Assessment_Status__c FROM Risk_Assessment__c]) {
            System.assertEquals(ER_Constants.AS_INACTIVE, ra.Assessment_Status__c);
        }
    }

    @IsTest
    static void accountTierChangeRaisesScore() {
        configure(false);
        Account basic = ER_TestDataFactory.account('ER Basic', 'Basic');
        Case c = ER_TestDataFactory.cases(1, basic.Id, 'Low', null)[0];
        ER_CaseRiskService.assessCases(new Set<Id>{ c.Id }, null, 'ER-T6');
        Decimal before = assessmentsByCase().get(c.Id).Risk_Score__c;
        basic.ER_Account_Tier__c = 'Strategic';
        update basic;
        ER_CaseRiskService.assessCases(new Set<Id>{ c.Id }, null, 'ER-T6b');
        System.assert(assessmentsByCase().get(c.Id).Risk_Score__c > before);
    }

    @IsTest
    static void missingFieldsDoNotBreakScoring() {
        configure(false);
        Case c = new Case(Subject = 'No priority no account', Status = 'New', Origin = 'Web');
        insert c;
        ER_CaseRiskService.Outcome out = ER_CaseRiskService.assessCases(new Set<Id>{ c.Id }, null, 'ER-T7');
        System.assertEquals(1, out.scored);
        System.assertEquals(0, out.failed);
    }

    @IsTest
    static void bulkTwoHundredCases() {
        configure(false);
        Account a = ER_TestDataFactory.account('ER Bulk', 'Enterprise');
        List<Case> cs = ER_TestDataFactory.cases(200, a.Id, 'Medium', null);
        Test.startTest();
        ER_CaseRiskService.Outcome out = ER_CaseRiskService.assessCases(new Map<Id, Case>(cs).keySet(), null, 'ER-T8');
        Test.stopTest();
        System.assertEquals(200, out.scored);
        System.assertEquals(0, out.failed);
        System.assertEquals(200, [SELECT COUNT() FROM Risk_Assessment__c WHERE Case__c IN :cs]);
    }

    @IsTest
    static void reopenCounterIncrementsWhenClosedCaseIsReopened() {
        Case c = new Case(Subject = 'Reopen me', Status = 'Closed', Origin = 'Web', Priority = 'Low');
        insert c;
        c.Status = 'Working';
        update c;
        System.assertEquals(1, [SELECT ER_Reopen_Count__c FROM Case WHERE Id = :c.Id].ER_Reopen_Count__c);
        c.Priority = 'High';
        update c;
        System.assertEquals(1, [SELECT ER_Reopen_Count__c FROM Case WHERE Id = :c.Id].ER_Reopen_Count__c);
    }
}
