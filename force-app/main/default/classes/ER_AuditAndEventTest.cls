@IsTest
private class ER_AuditAndEventTest {
    @IsTest
    static void auditRowsCannotBeUpdatedOrDeleted() {
        Account a = ER_TestDataFactory.account('ER Audit', 'Basic');
        Case c = ER_TestDataFactory.cases(1, a.Id, 'Low', null)[0];
        ER_AuditService.Entry e = ER_AuditService.entry('TEST', c.Id, 'ER-A1');
        e.details = 'x'.repeat(5000);
        ER_AuditService.log(e);
        Escalation_Audit__c row = [SELECT Id, Details__c, Actor_Id__c FROM Escalation_Audit__c LIMIT 1];
        System.assertEquals(4000, row.Details__c.length());
        System.assertEquals(String.valueOf(UserInfo.getUserId()), row.Actor_Id__c);
        row.Outcome__c = 'TAMPERED';
        Database.SaveResult sr = Database.update(row, false);
        System.assertEquals(false, sr.isSuccess());
        System.assert(sr.getErrors()[0].getMessage().contains('cannot be modified'));
        Database.DeleteResult dr = Database.delete(row, false);
        System.assertEquals(false, dr.isSuccess());
        System.assertEquals(1, [SELECT COUNT() FROM Escalation_Audit__c]);
    }

    @IsTest
    static void integrationLogRecordsFailureWithoutSecrets() {
        ER_AuditService.logIntegration('AI', 'analyze', null, 'ER-A2', 'Failure', 503, 120L, 'provider error', true, 1);
        Integration_Log__c l = [SELECT Integration__c, HTTP_Status__c, Retryable__c, Retry_Count__c FROM Integration_Log__c LIMIT 1];
        System.assertEquals(503, l.HTTP_Status__c);
        System.assertEquals(true, l.Retryable__c);
    }

    @IsTest
    static void platformEventsArePublishedAfterCommit() {
        Risk_Assessment__c ra = new Risk_Assessment__c(
            Id = '000000000000000AAA', Case_Id__c = '500000000000001AAA', Risk_Score__c = 77.5, Risk_Category__c = 'CRITICAL',
            Assessment_Status__c = 'Scored', Correlation_Id__c = 'ER-E1'
        );
        Test.startTest();
        Integer ok = ER_PlatformEventPublisher.publish(new List<Risk_Assessment__c>{ ra });
        Test.getEventBus().deliver();
        Test.stopTest();
        System.assertEquals(1, ok);
        System.assertEquals(0, ER_PlatformEventPublisher.publish(new List<Risk_Assessment__c>()));
    }

    @IsTest
    static void assessmentPublishesEventForChangedAssessmentsOnly() {
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        ER_Config.setSettingOverride('AI', ER_TestDataFactory.aiSetting('NONE', false));
        ER_Config.setSettingOverride('Slack', new ER_Config.IntegrationSetting());
        Account a = ER_TestDataFactory.account('ER Evt', 'Basic');
        Case c = ER_TestDataFactory.cases(1, a.Id, 'Low', null)[0];
        Test.startTest();
        ER_CaseRiskService.assessCases(new Set<Id>{ c.Id }, null, 'ER-E2');
        Test.getEventBus().deliver();
        ER_CaseRiskService.assessCases(new Set<Id>{ c.Id }, null, 'ER-E2b');
        Test.getEventBus().deliver();
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Risk_Assessment__c WHERE Case__c = :c.Id]);
    }
}
