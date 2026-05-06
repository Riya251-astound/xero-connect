/**
 * Asynchronous Opportunity (+ line items) → Xero ACCREC Invoice (Queueable callout).
 * Sends all invoices in one callout via {@link XeroService#callAccountingApiBulk}, then parses the response
 * ({@code InvoiceID}, {@code InvoiceNumber}) and bulk-inserts {@link Xero_Invoice__c} plus line mirrors.
 *
 * Xero {@code InvoiceNumber} maps to the record {@link Xero_Invoice__c#Name} (label Invoice Number) and {@link Xero_Invoice__c#Invoice_Number__c}.
 *
 * Execution order: (1) {@link XeroService#beginCalloutTransaction()}. (2) Optional POST /Contacts for Accounts missing
 * {@code Xero_Contact_ID__c} via {@link XeroContactSync#pushContactsCalloutOnly}. (3) POST /Invoices. (4) {@link XeroService#flushDeferredTokenPersistence()}.
 * (5) Update Accounts with new contact ids. (6) Bulk insert {@link Xero_Invoice__c} and line mirrors.
 * (7) Update source {@link Opportunity} rows with {@code Xero_Invoice_ID__c} from the Xero response (same GUID as the mirror).
 *
 * When an opportunity already has {@link Opportunity#Xero_Invoice_ID__c} and a {@link Xero_Invoice__c} mirror row, the same
 * bulk POST /Invoices payload includes {@code InvoiceID} so Xero updates the invoice in place; mirror lines are replaced from the response.
 */
