/**
 * Async processor for Xero webhook payloads: GETs affected resources from Xero and updates Salesforce rows.
 * DML runs under {@link XeroInboundSyncSuppressor} so outbound Account/Product2/Opportunity sync is not re-fired.
 */
public without sharing class XeroWebhookHandler implements Queueable, Database.AllowsCallouts {
    private final String payload;

    public XeroWebhookHandler(String payload) {
        this.payload = payload;
    }

    public void execute(QueueableContext context) {
        try {
        if (String.isBlank(payload)) {
            return;
        }
        Map<String, Object> root;
        try {
            root = (Map<String, Object>) JSON.deserializeUntyped(payload);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'XeroWebhookHandler invalid JSON: ' + e.getMessage());
            return;
        }
        List<Object> events = (List<Object>) root.get('events');
        if (events == null || events.isEmpty()) {
            return;
        }

        List<Xero_Connection__c> connRows = [SELECT Id, Tenant_ID__c FROM Xero_Connection__c LIMIT 1];
        if (connRows.isEmpty()) {
            return;
        }
        Id connectionId = connRows[0].Id;
        String expectedTenant = connRows[0].Tenant_ID__c != null ? connRows[0].Tenant_ID__c.trim() : null;

        Map<Id, Account> accountsById = new Map<Id, Account>();
        Map<Id, Product2> productsById = new Map<Id, Product2>();
        Map<String, Xero_Invoice__c> xeroInvoicesByExternalId = new Map<String, Xero_Invoice__c>();
        Map<String, Map<String, Object>> inboundInvoiceRowByXeroId = new Map<String, Map<String, Object>>();

        XeroService.beginCalloutTransaction();
        try {
            for (Object evObj : events) {
                Map<String, Object> ev = (Map<String, Object>) evObj;
                String tenantId = ev.get('tenantId') != null ? String.valueOf(ev.get('tenantId')).trim() : null;
                if (String.isNotBlank(expectedTenant) &&
                    String.isNotBlank(tenantId) &&
                    !tenantId.equalsIgnoreCase(expectedTenant)) {
                    continue;
                }
                String category = ev.get('eventCategory') != null ? String.valueOf(ev.get('eventCategory')).trim().toUpperCase() : '';
                String resourceId = ev.get('resourceId') != null ? String.valueOf(ev.get('resourceId')).trim() : null;
                if (String.isBlank(resourceId)) {
                    continue;
                }
                try {
                    if (category == 'CONTACT') {
                        mergeAccountFromXero(resourceId, accountsById, connectionId);
                    } else if (category == 'ITEM') {
                        mergeProductFromXero(resourceId, productsById, connectionId);
                    } else if (category == 'INVOICE') {
                        mergeXeroInvoiceFromXero(resourceId, xeroInvoicesByExternalId, inboundInvoiceRowByXeroId, connectionId);
                    }
                } catch (Exception ex) {
                    System.debug(LoggingLevel.ERROR, 'XeroWebhookHandler event failed category=' + category + ' id=' + resourceId + ' ' + ex.getMessage());
                    logWebhookProcessingError(connectionId, category, resourceId, ex.getMessage());
                }
            }
        } finally {
            XeroService.flushDeferredTokenPersistence();
        }

        XeroInboundSyncSuppressor.enter();
        try {
            if (!accountsById.isEmpty()) {
                update accountsById.values();
            }
            if (!productsById.isEmpty()) {
                update productsById.values();
            }
            if (!xeroInvoicesByExternalId.isEmpty()) {
                List<String> sortedExtIds = new List<String>(xeroInvoicesByExternalId.keySet());
                sortedExtIds.sort();
                List<Xero_Invoice__c> toProcess = new List<Xero_Invoice__c>();
                for (String ext : sortedExtIds) {
                    toProcess.add(xeroInvoicesByExternalId.get(ext));
                }
                Set<String> xeroInvoiceKeys = new Set<String>();
                for (Xero_Invoice__c xi : toProcess) {
                    if (String.isNotBlank(xi.Xero_Invoice_ID__c)) {
                        xeroInvoiceKeys.add(xi.Xero_Invoice_ID__c);
                    }
                }
                Map<String, Id> existingSfIdByXeroId = new Map<String, Id>();
                if (!xeroInvoiceKeys.isEmpty()) {
                    for (Xero_Invoice__c ex : [
                        SELECT Id, Xero_Invoice_ID__c
                        FROM Xero_Invoice__c
                        WHERE Xero_Invoice_ID__c IN :xeroInvoiceKeys
                    ]) {
                        existingSfIdByXeroId.put(ex.Xero_Invoice_ID__c, ex.Id);
                    }
                }
                List<Xero_Invoice__c> toInsert = new List<Xero_Invoice__c>();
                List<Xero_Invoice__c> toUpdate = new List<Xero_Invoice__c>();
                for (Xero_Invoice__c xi : toProcess) {
                    if (xi.Id == null &&
                        String.isNotBlank(xi.Xero_Invoice_ID__c) &&
                        existingSfIdByXeroId.containsKey(xi.Xero_Invoice_ID__c)) {
                        xi.Id = existingSfIdByXeroId.get(xi.Xero_Invoice_ID__c);
                    }
                    if (xi.Id == null) {
                        toInsert.add(xi);
                    } else {
                        toUpdate.add(xi);
                    }
                }
                if (!toInsert.isEmpty()) {
                    Database.SaveResult[] insRes = Database.insert(toInsert, false);
                    for (Integer i = 0; i < insRes.size(); i++) {
                        if (!insRes[i].isSuccess()) {
                            String xid = toInsert[i].Xero_Invoice_ID__c;
                            logWebhookProcessingError(
                                connectionId,
                                'INVOICE',
                                xid,
                                insRes[i].getErrors()[0].getMessage()
                            );
                        }
                    }
                }
                if (!toUpdate.isEmpty()) {
                    Database.SaveResult[] updRes = Database.update(toUpdate, false);
                    for (Integer i = 0; i < updRes.size(); i++) {
                        if (!updRes[i].isSuccess()) {
                            String xid = toUpdate[i].Xero_Invoice_ID__c;
                            logWebhookProcessingError(
                                connectionId,
                                'INVOICE',
                                xid,
                                updRes[i].getErrors()[0].getMessage()
                            );
                        }
                    }
                }
                Map<String, Id> sfIdByXeroId = new Map<String, Id>();
                if (!xeroInvoiceKeys.isEmpty()) {
                    for (Xero_Invoice__c row : [
                        SELECT Id, Xero_Invoice_ID__c
                        FROM Xero_Invoice__c
                        WHERE Xero_Invoice_ID__c IN :xeroInvoiceKeys
                    ]) {
                        sfIdByXeroId.put(row.Xero_Invoice_ID__c, row.Id);
                    }
                }
                Set<Id> invoiceIdsForLineRefresh = new Set<Id>();
                for (String extId : sortedExtIds) {
                    Id sfId = sfIdByXeroId.get(extId);
                    if (sfId != null) {
                        invoiceIdsForLineRefresh.add(sfId);
                    }
                }
                if (!invoiceIdsForLineRefresh.isEmpty()) {
                    delete [SELECT Id FROM Xero_Invoice_Line__c WHERE Xero_Invoice__c IN :invoiceIdsForLineRefresh];
                }
                List<Xero_Invoice_Line__c> inboundLines = new List<Xero_Invoice_Line__c>();
                for (String extId : sortedExtIds) {
                    Id sfId = sfIdByXeroId.get(extId);
                    if (sfId == null) {
                        continue;
                    }
                    Map<String, Object> srcRow = inboundInvoiceRowByXeroId.get(extId);
                    if (srcRow == null) {
                        continue;
                    }
                    inboundLines.addAll(buildXeroInvoiceLineRecords(sfId, srcRow));
                }
                if (!inboundLines.isEmpty()) {
                    insert inboundLines;
                }
            }
        } finally {
            XeroInboundSyncSuppressor.exit();
        }
        } finally {
            XeroService.flushDeferredTokenPersistence();
        }
    }

    private static void logWebhookProcessingError(Id connectionId, String category, String resourceId, String errorMessage) {
        String req =
            JSON.serialize(
                new Map<String, Object>{
                    'phase' => 'XeroWebhookHandler',
                    'eventCategory' => category,
                    'resourceId' => resourceId
                }
            );
        XeroService.logIntegration(
            connectionId,
            'Inbound',
            XeroService.INTEGRATION_LOG_TYPE_WEBHOOK_HANDLER,
            'Error',
            req,
            null,
            errorMessage
        );
    }

    /**
     * Persists a success row on {@link Integration_Log__c} for an applied webhook merge (resourceId in summary JSON).
     */
    private static void logWebhookMergeSuccess(Id connectionId, String category, String resourceId) {
        String summary =
            JSON.serialize(
                new Map<String, Object>{
                    'phase' => 'XeroWebhookHandler',
                    'eventCategory' => category,
                    'resourceId' => resourceId,
                    'result' => 'Merged into Salesforce'
                }
            );
        XeroService.logIntegration(
            connectionId,
            'Inbound',
            XeroService.INTEGRATION_LOG_TYPE_WEBHOOK_HANDLER,
            'Success',
            summary,
            null,
            null
        );
    }

    private static void mergeAccountFromXero(String contactId, Map<Id, Account> accountsById, Id connectionId) {
        HttpResponse res = XeroService.callAccountingApi('GET', '/Contacts/' + contactId, null);
        if (res.getStatusCode() != 200) {
            System.debug(LoggingLevel.WARN, 'GET Contact failed HTTP ' + res.getStatusCode() + ' ' + res.getBody());
            return;
        }
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> contacts = (List<Object>) parsed.get('Contacts');
        if (contacts == null || contacts.isEmpty()) {
            return;
        }
        Map<String, Object> row = (Map<String, Object>) contacts[0];
        List<Account> matches = [SELECT Id, Name, Phone, Website, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry FROM Account WHERE Xero_Contact_ID__c = :contactId LIMIT 1];
        if (matches.isEmpty()) {
            return;
        }
        Account a = matches[0];
        if (row.get('Name') != null) {
            a.Name = String.valueOf(row.get('Name'));
        }
        String phone = firstPhoneFromContact(row);
        if (phone != null) {
            a.Phone = phone;
        }
        if (row.get('Website') != null) {
            a.Website = String.valueOf(row.get('Website'));
        }
        applyStreetAddress(a, row);
        accountsById.put(a.Id, a);
        logWebhookMergeSuccess(connectionId, 'CONTACT', contactId);
    }

    private static void mergeProductFromXero(String itemId, Map<Id, Product2> productsById, Id connectionId) {
        HttpResponse res = XeroService.callAccountingApi('GET', '/Items/' + itemId, null);
        if (res.getStatusCode() != 200) {
            System.debug(LoggingLevel.WARN, 'GET Item failed HTTP ' + res.getStatusCode() + ' ' + res.getBody());
            return;
        }
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> items = (List<Object>) parsed.get('Items');
        if (items == null || items.isEmpty()) {
            return;
        }
        Map<String, Object> row = (Map<String, Object>) items[0];
        Object codeObj = row.get('Code');
        if (codeObj == null) {
            return;
        }
        String code = String.valueOf(codeObj);
        List<Product2> matches = [SELECT Id, Name, ProductCode, Description FROM Product2 WHERE Xero_Item_Code__c = :code LIMIT 1];
        if (matches.isEmpty()) {
            return;
        }
        Product2 p = matches[0];
        if (row.get('Name') != null) {
            p.Name = String.valueOf(row.get('Name'));
        }
        if (row.get('Description') != null) {
            p.Description = String.valueOf(row.get('Description'));
        }
        if (codeObj != null) {
            p.ProductCode = code;
        }
        productsById.put(p.Id, p);
        logWebhookMergeSuccess(connectionId, 'ITEM', itemId);
    }

    /**
     * Unified mirror: loads invoice from Xero, upserts {@link Xero_Invoice__c} by {@code Xero_Invoice_ID__c} (= webhook {@code resourceId}).
     * Creates the mirror row when missing (invoices created only in Xero).
     */
    private static void mergeXeroInvoiceFromXero(
        String invoiceId,
        Map<String, Xero_Invoice__c> invoicesByExternalId,
        Map<String, Map<String, Object>> inboundInvoiceRowByXeroId,
        Id connectionId
    ) {
        HttpResponse res = XeroService.callAccountingApi('GET', '/Invoices/' + invoiceId, null);
        if (res.getStatusCode() != 200) {
            String msg = 'GET Invoice failed HTTP ' + res.getStatusCode() + ' ' + res.getBody();
            System.debug(LoggingLevel.WARN, msg);
            logWebhookProcessingError(connectionId, 'INVOICE', invoiceId, msg);
            return;
        }
        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'XeroWebhookHandler invoice JSON parse failed: ' + e.getMessage());
            logWebhookProcessingError(connectionId, 'INVOICE', invoiceId, 'Parse response: ' + e.getMessage());
            return;
        }
        List<Object> invoices = (List<Object>) parsed.get('Invoices');
        if (invoices == null || invoices.isEmpty()) {
            String msg = 'GET Invoice response missing Invoices array.';
            System.debug(LoggingLevel.WARN, msg);
            logWebhookProcessingError(connectionId, 'INVOICE', invoiceId, msg);
            return;
        }
        Map<String, Object> row = (Map<String, Object>) invoices[0];

        Xero_Invoice__c xi;
        List<Xero_Invoice__c> existing = [
            SELECT Id, Xero_Invoice_ID__c, Opportunity__c, Account__c
            FROM Xero_Invoice__c
            WHERE Xero_Invoice_ID__c = :invoiceId
            LIMIT 1
        ];
        if (existing.isEmpty()) {
            xi = new Xero_Invoice__c();
            xi.Xero_Invoice_ID__c = invoiceId;
        } else {
            xi = new Xero_Invoice__c(
                Id = existing[0].Id,
                Xero_Invoice_ID__c = invoiceId,
                Opportunity__c = existing[0].Opportunity__c,
                Account__c = existing[0].Account__c
            );
        }
        try {
            applyXeroInvoiceMirrorFields(xi, row);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'XeroWebhookHandler apply invoice mirror failed id=' + invoiceId + ' ' + e.getMessage());
            logWebhookProcessingError(connectionId, 'INVOICE', invoiceId, e.getMessage());
            return;
        }
        inboundInvoiceRowByXeroId.put(invoiceId, row);
        invoicesByExternalId.put(invoiceId, xi);
        logWebhookMergeSuccess(connectionId, 'INVOICE', invoiceId);
    }

    private static List<Xero_Invoice_Line__c> buildXeroInvoiceLineRecords(Id xeroInvoiceId, Map<String, Object> invoiceRow) {
        List<Xero_Invoice_Line__c> out = new List<Xero_Invoice_Line__c>();
        Object liObj = invoiceRow.get('LineItems');
        if (liObj == null) {
            return out;
        }
        List<Object> lines = (List<Object>) liObj;
        if (lines == null) {
            return out;
        }
        for (Object o : lines) {
            Map<String, Object> lm = (Map<String, Object>) o;
            Xero_Invoice_Line__c line = new Xero_Invoice_Line__c();
            line.Xero_Invoice__c = xeroInvoiceId;
            Object descriptionVal = lm.get('Description');
            line.Description__c = descriptionVal != null ? String.valueOf(descriptionVal) : null;
            Decimal qty = toDecimal(lm.get('Quantity'));
            if (qty != null) {
                line.Quantity__c = qty;
            }
            Decimal unit = toDecimal(lm.get('UnitAmount'));
            if (unit != null) {
                line.Unit_Amount__c = unit;
            }
            Decimal lineAmt = toDecimal(lm.get('LineAmount'));
            if (lineAmt != null) {
                line.Line_Amount__c = lineAmt;
            }
            Object itemCode = lm.get('ItemCode');
            line.Item_Code__c = itemCode != null ? String.valueOf(itemCode) : null;
            Object lid = lm.get('LineItemID');
            if (lid == null) {
                lid = lm.get('LineItemId');
            }
            line.Xero_Line_Item_ID__c = lid != null ? String.valueOf(lid) : null;
            out.add(line);
        }
        return out;
    }

    private static void applyXeroInvoiceMirrorFields(Xero_Invoice__c xi, Map<String, Object> row) {
        Object st = row.get('Status');
        xi.Status__c = st != null ? String.valueOf(st) : null;
        xi.Xero_Status__c = xi.Status__c;
        xi.Invoice_Status__c = xi.Status__c;
        Decimal due = toDecimal(row.get('AmountDue'));
        if (due != null) {
            xi.Amount_Due__c = due;
        }
        Decimal total = toDecimal(row.get('Total'));
        if (total != null) {
            xi.Total_Amount__c = total;
            xi.Total__c = total;
        }
        Object invNum = row.get('InvoiceNumber');
        if (invNum == null) {
            invNum = row.get('invoiceNumber');
        }
        String numStr = invNum != null ? String.valueOf(invNum) : null;
        if (numStr != null && numStr.length() > 80) {
            numStr = numStr.substring(0, 80);
        }
        xi.Invoice_Number__c = numStr;
        String nameVal = String.isBlank(numStr) ? xi.Xero_Invoice_ID__c : numStr;
        if (String.isBlank(nameVal)) {
            nameVal = 'Xero Invoice';
        }
        if (nameVal.length() > 80) {
            nameVal = nameVal.substring(0, 80);
        }
        xi.Name = nameVal;
    }

    private static Decimal toDecimal(Object o) {
        if (o == null) {
            return null;
        }
        if (o instanceof Decimal) {
            return (Decimal) o;
        }
        if (o instanceof Integer) {
            return Decimal.valueOf((Integer) o);
        }
        if (o instanceof Long) {
            return Decimal.valueOf((Long) o);
        }
        if (o instanceof Double) {
            return Decimal.valueOf((Double) o);
        }
        return Decimal.valueOf(String.valueOf(o));
    }

    private static String firstPhoneFromContact(Map<String, Object> contactRow) {
        Object phonesObj = contactRow.get('Phones');
        if (phonesObj == null) {
            return null;
        }
        List<Object> phones = (List<Object>) phonesObj;
        for (Object p : phones) {
            Map<String, Object> pm = (Map<String, Object>) p;
            Object num = pm.get('PhoneNumber');
            if (num != null) {
                return String.valueOf(num);
            }
        }
        return null;
    }

    private static void applyStreetAddress(Account a, Map<String, Object> contactRow) {
        Object addrObj = contactRow.get('Addresses');
        if (addrObj == null) {
            return;
        }
        List<Object> addrs = (List<Object>) addrObj;
        for (Object ad : addrs) {
            Map<String, Object> am = (Map<String, Object>) ad;
            String t = am.get('AddressType') != null ? String.valueOf(am.get('AddressType')) : '';
            if (!'STREET'.equalsIgnoreCase(t)) {
                continue;
            }
            if (am.get('AddressLine1') != null) {
                a.BillingStreet = String.valueOf(am.get('AddressLine1'));
            }
            if (am.get('City') != null) {
                a.BillingCity = String.valueOf(am.get('City'));
            }
            if (am.get('Region') != null) {
                a.BillingState = String.valueOf(am.get('Region'));
            }
            if (am.get('PostalCode') != null) {
                a.BillingPostalCode = String.valueOf(am.get('PostalCode'));
            }
            if (am.get('Country') != null) {
                a.BillingCountry = String.valueOf(am.get('Country'));
            }
            return;
        }
    }
}
