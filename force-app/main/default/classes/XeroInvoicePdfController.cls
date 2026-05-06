/**
 * LWC entry points for fetching a Xero invoice PDF (binary) and storing it as a Salesforce file on {@link Xero_Invoice__c}.
 * PDF HTTP callouts run in {@link XeroInvoicePdfSync} (Queueable) so the UI does not hit synchronous callout limits.
 */
public inherited sharing class XeroInvoicePdfController {
    /**
     * Enqueues {@link XeroInvoicePdfSync} to download the PDF from Xero and attach it to the invoice record.
     * Returns {@code queued} immediately. The client should wait briefly and refresh wired data (or poll) for {@code PDF_Document_Id__c}.
     */
    @AuraEnabled
    public static String fetchAndStorePdf(Id xeroInvoiceRecordId) {
        Id invoiceId = resolveToXeroInvoiceId(xeroInvoiceRecordId);
        if (invoiceId == null) {
            throw new AuraHandledException('No Xero Invoice found for this record.');
        }
        List<Xero_Invoice__c> rows = [
            SELECT Id, Xero_Invoice_ID__c
            FROM Xero_Invoice__c
            WHERE Id = :invoiceId
            LIMIT 1
        ];
        if (rows.isEmpty() || String.isBlank(rows[0].Xero_Invoice_ID__c)) {
            throw new AuraHandledException('Xero Invoice ID is not set on this record.');
        }
        System.enqueueJob(new XeroInvoicePdfSync(invoiceId));
        return 'queued';
    }

    @AuraEnabled(cacheable=true)
    public static String getPdfDocumentId(Id xeroInvoiceRecordId) {
        Id invoiceId = resolveToXeroInvoiceId(xeroInvoiceRecordId);
        if (invoiceId == null) {
            return null;
        }
        List<Xero_Invoice__c> rows = [SELECT PDF_Document_Id__c FROM Xero_Invoice__c WHERE Id = :invoiceId LIMIT 1];
        return rows.isEmpty() ? null : rows[0].PDF_Document_Id__c;
    }

    @AuraEnabled(cacheable=true)
    public static Xero_Invoice__c getInvoiceDetails(Id recordId) {
        Id invoiceId = resolveToXeroInvoiceId(recordId);
        if (invoiceId == null) {
            return null;
        }
        List<Xero_Invoice__c> rows = [
            SELECT
                Id,
                Invoice_Number__c,
                Invoice_Status__c,
                Status__c,
                Total_Amount__c,
                Amount_Due__c,
                PDF_Document_Id__c,
                Xero_Invoice_ID__c,
                Opportunity__c
            FROM Xero_Invoice__c
            WHERE Id = :invoiceId
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Sends the stored invoice PDF (ContentDocument) to the related Account owner's email.
     *
     * @return map with {@code status} = {@code sent} and {@code ownerEmail} = recipient address
     */
    @AuraEnabled
    public static Map<String, String> sendInvoiceEmail(Id xeroInvoiceRecordId) {
        Id invoiceId = resolveToXeroInvoiceId(xeroInvoiceRecordId);
        if (invoiceId == null) {
            throw new AuraHandledException('No Xero Invoice found for this record.');
        }
        List<Xero_Invoice__c> invRows = [
            SELECT PDF_Document_Id__c, Account__c, Opportunity__c, Invoice_Number__c
            FROM Xero_Invoice__c
            WHERE Id = :invoiceId
            LIMIT 1
        ];
        if (invRows.isEmpty()) {
            throw new AuraHandledException('Invoice not found.');
        }
        Xero_Invoice__c xi = invRows[0];
        if (String.isBlank(xi.PDF_Document_Id__c)) {
            throw new AuraHandledException('No PDF attached. Download the invoice PDF first.');
        }
        if (xi.Account__c == null) {
            throw new AuraHandledException('Invoice has no Account; cannot resolve owner email.');
        }
        List<Account> accRows = [
            SELECT Owner.Email
            FROM Account
            WHERE Id = :xi.Account__c
            LIMIT 1
        ];
        if (accRows.isEmpty() || String.isBlank(accRows[0].Owner.Email)) {
            throw new AuraHandledException('Account owner email is not available.');
        }
        String ownerEmail = accRows[0].Owner.Email.trim();
        Id contentDocumentId;
        try {
            contentDocumentId = Id.valueOf(xi.PDF_Document_Id__c.trim());
        } catch (Exception e) {
            throw new AuraHandledException('Invalid PDF document id on invoice.');
        }
        List<ContentVersion> versions = [
            SELECT Title, VersionData
            FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId AND IsLatest = TRUE
            LIMIT 1
        ];
        if (versions.isEmpty() || versions[0].VersionData == null) {
            throw new AuraHandledException('PDF file content not found.');
        }
        ContentVersion latest = versions[0];
        String fileName = buildPdfAttachmentName(latest.Title);
        Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
        att.setFileName(fileName);
        att.setBody(latest.VersionData);
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ ownerEmail });
        mail.setSubject(buildEmailSubject(xi.Invoice_Number__c));
        mail.setPlainTextBody('Please find the invoice PDF attached.');
        mail.setFileAttachments(new List<Messaging.EmailFileAttachment>{ att });
        Messaging.SendEmailResult[] results = Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail }, false);
        if (results.isEmpty() || !results[0].isSuccess()) {
            String err = results.isEmpty()
                ? 'Unknown email error'
                : (results[0].getErrors().isEmpty() ? 'Email rejected' : results[0].getErrors()[0].getMessage());
            throw new AuraHandledException(err);
        }
        return new Map<String, String>{ 'status' => 'sent', 'ownerEmail' => ownerEmail };
    }

    private static String buildPdfAttachmentName(String title) {
        String base = String.isNotBlank(title) ? title.replaceAll('[\\\\/:*?"<>|]', '_') : 'Invoice';
        if (base.toLowerCase().endsWith('.pdf')) {
            return base;
        }
        return base + '.pdf';
    }

    private static String buildEmailSubject(String invoiceNumber) {
        if (String.isNotBlank(invoiceNumber)) {
            return 'Invoice: ' + invoiceNumber;
        }
        return 'Invoice PDF';
    }

    private static Id resolveToXeroInvoiceId(Id recordId) {
        if (recordId == null) {
            return null;
        }
        String typeName = recordId.getSobjectType().getDescribe().getName();
        if (typeName == 'Xero_Invoice__c') {
            return recordId;
        }
        if (typeName == 'Opportunity') {
            List<Xero_Invoice__c> found = [
                SELECT Id
                FROM Xero_Invoice__c
                WHERE Opportunity__c = :recordId
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            return found.isEmpty() ? null : found[0].Id;
        }
        return null;
    }
}
