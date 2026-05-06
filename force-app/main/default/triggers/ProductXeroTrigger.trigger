trigger ProductXeroTrigger on Product2 (after insert, after update) {
    if (XeroInboundSyncSuppressor.isActive()) {
        return;
    }
    if (Trigger.isInsert) {
        ProductXeroTriggerHandler.afterInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        ProductXeroTriggerHandler.afterUpdate(Trigger.new, (Map<Id, Product2>) Trigger.oldMap);
    }
}
