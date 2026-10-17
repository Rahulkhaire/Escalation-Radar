// Removes demo data created by seed-demo-data.apex (Cases/Accounts whose names start with "[ER Demo]").
// Risk assessments and actions are removed with their Cases' lookups cleared, so delete them explicitly first.
// NOTE: Escalation_Audit__c rows cannot be deleted by design (application-level protection); see docs/SETUP_GUIDE.md "Cleanup".
List<Case> cases = [SELECT Id FROM Case WHERE Subject LIKE '[ER Demo]%'];
Set<String> caseIds = new Set<String>();
for (Case c : cases) { caseIds.add(String.valueOf(c.Id)); }
delete [SELECT Id FROM Escalation_Action__c WHERE Case__c IN :cases];
delete [SELECT Id FROM Risk_Assessment__c WHERE Case_Id__c IN :caseIds];
delete [SELECT Id FROM Integration_Log__c WHERE Case_Id__c IN :caseIds];
delete cases;
delete [SELECT Id FROM Account WHERE Name LIKE '[ER Demo]%'];
System.debug('Demo data removed.');
