/**
 * Async PDF download from Xero and file attach to {@link Xero_Invoice__c}. Callouts must not run inside {@code @AuraEnabled} sync methods.
 */
public inherited sharing class XeroInvoicePdfSync implements Queueable, Database.AllowsCallouts {
    private final Id xeroInvoiceRecordId;

    public XeroInvoicePdfSync(Id xeroInvoiceRecordId) {
        this.xeroInvoiceRecordId = xeroInvoiceRecordId;
    }

    public void execute(QueueableContext context) {
        if (xeroInvoiceRecordId == null) {
            return;
        }
        List<Xero_Invoice__c> invRows = [
            SELECT Id, Xero_Invoice_ID__c, Invoice_Number__c
            FROM Xero_Invoice__c
            WHERE Id = :xeroInvoiceRecordId
            LIMIT 1
        ];
        if (invRows.isEmpty() || String.isBlank(invRows[0].Xero_Invoice_ID__c)) {
            return;
        }
        Xero_Invoice__c xi = invRows[0];
        List<Xero_Connection__c> connRows = [SELECT Tenant_ID__c FROM Xero_Connection__c LIMIT 1];
        if (connRows.isEmpty() || String.isBlank(connRows[0].Tenant_ID__c)) {
            throw new CalloutException('Xero_Connection__c.Tenant_ID__c is not configured.');
        }
        String tenantId = connRows[0].Tenant_ID__c.trim();

        XeroService.beginCalloutTransaction();
        HttpResponse res = null;
        try {
            String accessToken = XeroService.getValidAccessToken();
            res = requestInvoicePdf(xi.Xero_Invoice_ID__c, accessToken, tenantId);
            if (res.getStatusCode() == 401) {
                XeroService.refreshToken();
                accessToken = XeroService.getValidAccessToken();
                res = requestInvoicePdf(xi.Xero_Invoice_ID__c, accessToken, tenantId);
            }
        } finally {
            XeroService.flushDeferredTokenPersistence();
        }
        if (res == null) {
            throw new CalloutException('Unable to request PDF from Xero.');
        }

        Integer sc = res.getStatusCode();
        if (sc != 200) {
            throw new CalloutException('Xero PDF request failed: HTTP ' + String.valueOf(sc));
        }
        Blob pdfBlob = res.getBodyAsBlob();
        if (pdfBlob == null || pdfBlob.size() == 0) {
            throw new CalloutException('Xero returned an empty PDF body.');
        }
        String title = safePdfTitle(xi.Invoice_Number__c, xi.Xero_Invoice_ID__c);
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title,
            VersionData = pdfBlob,
            FirstPublishLocationId = xi.Id
        );
        insert cv;
        Id contentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].ContentDocumentId;
        update new Xero_Invoice__c(Id = xi.Id, PDF_Document_Id__c = String.valueOf(contentDocumentId));
    }

    private static HttpResponse requestInvoicePdf(String xeroInvoiceGuid, String accessToken, String tenantId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(XeroService.API_BASE + '/Invoices/' + xeroInvoiceGuid);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + accessToken.trim());
        req.setHeader('xero-tenant-id', tenantId.trim());
        req.setHeader('Accept', 'application/pdf');
        return new Http().send(req);
    }

    private static String safePdfTitle(String invoiceNumber, String fallbackId) {
        String base = String.isNotBlank(invoiceNumber) ? invoiceNumber : (String.isNotBlank(fallbackId) ? fallbackId : 'Invoice');
        String cleaned = base.replaceAll('[\\\\/:*?"<>|]', '_');
        if (cleaned.length() > 200) {
            cleaned = cleaned.substring(0, 200);
        }
        return 'Invoice_' + cleaned + '.pdf';
    }
}
