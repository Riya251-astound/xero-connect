/**
 * After insert/update: enqueue Xero Contact sync (async callouts).
 */
public inherited sharing class AccountXeroTriggerHandler {
    public static void afterInsert(List<Account> newRows) {
        if (XeroInboundSyncSuppressor.isActive()) {
            return;
        }
        if (!XeroSyncRecursionControl.enterAccountTrigger()) {
            return;
        }
        try {
            Set<Id> ids = new Set<Id>();
            for (Account a : newRows) {
                ids.add(a.Id);
            }
            if (!ids.isEmpty()) {
                System.enqueueJob(new XeroContactSync(ids));
            }
        } finally {
            XeroSyncRecursionControl.exitAccountTrigger();
        }
    }

    public static void afterUpdate(List<Account> newRows, Map<Id, Account> oldMap) {
        if (XeroInboundSyncSuppressor.isActive()) {
            return;
        }
        if (!XeroSyncRecursionControl.enterAccountTrigger()) {
            return;
        }
        try {
            Set<Id> ids = new Set<Id>();
            for (Account a : newRows) {
                Account oldA = oldMap.get(a.Id);
                if (XeroSyncRecursionControl.onlyIntegrationFieldChanged(oldA, a, 'Xero_Contact_ID__c')) {
                    continue;
                }
                ids.add(a.Id);
            }
            if (!ids.isEmpty()) {
                System.enqueueJob(new XeroContactSync(ids));
            }
        } finally {
            XeroSyncRecursionControl.exitAccountTrigger();
        }
    }
}
