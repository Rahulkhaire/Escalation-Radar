/** Isolated, deterministic test data. Tests never use SeeAllData and never call live services. */
@IsTest
public class ER_TestDataFactory {
    public static ER_Config.RiskConfig defaultConfig() {
        ER_Config.RiskConfig c = new ER_Config.RiskConfig();
        c.version = 'test-1.0';
        c.priorityFractions = new Map<String, Decimal>{ 'High' => 1.0, 'Medium' => 0.5, 'Low' => 0.2 };
        c.tierFractions = new Map<String, Decimal>{ 'Strategic' => 1.0, 'Enterprise' => 0.75, 'Standard' => 0.4, 'Basic' => 0.1 };
        return c;
    }

    public static ER_Config.IntegrationSetting aiSetting(String provider, Boolean enabled) {
        ER_Config.IntegrationSetting s = new ER_Config.IntegrationSetting();
        s.enabled = enabled;
        s.provider = provider;
        s.namedCredential = 'ER_LLM_Test';
        s.endpointPath = '/v1/messages';
        s.model = 'test-model';
        s.timeoutMs = 5000;
        s.maxPayloadChars = 6000;
        s.maxRetries = 3;
        s.minScore = 0;
        s.maxUplift = 5;
        return s;
    }

    public static Account account(String name, String tier) {
        Account a = new Account(Name = name, ER_Account_Tier__c = tier);
        insert a;
        return a;
    }

    public static List<Case> cases(Integer n, Id accountId, String priority, Datetime slaDeadline) {
        List<Case> cs = new List<Case>();
        for (Integer i = 0; i < n; i++) {
            cs.add(new Case(
                Subject = 'ER Test Case ' + i,
                Description = 'Customer reports an issue number ' + i,
                Priority = priority,
                Status = 'New',
                Origin = 'Web',
                AccountId = accountId,
                ER_SLA_Deadline__c = slaDeadline
            ));
        }
        insert cs;
        return cs;
    }

    public static User user(String lastName) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = String.valueOf(Crypto.getRandomInteger()).replace('-', 'n');
        User u = new User(
            LastName = lastName,
            Alias = lastName.left(4) + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(3),
            Email = 'er.' + uniq + '@example.invalid',
            Username = 'er.' + uniq + '@example.invalid.er',
            ProfileId = p.Id,
            TimeZoneSidKey = 'GMT',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        return u;
    }

    /** Grants a custom permission through a throwaway permission set. Call inside System.runAs to avoid mixed-DML errors. */
    public static void grant(Id userId, String customPermissionName) {
        PermissionSet ps = new PermissionSet(Name = 'ER_T_' + String.valueOf(Math.abs(Crypto.getRandomInteger())), Label = 'ER test ' + customPermissionName);
        insert ps;
        CustomPermission cp = [SELECT Id FROM CustomPermission WHERE DeveloperName = :customPermissionName LIMIT 1];
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cp.Id);
        insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = ps.Id);
    }

    /** Assigns a permission set that ships with this project (also exercises its FLS and custom permissions). Call inside System.runAs. */
    public static void assignPermissionSet(Id userId, String permissionSetName) {
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = ps.Id);
    }

    public static Risk_Assessment__c assessment(Case c, String category, Decimal score, String status) {
        Risk_Assessment__c ra = new Risk_Assessment__c(
            Case__c = c.Id,
            Case_Id__c = String.valueOf(c.Id),
            Risk_Score__c = score,
            Deterministic_Score__c = score,
            Risk_Category__c = category,
            Assessment_Status__c = status,
            Last_Assessed__c = Datetime.now(),
            Explanation__c = 'Test explanation'
        );
        insert ra;
        return ra;
    }

    public static Escalation_Action__c action(Case c, Risk_Assessment__c ra, String actionType, Boolean requiresApproval, Id requestedBy) {
        Escalation_Action__c a = new Escalation_Action__c(
            Case__c = c.Id,
            Risk_Assessment__c = ra == null ? null : ra.Id,
            Action_Type__c = actionType,
            Reason__c = 'Test reason',
            Draft_Text__c = 'Test draft text',
            Risk_Score_At_Proposal__c = 80,
            Risk_Category_At_Proposal__c = 'CRITICAL',
            Source__c = 'Rules',
            Requires_Approval__c = requiresApproval,
            Requested_By__c = requestedBy,
            Approval_Status__c = requiresApproval ? 'Pending' : 'Not_Required',
            Execution_Status__c = 'Not_Started',
            Correlation_Id__c = 'ER-TEST'
        );
        insert a;
        return a;
    }

    /** Test double that records calls and returns a canned analysis, or throws. */
    public class StubProvider implements ER_AIProvider {
        public Integer calls = 0;
        public ER_AIAnalysis result;
        public Exception toThrow;

        public String name() {
            return 'STUB';
        }

        public ER_AIAnalysis analyze(ER_AIRequest req) {
            calls++;
            if (toThrow != null) {
                throw toThrow;
            }
            return result;
        }
    }

    public static ER_AIAnalysis analysis(String urgency, Decimal confidence, List<String> actions) {
        ER_AIAnalysis a = new ER_AIAnalysis();
        a.provider = 'STUB';
        a.summary = 'Stub summary';
        a.riskExplanation = 'Stub explanation';
        a.urgency = urgency;
        a.sentiment = 'NEGATIVE';
        a.rootCauses = new List<String>{ 'OTHER' };
        a.nextSteps = new List<String>{ 'Call the customer' };
        a.suggestedCustomerUpdate = 'We are working on it.';
        a.confidence = confidence;
        a.proposedActions = actions;
        return a;
    }
}
