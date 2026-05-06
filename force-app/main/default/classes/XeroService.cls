/**
 * Xero OAuth 2.0 (Authorization Code) and Accounting API helpers.
 * Connection and tokens are stored on custom object Xero_Connection__c (single primary row).
 *
 * For Queueable/callout batches: call beginCalloutTransaction() before callouts and
 * flushDeferredTokenPersistence() after all callouts (before record DML) to avoid
 * "Uncommitted work pending" (no DML between callouts).
 *
 * Integration logs ({@link Integration_Log__c}) are buffered during deferred callout
 * transactions and inserted in {@link #flushDeferredTokenPersistence()} for the same reason.
 *
 * Log field sizes: {@link #INTEGRATION_LOG_REQUEST_BODY_MAX} (request), {@link #INTEGRATION_LOG_RESPONSE_BODY_MAX}
 * (response), {@link #INTEGRATION_LOG_ERROR_MESSAGE_MAX} (error message).
 */
public inherited sharing class XeroService {
    public static final String AUTH_AUTHORIZE_URL = 'https://login.xero.com/identity/connect/authorize';
    public static final String TOKEN_URL = 'https://identity.xero.com/connect/token';
    public static final String CONNECTIONS_URL = 'https://api.xero.com/connections';
    public static final String API_BASE = 'https://api.xero.com/api.xro/2.0';

    /** When true, token refresh does not update the row until flushDeferredTokenPersistence(). */
    private static Boolean deferTokenDml = false;
    private static String txnAccessTokenFull;
    private static String txnRefreshTokenFull;
    private static Boolean pendingTokenFlush = false;

    /** Buffered {@link Integration_Log__c} rows when {@link #deferTokenDml} is true (no DML between callouts). */
    private static List<Integration_Log__c> pendingIntegrationLogs = new List<Integration_Log__c>();

    public static final Integer INTEGRATION_LOG_REQUEST_BODY_MAX = 40000;
    public static final Integer INTEGRATION_LOG_RESPONSE_BODY_MAX = 32768;
    public static final Integer INTEGRATION_LOG_ERROR_MESSAGE_MAX = 32768;

    /**
     * {@link Integration_Log__c.Integration_Type__c} value for Xero Accounting API traffic and related outbound logs.
     * Must match an active picklist API value in the org (replace if your metadata uses e.g. {@code Accounting}).
     */
    public static final String INTEGRATION_LOG_TYPE_XERO = 'Xero';

    /** Inbound REST webhook listener ({@link XeroWebhookListener}). Must match {@code Integration_Log__c.Integration_Type__c} picklist API value. */
    public static final String INTEGRATION_LOG_TYPE_WEBHOOK = 'Xero Webhook';

    /** Async webhook processor ({@link XeroWebhookHandler}). Must match {@code Integration_Log__c.Integration_Type__c} picklist API value. */
    public static final String INTEGRATION_LOG_TYPE_WEBHOOK_HANDLER = 'Xero Webhook Handler';

    /** Items need accounting.settings; invoices need accounting.transactions (plus contacts for sync). */
    public static final String DEFAULT_SCOPES =
        'openid profile email offline_access accounting.contacts accounting.invoices accounting.settings';

    /**
     * Call at the start of Queueable.execute (or any flow that performs multiple callouts).
     */
    public static void beginCalloutTransaction() {
        deferTokenDml = true;
        txnAccessTokenFull = null;
        txnRefreshTokenFull = null;
        pendingTokenFlush = false;
        pendingIntegrationLogs = new List<Integration_Log__c>();
    }

    /**
     * Persist deferred tokens after all accounting callouts, before updating other records.
     */
    public static void flushDeferredTokenPersistence() {
        if (!deferTokenDml) {
            return;
        }
        if (!pendingIntegrationLogs.isEmpty()) {
            Database.SaveResult[] logResults = Database.insert(pendingIntegrationLogs, false);
            for (Integer i = 0; i < logResults.size(); i++) {
                if (!logResults[i].isSuccess()) {
                    System.debug(
                        LoggingLevel.ERROR,
                        'flushDeferredTokenPersistence: Integration_Log__c insert failed: ' +
                            logResults[i].getErrors()[0].getMessage()
                    );
                }
            }
            pendingIntegrationLogs.clear();
        }
        deferTokenDml = false;
        if (!pendingTokenFlush) {
            txnAccessTokenFull = null;
            txnRefreshTokenFull = null;
            return;
        }
        Xero_Connection__c conn = getConnectionRequired();
        if (String.isNotBlank(txnAccessTokenFull)) {
            conn.Access_Token__c = txnAccessTokenFull;
        }
        if (String.isNotBlank(txnRefreshTokenFull)) {
            conn.Refresh_Token__c = txnRefreshTokenFull;
        }
        update conn;
        txnAccessTokenFull = null;
        txnRefreshTokenFull = null;
        pendingTokenFlush = false;
    }

    public static String getAuthUrl() {
        Xero_Connection__c conn = getConnectionRequired();
        if (String.isBlank(conn.Client_ID__c)) {
            throw new XeroServiceException('Client_ID__c not configured.');
        }
        String redirectEnc = EncodingUtil.urlEncode(getRedirectUri(), 'UTF-8');
        String scopeEnc = EncodingUtil.urlEncode(DEFAULT_SCOPES.trim().replaceAll('\\s+', ' '), 'UTF-8');
        return AUTH_AUTHORIZE_URL +
            '?response_type=code&client_id=' +
            EncodingUtil.urlEncode(conn.Client_ID__c, 'UTF-8') +
            '&redirect_uri=' +
            redirectEnc +
            '&scope=' +
            scopeEnc;
    }

    public static String getRedirectUri() {
        String base = Url.getOrgDomainUrl().toExternalForm();
        if (base.endsWith('/')) {
            base = base.substring(0, base.length() - 1);
        }
        return base + '/apex/XeroCallback';
    }

    public static Map<String, Object> exchangeCodeForTokens(String authorizationCode) {
        Xero_Connection__c conn = getConnectionRequired();
        String body =
            'grant_type=authorization_code&code=' +
            EncodingUtil.urlEncode(authorizationCode, 'UTF-8') +
            '&redirect_uri=' +
            EncodingUtil.urlEncode(getRedirectUri(), 'UTF-8') +
            '&client_id=' +
            EncodingUtil.urlEncode(conn.Client_ID__c, 'UTF-8') +
            '&client_secret=' +
            EncodingUtil.urlEncode(conn.Client_Secret__c, 'UTF-8');
        HttpResponse res = postForm(TOKEN_URL, body);
        if (res.getStatusCode() != 200) {
            throw new XeroServiceException('Token exchange failed: ' + res.getBody());
        }
        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    public static String getTenantId(String accessToken) {
        if (String.isBlank(accessToken)) {
            throw new XeroServiceException('Access token is required to resolve tenant id.');
        }
        HttpRequest req = new HttpRequest();
        req.setEndpoint(CONNECTIONS_URL);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('Content-Type', 'application/json');
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new XeroServiceException('Connections failed: HTTP ' + res.getStatusCode() + ' ' + res.getBody());
        }
        List<Object> rows = (List<Object>) JSON.deserializeUntyped(res.getBody());
        if (rows == null || rows.isEmpty()) {
            throw new XeroServiceException('No connections found.');
        }
        String tenantId = (String) ((Map<String, Object>) rows[0]).get('tenantId');
        if (String.isBlank(tenantId)) {
            throw new XeroServiceException('tenantId missing in connections payload.');
        }
        return tenantId;
    }

    public static void saveTokens(Map<String, Object> tokenResponse, String tenantId) {
        if (deferTokenDml) {
            Object at = tokenResponse.get('access_token');
            Object rt = tokenResponse.get('refresh_token');
            if (at != null) {
                txnAccessTokenFull = String.valueOf(at);
            }
            if (rt != null) {
                txnRefreshTokenFull = String.valueOf(rt);
            }
            pendingTokenFlush = true;
            return;
        }
        Xero_Connection__c conn = getConnectionRequired();
        Object accToken = tokenResponse.get('access_token');
        Object refToken = tokenResponse.get('refresh_token');
        if (accToken != null) {
            conn.Access_Token__c = String.valueOf(accToken);
        }
        if (refToken != null) {
            conn.Refresh_Token__c = String.valueOf(refToken);
        }
        if (!String.isBlank(tenantId)) {
            conn.Tenant_ID__c = tenantId;
        }
        update conn;
    }

    public static String getValidAccessToken() {
        if (deferTokenDml && String.isNotBlank(txnAccessTokenFull)) {
            return txnAccessTokenFull;
        }
        Xero_Connection__c conn = getConnectionRequired();
        String fullAccess = conn.Access_Token__c;
        if (String.isBlank(fullAccess)) {
            refreshToken();
            if (deferTokenDml && String.isNotBlank(txnAccessTokenFull)) {
                return txnAccessTokenFull;
            }
            conn = getConnectionRequired();
            fullAccess = conn.Access_Token__c;
        }
        return fullAccess;
    }

    public static Map<String, Object> refreshToken() {
        Xero_Connection__c conn = getConnectionRequired();
        String fullRefresh = conn.Refresh_Token__c;
        if (deferTokenDml && String.isNotBlank(txnRefreshTokenFull)) {
            fullRefresh = txnRefreshTokenFull;
        }
        String body =
            'grant_type=refresh_token&refresh_token=' +
            EncodingUtil.urlEncode(fullRefresh, 'UTF-8') +
            '&client_id=' +
            EncodingUtil.urlEncode(conn.Client_ID__c, 'UTF-8') +
            '&client_secret=' +
            EncodingUtil.urlEncode(conn.Client_Secret__c, 'UTF-8');
        HttpResponse res = postForm(TOKEN_URL, body);
        if (res.getStatusCode() != 200) {
            throw new XeroServiceException('Refresh failed: ' + res.getBody());
        }
        Map<String, Object> tokenMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        saveTokens(tokenMap, null);
        return tokenMap;
    }

    /**
     * Xero Accounting API (api.xro/2.0). Transparent 401 handling: refresh OAuth token and retry once.
     * Never returns the first 401 to callers when refresh succeeds; if still 401 after refresh, throws.
     * GET and POST both receive Authorization + xero-tenant-id + Accept.
     */
    public static HttpResponse callAccountingApi(String method, String relativePath, String jsonBody) {
        Xero_Connection__c settings = getConnectionRequired();
        if (String.isBlank(settings.Tenant_ID__c)) {
            throw new XeroServiceException(
                'Tenant_ID__c is blank on Xero_Connection__c. Complete OAuth (XeroCallback) so the Xero organisation is saved.'
            );
        }
        Id connectionId = settings.Id;
        String tenantId = settings.Tenant_ID__c.trim();
        String accessToken = getValidAccessToken();
        String requestJson = buildAccountingApiRequestJson(method, relativePath, jsonBody);

        HttpResponse res;
        try {
            res = sendAccountingRequestWithLogging(connectionId, method, relativePath, jsonBody, accessToken, tenantId);
        } catch (Exception e) {
            logIntegration(connectionId, 'Outbound', 'Error', requestJson, null, e.getMessage());
            throw e;
        }

        if (res.getStatusCode() == 401) {
            refreshToken();
            settings = getConnectionRequired();
            if (String.isBlank(settings.Tenant_ID__c)) {
                throw new XeroServiceException('Tenant_ID__c missing after token refresh.');
            }
            tenantId = settings.Tenant_ID__c.trim();
            accessToken = getValidAccessToken();
            if (String.isBlank(accessToken)) {
                throw new XeroServiceException('Access token is blank after refreshToken(); cannot retry Xero call.');
            }
            try {
                res = sendAccountingRequestWithLogging(connectionId, method, relativePath, jsonBody, accessToken, tenantId);
            } catch (Exception e) {
                logIntegration(connectionId, 'Outbound', 'Error', requestJson, null, e.getMessage());
                throw e;
            }
            if (res.getStatusCode() == 401) {
                System.debug(LoggingLevel.ERROR, 'Xero still returned 401 after token refresh. Body=' + res.getBody());
                String msg =
                    'Xero returned 401 Unauthorized after refreshing the token. Check app scopes and tenant. Response: ' +
                    res.getBody();
                logIntegration(connectionId, 'Outbound', 'Error', requestJson, res.getBody(), msg);
                throw new XeroServiceException(msg);
            }
        }

        return res;
    }

    /**
     * Performs one HTTP call to the Accounting API and logs before (In Progress) and after (Success/Error) using {@link #logIntegration}.
     */
    private static HttpResponse sendAccountingRequestWithLogging(
        Id connectionId,
        String method,
        String relativePath,
        String jsonBody,
        String accessToken,
        String tenantId
    ) {
        String requestJson = buildAccountingApiRequestJson(method, relativePath, jsonBody);
        logIntegration(connectionId, 'Outbound', 'In Progress', requestJson, null, null);
        HttpResponse res = sendAccountingRequest(method, relativePath, jsonBody, accessToken, tenantId);
        Integer sc = res.getStatusCode();
        String status = (sc >= 200 && sc < 300) ? 'Success' : 'Error';
        String err = status == 'Error' ? ('HTTP ' + String.valueOf(sc)) : null;
        logIntegration(connectionId, 'Outbound', status, requestJson, res.getBody(), err);
        return res;
    }

    /** Xero recommends keeping bulk Accounting payloads bounded; we chunk and merge responses when larger. */
    public static final Integer ACCOUNTING_API_BULK_CHUNK_SIZE = 100;

    /**
     * Bulk Accounting API: wraps {@code records} in the Xero root collection ({@code Invoices}, {@code Contacts}, or {@code Items})
     * inferred from {@code relativePath}, then delegates to {@link #callAccountingApi(String, String, String)} (401 retry + logging).
     * Lists larger than {@link #ACCOUNTING_API_BULK_CHUNK_SIZE} are sent in sequential chunks; JSON responses are merged into one
     * synthetic {@link HttpResponse} (same root key, array concatenated in request order).
     */
    public static HttpResponse callAccountingApiBulk(String method, String relativePath, List<Map<String, Object>> records) {
        if (records == null || records.isEmpty()) {
            throw new XeroServiceException('callAccountingApiBulk requires a non-empty records list.');
        }
        if (String.isBlank(relativePath)) {
            throw new XeroServiceException('callAccountingApiBulk requires a non-blank relativePath.');
        }
        String rootKey = resolveBulkAccountingRootKey(relativePath);
        if (String.isBlank(rootKey)) {
            throw new XeroServiceException(
                'callAccountingApiBulk: unsupported relativePath for bulk root key "' +
                    relativePath +
                    '". Expected path to contain /Invoices, /Contacts, or /Items.'
            );
        }
        Integer total = records.size();
        if (total > ACCOUNTING_API_BULK_CHUNK_SIZE) {
            System.debug(
                LoggingLevel.WARN,
                'callAccountingApiBulk: record count ' +
                    total +
                    ' exceeds chunk size ' +
                    ACCOUNTING_API_BULK_CHUNK_SIZE +
                    '; splitting into sequential requests (responses merged).'
            );
        }
        if (total <= ACCOUNTING_API_BULK_CHUNK_SIZE) {
            Map<String, Object> body = new Map<String, Object>{ rootKey => (Object) records };
            return callAccountingApi(method, relativePath, JSON.serialize(body));
        }
        List<Object> mergedRoot = new List<Object>();
        HttpResponse lastRes = null;
        for (Integer offset = 0; offset < total; offset += ACCOUNTING_API_BULK_CHUNK_SIZE) {
            Integer endExclusive = Math.min(offset + ACCOUNTING_API_BULK_CHUNK_SIZE, total);
            List<Map<String, Object>> chunk = new List<Map<String, Object>>();
            for (Integer j = offset; j < endExclusive; j++) {
                chunk.add(records[j]);
            }
            Map<String, Object> chunkBody = new Map<String, Object>{ rootKey => (Object) chunk };
            lastRes = callAccountingApi(method, relativePath, JSON.serialize(chunkBody));
            Integer sc = lastRes.getStatusCode();
            if (sc != 200 && sc != 201) {
                return lastRes;
            }
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(lastRes.getBody());
            List<Object> part = (List<Object>) parsed.get(rootKey);
            if (part != null) {
                mergedRoot.addAll(part);
            }
        }
        HttpResponse merged = new HttpResponse();
        merged.setStatusCode(lastRes != null ? lastRes.getStatusCode() : 200);
        merged.setHeader('Content-Type', 'application/json');
        merged.setBody(JSON.serialize(new Map<String, Object>{ rootKey => mergedRoot }));
        return merged;
    }

    /**
     * Root JSON key for bulk payloads: {@code Invoices}, {@code Contacts}, or {@code Items} from path segment.
     */
    private static String resolveBulkAccountingRootKey(String relativePath) {
        String p = relativePath.toLowerCase();
        if (p.contains('/invoices')) {
            return 'Invoices';
        }
        if (p.contains('/contacts')) {
            return 'Contacts';
        }
        if (p.contains('/items')) {
            return 'Items';
        }
        return null;
    }

    /**
     * JSON for {@link Integration_Log__c.Request_Body__c}: HTTP method, relative path, and optional JSON body.
     */
    private static String buildAccountingApiRequestJson(String method, String relativePath, String jsonBody) {
        Map<String, Object> payload = new Map<String, Object>{
            'method' => method,
            'path' => relativePath
        };
        if (jsonBody != null) {
            payload.put('body', jsonBody);
        }
        return JSON.serialize(payload);
    }

    /**
     * Persists {@link Integration_Log__c} with {@link #INTEGRATION_LOG_TYPE_XERO}. When {@code connectionId} is set,
     * links to {@link Xero_Connection__c}. When {@link #deferTokenDml} is true, rows are queued for {@link #flushDeferredTokenPersistence()}.
     */
    public static void logIntegration(
        Id connectionId,
        String direction,
        String status,
        String requestBody,
        String responseBody,
        String errorMessage
    ) {
        saveIntegrationLog(
            connectionId,
            direction,
            INTEGRATION_LOG_TYPE_XERO,
            status,
            requestBody,
            responseBody,
            errorMessage
        );
    }

    /**
     * Same as {@link #logIntegration(Id, String, String, String, String, String)} but sets {@link Integration_Log__c.Integration_Type__c}
     * (for inbound webhook picklist values such as {@link #INTEGRATION_LOG_TYPE_WEBHOOK}).
     */
    public static void logIntegration(
        Id connectionId,
        String direction,
        String integrationType,
        String status,
        String requestBody,
        String responseBody,
        String errorMessage
    ) {
        saveIntegrationLog(connectionId, direction, integrationType, status, requestBody, responseBody, errorMessage);
    }

    /**
     * Inserts {@link Integration_Log__c} with request/response/error bodies truncated to
     * {@link #INTEGRATION_LOG_REQUEST_BODY_MAX}, {@link #INTEGRATION_LOG_RESPONSE_BODY_MAX}, and
     * {@link #INTEGRATION_LOG_ERROR_MESSAGE_MAX} so values stay within long-text field limits and DML succeeds.
     */
    private static void saveIntegrationLog(
        Id connectionId,
        String direction,
        String integrationType,
        String status,
        String requestBody,
        String responseBody,
        String errorMessage
    ) {
        Integration_Log__c row = new Integration_Log__c(
            Direction__c = direction,
            Integration_Type__c = integrationType,
            Status__c = status,
            Request_Body__c = truncateRequestBodyForLog(requestBody),
            Response_Body__c = truncateResponseBodyForLog(responseBody),
            Error_Message__c = truncateErrorMessageForLog(errorMessage)
        );
        if (connectionId != null) {
            row.Xero_Connection__c = connectionId;
        }
        if (deferTokenDml) {
            pendingIntegrationLogs.add(row);
        } else {
            Database.SaveResult[] sr = Database.insert(new List<Integration_Log__c>{ row }, false);
            if (!sr[0].isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'logIntegration insert failed: ' + sr[0].getErrors()[0].getMessage());
            }
        }
    }

    private static String truncateRequestBodyForLog(String value) {
        return truncateToMaxLength(value, INTEGRATION_LOG_REQUEST_BODY_MAX);
    }

    private static String truncateResponseBodyForLog(String value) {
        return truncateToMaxLength(value, INTEGRATION_LOG_RESPONSE_BODY_MAX);
    }

    private static String truncateErrorMessageForLog(String value) {
        return truncateToMaxLength(value, INTEGRATION_LOG_ERROR_MESSAGE_MAX);
    }

    private static String truncateToMaxLength(String value, Integer maxLen) {
        if (value == null) {
            return null;
        }
        if (maxLen == null || maxLen < 1 || value.length() <= maxLen) {
            return value;
        }
        return value.substring(0, maxLen);
    }

    /**
     * Builds a fresh HttpRequest and applies required Xero headers (GET and POST).
     * Retry after 401 uses this again with a new access token and the same tenant id.
     */
    private static HttpResponse sendAccountingRequest(String method, String relativePath, String jsonBody, String accessToken, String tenantId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(API_BASE + relativePath);
        req.setMethod(method);
        applyAccountingHeaders(req, accessToken, tenantId);
        if (jsonBody != null) {
            req.setHeader('Content-Type', 'application/json');
            req.setBody(jsonBody);
        }
        return new Http().send(req);
    }

    /**
     * Required on every Accounting API call including GET /Items (Bearer + xero-tenant-id).
     */
    private static void applyAccountingHeaders(HttpRequest req, String accessToken, String tenantId) {
        if (String.isBlank(accessToken)) {
            throw new XeroServiceException('applyAccountingHeaders: access token is blank.');
        }
        if (String.isBlank(tenantId)) {
            throw new XeroServiceException('applyAccountingHeaders: xero-tenant-id is blank.');
        }
        req.setHeader('Authorization', 'Bearer ' + accessToken.trim());
        req.setHeader('xero-tenant-id', tenantId.trim());
        req.setHeader('Accept', 'application/json');
    }

    private static HttpResponse postForm(String endpoint, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setBody(body);
        return new Http().send(req);
    }

    private static Xero_Connection__c getConnectionRequired() {
        List<Xero_Connection__c> rows = [
            SELECT Id, Client_ID__c, Client_Secret__c, Access_Token__c, Refresh_Token__c, Tenant_ID__c, Default_Account_Code__c, Default_Unit_Price__c
            FROM Xero_Connection__c
            LIMIT 1
        ];
        if (rows == null || rows.isEmpty()) {
            throw new XeroServiceException('No Xero_Connection__c record found. Please create the Primary Connection record.');
        }
        return rows[0];
    }

    public class XeroServiceException extends Exception {
    }
}
