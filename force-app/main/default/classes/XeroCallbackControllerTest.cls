@isTest
private class XeroCallbackControllerTest {
    @TestSetup
    static void setupConnection() {
        insert new Xero_Connection__c(Name = 'Primary', Client_ID__c = 'client', Client_Secret__c = 'secret');
    }

    @isTest
    static void callback_withCode_savesTokens() {
        Test.setMock(HttpCalloutMock.class, new XeroHttpCalloutMock());
        PageReference p = Page.XeroCallback;
        p.getParameters().put('code', 'auth-code-value');
        Test.setCurrentPage(p);
        XeroCallbackController c = new XeroCallbackController();
        c.handleCallback();
        System.assertEquals(null, c.errorMessage, c.errorMessage);
        System.assert(String.isNotBlank(c.message));
        Xero_Connection__c conn = [SELECT Tenant_ID__c FROM Xero_Connection__c LIMIT 1];
        System.assertEquals('11111111-1111-1111-1111-111111111111', conn.Tenant_ID__c);
    }

    @isTest
    static void callback_withOAuthError_showsError() {
        PageReference p = Page.XeroCallback;
        p.getParameters().put('error', 'access_denied');
        p.getParameters().put('error_description', 'User cancelled');
        Test.setCurrentPage(p);
        XeroCallbackController c = new XeroCallbackController();
        c.handleCallback();
        System.assert(String.isNotBlank(c.errorMessage));
    }
}
