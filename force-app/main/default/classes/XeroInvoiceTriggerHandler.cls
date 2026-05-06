/**
 * After update: when {@link Xero_Invoice__c.Status__c} changes to a value that can be pushed to Xero (AUTHORISED, VOIDED, DELETED),
 * enqueue {@link XeroInvoiceStatusSync}. PAID is not pushed (requires Xero Payment API).
 */
public inherited sharing class XeroInvoiceTriggerHandler {
    private static final Set<String> OUTBOUND_SYNCABLE_STATUSES = new Set<String>{
        'AUTHORISED',
        'VOIDED',
        'DELETED'
    };

    public static void afterUpdate(List<Xero_Invoice__c> newRows, Map<Id, Xero_Invoice__c> oldMap) {
        if (XeroInboundSyncSuppressor.isActive()) {
            return;
        }
        if (!XeroSyncRecursionControl.enterInvoiceTrigger()) {
            return;
        }
        try {
            Set<Id> ids = new Set<Id>();
            for (Xero_Invoice__c xi : newRows) {
                Xero_Invoice__c oldXi = oldMap.get(xi.Id);
                String oldNorm = normalizeStatus(oldXi.Status__c);
                String newNorm = normalizeStatus(xi.Status__c);
                if (oldNorm == newNorm) {
                    continue;
                }
                if (String.isBlank(xi.Xero_Invoice_ID__c)) {
                    continue;
                }
                if (newNorm == null || !OUTBOUND_SYNCABLE_STATUSES.contains(newNorm)) {
                    continue;
                }
                ids.add(xi.Id);
            }
            if (!ids.isEmpty()) {
                System.enqueueJob(new XeroInvoiceStatusSync(new List<Id>(ids)));
            }
        } finally {
            XeroSyncRecursionControl.exitInvoiceTrigger();
        }
    }

    private static String normalizeStatus(String value) {
        return String.isBlank(value) ? null : value.trim().toUpperCase();
    }
}
