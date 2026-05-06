/**
 * Same-transaction recursion guards (bulk-safe) for Xero trigger handlers.
 */
public inherited sharing class XeroSyncRecursionControl {
    private static Integer accountDepth = 0;
    private static Integer invoiceDepth = 0;
    private static Integer opportunityDepth = 0;
    private static Integer productDepth = 0;

    public static Boolean enterAccountTrigger() {
        if (accountDepth > 0) {
            return false;
        }
        accountDepth++;
        return true;
    }

    public static void exitAccountTrigger() {
        accountDepth = Math.max(0, accountDepth - 1);
    }

    public static Boolean enterInvoiceTrigger() {
        if (invoiceDepth > 0) {
            return false;
        }
        invoiceDepth++;
        return true;
    }

    public static void exitInvoiceTrigger() {
        invoiceDepth = Math.max(0, invoiceDepth - 1);
    }

    public static Boolean enterOpportunityTrigger() {
        if (opportunityDepth > 0) {
            return false;
        }
        opportunityDepth++;
        return true;
    }

    public static void exitOpportunityTrigger() {
        opportunityDepth = Math.max(0, opportunityDepth - 1);
    }

    public static Boolean enterProductTrigger() {
        if (productDepth > 0) {
            return false;
        }
        productDepth++;
        return true;
    }

    public static void exitProductTrigger() {
        productDepth = Math.max(0, productDepth - 1);
    }

    /**
     * True when the only difference is the integration external id (async write-back).
     */
    public static Boolean onlyIntegrationFieldChanged(SObject oldRec, SObject newRec, String integrationFieldApi) {
        Map<String, Schema.SObjectField> fieldMap = oldRec.getSObjectType().getDescribe().fields.getMap();
        Boolean integrationChanged = oldRec.get(integrationFieldApi) != newRec.get(integrationFieldApi);
        if (!integrationChanged) {
            return false;
        }
        for (String apiName : fieldMap.keySet()) {
            if (apiName == integrationFieldApi) {
                continue;
            }
            Schema.DescribeFieldResult d = fieldMap.get(apiName).getDescribe();
            if (!d.isAccessible() || d.isCalculated() || !d.isUpdateable()) {
                continue;
            }
            if (oldRec.get(apiName) != newRec.get(apiName)) {
                return false;
            }
        }
        return true;
    }
}
