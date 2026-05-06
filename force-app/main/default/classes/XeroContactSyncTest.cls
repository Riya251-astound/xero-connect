@isTest
private class XeroContactSyncTest {
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
    static void queueable_updatesAccountExternalId() {
        Test.setMock(HttpCalloutMock.class, new XeroHttpCalloutMock());
        Account a = new Account(Name = 'Test Co');
        insert a;
        Test.startTest();
        System.enqueueJob(new XeroContactSync(new Set<Id>{ a.Id }));
        Test.stopTest();
        Account after = [SELECT Xero_Contact_ID__c FROM Account WHERE Id = :a.Id];
        System.assertEquals('cccccccc-cccc-cccc-cccc-cccccccccccc', after.Xero_Contact_ID__c);
        System.assert(!String.isBlank(after.Xero_Contact_ID__c));
    }
}
