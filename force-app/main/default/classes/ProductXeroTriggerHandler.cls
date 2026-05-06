/**
 * After insert/update: enqueue Xero Item sync for Product2 (async callouts).
 */
public inherited sharing class ProductXeroTriggerHandler {
    
    public static void afterInsert(List<Product2> newRows) {
        if (XeroInboundSyncSuppressor.isActive()) {
            return;
        }
        // Prevent infinite loops
        if (!XeroSyncRecursionControl.enterProductTrigger()) {
            return;
        }
        
        try {
            Set<Id> ids = new Set<Id>();
            for (Product2 p : newRows) {
                // Xero REQUIRES a Product Code. Don't sync if it's missing.
                if (String.isNotBlank(p.ProductCode)) {
                    ids.add(p.Id);
                }
            }
            
            if (!ids.isEmpty()) {
                System.enqueueJob(new XeroProductSync(ids));
            }
        } catch (Exception e) {
            System.debug('Error in Product AfterInsert Trigger: ' + e.getMessage());
        } finally {
            XeroSyncRecursionControl.exitProductTrigger();
        }
    }

    public static void afterUpdate(List<Product2> newRows, Map<Id, Product2> oldMap) {
        if (XeroInboundSyncSuppressor.isActive()) {
            return;
        }
        if (!XeroSyncRecursionControl.enterProductTrigger()) {
            return;
        }
        
        try {
            Set<Id> ids = new Set<Id>();
            for (Product2 p : newRows) {
                Product2 oldP = oldMap.get(p.Id);
                
                // 1. Skip if the only change was the Xero ID coming back from the previous sync
                if (XeroSyncRecursionControl.onlyIntegrationFieldChanged(oldP, p, 'Xero_Item_Code__c')) {
                    continue;
                }
                
                // 2. Only sync if the Product has a Code
                if (String.isNotBlank(p.ProductCode)) {
                    ids.add(p.Id);
                }
            }
            
            if (!ids.isEmpty()) {
                System.enqueueJob(new XeroProductSync(ids));
            }
        } catch (Exception e) {
            System.debug('Error in Product AfterUpdate Trigger: ' + e.getMessage());
        } finally {
            XeroSyncRecursionControl.exitProductTrigger();
        }
    }
}