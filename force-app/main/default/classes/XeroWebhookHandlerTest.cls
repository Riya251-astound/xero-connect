@isTest
private class XeroWebhookHandlerTest {
    private static final String TENANT = '11111111-1111-1111-1111-111111111111';
    private static final String CONTACT_ID = 'cccccccc-cccc-cccc-cccc-cccccccccccc';

    @TestSetup
    static void setup() {
        insert new Xero_Connection__c(
            Name = 'Primary',
            Client_ID__c = 'client',
            Client_Secret__c = 'secret',
            Access_Token__c = 'mock-access',
            Refresh_Token__c = 'mock-refresh',
            Tenant_ID__c = TENANT
        );
        insert new Account(Name = 'Acct', Xero_Contact_ID__c = CONTACT_ID);
    }

    @isTest
    static void contactEvent_updatesAccountFromXero() {
        Test.setMock(HttpCalloutMock.class, new WebhookInboundMock());

        String payload =
            '{"events":[{' +
            '"tenantId":"' +
            TENANT +
            '",' +
            '"resourceId":"' +
            CONTACT_ID +
            '",' +
            '"eventCategory":"CONTACT"' +
            '}]}';

        Test.startTest();
        new XeroWebhookHandler(payload).execute(null);
        Test.stopTest();

        Account a = [SELECT Name, Phone FROM Account WHERE Xero_Contact_ID__c = :CONTACT_ID];
        System.assertEquals('Webhook Contact Name', a.Name);
        System.assertEquals('555-0100', a.Phone);
    }

    private class WebhookInboundMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            String ep = req.getEndpoint();
            String method = req.getMethod();
            if (ep.contains('identity.xero.com/connect/token')) {
                res.setStatusCode(200);
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"access_token":"mock-access","refresh_token":"mock-refresh","expires_in":1800}');
                return res;
            }
            if (method == 'GET' && ep.contains('/Contacts/')) {
                res.setStatusCode(200);
                res.setHeader('Content-Type', 'application/json');
                res.setBody(
                    '{"Contacts":[{"ContactID":"' +
                        CONTACT_ID +
                        '","Name":"Webhook Contact Name","Phones":[{"PhoneType":"DEFAULT","PhoneNumber":"555-0100"}]}]}'
                );
                return res;
            }
            if (method == 'GET' && ep.contains('/Items/')) {
                res.setStatusCode(200);
                res.setBody('{"Items":[{"ItemID":"aa","Code":"SKU1","Name":"Item N","Description":"D"}]}');
                return res;
            }
            if (method == 'GET' && ep.contains('/Invoices/')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"Invoices":[{"InvoiceID":"iiiiiiii-iiii-iiii-iiii-iiiiiiiiiiii","Status":"AUTHORISED","Total":99.5,"AmountDue":12.25,"Reference":"Ref","Date":"2026-04-01T00:00:00","LineItems":[{"Description":"Webhook line","Quantity":2,"UnitAmount":10,"LineAmount":20,"LineItemID":"wwwwwwww-wwww-wwww-wwww-wwwwwwwwwwww","ItemCode":"SKU1"}]}]}'
                );
                return res;
            }
            res.setStatusCode(500);
            res.setBody('{}');
            return res;
        }
    }

    @isTest
    static void itemEvent_updatesProductByItemCode() {
        Test.setMock(HttpCalloutMock.class, new WebhookInboundMock());
        Product2 p = new Product2(Name = 'P', ProductCode = 'SKU1', Xero_Item_Code__c = 'SKU1', IsActive = true);
        insert p;

        String payload =
            '{"events":[{' +
            '"tenantId":"' +
            TENANT +
            '",' +
            '"resourceId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",' +
            '"eventCategory":"ITEM"' +
            '}]}';

        Test.startTest();
        new XeroWebhookHandler(payload).execute(null);
        Test.stopTest();

        Product2 after = [SELECT Name, Description FROM Product2 WHERE Id = :p.Id];
        System.assertEquals('Item N', after.Name);
        System.assertEquals('D', after.Description);
    }

    @isTest
    static void invoiceEvent_updatesXeroInvoiceMirror() {
        Test.setMock(HttpCalloutMock.class, new WebhookInboundMock());
        Account a = new Account(Name = 'A');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'O',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(10),
            AccountId = a.Id
        );
        insert o;
        insert new Xero_Invoice__c(
            Opportunity__c = o.Id,
            Account__c = a.Id,
            Xero_Invoice_ID__c = 'iiiiiiii-iiii-iiii-iiii-iiiiiiiiiiii',
            Status__c = 'DRAFT',
            Invoice_Status__c = 'DRAFT',
            Amount_Due__c = 0,
            Total_Amount__c = 0
        );

        String payload =
            '{"events":[{' +
            '"tenantId":"' +
            TENANT +
            '",' +
            '"resourceId":"iiiiiiii-iiii-iiii-iiii-iiiiiiiiiiii",' +
            '"eventCategory":"INVOICE"' +
            '}]}';

        Test.startTest();
        new XeroWebhookHandler(payload).execute(null);
        Test.stopTest();

        Xero_Invoice__c xi = [
            SELECT Status__c, Invoice_Status__c, Amount_Due__c, Total_Amount__c, Opportunity__c, (SELECT Id, Description__c FROM Invoice_Lines__r)
            FROM Xero_Invoice__c
            WHERE Xero_Invoice_ID__c = 'iiiiiiii-iiii-iiii-iiii-iiiiiiiiiiii'
            LIMIT 1
        ];
        System.assertEquals('AUTHORISED', xi.Status__c);
        System.assertEquals('AUTHORISED', xi.Invoice_Status__c);
        System.assertEquals(12.25, xi.Amount_Due__c);
        System.assertEquals(99.5, xi.Total_Amount__c);
        System.assertEquals(o.Id, xi.Opportunity__c);
        System.assertEquals(1, xi.Invoice_Lines__r.size());
        System.assertEquals('Webhook line', xi.Invoice_Lines__r[0].Description__c);
    }

    @isTest
    static void invoiceEvent_createsXeroInvoiceWhenMissing() {
        Test.setMock(HttpCalloutMock.class, new WebhookInboundMock());
        String payload =
            '{"events":[{' +
            '"tenantId":"' +
            TENANT +
            '",' +
            '"resourceId":"iiiiiiii-iiii-iiii-iiii-iiiiiiiiiiii",' +
            '"eventCategory":"INVOICE"' +
            '}]}';

        Test.startTest();
        new XeroWebhookHandler(payload).execute(null);
        Test.stopTest();

        Xero_Invoice__c xi = [
            SELECT Status__c, Invoice_Status__c, Amount_Due__c, Total_Amount__c
            FROM Xero_Invoice__c
            WHERE Xero_Invoice_ID__c = 'iiiiiiii-iiii-iiii-iiii-iiiiiiiiiiii'
            LIMIT 1
        ];
        System.assertEquals('AUTHORISED', xi.Status__c);
        System.assertEquals('AUTHORISED', xi.Invoice_Status__c);
        System.assertEquals(12.25, xi.Amount_Due__c);
        System.assertEquals(99.5, xi.Total_Amount__c);
    }
}
