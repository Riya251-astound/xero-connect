/**
 * Inbound REST endpoint for Xero webhooks. URL: /services/apexrest/xero_events/
 * Verifies x-xero-signature (HMAC-SHA256, Base64) with Webhook_Key__c, logs each POST to {@link Integration_Log__c}
 * via {@link XeroService#logIntegration}, responds with 200/401, and enqueues {@link XeroWebhookHandler} when valid.
 */
@RestResource(urlMapping='/xero_events/*')
global with sharing class XeroWebhookListener {
    @HttpPost
    global static void doPost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        Blob bodyBlob = req.requestBody == null ? Blob.valueOf('') : req.requestBody;
        String requestBodyStr = bodyBlob.toString();
        String sigHeader = getHeaderIgnoreCase(req, 'x-xero-signature');

        Id connectionId;
        String webhookKey;
        List<Xero_Connection__c> rows = [SELECT Id, Webhook_Key__c FROM Xero_Connection__c LIMIT 1];
        if (!rows.isEmpty()) {
            connectionId = rows[0].Id;
            webhookKey = rows[0].Webhook_Key__c;
        }

        Boolean signatureValid = false;
        String errorMessage;
        if (rows.isEmpty()) {
            errorMessage = 'No Xero_Connection__c record found.';
        } else if (String.isBlank(webhookKey)) {
            errorMessage = 'Webhook_Key__c is not configured on Xero_Connection__c.';
        } else if (String.isBlank(sigHeader)) {
            errorMessage = 'Missing x-xero-signature header (blocked / unauthorized).';
        } else if (!verifySignature(bodyBlob, sigHeader, webhookKey)) {
            errorMessage = 'x-xero-signature validation failed (signature mismatch).';
        } else {
            signatureValid = true;
        }

        String status = signatureValid ? 'Success' : 'Error';
        XeroService.logIntegration(
            connectionId,
            'Inbound',
            XeroService.INTEGRATION_LOG_TYPE_WEBHOOK,
            status,
            requestBodyStr,
            null,
            errorMessage
        );

        if (!signatureValid) {
            res.statusCode = 401;
            res.responseBody = Blob.valueOf('');
            return;
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf('');
        System.enqueueJob(new XeroWebhookHandler(requestBodyStr));
    }

    /**
     * Optional connectivity / health check. Xero webhook delivery uses POST only.
     */
    @HttpGet
    global static void doGet() {
        RestContext.response.statusCode = 200;
        RestContext.response.responseBody = Blob.valueOf('');
    }

    private static String getHeaderIgnoreCase(RestRequest req, String canonicalHeaderName) {
        if (req.headers == null) {
            return null;
        }
        for (String k : req.headers.keySet()) {
            if (k != null && canonicalHeaderName.equalsIgnoreCase(k)) {
                return req.headers.get(k);
            }
        }
        return null;
    }

    /**
     * Xero: Base64(HMAC_SHA256(raw body, UTF-8 webhook key)).
     */
    public static Boolean verifySignature(Blob bodyBlob, String signatureHeader, String webhookKey) {
        if (String.isBlank(webhookKey) || signatureHeader == null) {
            return false;
        }
        Blob keyBlob = Blob.valueOf(webhookKey);
        Blob dataBlob = bodyBlob == null ? Blob.valueOf('') : bodyBlob;
        Blob mac = Crypto.generateMac('HmacSHA256', dataBlob, keyBlob);
        String expected = EncodingUtil.base64Encode(mac);
        return secureEquals(expected.trim(), signatureHeader.trim());
    }

    private static Boolean secureEquals(String a, String b) {
        if (a == null || b == null) {
            return false;
        }
        if (a.length() != b.length()) {
            return false;
        }
        Integer xor = 0;
        for (Integer i = 0; i < a.length(); i++) {
            xor |= a.charAt(i) ^ b.charAt(i);
        }
        return xor == 0;
    }
}
