trigger ER_CaseTrigger on Case(before update) {
    ER_CaseTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
}