public inherited sharing class XeroInvoiceSync implements Queueable, Database.AllowsCallouts {
    public class XeroInvoiceSyncException extends Exception {
    }

    private final Set<Id> opportunityIds;

    public XeroInvoiceSync(Set<Id> opportunityIds) {
        this.opportunityIds = opportunityIds == null ? new Set<Id>() : opportunityIds.clone();
    }

    public void execute(QueueableContext qc) {
        if (opportunityIds.isEmpty()) {
            return;
        }
        try {
        List<Opportunity> opps = queryOpportunities(opportunityIds);
        List<Xero_Connection__c> connRows = [
            SELECT Default_Account_Code__c, Default_Unit_Price__c
            FROM Xero_Connection__c
            LIMIT 1
        ];
        Xero_Connection__c connectionDefaults = connRows.isEmpty() ? null : connRows[0];
        List<String> errorMessages = new List<String>();
        Set<Id> accountIdsNeedingContactPush = new Set<Id>();
        for (Opportunity o : opps) {
            if (o.AccountId != null && String.isBlank(o.Account.Xero_Contact_ID__c)) {
                accountIdsNeedingContactPush.add(o.AccountId);
            }
        }
        Map<Id, String> preSyncedContactIdByAccountId = new Map<Id, String>();
        List<Opportunity> stagedOpps = new List<Opportunity>();
        List<Id> stagedExistingMirrorIds = new List<Id>();
        List<Map<String, Object>> invoicePayload = new List<Map<String, Object>>();
        String responseBody;

        XeroService.beginCalloutTransaction();
        try {
            if (!accountIdsNeedingContactPush.isEmpty()) {
                try {
                    List<Account> accountsToPush = XeroContactSync.queryAccountsForSync(accountIdsNeedingContactPush);
                    preSyncedContactIdByAccountId.putAll(XeroContactSync.pushContactsCalloutOnly(accountsToPush));
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, 'XeroInvoiceSync contact pre-sync: ' + e.getMessage());
                    errorMessages.add('Xero Contact pre-sync: ' + e.getMessage());
                }
            }

            for (Opportunity o : opps) {
                Boolean hasMirror = o.Xero_Invoices__r != null && !o.Xero_Invoices__r.isEmpty();
                Boolean updateExistingInXero =
                    hasMirror &&
                    String.isNotBlank(o.Xero_Invoice_ID__c);
                // ASSUMPTION: If a mirror row exists but Opportunity.Xero_Invoice_ID__c is blank, skip rather than create a second Xero invoice.
                if (hasMirror && !updateExistingInXero) {
                    continue;
                }
                if (o.AccountId == null) {
                    errorMessages.add(o.Id + ': Opportunity has no Account.');
                    continue;
                }
                String xeroContactId = !String.isBlank(o.Account.Xero_Contact_ID__c)
                    ? o.Account.Xero_Contact_ID__c
                    : preSyncedContactIdByAccountId.get(o.AccountId);
                if (String.isBlank(xeroContactId)) {
                    errorMessages.add(
                        o.Id +
                            ': Account has no Xero_Contact_ID__c after automatic contact push. Run Account → Xero contact sync (or ensure the Account can be created in Xero), then retry invoicing.'
                    );
                    continue;
                }
                try {
                    invoicePayload.add(buildInvoiceMap(o, xeroContactId, connectionDefaults, updateExistingInXero));
                    stagedOpps.add(o);
                    stagedExistingMirrorIds.add(updateExistingInXero ? o.Xero_Invoices__r[0].Id : null);
                } catch (XeroInvoiceSyncException e) {
                    errorMessages.add(o.Id + ': ' + e.getMessage());
                }
            }

            responseBody = null;
            try {
                if (!invoicePayload.isEmpty()) {
                    HttpResponse res = XeroService.callAccountingApiBulk('POST', '/Invoices', invoicePayload);
                    Integer sc = res.getStatusCode();
                    if (sc != 200 && sc != 201) {
                        System.debug(LoggingLevel.ERROR, 'Xero Invoices API status=' + sc + ' body=' + res.getBody());
                        throw new CalloutException('HTTP ' + sc + ' ' + res.getBody());
                    }
                    responseBody = res.getBody();
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'XeroInvoiceSync bulk callout failed: ' + e.getMessage());
                System.debug(LoggingLevel.ERROR, e.getStackTraceString());
                errorMessages.add('Bulk: ' + e.getMessage());
                responseBody = null;
            }
        } finally {
            XeroService.flushDeferredTokenPersistence();
        }

        if (!preSyncedContactIdByAccountId.isEmpty()) {
            List<Account> accountsForPatch = XeroContactSync.queryAccountsForSync(preSyncedContactIdByAccountId.keySet());
            XeroContactSync.applyContactIdsToAccounts(accountsForPatch, preSyncedContactIdByAccountId);
        }

        if (responseBody != null && !stagedOpps.isEmpty()) {
            try {
                mirrorInvoicesFromResponse(responseBody, stagedOpps, stagedExistingMirrorIds, errorMessages);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'XeroInvoiceSync mirror failed: ' + e.getMessage());
                errorMessages.add('Mirror: ' + e.getMessage());
            }
        }

        if (!errorMessages.isEmpty()) {
            throw new CalloutException(
                'XeroInvoiceSync completed with errors (' +
                    errorMessages.size() +
                    '). First: ' +
                    errorMessages[0]
            );
        }
        } finally {
            XeroService.flushDeferredTokenPersistence();
        }
    }

    private static List<Opportunity> queryOpportunities(Set<Id> ids) {
        return [
            SELECT
                Id,
                Name,
                CloseDate,
                Amount,
                Xero_Invoice_ID__c,
                AccountId,
                Account.Xero_Contact_ID__c,
                Account.Name,
                (SELECT Id FROM Xero_Invoices__r LIMIT 1),
                (
                    SELECT
                        Id,
                        Quantity,
                        UnitPrice,
                        TotalPrice,
                        Description,
                        PricebookEntry.Product2Id,
                        PricebookEntry.Product2.Name,
                        PricebookEntry.Product2.Xero_Item_Code__c
                    FROM OpportunityLineItems
                )
            FROM Opportunity
            WHERE Id IN :ids
            ORDER BY Id
        ];
    }

    /**
     * Parses Xero {@code Invoices} array from the POST response, aligns rows to {@code stagedOpps} by index,
     * bulk-inserts or updates {@link Xero_Invoice__c} mirrors, then replaces line items for each successful parent.
     */
    private static void mirrorInvoicesFromResponse(
        String responseBody,
        List<Opportunity> stagedOpps,
        List<Id> stagedExistingMirrorIds,
        List<String> errorMessages
    ) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        List<Object> invObjects = (List<Object>) parsed.get('Invoices');
        if (invObjects == null || invObjects.isEmpty()) {
            errorMessages.add('Mirror: response missing Invoices array.');
            return;
        }
        if (invObjects.size() != stagedOpps.size()) {
            errorMessages.add(
                'Mirror: expected ' +
                    stagedOpps.size() +
                    ' invoices from Xero, got ' +
                    invObjects.size() +
                    '; matching by index for overlapping rows only.'
            );
        }
        Integer n = Math.min(invObjects.size(), stagedOpps.size());
        if (n == 0) {
            return;
        }

        List<Opportunity> mirrorOpps = new List<Opportunity>();
        List<Map<String, Object>> mirrorRows = new List<Map<String, Object>>();
        List<Id> mirrorExistingSfIds = new List<Id>();
        for (Integer i = 0; i < n; i++) {
            Opportunity opp = stagedOpps[i];
            Map<String, Object> row = (Map<String, Object>) invObjects[i];
            String invoiceId = extractInvoiceIdFromRow(row);
            if (String.isBlank(invoiceId)) {
                errorMessages.add(opp.Id + ': Mirror: Xero response row missing InvoiceID at index ' + i + '.');
                continue;
            }
            mirrorOpps.add(opp);
            mirrorRows.add(row);
            mirrorExistingSfIds.add(stagedExistingMirrorIds[i]);
        }
        if (mirrorOpps.isEmpty()) {
            return;
        }

        List<Xero_Invoice__c> invoiceRows = new List<Xero_Invoice__c>();
        for (Integer j = 0; j < mirrorRows.size(); j++) {
            invoiceRows.add(
                buildXeroInvoiceRecordFromResponse(mirrorOpps[j], mirrorRows[j], mirrorExistingSfIds[j])
            );
        }

        List<Xero_Invoice__c> toInsert = new List<Xero_Invoice__c>();
        List<Xero_Invoice__c> toUpdate = new List<Xero_Invoice__c>();
        List<Integer> insertMirrorIndex = new List<Integer>();
        List<Integer> updateMirrorIndex = new List<Integer>();
        for (Integer j = 0; j < invoiceRows.size(); j++) {
            if (invoiceRows[j].Id != null) {
                toUpdate.add(invoiceRows[j]);
                updateMirrorIndex.add(j);
            } else {
                toInsert.add(invoiceRows[j]);
                insertMirrorIndex.add(j);
            }
        }

        Database.SaveResult[] insertResults = toInsert.isEmpty() ? new List<Database.SaveResult>() : Database.insert(toInsert, false);
        for (Integer u = 0; u < insertResults.size(); u++) {
            if (!insertResults[u].isSuccess()) {
                Integer mj = insertMirrorIndex[u];
                errorMessages.add(
                    mirrorOpps[mj].Id +
                        ': insert Xero_Invoice__c failed: ' +
                        insertResults[u].getErrors()[0].getMessage()
                );
            }
        }
        Database.SaveResult[] updateResults = toUpdate.isEmpty() ? new List<Database.SaveResult>() : Database.update(toUpdate, false);
        for (Integer u = 0; u < updateResults.size(); u++) {
            if (!updateResults[u].isSuccess()) {
                Integer mj = updateMirrorIndex[u];
                errorMessages.add(
                    mirrorOpps[mj].Id +
                        ': update Xero_Invoice__c failed: ' +
                        updateResults[u].getErrors()[0].getMessage()
                );
            }
        }

        Map<Integer, Id> parentIdByMirrorIndex = new Map<Integer, Id>();
        for (Integer u = 0; u < insertResults.size(); u++) {
            if (insertResults[u].isSuccess()) {
                parentIdByMirrorIndex.put(insertMirrorIndex[u], toInsert[u].Id);
            }
        }
        for (Integer u = 0; u < updateResults.size(); u++) {
            if (updateResults[u].isSuccess()) {
                parentIdByMirrorIndex.put(updateMirrorIndex[u], toUpdate[u].Id);
            }
        }

        Set<Id> parentIds = new Set<Id>(parentIdByMirrorIndex.values());
        if (!parentIds.isEmpty()) {
            delete [SELECT Id FROM Xero_Invoice_Line__c WHERE Xero_Invoice__c IN :parentIds];
        }

        List<Xero_Invoice_Line__c> lineRows = new List<Xero_Invoice_Line__c>();
        for (Integer mirrorIdx : parentIdByMirrorIndex.keySet()) {
            Id parentId = parentIdByMirrorIndex.get(mirrorIdx);
            if (parentId == null) {
                continue;
            }
            lineRows.addAll(buildLineRecords(parentId, mirrorRows[mirrorIdx]));
        }
        if (!lineRows.isEmpty()) {
            insert lineRows;
        }

        List<Opportunity> oppPatches = new List<Opportunity>();
        for (Integer p = 0; p < mirrorOpps.size(); p++) {
            if (!parentIdByMirrorIndex.containsKey(p)) {
                continue;
            }
            String xeroInvId = extractInvoiceIdFromRow(mirrorRows[p]);
            if (String.isBlank(xeroInvId)) {
                continue;
            }
            oppPatches.add(new Opportunity(Id = mirrorOpps[p].Id, Xero_Invoice_ID__c = xeroInvId));
        }
        if (!oppPatches.isEmpty()) {
            XeroInboundSyncSuppressor.enter();
            try {
                Database.SaveResult[] oppUpd = Database.update(oppPatches, false);
                for (Integer k = 0; k < oppUpd.size(); k++) {
                    if (!oppUpd[k].isSuccess()) {
                        errorMessages.add(
                            oppPatches[k].Id +
                                ': update Opportunity.Xero_Invoice_ID__c failed: ' +
                                oppUpd[k].getErrors()[0].getMessage()
                        );
                    }
                }
            } finally {
                XeroInboundSyncSuppressor.exit();
            }
        }
    }

    /**
     * Builds a mirror row from one Xero invoice object in the POST response (InvoiceID, InvoiceNumber, totals, status).
     */
    private static Xero_Invoice__c buildXeroInvoiceRecordFromResponse(
        Opportunity opp,
        Map<String, Object> row,
        Id existingMirrorSfId
    ) {
        Xero_Invoice__c xi = new Xero_Invoice__c();
        if (existingMirrorSfId != null) {
            xi.Id = existingMirrorSfId;
        }
        xi.Opportunity__c = opp.Id;
        xi.Account__c = opp.AccountId;
        xi.Xero_Invoice_ID__c = extractInvoiceIdFromRow(row);
        Object st = row.get('Status');
        if (st == null) {
            st = row.get('status');
        }
        String statusStr = st != null ? String.valueOf(st) : null;
        xi.Status__c = statusStr;
        xi.Xero_Status__c = statusStr;
        Decimal total = toDecimal(row.get('Total'));
        if (total == null) {
            total = toDecimal(row.get('total'));
        }
        if (total != null) {
            xi.Total_Amount__c = total;
            xi.Total__c = total;
        }
        Decimal due = toDecimal(row.get('AmountDue'));
        if (due == null) {
            due = toDecimal(row.get('amountDue'));
        }
        if (due != null) {
            xi.Amount_Due__c = due;
        }
        String invNumStr = extractInvoiceNumberFromRow(row);
        xi.Invoice_Number__c = truncateForTextField(invNumStr, 80);
        xi.Name = truncateForTextField(
            String.isBlank(invNumStr) ? xi.Xero_Invoice_ID__c : invNumStr,
            80
        );
        if (String.isBlank(xi.Name)) {
            xi.Name = 'Xero Invoice';
        }
        return xi;
    }

    private static String truncateForTextField(String value, Integer maxLen) {
        if (String.isBlank(value)) {
            return null;
        }
        if (maxLen == null || maxLen < 1 || value.length() <= maxLen) {
            return value;
        }
        return value.substring(0, maxLen);
    }

    private static String extractInvoiceIdFromRow(Map<String, Object> row) {
        Object iid = row.get('InvoiceID');
        if (iid == null) {
            iid = row.get('InvoiceId');
        }
        if (iid == null) {
            iid = row.get('invoiceID');
        }
        if (iid == null) {
            iid = row.get('invoiceId');
        }
        return iid != null ? String.valueOf(iid) : null;
    }

    private static String extractInvoiceNumberFromRow(Map<String, Object> row) {
        Object invNum = row.get('InvoiceNumber');
        if (invNum == null) {
            invNum = row.get('invoiceNumber');
        }
        return invNum != null ? String.valueOf(invNum) : null;
    }

    private static List<Xero_Invoice_Line__c> buildLineRecords(Id xeroInvoiceId, Map<String, Object> invoiceRow) {
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
        try {
            return Decimal.valueOf(String.valueOf(o));
        } catch (Exception e) {
            return null;
        }
    }

    private static Map<String, Object> buildInvoiceMap(
        Opportunity o,
        String xeroContactId,
        Xero_Connection__c connectionDefaults,
        Boolean includeXeroInvoiceId
    ) {
        Date invDate = o.CloseDate != null ? o.CloseDate : Date.today();
        Date dueDate = invDate.addDays(30);
        Map<String, Object> invoice = new Map<String, Object>();
        invoice.put('Type', 'ACCREC');
        invoice.put('Contact', new Map<String, Object>{ 'ContactID' => xeroContactId });
        invoice.put('Date', formatXeroDate(invDate));
        invoice.put('DueDate', formatXeroDate(dueDate));
        invoice.put('LineAmountTypes', 'Exclusive');
        invoice.put('Status', 'AUTHORISED');
        invoice.put('Reference', o.Name);
        if (includeXeroInvoiceId == true && String.isNotBlank(o.Xero_Invoice_ID__c)) {
            invoice.put('InvoiceID', o.Xero_Invoice_ID__c);
        }
        String defaultAccountCode = '200';
        if (connectionDefaults != null && String.isNotBlank(connectionDefaults.Default_Account_Code__c)) {
            defaultAccountCode = connectionDefaults.Default_Account_Code__c.trim();
        }
        Decimal defaultUnitPrice = 0;
        if (connectionDefaults != null && connectionDefaults.Default_Unit_Price__c != null) {
            defaultUnitPrice = connectionDefaults.Default_Unit_Price__c;
        }
        List<Object> lines = new List<Object>();
        if (o.OpportunityLineItems != null && !o.OpportunityLineItems.isEmpty()) {
            for (OpportunityLineItem li : o.OpportunityLineItems) {
                Boolean hasProduct = li.PricebookEntry != null && li.PricebookEntry.Product2Id != null;
                if (hasProduct && String.isBlank(li.PricebookEntry.Product2.Xero_Item_Code__c)) {
                    String prodName = li.PricebookEntry.Product2.Name != null ? li.PricebookEntry.Product2.Name : '(unknown)';
                    throw new XeroInvoiceSyncException(
                        'Invoice line references product "' +
                            prodName +
                            '" but Product2.Xero_Item_Code__c is blank. Sync the product to Xero first (Product2 → Xero Item), then retry.'
                    );
                }
                Map<String, Object> line = new Map<String, Object>();
                String lineDescription = li.Description;
                if (String.isBlank(lineDescription) && hasProduct) {
                    lineDescription = li.PricebookEntry.Product2.Name;
                }
                line.put('Description', String.isBlank(lineDescription) ? 'Line' : lineDescription);
                line.put('Quantity', li.Quantity != null ? li.Quantity : 1);
                Decimal unit = li.UnitPrice != null ? li.UnitPrice : defaultUnitPrice;
                line.put('UnitAmount', unit);
                line.put('AccountCode', defaultAccountCode);
                if (hasProduct) {
                    line.put('ItemCode', li.PricebookEntry.Product2.Xero_Item_Code__c);
                }
                lines.add(line);
            }
        } else {
            Map<String, Object> line = new Map<String, Object>();
            line.put('Description', 'Opportunity: ' + o.Name);
            line.put('Quantity', 1);
            line.put('UnitAmount', o.Amount != null ? o.Amount : defaultUnitPrice);
            line.put('AccountCode', defaultAccountCode);
            lines.add(line);
        }
        invoice.put('LineItems', lines);
        return invoice;
    }

    private static String formatXeroDate(Date d) {
        return DateTime.newInstance(d.year(), d.month(), d.day(), 0, 0, 0).format('yyyy-MM-dd');
    }
}
