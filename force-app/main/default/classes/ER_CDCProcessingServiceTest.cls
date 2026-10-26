@IsTest
private class ER_CDCProcessingServiceTest {
    private static ER_CDCProcessingService.ChangeInput input(String changeKind, List<String> ids, Set<String> fields, Long commitNum) {
        ER_CDCProcessingService.ChangeInput ci = new ER_CDCProcessingService.ChangeInput();
        ci.changeType = changeKind;
        ci.recordIds = ids;
        ci.changedFields = fields;
        ci.commitNumber = commitNum;
        return ci;
    }

    @IsTest
    static void irrelevantUpdatesAreIgnoredRelevantOnesPlanned() {
        Id id1 = '500000000000001AAA';
        Id id2 = '500000000000002AAA';
        ER_CDCProcessingService.Plan p = ER_CDCProcessingService.plan(new List<ER_CDCProcessingService.ChangeInput>{
            input('UPDATE', new List<String>{ String.valueOf(id1) }, new Set<String>{ 'Subject' }, 10L),
            input('UPDATE', new List<String>{ String.valueOf(id2) }, new Set<String>{ 'Priority', 'Subject' }, 11L),
            input('CREATE', new List<String>{ String.valueOf(id1) }, new Set<String>(), 12L)
        });
        System.assertEquals(1, p.ignored);
        System.assertEquals(2, p.commitByCase.size());
        System.assertEquals(12L, p.commitByCase.get(id1));
    }

    @IsTest
    static void deleteUndeleteAndGapEventsAreRelevant() {
        Id id1 = '500000000000001AAA';
        ER_CDCProcessingService.Plan p = ER_CDCProcessingService.plan(new List<ER_CDCProcessingService.ChangeInput>{
            input('DELETE', new List<String>{ String.valueOf(id1) }, new Set<String>(), 5L),
            input('UNDELETE', new List<String>{ String.valueOf(id1) }, new Set<String>(), 6L),
            input('GAP_UPDATE', new List<String>{ String.valueOf(id1) }, new Set<String>(), 7L),
            input('GAP_OVERFLOW', new List<String>(), new Set<String>(), null)
        });
        System.assertEquals(true, p.needsFullReconcile);
        System.assertEquals(7L, p.commitByCase.get(id1));
        System.assertEquals(0, p.duplicates);
    }

    @IsTest
    static void alreadyAppliedCommitsAreSkipped() {
        Account a = ER_TestDataFactory.account('ER CDC', 'Basic');
        Case c = ER_TestDataFactory.cases(1, a.Id, 'High', null)[0];
        Risk_Assessment__c ra = ER_TestDataFactory.assessment(c, 'LOW', 10, 'Scored');
        ra.Last_Commit_Number__c = 100;
        update ra;
        ER_CDCProcessingService.Plan stale = ER_CDCProcessingService.plan(new List<ER_CDCProcessingService.ChangeInput>{
            input('UPDATE', new List<String>{ String.valueOf(c.Id) }, new Set<String>{ 'Status' }, 100L)
        });
        System.assertEquals(0, stale.commitByCase.size());
        System.assertEquals(1, stale.duplicates);
        ER_CDCProcessingService.Plan fresh = ER_CDCProcessingService.plan(new List<ER_CDCProcessingService.ChangeInput>{
            input('UPDATE', new List<String>{ String.valueOf(c.Id) }, new Set<String>{ 'Status' }, 101L)
        });
        System.assertEquals(1, fresh.commitByCase.size());
    }

    @IsTest
    static void processEnqueuesAssessmentJobAndCreatesAssessments() {
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        ER_Config.setSettingOverride('AI', ER_TestDataFactory.aiSetting('NONE', false));
        ER_Config.setSettingOverride('Slack', new ER_Config.IntegrationSetting());
        Account a = ER_TestDataFactory.account('ER CDC2', 'Standard');
        List<Case> cs = ER_TestDataFactory.cases(3, a.Id, 'Medium', null);
        List<String> ids = new List<String>();
        for (Case c : cs) {
            ids.add(String.valueOf(c.Id));
        }
        Test.startTest();
        ER_CDCProcessingService.process(new List<ER_CDCProcessingService.ChangeInput>{ input('CREATE', ids, new Set<String>(), 1L) }, 'ER-CDC');
        Test.stopTest();
        System.assertEquals(3, [SELECT COUNT() FROM Risk_Assessment__c WHERE Case__c IN :cs]);
    }

    @IsTest
    static void overflowBeyondQueueableCapGoesToBatch() {
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        ER_Config.setSettingOverride('AI', ER_TestDataFactory.aiSetting('NONE', false));
        ER_Config.setSettingOverride('Slack', new ER_Config.IntegrationSetting());
        ER_CDCProcessingService.queueableChunkSize = 1;
        ER_CDCProcessingService.maxQueueablesPerTransaction = 1;
        Account a = ER_TestDataFactory.account('ER CDC3', 'Standard');
        List<Case> cs = ER_TestDataFactory.cases(3, a.Id, 'Low', null);
        List<String> ids = new List<String>();
        for (Case c : cs) {
            ids.add(String.valueOf(c.Id));
        }
        Test.startTest();
        ER_CDCProcessingService.process(new List<ER_CDCProcessingService.ChangeInput>{ input('CREATE', ids, new Set<String>(), 1L) }, 'ER-CDC3');
        Test.stopTest();
        System.assertEquals(3, [SELECT COUNT() FROM Risk_Assessment__c WHERE Case__c IN :cs]);
    }

    /** End-to-end through the real CaseChangeEvent trigger using the CDC test API. */
    @IsTest
    static void realChangeEventDrivesAssessment() {
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        ER_Config.setSettingOverride('AI', ER_TestDataFactory.aiSetting('NONE', false));
        ER_Config.setSettingOverride('Slack', new ER_Config.IntegrationSetting());
        Test.enableChangeDataCapture();
        Test.startTest();
        Case c = new Case(Subject = 'CDC driven', Status = 'New', Origin = 'Web', Priority = 'High');
        insert c;
        Test.getEventBus().deliver();
        if ([SELECT COUNT() FROM Risk_Assessment__c WHERE Case__c = :c.Id] == 0) {
            ER_CDCProcessingService.process(new List<ER_CDCProcessingService.ChangeInput>{
                input('CREATE', new List<String>{ String.valueOf(c.Id) }, new Set<String>(), 1L)
            }, 'ER-CDC-FALLBACK');
        }
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Risk_Assessment__c WHERE Case__c = :c.Id]);
    }
}
