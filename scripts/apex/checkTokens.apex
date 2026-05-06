// Verify OAuth handshake: tokens live on Xero_Connection__c (single primary row).
List<Xero_Connection__c> rows = [
    SELECT Access_Token__c, Refresh_Token__c, Tenant_ID__c
    FROM Xero_Connection__c
    LIMIT 1
];
if (rows.isEmpty()) {
    System.debug('ERROR: No Xero_Connection__c row. Create the Primary Connection record.');
} else {
    Xero_Connection__c conn = rows[0];
    Boolean hasTenantId = !String.isBlank(conn.Tenant_ID__c);
    System.debug('Tenant_ID__c populated? ' + hasTenantId);
    System.debug('Tenant_ID__c value: ' + (hasTenantId ? conn.Tenant_ID__c : '[BLANK]'));
    System.debug(
        'Access_Token__c populated? ' + (String.isBlank(conn.Access_Token__c) ? 'false' : 'true') +
        ', length=' + (conn.Access_Token__c != null ? conn.Access_Token__c.length() : 0)
    );
    System.debug(
        'Refresh_Token__c populated? ' + (String.isBlank(conn.Refresh_Token__c) ? 'false' : 'true') +
        ', length=' + (conn.Refresh_Token__c != null ? conn.Refresh_Token__c.length() : 0)
    );
}
