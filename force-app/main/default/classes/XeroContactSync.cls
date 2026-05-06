/**
 * Asynchronous Account → Xero Contact sync (Queueable callout).
 * Sends all contacts in one Accounting API request via {@link XeroService#callAccountingApiBulk}.
 */
public inherited sharing class XeroContactSync implements Queueable, Database.AllowsCallouts {
    private final Set<Id> accountIds;

    public XeroContactSync(Set<Id> accountIds) {
        this.accountIds = accountIds == null ? new Set<Id>() : accountIds.clone();
    }

    public void execute(QueueableContext qc) {
        if (accountIds.isEmpty()) {
            return;
        }
        try {
        List<Account> accounts = queryAccountsForSync(accountIds);
        if (accounts.isEmpty()) {
            return;
        }
        XeroService.beginCalloutTransaction();
        Map<Id, String> contactIdsByAccountId = new Map<Id, String>();
        try {
            contactIdsByAccountId = pushContactsCalloutOnly(accounts);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'XeroContactSync bulk failed: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, e.getStackTraceString());
            logQueueableSyncFailure('Contact Sync: ' + JSON.serialize(new List<Id>(accountIds)), e);
        } finally {
            XeroService.flushDeferredTokenPersistence();
        }
        applyContactIdsToAccounts(accounts, contactIdsByAccountId);
        } finally {
            XeroService.flushDeferredTokenPersistence();
        }
    }

    /**
     * POSTs the given Accounts to Xero as Contacts while {@link XeroService#beginCalloutTransaction()} is active.
     * Does not flush or perform Salesforce Account DML. Caller must {@link XeroService#flushDeferredTokenPersistence()}
     * after all callouts, then persist IDs with {@link #applyContactIdsToAccounts}.
     *
     * @return map of Account Id → Xero ContactID from the response (index-aligned with {@code accounts} order).
     */
    public static Map<Id, String> pushContactsCalloutOnly(List<Account> accounts) {
        Map<Id, String> contactIdsByAccountId = new Map<Id, String>();
        if (accounts == null || accounts.isEmpty()) {
            return contactIdsByAccountId;
        }
        List<Map<String, Object>> contactRows = new List<Map<String, Object>>();
        for (Account a : accounts) {
            contactRows.add(buildContactPayload(a));
        }
        if (contactRows.isEmpty()) {
            return contactIdsByAccountId;
        }
        HttpResponse res = XeroService.callAccountingApiBulk('POST', '/Contacts', contactRows);
        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            throw new CalloutException('Xero Contacts API error: HTTP ' + res.getStatusCode() + ' ' + res.getBody());
        }
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> contacts = (List<Object>) parsed.get('Contacts');
        if (contacts == null || contacts.isEmpty()) {
            throw new CalloutException('Xero response missing Contacts array.');
        }
        Integer n = Math.min(contacts.size(), accounts.size());
        for (Integer i = 0; i < n; i++) {
            Map<String, Object> row = (Map<String, Object>) contacts[i];
            Account a = accounts[i];
            Object cid = row.get('ContactID');
            if (cid != null) {
                contactIdsByAccountId.put(a.Id, String.valueOf(cid));
            }
        }
        return contactIdsByAccountId;
    }

    /**
     * Persists ContactID values on Account with partial success so one bad row does not fail the batch.
     */
    public static void applyContactIdsToAccounts(List<Account> accounts, Map<Id, String> contactIdsByAccountId) {
        if (contactIdsByAccountId == null || contactIdsByAccountId.isEmpty()) {
            return;
        }
        List<Account> toUpdate = new List<Account>();
        for (Account a : accounts) {
            if (!contactIdsByAccountId.containsKey(a.Id)) {
                continue;
            }
            String cid = contactIdsByAccountId.get(a.Id);
            if (String.isBlank(cid) || cid == a.Xero_Contact_ID__c) {
                continue;
            }
            toUpdate.add(new Account(Id = a.Id, Xero_Contact_ID__c = cid));
        }
        if (toUpdate.isEmpty()) {
            return;
        }
        Database.SaveResult[] results = Database.update(toUpdate, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(
                    LoggingLevel.ERROR,
                    'XeroContactSync Account update failed id=' +
                        toUpdate[i].Id +
                        ' ' +
                        results[i].getErrors()[0].getMessage()
                );
            }
        }
    }

    public static List<Account> queryAccountsForSync(Set<Id> accountIds) {
        return [
            SELECT
                Id,
                Name,
                Phone,
                Fax,
                Website,
                BillingStreet,
                BillingCity,
                BillingState,
                BillingPostalCode,
                BillingCountry,
                ShippingStreet,
                ShippingCity,
                ShippingState,
                ShippingPostalCode,
                ShippingCountry,
                Description,
                Xero_Contact_ID__c
            FROM Account
            WHERE Id IN :accountIds
            ORDER BY Id
        ];
    }

    private static Map<String, Object> buildContactPayload(Account a) {
        Map<String, Object> row = new Map<String, Object>();
        row.put('Name', a.Name);
        if (!String.isBlank(a.Phone)) {
            row.put(
                'Phones',
                new List<Object>{
                    new Map<String, Object>{ 'PhoneType' => 'DEFAULT', 'PhoneNumber' => a.Phone }
                }
            );
        }
        if (!String.isBlank(a.Website)) {
            row.put('Website', a.Website);
        }
        List<Object> addresses = new List<Object>();
        if (hasBilling(a)) {
            addresses.add(
                new Map<String, Object>{
                    'AddressType' => 'STREET',
                    'AddressLine1' => trimToNull(a.BillingStreet),
                    'City' => trimToNull(a.BillingCity),
                    'Region' => trimToNull(a.BillingState),
                    'PostalCode' => trimToNull(a.BillingPostalCode),
                    'Country' => trimToNull(a.BillingCountry)
                }
            );
        }
        if (!addresses.isEmpty()) {
            row.put('Addresses', addresses);
        }
        if (!String.isBlank(a.Xero_Contact_ID__c)) {
            row.put('ContactID', a.Xero_Contact_ID__c);
        }
        return row;
    }

    private static Boolean hasBilling(Account a) {
        return !String.isBlank(a.BillingStreet) ||
            !String.isBlank(a.BillingCity) ||
            !String.isBlank(a.BillingState) ||
            !String.isBlank(a.BillingPostalCode) ||
            !String.isBlank(a.BillingCountry);
    }

    private static String trimToNull(String s) {
        return String.isBlank(s) ? null : s.trim();
    }

    private static Id primaryConnectionId() {
        List<Xero_Connection__c> rows = [SELECT Id FROM Xero_Connection__c LIMIT 1];
        return rows.isEmpty() ? null : rows[0].Id;
    }

    private static void logQueueableSyncFailure(String requestSummary, Exception e) {
        try {
            XeroService.logIntegration(
                primaryConnectionId(),
                'Outbound',
                'Error',
                requestSummary,
                null,
                e != null ? e.getMessage() : null
            );
        } catch (Exception ignore) {
        }
    }
}
