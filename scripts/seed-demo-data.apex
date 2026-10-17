// Demo data for Escalation Radar. All records are tagged "[ER Demo]" so scripts/cleanup-demo-data.apex can remove them.
// Run: sf apex run --file scripts/seed-demo-data.apex --target-org escalation-radar-dev
// Cases are created with realistic-looking but fictional content. SLA deadlines are relative to "now".
List<Account> accounts = new List<Account>{
    new Account(Name = '[ER Demo] Northwind Logistics', ER_Account_Tier__c = 'Strategic'),
    new Account(Name = '[ER Demo] Contoso Retail', ER_Account_Tier__c = 'Enterprise'),
    new Account(Name = '[ER Demo] Fabrikam Studio', ER_Account_Tier__c = 'Standard'),
    new Account(Name = '[ER Demo] Tailspin Hobbies', ER_Account_Tier__c = 'Basic')
};
insert accounts;
Datetime n = Datetime.now();
List<Case> cases = new List<Case>{
    new Case(Subject = '[ER Demo] Production outage: orders API unavailable', Description = 'Our production integration is down and customers cannot place orders. This is unacceptable, we need an update now.', Priority = 'High', Status = 'Working', Origin = 'Phone', AccountId = accounts[0].Id, ER_SLA_Deadline__c = n.addHours(-2)),
    new Case(Subject = '[ER Demo] Invoices sync again failing', Description = 'The billing sync failed again overnight. Third time this month. Considering cancel of renewal.', Priority = 'High', Status = 'New', Origin = 'Email', AccountId = accounts[1].Id, ER_SLA_Deadline__c = n.addMinutes(-10)),
    new Case(Subject = '[ER Demo] Report export is slow', Description = 'Exports take several minutes since last week. Performance is degraded for the whole team.', Priority = 'Medium', Status = 'Working', Origin = 'Web', AccountId = accounts[1].Id, ER_SLA_Deadline__c = n.addHours(6)),
    new Case(Subject = '[ER Demo] Cannot log in after password reset', Description = 'User cannot log in after resetting the password. Access permissions look correct.', Priority = 'Medium', Status = 'New', Origin = 'Web', AccountId = accounts[2].Id),
    new Case(Subject = '[ER Demo] How do I change the dashboard colours?', Description = 'Question about training on the dashboard settings.', Priority = 'Low', Status = 'New', Origin = 'Web', AccountId = accounts[3].Id),
    new Case(Subject = '[ER Demo] Feature request: bulk edit', Description = 'Would like bulk editing on the list view.', Priority = 'Low', Status = 'Working', Origin = 'Web', AccountId = accounts[2].Id),
    new Case(Subject = '[ER Demo] Data import duplicates records', Description = 'Import created duplicate data quality issues in contacts.', Priority = 'High', Status = 'Working', Origin = 'Email', AccountId = accounts[0].Id, ER_SLA_Deadline__c = n.addHours(-1)),
    new Case(Subject = '[ER Demo] Escalated: shipment notifications missing', Description = 'Notifications stopped; customer is frustrated and wants a manager to call.', Priority = 'Medium', Status = 'Escalated', Origin = 'Phone', AccountId = accounts[0].Id, ER_SLA_Deadline__c = n.addHours(1))
};
insert cases;

// NOTE: Cases are created 'now', so a deadline in the future shows ~0% SLA consumption at first. To make the demo meaningful immediately,
// three cases get a deadline already in the past (SLA breached = 100% consumed). Others use the priority-based policy hours and rise over time.
// Add a published comment on one case so the "recent communication" signal differs between cases.
insert new CaseComment(ParentId = cases[1].Id, CommentBody = 'We have escalated this to engineering and will update you in two hours.', IsPublished = true);

// Reopen one case to demonstrate the reopen factor: close it, then reopen it (the ER_CaseTrigger increments ER_Reopen_Count__c).
cases[2].Status = 'Closed';
update cases[2];
cases[2].Status = 'Working';
update cases[2];

// Initial assessment of existing cases. If Change Data Capture is enabled for Case, assessments also appear automatically.
Database.executeBatch(new ER_RiskAssessmentBatch(ER_RiskAssessmentBatch.MODE_INITIAL, null), 50);
System.debug('Seeded ' + cases.size() + ' demo cases and started the initial assessment batch.');
