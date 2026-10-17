/**
 * Application-level protection for audit rows: blocks update and delete from any context, including
 * administrators. This is NOT tamper-evidence: someone with Customize Application can disable or change this trigger,
 * and data can be removed by other platform means. See docs/SECURITY.md.
 */
public with sharing class ER_AuditProtectionHandler {
    public static void block(List<Escalation_Audit__c> records) {
        for (Escalation_Audit__c r : records) {
            r.addError('Escalation audit records cannot be modified or deleted.');
        }
    }
}
