trigger ER_CaseChangeTrigger on CaseChangeEvent(after insert) {
    ER_CDCProcessingService.processEvents(Trigger.new);
}
