/**
 * Pushes {@link Xero_Invoice__c.Status__c} changes to Xero for supported statuses (AUTHORISED, VOIDED, DELETED).
 * PAID is not sent here; Xero requires a payment API to mark invoices paid.
 */
public inherited sharing class XeroInvoiceStatusSync implements Queueable, Database.AllowsCallouts {
    private static final Set<String> OUTBOUND_SYNCABLE_STATUSES = new Set<String>{
        'AUTHORISED',
        'VOIDED',
        'DELETED'
    };

    private final List<Id> xeroInvoiceIds;

    public XeroInvoiceStatusSync(List<Id> xeroInvoiceIds) {
        this.xeroInvoiceIds = xeroInvoiceIds == null ? new List<Id>() : xeroInvoiceIds.clone();
    }

    public void execute(QueueableContext context) {
        if (xeroInvoiceIds.isEmpty()) {
            return;
        }
        List<Xero_Invoice__c> invoices = [
            SELECT Id, Xero_Invoice_ID__c, Status__c
            FROM Xero_Invoice__c
            WHERE Id IN :xeroInvoiceIds
        ];
        List<Map<String, Object>> invoicePayload = new List<Map<String, Object>>();
        for (Xero_Invoice__c xi : invoices) {
            if (String.isBlank(xi.Xero_Invoice_ID__c) || String.isBlank(xi.Status__c)) {
                continue;
            }
            String statusNorm = xi.Status__c.trim().toUpperCase();
            if (!OUTBOUND_SYNCABLE_STATUSES.contains(statusNorm)) {
                continue;
            }
            invoicePayload.add(
                new Map<String, Object>{
                    'InvoiceID' => xi.Xero_Invoice_ID__c,
                    'Status' => statusNorm
                }
            );
        }
        if (invoicePayload.isEmpty()) {
            return;
        }

        XeroService.beginCalloutTransaction();
        try {
            Map<String, Object> body = new Map<String, Object>{ 'Invoices' => (Object) invoicePayload };
            String jsonBody = JSON.serialize(body);
            HttpResponse res = XeroService.callAccountingApi('POST', '/Invoices', jsonBody);
            Integer sc = res.getStatusCode();
            if (sc != 200 && sc != 201) {
                throw new CalloutException('Xero invoice status sync failed: HTTP ' + String.valueOf(sc) + ' ' + res.getBody());
            }
        } finally {
            XeroService.flushDeferredTokenPersistence();
        }
    }
}
