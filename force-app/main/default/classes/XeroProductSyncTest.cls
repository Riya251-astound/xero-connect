@isTest
private class XeroProductSyncTest {
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
    static void queueable_setsItemCodeOnProduct() {
        Test.setMock(HttpCalloutMock.class, new XeroHttpCalloutMock());
        Product2 p = new Product2(Name = 'Widget', ProductCode = 'SKU1', IsActive = true);
        insert p;
        Test.startTest();
        System.enqueueJob(new XeroProductSync(new Set<Id>{ p.Id }));
        Test.stopTest();
        Product2 after = [SELECT Xero_Item_Code__c FROM Product2 WHERE Id = :p.Id];
        System.assertEquals('SKU1', after.Xero_Item_Code__c);
    }
}
