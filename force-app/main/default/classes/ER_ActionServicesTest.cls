@IsTest
private class ER_ActionServicesTest {
    private static User requester;

    @TestSetup
    static void setup() {
        User plain;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            plain = ER_TestDataFactory.user('ERPlain');
            ER_TestDataFactory.user('ERReq');
            // Real permission set shipped with the project: grants approve + execute custom permissions and read access.
            ER_TestDataFactory.assignPermissionSet(UserInfo.getUserId(), 'ER_Radar_Manager');
        }
    }

    private static void configure() {
        ER_Config.setRiskOverride(ER_TestDataFactory.defaultConfig());
        ER_Config.setSettingOverride('AI', ER_TestDataFactory.aiSetting('NONE', false));
        ER_Config.setSettingOverride('Slack', new ER_Config.IntegrationSetting());
        ER_Config.setSettingOverride('Actions', new ER_Config.IntegrationSetting());
    }

    private static Id otherUserId() {
        return [SELECT Id FROM User WHERE LastName = 'ERReq' LIMIT 1].Id;
    }

    private static Case newCase() {
        Account a = ER_TestDataFactory.account('ER Action ' + String.valueOf(Crypto.getRandomInteger()), 'Strategic');
        return ER_TestDataFactory.cases(1, a.Id, 'High', null)[0];
    }

    private static Escalation_Action__c reload(Id id) {
        return [SELECT Id, Approval_Status__c, Execution_Status__c, Failure_Details__c, Approved_By__c FROM Escalation_Action__c WHERE Id = :id];
    }

    // ---------- approval ----------
    @IsTest
    static void approvalExecutesAllowlistedActionAndAudits() {
        configure();
        Case c = newCase();
        Risk_Assessment__c ra = ER_TestDataFactory.assessment(c, 'CRITICAL', 90, 'Scored');
        Escalation_Action__c a = ER_TestDataFactory.action(c, ra, ER_Constants.ACT_ESCALATE, true, otherUserId());
        Test.startTest();
        ER_ActionApprovalService.decide(a.Id, true, 'looks right');
        Test.stopTest();
        Escalation_Action__c r = reload(a.Id);
        System.assertEquals('Approved', r.Approval_Status__c);
        System.assertEquals('Succeeded', r.Execution_Status__c);
        System.assertEquals(UserInfo.getUserId(), r.Approved_By__c);
        System.assertEquals(true, [SELECT IsEscalated FROM Case WHERE Id = :c.Id].IsEscalated);
        Set<String> events = new Set<String>();
        for (Escalation_Audit__c au : [SELECT Event_Type__c FROM Escalation_Audit__c WHERE Action_Id__c = :String.valueOf(a.Id)]) {
            events.add(au.Event_Type__c);
        }
        System.assert(events.containsAll(new Set<String>{ 'ACTION_APPROVED', 'ACTION_EXECUTION_ATTEMPTED', 'ACTION_EXECUTED' }), String.valueOf(events));
    }

    @IsTest
    static void approvalReplayIsRejected() {
        configure();
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_REVIEW, true, otherUserId());
        Test.startTest();
        ER_ActionApprovalService.decide(a.Id, true, null);
        Test.stopTest();
        try {
            ER_ActionApprovalService.decide(a.Id, true, null);
            System.assert(false, 'second approval must fail');
        } catch (ER_Exception e) {
            System.assert(e.getMessage().contains('already been decided'));
        }
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :c.Id]);
    }

    @IsTest
    static void rejectionSkipsExecution() {
        configure();
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_REVIEW, true, otherUserId());
        ER_ActionApprovalService.decide(a.Id, false, 'not needed');
        Escalation_Action__c r = reload(a.Id);
        System.assertEquals('Rejected', r.Approval_Status__c);
        System.assertEquals('Skipped', r.Execution_Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Escalation_Audit__c WHERE Event_Type__c = 'ACTION_REJECTED']);
    }

    @IsTest
    static void unauthorizedUserCannotApprove() {
        configure();
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_REVIEW, true, otherUserId());
        User plain = [SELECT Id FROM User WHERE LastName = 'ERPlain' LIMIT 1];
        System.runAs(plain) {
            try {
                ER_ActionApprovalService.decide(a.Id, true, null);
                System.assert(false, 'expected authorization failure');
            } catch (ER_AuthorizationException e) {
                System.assert(e.getMessage().contains('not authorised'));
            }
        }
        System.assertEquals('Pending', reload(a.Id).Approval_Status__c);
    }

    @IsTest
    static void requesterCannotApproveOwnProposal() {
        configure();
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_REVIEW, true, UserInfo.getUserId());
        try {
            ER_ActionApprovalService.decide(a.Id, true, null);
            System.assert(false, 'expected separation-of-duties failure');
        } catch (ER_AuthorizationException e) {
            System.assert(e.getMessage().contains('Separation of duties'));
        }
    }

    @IsTest
    static void closedCaseCannotBeApproved() {
        configure();
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_REVIEW, true, otherUserId());
        c.Status = 'Closed';
        update c;
        try {
            ER_ActionApprovalService.decide(a.Id, true, null);
            System.assert(false, 'expected failure');
        } catch (ER_Exception e) {
            System.assert(e.getMessage().contains('closed'));
        }
    }

    // ---------- execution ----------
    @IsTest
    static void executionRefusedWithoutApproval() {
        configure();
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_REASSIGN, true, otherUserId());
        Id ownerBefore = [SELECT OwnerId FROM Case WHERE Id = :c.Id].OwnerId;
        ER_ActionExecutionService.execute(a.Id);
        Escalation_Action__c r = reload(a.Id);
        System.assertEquals('Failed', r.Execution_Status__c);
        System.assert(r.Failure_Details__c.contains('not been approved'));
        System.assertEquals(ownerBefore, [SELECT OwnerId FROM Case WHERE Id = :c.Id].OwnerId);
    }

    @IsTest
    static void duplicateExecutionIsBlockedAndDraftCreatesOneInternalComment() {
        configure();
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_DRAFT, false, otherUserId());
        ER_ActionExecutionService.execute(a.Id);
        try {
            ER_ActionExecutionService.execute(a.Id);
            System.assert(false, 'duplicate execution must be refused');
        } catch (ER_Exception e) {
            System.assert(e.getMessage().contains('already processed'));
        }
        List<CaseComment> comments = [SELECT IsPublished, CommentBody FROM CaseComment WHERE ParentId = :c.Id];
        System.assertEquals(1, comments.size());
        System.assertEquals(false, comments[0].IsPublished);
        System.assert(comments[0].CommentBody.contains('NOT sent'));
        System.assertEquals('Succeeded', reload(a.Id).Execution_Status__c);
    }

    @IsTest
    static void executionWithoutExecutePermissionFails() {
        configure();
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_NOTE, false, otherUserId());
        User plain = [SELECT Id FROM User WHERE LastName = 'ERPlain' LIMIT 1];
        System.runAs(plain) {
            ER_ActionExecutionService.execute(a.Id);
        }
        Escalation_Action__c r = reload(a.Id);
        System.assertEquals('Failed', r.Execution_Status__c);
        System.assert(r.Failure_Details__c.contains('not authorised'));
        System.assertEquals(0, [SELECT COUNT() FROM CaseComment WHERE ParentId = :c.Id]);
    }

    @IsTest
    static void closedCaseSkipsExecution() {
        configure();
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_DRAFT, false, otherUserId());
        c.Status = 'Closed';
        update c;
        ER_ActionExecutionService.execute(a.Id);
        System.assertEquals('Skipped', reload(a.Id).Execution_Status__c);
    }

    @IsTest
    static void reassignRequiresConfiguredQueue() {
        configure();
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_REASSIGN, true, otherUserId());
        a.Target_Queue__c = 'Not_The_Configured_Queue';
        update a;
        Test.startTest();
        ER_ActionApprovalService.decide(a.Id, true, null);
        Test.stopTest();
        Escalation_Action__c r = reload(a.Id);
        System.assertEquals('Failed', r.Execution_Status__c);
        System.assert(r.Failure_Details__c.contains('allowlisted'));
    }

    @IsTest
    static void reassignMovesCaseToConfiguredQueueAfterApproval() {
        configure();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Group q = new Group(Name = 'ER Test Queue', DeveloperName = 'ER_Test_Queue', Type = 'Queue');
            insert q;
            insert new QueueSobject(QueueId = q.Id, SobjectType = 'Case');
        }
        ER_Config.IntegrationSetting act = new ER_Config.IntegrationSetting();
        act.reassignQueue = 'ER_Test_Queue';
        ER_Config.setSettingOverride('Actions', act);
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_REASSIGN, true, otherUserId());
        a.Target_Queue__c = 'ER_Test_Queue';
        update a;
        Test.startTest();
        ER_ActionApprovalService.decide(a.Id, true, null);
        Test.stopTest();
        System.assertEquals('Succeeded', reload(a.Id).Execution_Status__c);
        Group q = [SELECT Id FROM Group WHERE DeveloperName = 'ER_Test_Queue' LIMIT 1];
        System.assertEquals(q.Id, [SELECT OwnerId FROM Case WHERE Id = :c.Id].OwnerId);
    }

    @IsTest
    static void unsupportedActionTypesAreNeverAllowlisted() {
        for (String bad : new List<String>{ 'EXECUTE_APEX', 'DELETE_CASE', 'RUN_SOQL', '' }) {
            System.assertEquals(false, ER_Constants.ALLOWED_ACTIONS.contains(bad));
        }
        System.assertEquals(6, ER_Constants.ALLOWED_ACTIONS.size());
        System.assert(ER_Constants.ALWAYS_APPROVAL.contains(ER_Constants.ACT_REASSIGN));
        System.assert(ER_Constants.ALWAYS_APPROVAL.contains(ER_Constants.ACT_SLACK));
    }

    // ---------- Slack ----------
    private class SlackMock implements HttpCalloutMock {
        Integer status;
        Boolean timeout = false;
        SlackMock(Integer status) {
            this.status = status;
        }
        public HttpResponse respond(HttpRequest req) {
            if (timeout) {
                throw new CalloutException('timeout');
            }
            System.assert(req.getEndpoint().startsWith('callout:ER_Slack_Test'));
            System.assert(req.getBody().contains('Escalation Radar'));
            HttpResponse r = new HttpResponse();
            r.setStatusCode(status);
            r.setBody('ok');
            return r;
        }
    }

    private static void enableSlack(String provider) {
        ER_Config.IntegrationSetting s = new ER_Config.IntegrationSetting();
        s.enabled = true;
        s.provider = provider;
        s.namedCredential = 'ER_Slack_Test';
        s.minCategory = 'HIGH';
        ER_Config.setSettingOverride('Slack', s);
    }

    @IsTest
    static void slackSuccessAfterApproval() {
        configure();
        enableSlack('SLACK');
        Test.setMock(HttpCalloutMock.class, new SlackMock(200));
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_SLACK, true, otherUserId());
        Test.startTest();
        ER_ActionApprovalService.decide(a.Id, true, null);
        Test.stopTest();
        System.assertEquals('Succeeded', reload(a.Id).Execution_Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Integration_Log__c WHERE Integration__c = 'SLACK' AND Status__c = 'Success']);
    }

    @IsTest
    static void slackFailureIsRecordedNotThrown() {
        configure();
        enableSlack('SLACK');
        Test.setMock(HttpCalloutMock.class, new SlackMock(429));
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_SLACK, true, otherUserId());
        Test.startTest();
        ER_ActionApprovalService.decide(a.Id, true, null);
        Test.stopTest();
        Escalation_Action__c r = reload(a.Id);
        System.assertEquals('Failed', r.Execution_Status__c);
        System.assert(r.Failure_Details__c.contains('429'));
        System.assertEquals(1, [SELECT COUNT() FROM Integration_Log__c WHERE Integration__c = 'SLACK' AND Retryable__c = true]);
    }

    @IsTest
    static void slackDisabledDoesNotBreakCore() {
        configure();
        Case c = newCase();
        Escalation_Action__c a = ER_TestDataFactory.action(c, null, ER_Constants.ACT_SLACK, true, otherUserId());
        Test.startTest();
        ER_ActionApprovalService.decide(a.Id, true, null);
        Test.stopTest();
        Escalation_Action__c r = reload(a.Id);
        System.assertEquals('Failed', r.Execution_Status__c);
        System.assert(r.Failure_Details__c.contains('disabled'));
    }

    @IsTest
    static void slackMockProviderMakesNoCallout() {
        configure();
        enableSlack('MOCK');
        Case c = newCase();
        ER_SlackNotificationService.send(c.Id, 'ER-S', 'hello');
        System.assertEquals(1, [SELECT COUNT() FROM Integration_Log__c WHERE Integration__c = 'SLACK' AND Operation__c = 'send (mock)']);
    }

    @IsTest
    static void slackCalloutExceptionIsRetryable() {
        configure();
        enableSlack('SLACK');
        SlackMock m = new SlackMock(200);
        m.timeout = true;
        Test.setMock(HttpCalloutMock.class, m);
        Case c = newCase();
        try {
            ER_SlackNotificationService.send(c.Id, 'ER-S2', 'hello');
            System.assert(false, 'expected exception');
        } catch (ER_IntegrationException e) {
            System.assertEquals(true, e.retryable);
        }
    }

    // ---------- recommendation ----------
    private static Risk_Assessment__c aiAssessment(Case c, String category, String proposed) {
        Risk_Assessment__c ra = ER_TestDataFactory.assessment(c, category, category == 'CRITICAL' ? 90 : 60, 'Enriched');
        ra.AI_Proposed_Actions__c = proposed;
        ra.AI_Suggested_Update__c = 'We are on it.';
        ra.AI_Next_Steps__c = 'Call the customer';
        ra.AI_Completed_At__c = Datetime.now();
        update ra;
        return ra;
    }

    @IsTest
    static void recommendationCreatesApprovalGatedAllowlistedActionsAndDeduplicates() {
        configure();
        ER_Config.IntegrationSetting act = new ER_Config.IntegrationSetting();
        act.reassignQueue = 'Some_Queue';
        ER_Config.setSettingOverride('Actions', act);
        enableSlack('MOCK');
        Case c = newCase();
        Risk_Assessment__c ra = aiAssessment(c, 'CRITICAL', 'REASSIGN_CASE,ADD_INTERNAL_NOTE');
        List<Escalation_Action__c> first = ER_ActionRecommendationService.propose(new Set<Id>{ ra.Id }, 'ER-R1');
        Map<String, Escalation_Action__c> byType = new Map<String, Escalation_Action__c>();
        for (Escalation_Action__c a : first) {
            byType.put(a.Action_Type__c, a);
        }
        System.assert(byType.keySet().containsAll(new Set<String>{ 'REQUEST_MANAGER_REVIEW', 'ESCALATE_CASE', 'DRAFT_CUSTOMER_UPDATE', 'REASSIGN_CASE', 'ADD_INTERNAL_NOTE', 'SEND_SLACK_ALERT' }), String.valueOf(byType.keySet()));
        System.assertEquals(true, byType.get('REASSIGN_CASE').Requires_Approval__c);
        System.assertEquals(true, byType.get('SEND_SLACK_ALERT').Requires_Approval__c);
        System.assertEquals('Pending', byType.get('SEND_SLACK_ALERT').Approval_Status__c);
        System.assertEquals(false, byType.get('REQUEST_MANAGER_REVIEW').Requires_Approval__c);
        System.assertEquals('Not_Required', byType.get('REQUEST_MANAGER_REVIEW').Approval_Status__c);
        List<Escalation_Action__c> second = ER_ActionRecommendationService.propose(new Set<Id>{ ra.Id }, 'ER-R1b');
        System.assertEquals(0, second.size(), 'duplicate proposals must be suppressed');
        System.assertEquals(first.size(), [SELECT COUNT() FROM Escalation_Action__c WHERE Case__c = :c.Id]);
    }

    @IsTest
    static void lowRiskAndMissingQueueProduceNoRiskyActions() {
        configure();
        Case c = newCase();
        Risk_Assessment__c low = ER_TestDataFactory.assessment(c, 'LOW', 5, 'Scored');
        System.assertEquals(0, ER_ActionRecommendationService.propose(new Set<Id>{ low.Id }, 'ER-R2').size());
        Case c2 = newCase();
        Risk_Assessment__c ra = aiAssessment(c2, 'HIGH', 'REASSIGN_CASE');
        for (Escalation_Action__c a : ER_ActionRecommendationService.propose(new Set<Id>{ ra.Id }, 'ER-R3')) {
            System.assertNotEquals('REASSIGN_CASE', a.Action_Type__c);
        }
    }

    @IsTest
    static void rejectedProposalIsNotImmediatelyRepeated() {
        configure();
        Case c = newCase();
        Risk_Assessment__c ra = aiAssessment(c, 'HIGH', 'REQUEST_MANAGER_REVIEW');
        List<Escalation_Action__c> first = ER_ActionRecommendationService.propose(new Set<Id>{ ra.Id }, 'ER-R4');
        System.assert(!first.isEmpty());
        for (Escalation_Action__c a : first) {
            a.Execution_Status__c = 'Skipped';
            a.Approval_Status__c = a.Requires_Approval__c ? 'Rejected' : 'Not_Required';
            a.Decision_Date__c = Datetime.now();
        }
        update first;
        System.assertEquals(0, ER_ActionRecommendationService.propose(new Set<Id>{ ra.Id }, 'ER-R4b').size());
    }
}
