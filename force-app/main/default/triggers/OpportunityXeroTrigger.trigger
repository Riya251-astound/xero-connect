trigger OpportunityXeroTrigger on Opportunity (after insert, after update) {
    if (XeroInboundSyncSuppressor.isActive()) {
        return;
    }
    if (Trigger.isInsert) {
        OpportunityXeroTriggerHandler.afterInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        OpportunityXeroTriggerHandler.afterUpdate(Trigger.new, (Map<Id, Opportunity>) Trigger.oldMap);
    }
}
