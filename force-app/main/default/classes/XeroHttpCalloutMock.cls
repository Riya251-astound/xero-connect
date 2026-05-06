/**
 * Multi-endpoint HttpCalloutMock for Xero OAuth and Accounting API tests.
 */
@isTest
public inherited sharing class XeroHttpCalloutMock implements HttpCalloutMock {
    public Integer tokenStatus = 200;
    public Integer connectionsStatus = 200;
    public Integer apiStatus = 200;

    public HTTPResponse respond(HTTPRequest req) {
        HttpResponse res = new HttpResponse();
        String ep = req.getEndpoint();
        if (ep.contains('identity.xero.com/connect/token')) {
            res.setStatusCode(tokenStatus);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"access_token":"mock-access","refresh_token":"mock-refresh","expires_in":1800}');
            return res;
        }
        if (ep.contains('api.xero.com/connections')) {
            res.setStatusCode(connectionsStatus);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('[{"tenantId":"11111111-1111-1111-1111-111111111111","tenantName":"Demo"}]');
            return res;
        }
        if (ep.contains('/Contacts')) {
            res.setStatusCode(apiStatus);
            res.setHeader('Content-Type', 'application/json');
            Integer contactCount = 1;
            if (req.getBody() != null && !String.isBlank(req.getBody())) {
                try {
                    Map<String, Object> bodyMap = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
                    List<Object> reqContacts = (List<Object>) bodyMap.get('Contacts');
                    if (reqContacts != null && !reqContacts.isEmpty()) {
                        contactCount = reqContacts.size();
                    }
                } catch (Exception e) {
                    contactCount = 1;
                }
            }
            List<String> contactParts = new List<String>();
            for (Integer i = 0; i < contactCount; i++) {
                String contactId;
                if (i == 0) {
                    contactId = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
                } else {
                    String num = String.valueOf(100000 + i);
                    while (num.length() < 12) {
                        num = '0' + num;
                    }
                    contactId = 'cccccccc-cccc-cccc-cccc-' + num;
                }
                contactParts.add('{"ContactID":"' + contactId + '"}');
            }
            res.setBody('{"Contacts":[' + String.join(contactParts, ',') + ']}');
            return res;
        }
        if (ep.contains('/Invoices')) {
            res.setStatusCode(apiStatus);
            String path = ep.contains('?') ? ep.substring(0, ep.indexOf('?')) : ep;
            Integer invoicesIdx = path.indexOf('/Invoices');
            String afterInvoices = invoicesIdx >= 0 ? path.substring(invoicesIdx + '/Invoices'.length()) : '';
            Boolean getById =
                req.getMethod().equalsIgnoreCase('GET') &&
                afterInvoices.startsWith('/') &&
                afterInvoices.length() > 1;
            if (getById && 'application/pdf'.equalsIgnoreCase(req.getHeader('Accept'))) {
                res.setHeader('Content-Type', 'application/pdf');
                res.setBodyAsBlob(Blob.valueOf('%PDF-1.4 mock invoice pdf'));
                return res;
            }
            res.setHeader('Content-Type', 'application/json');
            if (getById) {
                String invoiceId = afterInvoices.substring(1);
                res.setBody(
                    '{"Invoices":[{"InvoiceID":"' +
                        invoiceId +
                        '","Status":"AUTHORISED","Total":50,"AmountDue":50,"InvoiceNumber":"MOCK-1","LineItems":[]}]}'
                );
                return res;
            }
            Integer count = 1;
            if (req.getBody() != null) {
                try {
                    Map<String, Object> bodyMap = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
                    List<Object> invs = (List<Object>) bodyMap.get('Invoices');
                    if (invs != null && !invs.isEmpty()) {
                        count = invs.size();
                    }
                } catch (Exception e) {
                    count = 1;
                }
            }
            List<String> parts = new List<String>();
            for (Integer i = 0; i < count; i++) {
                String invoiceId;
                String lineIdSuffix;
                if (i == 0) {
                    invoiceId = 'iiiiiiii-iiii-iiii-iiii-iiiiiiiiiiii';
                    lineIdSuffix = 'llllllllllll';
                } else {
                    String num = String.valueOf(100000 + i);
                    while (num.length() < 12) {
                        num = '0' + num;
                    }
                    invoiceId = 'aaaaaaaa-aaaa-aaaa-aaaa-' + num;
                    lineIdSuffix = num;
                }
                parts.add(
                    '{"InvoiceID":"' +
                        invoiceId +
                        '","Status":"AUTHORISED","Total":100,"AmountDue":100,"InvoiceNumber":"INV-' +
                        String.valueOf(i + 1) +
                        '","LineItems":[{"Description":"Line","Quantity":1,"UnitAmount":100,"LineAmount":100,"LineItemID":"llllllll-llll-llll-llll-' +
                        lineIdSuffix +
                        '","ItemCode":"SKU"}]}'
                );
            }
            res.setBody('{"Invoices":[' + String.join(parts, ',') + ']}');
            return res;
        }
        if (ep.contains('/Items') && 'GET'.equalsIgnoreCase(req.getMethod())) {
            res.setStatusCode(apiStatus);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"Items":[]}');
            return res;
        }
        if (ep.contains('/Items')) {
            res.setStatusCode(apiStatus);
            res.setHeader('Content-Type', 'application/json');
            List<String> itemParts = new List<String>();
            if (req.getBody() != null && !String.isBlank(req.getBody())) {
                try {
                    Map<String, Object> bodyMap = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
                    List<Object> reqItems = (List<Object>) bodyMap.get('Items');
                    if (reqItems != null) {
                        for (Integer i = 0; i < reqItems.size(); i++) {
                            Map<String, Object> im = (Map<String, Object>) reqItems[i];
                            String code = im.get('Code') != null ? String.valueOf(im.get('Code')) : 'SKU' + i;
                            Object iidObj = im.get('ItemID');
                            String itemId;
                            if (iidObj != null) {
                                itemId = String.valueOf(iidObj);
                            } else if (i == 0) {
                                itemId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
                            } else {
                                String num = String.valueOf(100000 + i);
                                while (num.length() < 12) {
                                    num = '0' + num;
                                }
                                itemId = 'bbbbbbbb-bbbb-bbbb-bbbb-' + num;
                            }
                            itemParts.add(
                                '{"ItemID":"' +
                                    itemId +
                                    '","Code":"' +
                                    code +
                                    '","Name":"Test Product"}'
                            );
                        }
                    }
                } catch (Exception e) {
                    itemParts.clear();
                }
            }
            if (itemParts.isEmpty()) {
                res.setBody(
                    '{"Items":[{"ItemID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","Code":"SKU1","Name":"Test Product"}]}'
                );
            } else {
                res.setBody('{"Items":[' + String.join(itemParts, ',') + ']}');
            }
            return res;
        }
        res.setStatusCode(500);
        res.setBody('{}');
        return res;
    }
}
