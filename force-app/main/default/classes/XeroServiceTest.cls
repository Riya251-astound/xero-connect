@isTest
private class XeroServiceTest {
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
    static void getAuthUrl_buildsAuthorizeUrl() {
        String url = XeroService.getAuthUrl();
        System.assert(url.contains('login.xero.com'), url);
        System.assert(url.contains('client_id='), url);
        System.assert(url.contains('redirect_uri='), url);
    }

    @isTest
    static void getRedirectUri_endsWithCallback() {
        String u = XeroService.getRedirectUri();
        System.assert(u.endsWith('/apex/XeroCallback'), u);
    }

    @isTest
    static void exchangeAndTenant_flow() {
        Test.setMock(HttpCalloutMock.class, new XeroHttpCalloutMock());
        Map<String, Object> tok = XeroService.exchangeCodeForTokens('auth-code');
        System.assertEquals('mock-access', String.valueOf(tok.get('access_token')));
        String tid = XeroService.getTenantId('mock-access');
        System.assertEquals('11111111-1111-1111-1111-111111111111', tid);
    }

    @isTest
    static void refreshToken_updatesConnection() {
        Test.setMock(HttpCalloutMock.class, new XeroHttpCalloutMock());
        XeroService.refreshToken();
        Xero_Connection__c conn = [
            SELECT Access_Token__c, Refresh_Token__c
            FROM Xero_Connection__c
            LIMIT 1
        ];
        System.assertEquals('mock-access', conn.Access_Token__c);
        System.assert(!String.isBlank(conn.Refresh_Token__c));
    }

    @isTest
    static void callAccountingApi_postsContacts() {
        Test.setMock(HttpCalloutMock.class, new XeroHttpCalloutMock());
        HttpResponse res = XeroService.callAccountingApi('POST', '/Contacts', '{"Contacts":[]}');
        System.assertEquals(200, res.getStatusCode());
    }
}
