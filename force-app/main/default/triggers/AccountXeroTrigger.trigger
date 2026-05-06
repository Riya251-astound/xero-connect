trigger AccountXeroTrigger on Account (after insert, after update) {
    if (XeroInboundSyncSuppressor.isActive()) {
        return;
    }
    if (Trigger.isInsert) {
        AccountXeroTriggerHandler.afterInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        AccountXeroTriggerHandler.afterUpdate(Trigger.new, (Map<Id, Account>) Trigger.oldMap);
    }
}
