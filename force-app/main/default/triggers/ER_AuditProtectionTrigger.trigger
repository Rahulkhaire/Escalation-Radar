trigger ER_AuditProtectionTrigger on Escalation_Audit__c(before update, before delete) {
    ER_AuditProtectionHandler.block(Trigger.isDelete ? Trigger.old : Trigger.new);
}
