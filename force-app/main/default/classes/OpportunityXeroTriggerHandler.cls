/**
 * After insert/update: when Opportunity reaches Closed Won, enqueue Xero Invoice sync.
 * Skips opportunities that already have a {@link Xero_Invoice__c} mirror row for first-time insert sync only;
 * already-Closed-Won updates that affect the invoice (and have a prior Xero invoice id plus mirror) enqueue an update sync.
 */
public inherited sharing class OpportunityXeroTriggerHandler {
    public static void afterInsert(List<Opportunity> newRows) {
        if (XeroInboundSyncSuppressor.isActive()) {
            return;
        }
        if (!XeroSyncRecursionControl.enterOpportunityTrigger()) {
            return;
        }
        try {
            Set<Id> ids = collectClosedWon(newRows, null);
            enqueue(ids);
        } finally {
            XeroSyncRecursionControl.exitOpportunityTrigger();
        }
    }

    public static void afterUpdate(List<Opportunity> newRows, Map<Id, Opportunity> oldMap) {
        if (XeroInboundSyncSuppressor.isActive()) {
            return;
        }
        if (!XeroSyncRecursionControl.enterOpportunityTrigger()) {
            return;
        }
        try {
            Set<Id> ids = collectClosedWon(newRows, oldMap);
            enqueue(ids);
        } finally {
            XeroSyncRecursionControl.exitOpportunityTrigger();
        }
    }

    private static void enqueue(Set<Id> ids) {
        if (!ids.isEmpty()) {
            System.enqueueJob(new XeroInvoiceSync(ids));
        }
    }

    private static Set<Id> collectClosedWon(List<Opportunity> newRows, Map<Id, Opportunity> oldMap) {
        Set<Id> insertCandidates = new Set<Id>();
        Set<Id> updateCandidates = new Set<Id>();
        for (Opportunity o : newRows) {
            if (!o.IsWon || !o.IsClosed) {
                continue;
            }
            if (oldMap != null) {
                Opportunity oldO = oldMap.get(o.Id);
                if (XeroSyncRecursionControl.onlyIntegrationFieldChanged(oldO, o, 'Xero_Invoice_ID__c')) {
                    continue;
                }
                if (oldO.IsWon && oldO.IsClosed) {
                    // ASSUMPTION: OpportunityLineItem changes are reflected on the parent via Amount (rollup); other fields alone do not enqueue.
                    if (
                        String.isNotBlank(o.Xero_Invoice_ID__c) &&
                        invoiceDrivingFieldsChanged(oldO, o)
                    ) {
                        updateCandidates.add(o.Id);
                    }
                    continue;
                }
            }
            insertCandidates.add(o.Id);
        }
        if (insertCandidates.isEmpty() && updateCandidates.isEmpty()) {
            return new Set<Id>();
        }
        Set<Id> withMirror = new Set<Id>();
        Set<Id> allToCheck = new Set<Id>();
        allToCheck.addAll(insertCandidates);
        allToCheck.addAll(updateCandidates);
        for (Xero_Invoice__c xi : [
            SELECT Opportunity__c
            FROM Xero_Invoice__c
            WHERE Opportunity__c IN :allToCheck
        ]) {
            if (xi.Opportunity__c != null) {
                withMirror.add(xi.Opportunity__c);
            }
        }
        Set<Id> ids = new Set<Id>();
        for (Id oppId : insertCandidates) {
            if (!withMirror.contains(oppId)) {
                ids.add(oppId);
            }
        }
        for (Id oppId : updateCandidates) {
            if (withMirror.contains(oppId)) {
                ids.add(oppId);
            }
        }
        return ids;
    }

    private static Boolean invoiceDrivingFieldsChanged(Opportunity oldO, Opportunity newO) {
        return oldO.Name != newO.Name ||
            oldO.CloseDate != newO.CloseDate ||
            oldO.Amount != newO.Amount;
    }
}
