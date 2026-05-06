@isTest
private class XeroInvoiceSyncTest {
    @TestSetup
    static void setupConnection() {
        insert new Xero_Connection__c(
            Name = 'Primary',
            Client_ID__c = 'client',
            Client_Secret__c = 'secret',
            Access_Token__c = 'mock-access',
            Refresh_Token__c = 'mock-refresh',
            Tenant_ID__c = '11111111-1111-1111-1111-111111111111'
        );
    }

    @isTest
    static void queueable_setsInvoiceIdOnOpportunity() {
        Test.setMock(HttpCalloutMock.class, new XeroHttpCalloutMock());
        Account a = new Account(Name = 'Acct', Xero_Contact_ID__c = 'cccccccc-cccc-cccc-cccc-cccccccccccc');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = a.Id,
            Amount = 100
        );
        insert o;
        Test.startTest();
        System.enqueueJob(new XeroInvoiceSync(new Set<Id>{ o.Id }));
        Test.stopTest();
        Xero_Invoice__c xi = [
            SELECT
                Id,
                Name,
                Xero_Invoice_ID__c,
                Opportunity__c,
                Account__c,
                Status__c,
                Xero_Status__c,
                Total_Amount__c,
                Total__c,
                Amount_Due__c,
                Invoice_Number__c,
                (SELECT Id FROM Invoice_Lines__r)
            FROM Xero_Invoice__c
            WHERE Opportunity__c = :o.Id
            LIMIT 1
        ];
        System.assertEquals('iiiiiiii-iiii-iiii-iiii-iiiiiiiiiiii', xi.Xero_Invoice_ID__c);
        System.assertEquals(o.Id, xi.Opportunity__c);
        System.assertEquals(a.Id, xi.Account__c);
        System.assertEquals('AUTHORISED', xi.Status__c);
        System.assertEquals('AUTHORISED', xi.Xero_Status__c);
        System.assertEquals(100, xi.Total_Amount__c);
        System.assertEquals(100, xi.Total__c);
        System.assertEquals(100, xi.Amount_Due__c);
        System.assertEquals('INV-1', xi.Name);
        System.assertEquals('INV-1', xi.Invoice_Number__c);
        System.assertEquals(1, xi.Invoice_Lines__r.size());
        Opportunity oAfter = [SELECT Xero_Invoice_ID__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals('iiiiiiii-iiii-iiii-iiii-iiiiiiiiiiii', oAfter.Xero_Invoice_ID__c);
    }
}
