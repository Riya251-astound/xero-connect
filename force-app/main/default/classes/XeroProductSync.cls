/**
 * Asynchronous Product2 → Xero Item sync (Queueable callout).
 * Maps ProductCode → Code; uses one GET /Items for existing id map, then one POST /Items bulk via
 * {@link XeroService#callAccountingApiBulk} (ItemID on each row when updating). Stores Xero Item Code on Product2.Xero_Item_Code__c.
 *
 * Execution order: (1) All HTTP callouts inside try. (2) flushDeferredTokenPersistence() in finally.
 * (3) update Product2 — last DML in execute(), after every callout completes.
 */
public inherited sharing class XeroProductSync implements Queueable, Database.AllowsCallouts {
    private final Set<Id> productIds;

    public XeroProductSync(Set<Id> productIds) {
        this.productIds = productIds == null ? new Set<Id>() : productIds.clone();
    }

    public void execute(QueueableContext qc) {
        if (productIds.isEmpty()) {
            return;
        }
        try {
        List<Product2> products = [
            SELECT Id, Name, ProductCode, Description, Xero_Item_Code__c
            FROM Product2
            WHERE Id IN :productIds
            ORDER BY Id
        ];
        List<String> errorMessages = new List<String>();
        List<Product2> eligible = new List<Product2>();
        List<Map<String, Object>> itemRows = new List<Map<String, Object>>();

        List<Product2> toUpdate = new List<Product2>();
        Xero_Connection__c connectionDefaults = primaryConnectionRow();
        XeroService.beginCalloutTransaction();
        Map<String, String> codeToItemId = new Map<String, String>();
        try {
            codeToItemId = loadCodeToItemIdMap();
            for (Product2 p : products) {
                if (String.isBlank(p.ProductCode)) {
                    System.debug(LoggingLevel.WARN, 'XeroProductSync skipped Product2 ' + p.Id + ': ProductCode is required.');
                    errorMessages.add(p.Id + ': ProductCode is required.');
                    continue;
                }
                Map<String, Object> itemPayload = buildItemMap(p, connectionDefaults);
                String existingItemId = codeToItemId.get(p.ProductCode);
                if (!String.isBlank(existingItemId)) {
                    itemPayload.put('ItemID', existingItemId);
                }
                eligible.add(p);
                itemRows.add(itemPayload);
            }
            if (itemRows.isEmpty()) {
                return;
            }
            HttpResponse res = XeroService.callAccountingApiBulk('POST', '/Items', itemRows);
            Integer sc = res.getStatusCode();
            if (sc != 200 && sc != 201) {
                System.debug(LoggingLevel.ERROR, 'Xero Items API status=' + sc + ' body=' + res.getBody());
                throw new CalloutException('HTTP ' + sc + ' ' + res.getBody());
            }
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> items = (List<Object>) parsed.get('Items');
            if (items == null || items.isEmpty()) {
                System.debug(LoggingLevel.ERROR, 'Xero Items missing array. body=' + res.getBody());
                throw new CalloutException('Response missing Items array. Body: ' + res.getBody());
            }
            Integer n = Math.min(items.size(), eligible.size());
            for (Integer i = 0; i < n; i++) {
                Map<String, Object> row = (Map<String, Object>) items[i];
                Product2 p = eligible[i];
                Object codeVal = row.get('Code');
                String xeroCode = codeVal != null ? String.valueOf(codeVal) : p.ProductCode;
                if (String.isBlank(xeroCode)) {
                    errorMessages.add(p.Id + ': No Code in Xero response.');
                    continue;
                }
                toUpdate.add(new Product2(Id = p.Id, Xero_Item_Code__c = xeroCode));
            }
        } catch (Exception e) {
            String msg = 'XeroProductSync bulk: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, msg);
            System.debug(LoggingLevel.ERROR, e.getStackTraceString());
            errorMessages.add(msg);
            logQueueableSyncFailure('Product Sync: ' + JSON.serialize(new List<Id>(productIds)), e, connectionDefaults);
        } finally {
            XeroService.flushDeferredTokenPersistence();
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
        if (!errorMessages.isEmpty()) {
            throw new CalloutException(
                'XeroProductSync completed with errors (' +
                    errorMessages.size() +
                    '). First: ' +
                    errorMessages[0]
            );
        }
        } finally {
            XeroService.flushDeferredTokenPersistence();
        }
    }

    private static Map<String, String> loadCodeToItemIdMap() {
        Map<String, String> result = new Map<String, String>();
        HttpResponse res = XeroService.callAccountingApi('GET', '/Items', null);
        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            System.debug(LoggingLevel.ERROR, 'Xero GET /Items status=' + res.getStatusCode() + ' body=' + res.getBody());
            throw new CalloutException('Xero GET /Items failed: HTTP ' + res.getStatusCode());
        }
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> items = (List<Object>) parsed.get('Items');
        if (items == null) {
            return result;
        }
        for (Object row : items) {
            Map<String, Object> m = (Map<String, Object>) row;
            Object c = m.get('Code');
            Object iid = m.get('ItemID');
            if (c != null && iid != null) {
                result.put(String.valueOf(c), String.valueOf(iid));
            }
        }
        return result;
    }

    private static Map<String, Object> buildItemMap(Product2 p, Xero_Connection__c connectionDefaults) {
        Map<String, Object> item = new Map<String, Object>();
        item.put('Code', p.ProductCode);
        item.put('Name', String.isBlank(p.Name) ? p.ProductCode : p.Name);
        item.put('Description', p.Description);
        Decimal unitPrice = 0;
        if (connectionDefaults != null && connectionDefaults.Default_Unit_Price__c != null) {
            unitPrice = connectionDefaults.Default_Unit_Price__c;
        }
        String accountCode = '200';
        if (connectionDefaults != null && String.isNotBlank(connectionDefaults.Default_Account_Code__c)) {
            accountCode = connectionDefaults.Default_Account_Code__c.trim();
        }
        item.put(
            'SalesDetails',
            new Map<String, Object>{
                'UnitPrice' => unitPrice,
                'AccountCode' => accountCode
            }
        );
        return item;
    }

    private static Xero_Connection__c primaryConnectionRow() {
        List<Xero_Connection__c> rows = [
            SELECT Id, Default_Account_Code__c, Default_Unit_Price__c
            FROM Xero_Connection__c
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static Id connectionIdForLogging(Xero_Connection__c connectionDefaults) {
        return connectionDefaults == null ? null : connectionDefaults.Id;
    }

    private static void logQueueableSyncFailure(String requestSummary, Exception e, Xero_Connection__c connectionDefaults) {
        try {
            XeroService.logIntegration(
                connectionIdForLogging(connectionDefaults),
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
