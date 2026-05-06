@isTest
private class XeroSyncRecursionControlTest {
    @isTest
    static void onlyIntegrationFieldChanged_trueWhenOnlyExternalIdChanges() {
        Account oldA = new Account(Name = 'Same', BillingCity = 'London');
        Account newA = new Account(Name = 'Same', BillingCity = 'London', Xero_Contact_ID__c = 'new-id');
        System.assert(
            XeroSyncRecursionControl.onlyIntegrationFieldChanged(oldA, newA, 'Xero_Contact_ID__c'),
            'Expected true when only integration field differs'
        );
    }

    @isTest
    static void onlyIntegrationFieldChanged_falseWhenBusinessFieldChanges() {
        Account oldA = new Account(Name = 'A');
        Account newA = new Account(Name = 'B', Xero_Contact_ID__c = 'x');
        System.assert(
            !XeroSyncRecursionControl.onlyIntegrationFieldChanged(oldA, newA, 'Xero_Contact_ID__c'),
            'Expected false when business fields change too'
        );
    }

    @isTest
    static void triggerDepth_preventsReentry() {
        System.assert(XeroSyncRecursionControl.enterAccountTrigger());
        System.assertEquals(false, XeroSyncRecursionControl.enterAccountTrigger());
        XeroSyncRecursionControl.exitAccountTrigger();
        System.assert(XeroSyncRecursionControl.enterAccountTrigger());
        XeroSyncRecursionControl.exitAccountTrigger();
    }

    @isTest
    static void invoiceTriggerDepth_preventsReentry() {
        System.assert(XeroSyncRecursionControl.enterInvoiceTrigger());
        System.assertEquals(false, XeroSyncRecursionControl.enterInvoiceTrigger());
        XeroSyncRecursionControl.exitInvoiceTrigger();
        System.assert(XeroSyncRecursionControl.enterInvoiceTrigger());
        XeroSyncRecursionControl.exitInvoiceTrigger();
    }
}
