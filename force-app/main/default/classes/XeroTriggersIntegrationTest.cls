@isTest
private class XeroTriggersIntegrationTest {
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
    static void accountInsert_enqueuesContactSync() {
        Test.setMock(HttpCalloutMock.class, new XeroHttpCalloutMock());
        Test.startTest();
        insert new Account(Name = 'Integration Co');
        Test.stopTest();
        System.assert([SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND Status IN ('Queued', 'Processing', 'Completed', 'Holding')] > 0);
    }

    @isTest
    static void productInsert_enqueuesProductSync() {
        Test.setMock(HttpCalloutMock.class, new XeroHttpCalloutMock());
        Test.startTest();
        insert new Product2(Name = 'Integration Product', ProductCode = 'INT-SKU', IsActive = true);
        Test.stopTest();
        System.assert([SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND Status IN ('Queued', 'Processing', 'Completed', 'Holding')] > 0);
    }
}
