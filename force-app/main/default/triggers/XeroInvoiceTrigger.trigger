trigger XeroInvoiceTrigger on Xero_Invoice__c(after update) {
    if (XeroInboundSyncSuppressor.isActive()) {
        return;
    }
    if (Trigger.isUpdate) {
        XeroInvoiceTriggerHandler.afterUpdate(Trigger.new, (Map<Id, Xero_Invoice__c>) Trigger.oldMap);
    }
}
