/**
 * Thin Case trigger logic. Only maintains the reopen counter (before update, no SOQL on records, no callouts).
 * Risk assessment is NOT done here: it is driven by Change Data Capture (ER_CaseChangeTrigger).
 */
public with sharing class ER_CaseTriggerHandler {
    private static Set<String> closedStatuses;

    public static void beforeUpdate(List<Case> newList, Map<Id, Case> oldMap) {
        for (Case c : newList) {
            Case old = oldMap.get(c.Id);
            if (old == null || old.Status == c.Status) {
                continue;
            }
            if (isClosedStatus(old.Status) && !isClosedStatus(c.Status)) {
                c.ER_Reopen_Count__c = (c.ER_Reopen_Count__c == null ? 0 : c.ER_Reopen_Count__c) + 1;
            }
        }
    }

    private static Boolean isClosedStatus(String status) {
        if (closedStatuses == null) {
            closedStatuses = new Set<String>();
            for (CaseStatus cs : [SELECT MasterLabel FROM CaseStatus WHERE IsClosed = true]) {
                closedStatuses.add(cs.MasterLabel);
            }
        }
        return closedStatuses.contains(status);
    }
}
