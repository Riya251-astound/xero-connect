/**
 * When true, Account/Product2/Opportunity trigger handlers skip enqueueing outbound Xero sync jobs.
 * Used by inbound webhook processing so Xero-originated field updates do not loop back to Xero.
 */
public inherited sharing class XeroInboundSyncSuppressor {
    private static Integer depth = 0;

    public static void enter() {
        depth++;
    }

    public static void exit() {
        depth = Math.max(0, depth - 1);
    }

    public static Boolean isActive() {
        return depth > 0;
    }
}
