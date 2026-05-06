@isTest
private class XeroWebhookListenerTest {
    private static final String WEBHOOK_KEY = 'test-webhook-secret-key';

    @TestSetup
    static void setup() {
        insert new Xero_Connection__c(
            Name = 'Primary',
            Client_ID__c = 'client',
            Client_Secret__c = 'secret',
            Access_Token__c = 'mock-access',
            Refresh_Token__c = 'mock-refresh',
            Tenant_ID__c = '11111111-1111-1111-1111-111111111111',
            Webhook_Key__c = WEBHOOK_KEY
        );
    }

    @isTest
    static void doPost_validSignature_returns200AndEnqueues() {
        String body = '{"events":[],"lastEventSequence":0}';
        Blob bodyBlob = Blob.valueOf(body);
        Blob mac = Crypto.generateMac('HmacSHA256', bodyBlob, Blob.valueOf(WEBHOOK_KEY));
        String sig = EncodingUtil.base64Encode(mac);

        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestUri = '/services/apexrest/xero_events/';
        req.addHeader('x-xero-signature', sig);
        req.requestBody = bodyBlob;
        RestResponse res = new RestResponse();
        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        XeroWebhookListener.doPost();
        Test.stopTest();

        System.assertEquals(200, res.statusCode, 'Expected 200 for valid HMAC');
        Id connId = [SELECT Id FROM Xero_Connection__c LIMIT 1].Id;
        String expectedIntegrationType = XeroService.INTEGRATION_LOG_TYPE_WEBHOOK;
        Integration_Log__c logRow = [
            SELECT Status__c, Direction__c, Integration_Type__c, Request_Body__c, Error_Message__c, Xero_Connection__c
            FROM Integration_Log__c
            WHERE
                Xero_Connection__c = :connId
                AND Direction__c = 'Inbound'
                AND Integration_Type__c = :expectedIntegrationType
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        System.assertEquals('Success', logRow.Status__c);
        System.assertEquals('Inbound', logRow.Direction__c);
        System.assertEquals(XeroService.INTEGRATION_LOG_TYPE_WEBHOOK, logRow.Integration_Type__c);
        System.assertEquals(null, logRow.Error_Message__c);
        System.assertEquals(body, logRow.Request_Body__c);
    }

    @isTest
    static void doPost_invalidSignature_returns401() {
        String body = '{"events":[]}';
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestUri = '/services/apexrest/xero_events/';
        req.addHeader('x-xero-signature', 'not-valid-signature');
        req.requestBody = Blob.valueOf(body);
        RestResponse res = new RestResponse();
        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        XeroWebhookListener.doPost();
        Test.stopTest();

        System.assertEquals(401, res.statusCode);
        Id connId = [SELECT Id FROM Xero_Connection__c LIMIT 1].Id;
        String expectedIntegrationType = XeroService.INTEGRATION_LOG_TYPE_WEBHOOK;
        Integration_Log__c logRow = [
            SELECT Status__c, Direction__c, Integration_Type__c, Error_Message__c, Request_Body__c
            FROM Integration_Log__c
            WHERE
                Xero_Connection__c = :connId
                AND Direction__c = 'Inbound'
                AND Integration_Type__c = :expectedIntegrationType
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        System.assertEquals('Error', logRow.Status__c);
        System.assertEquals(body, logRow.Request_Body__c);
        System.assert(
            logRow.Error_Message__c != null && logRow.Error_Message__c.contains('signature mismatch'),
            logRow.Error_Message__c
        );
    }

    @isTest
    static void doGet_returns200() {
        RestResponse res = new RestResponse();
        RestContext.response = res;
        XeroWebhookListener.doGet();
        System.assertEquals(200, res.statusCode);
    }

    @isTest
    static void verifySignature_matchesXeroPattern() {
        String key = 'k';
        Blob payload = Blob.valueOf('{"events":[]}');
        Blob mac = Crypto.generateMac('HmacSHA256', payload, Blob.valueOf(key));
        String expected = EncodingUtil.base64Encode(mac);
        System.assert(XeroWebhookListener.verifySignature(payload, expected, key));
        System.assert(!XeroWebhookListener.verifySignature(payload, 'bad', key));
    }
}
