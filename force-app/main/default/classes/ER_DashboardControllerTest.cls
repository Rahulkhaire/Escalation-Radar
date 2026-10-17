@IsTest
private class ER_DashboardControllerTest {
    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ER_TestDataFactory.user('ERDashPlain');
            ER_TestDataFactory.user('ERDashReq');
            ER_TestDataFactory.assignPermissionSet(UserInfo.getUserId(), 'ER_Radar_Manager');
        }
        Account a = ER_TestDataFactory.account('ER Dash Customer', 'Enterprise');
        List<Case> high = ER_TestDataFactory.cases(2, a.Id, 'High', null);
        List<Case> low = ER_TestDataFactory.cases(1, a.Id, 'Low', null);
        ER_TestDataFactory.assessment(high[0], 'CRITICAL', 90, 'Scored');
        ER_TestDataFactory.assessment(high[1], 'HIGH', 60, 'AI_Failed');
        Risk_Assessment__c lowRa = ER_TestDataFactory.assessment(low[0], 'LOW', 10, 'Scored');
        lowRa.SLA_Consumption_Pct__c = 85;
        lowRa.Factors_JSON__c = '[{"key":"SLA","label":"SLA consumption","detail":"SLA is 85.0% consumed.","source":"DETERMINISTIC","points":10.0,"maxPoints":35.0}]';
        update lowRa;
    }

    private static Id otherUser() {
        return [SELECT Id FROM User WHERE LastName = 'ERDashReq' LIMIT 1].Id;
    }

    @IsTest
    static void summaryCountsAndDistribution() {
        ER_DashboardController.Summary s = ER_DashboardController.getSummary();
        System.assertEquals(3, s.total);
        System.assertEquals(1, s.critical);
        System.assertEquals(1, s.high);
        System.assertEquals(1, s.approachingSla);
        System.assertEquals(1, s.failedAi);
        System.assertEquals(53.3, s.averageScore);
        System.assertEquals(1, s.distribution.get('LOW'));
    }

    @IsTest
    static void casesSupportFilterSearchSortAndPaging() {
        ER_DashboardController.FilterInput f = new ER_DashboardController.FilterInput();
        f.pageSize = 2;
        f.pageNumber = 1;
        f.sortField = 'score';
        f.sortDir = 'desc';
        ER_DashboardController.CasePage p = ER_DashboardController.getCases(f);
        System.assertEquals(3, p.total);
        System.assertEquals(2, p.rows.size());
        System.assertEquals(90.0, p.rows[0].score);
        f.pageNumber = 2;
        System.assertEquals(1, ER_DashboardController.getCases(f).rows.size());
        f.pageNumber = 1;
        f.priority = 'Low';
        System.assertEquals(1, ER_DashboardController.getCases(f).total);
        f.priority = null;
        f.category = 'CRITICAL';
        System.assertEquals(1, ER_DashboardController.getCases(f).total);
        f.category = null;
        f.searchText = 'ER Dash Customer';
        System.assertEquals(3, ER_DashboardController.getCases(f).total);
        f.searchText = 'no-such-text-xyz';
        System.assertEquals(0, ER_DashboardController.getCases(f).total);
        f.searchText = null;
        f.sortField = 'x; DROP TABLE'; // not in the sort allowlist: falls back to the default sort, no injection
        System.assertEquals(3, ER_DashboardController.getCases(f).total);
    }

    @IsTest
    static void detailParsesFactors() {
        Risk_Assessment__c ra = [SELECT Id FROM Risk_Assessment__c WHERE Risk_Category__c = 'LOW' LIMIT 1];
        ER_DashboardController.Detail d = ER_DashboardController.getCaseDetail(ra.Id);
        System.assertEquals(1, d.factors.size());
        System.assertEquals('DETERMINISTIC', d.factors[0].source);
        System.assertEquals(10.0, d.factors[0].points);
    }

    @IsTest
    static void approvalQueueAndApproveRejectFlow() {
        Case c = [SELECT Id FROM Case LIMIT 1];
        Escalation_Action__c a1 = ER_TestDataFactory.action(c, null, ER_Constants.ACT_REASSIGN, true, otherUser());
        Escalation_Action__c a2 = ER_TestDataFactory.action(c, null, ER_Constants.ACT_SLACK, true, otherUser());
        System.assertEquals(2, ER_DashboardController.getApprovalQueue().size());
        System.assertEquals(2, ER_DashboardController.getSummary().awaitingApproval);
        ER_DashboardController.ActionDto rej = ER_DashboardController.rejectAction(a2.Id, 'no');
        System.assertEquals('Rejected', rej.approvalStatus);
        try {
            ER_DashboardController.rejectAction(a2.Id, 'again');
            System.assert(false, 'replay must fail');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('already been decided'));
        }
        System.assertEquals(1, ER_DashboardController.getApprovalQueue().size());
        System.assertEquals(a1.Id, ER_DashboardController.getApprovalQueue()[0].id);
    }

    @IsTest
    static void unauthorizedUserGetsSafeErrors() {
        Case c = [SELECT Id FROM Case LIMIT 1];
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_REASSIGN, true, otherUser());
        User plain = [SELECT Id FROM User WHERE LastName = 'ERDashPlain' LIMIT 1];
        System.runAs(plain) {
            try {
                ER_DashboardController.approveAction(a.Id, null);
                System.assert(false, 'expected failure');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('not authorised'));
            }
            try {
                ER_DashboardController.runAction(a.Id);
                System.assert(false, 'expected failure');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('not authorised'));
            }
            try {
                ER_DashboardController.getSummary();
                System.assert(false, 'plain user has no object access');
            } catch (AuraHandledException e) {
                System.assert(String.isNotBlank(e.getMessage()));
            }
        }
    }

    @IsTest
    static void runActionQueuesNoApprovalActionOnly() {
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        Case c = [SELECT Id FROM Case LIMIT 1];
        Escalation_Action__c draft = ER_TestDataFactory.action(c, null, ER_Constants.ACT_DRAFT, false, otherUser());
        Escalation_Action__c gated = ER_TestDataFactory.action(c, null, ER_Constants.ACT_REASSIGN, true, otherUser());
        try {
            ER_DashboardController.runAction(gated.Id);
            System.assert(false, 'approval-gated action must not be runnable directly');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('not available'));
        }
        Test.startTest();
        ER_DashboardController.runAction(draft.Id);
        Test.stopTest();
        System.assertEquals('Succeeded', [SELECT Execution_Status__c FROM Escalation_Action__c WHERE Id = :draft.Id].Execution_Status__c);
    }

    @IsTest
    static void auditHealthAndOptions() {
        Case c = [SELECT Id FROM Case LIMIT 1];
        ER_AuditService.log(ER_AuditService.entry('TEST_EVENT', c.Id, 'ER-D1'));
        List<ER_DashboardController.AuditDto> audit = ER_DashboardController.getAudit(c.Id);
        System.assertEquals(1, audit.size());
        System.assertEquals('TEST_EVENT', audit[0].eventType);
        ER_DashboardController.Health h = ER_DashboardController.getHealth();
        System.assertEquals(true, h.canApprove);
        System.assertEquals(1, h.aiFailed);
        ER_DashboardController.FilterOptions o = ER_DashboardController.getFilterOptions();
        System.assert(o.priorities.contains('High'));
        System.assert(!o.owners.isEmpty());
        System.assertEquals(0, ER_DashboardController.getReadyToRun().size());
    }

    @IsTest
    static void retryFailedAiResetsAndStartsRecovery() {
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        ER_Config.setSettingOverride('AI', ER_TestDataFactory.aiSetting('NONE', false));
        ER_Config.setSettingOverride('Slack', new ER_Config.IntegrationSetting());
        Test.startTest();
        Integer n = ER_DashboardController.retryFailedAi();
        Test.stopTest();
        System.assertEquals(1, n);
        System.assertEquals(0, [SELECT COUNT() FROM Risk_Assessment__c WHERE Assessment_Status__c = 'AI_Failed']);
    }

    @IsTest
    static void reassessCaseQueuesJob() {
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        ER_Config.setSettingOverride('AI', ER_TestDataFactory.aiSetting('NONE', false));
        ER_Config.setSettingOverride('Slack', new ER_Config.IntegrationSetting());
        Case c = [SELECT Id FROM Case LIMIT 1];
        Test.startTest();
        ER_DashboardController.reassessCase(c.Id);
        Test.stopTest();
        System.assert([SELECT COUNT() FROM Escalation_Audit__c WHERE Case_Id__c = :String.valueOf(c.Id) AND Event_Type__c = 'ASSESSMENT_REQUESTED'] > 0);
    }

    @IsTest
    static void unexpectedErrorsAreGenericAndSafe() {
        AuraHandledException e1 = ER_DashboardController.toAura(new NullPointerException());
        System.assert(!e1.getMessage().contains('NullPointer'));
        AuraHandledException e2 = ER_DashboardController.toAura(new ER_Exception('Business rule message'));
        System.assertEquals('Business rule message', e2.getMessage());
    }
}
