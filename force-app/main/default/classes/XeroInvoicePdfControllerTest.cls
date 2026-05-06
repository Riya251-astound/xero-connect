@isTest
private class XeroInvoicePdfControllerTest {
    @TestSetup
    static void setup() {
        insert new Xero_Connection__c(
            Name = 'Primary',
            Client_ID__c = 'client',
            Client_Secret__c = 'secret',
            Access_Token__c = 'mock-access',
            Refresh_Token__c = 'mock-refresh',
            Tenant_ID__c = '11111111-1111-1111-1111-111111111111'
        );
        Account a = new Account(Name = 'Acct');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = a.Id
        );
        insert o;
        insert new Xero_Invoice__c(
            Name = 'INV-PDF-1',
            Opportunity__c = o.Id,
            Account__c = a.Id,
            Xero_Invoice_ID__c = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            Invoice_Number__c = 'INV-PDF-1',
            Status__c = 'AUTHORISED',
            Invoice_Status__c = 'AUTHORISED',
            Total_Amount__c = 250,
            Amount_Due__c = 250
        );
    }

    @isTest
    static void fetchAndStorePdf_createsContentVersionAndSetsPdfField() {
        Test.setMock(HttpCalloutMock.class, new XeroHttpCalloutMock());
        Xero_Invoice__c xi = [SELECT Id FROM Xero_Invoice__c LIMIT 1];
        Test.startTest();
        System.assertEquals('queued', XeroInvoicePdfController.fetchAndStorePdf(xi.Id));
        Test.stopTest();
        xi = [
            SELECT PDF_Document_Id__c
            FROM Xero_Invoice__c
            WHERE Id = :xi.Id
        ];
        System.assert(
            String.isNotBlank(xi.PDF_Document_Id__c),
            'PDF_Document_Id__c should be set after queueable PDF fetch.'
        );
        List<ContentVersion> cvs = [
            SELECT Id, ContentDocumentId, FirstPublishLocationId
            FROM ContentVersion
            WHERE FirstPublishLocationId = :xi.Id
        ];
        System.assertEquals(1, cvs.size(), 'Expected one ContentVersion linked to the invoice.');
        System.assertEquals(cvs[0].ContentDocumentId, xi.PDF_Document_Id__c);
    }

    @isTest
    static void getPdfDocumentId_returnsStoredId() {
        Xero_Invoice__c xi = [SELECT Id FROM Xero_Invoice__c LIMIT 1];
        String fakeDocId = '069000000000001';
        update new Xero_Invoice__c(Id = xi.Id, PDF_Document_Id__c = fakeDocId);
        System.assertEquals(fakeDocId, XeroInvoicePdfController.getPdfDocumentId(xi.Id));
    }

    @isTest
    static void getPdfDocumentId_returnsNullWhenUnset() {
        Xero_Invoice__c xi = [SELECT Id FROM Xero_Invoice__c LIMIT 1];
        update new Xero_Invoice__c(Id = xi.Id, PDF_Document_Id__c = null);
        System.assertEquals(null, XeroInvoicePdfController.getPdfDocumentId(xi.Id));
    }

    @isTest
    static void getInvoiceDetails_resolvesFromOpportunity() {
        Opportunity o = [SELECT Id FROM Opportunity LIMIT 1];
        Xero_Invoice__c row = XeroInvoicePdfController.getInvoiceDetails(o.Id);
        System.assertNotEquals(null, row);
        System.assertEquals('INV-PDF-1', row.Invoice_Number__c);
        System.assertEquals('AUTHORISED', row.Invoice_Status__c);
        System.assertEquals(o.Id, row.Opportunity__c);
    }

    @isTest
    static void fetchAndStorePdf_throwsWhenNoInvoice() {
        Boolean threw = false;
        try {
            XeroInvoicePdfController.fetchAndStorePdf(UserInfo.getUserId());
        } catch (AuraHandledException e) {
            threw = true;
            System.assert(e.getMessage() != null);
        }
        System.assert(threw, 'Expected AuraHandledException for unsupported Id type.');
    }
}
