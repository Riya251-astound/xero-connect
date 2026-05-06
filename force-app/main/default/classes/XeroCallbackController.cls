/**
 * OAuth redirect target: reads ?code= and exchanges it for tokens (synchronous callout — not a trigger).
 * Callouts and DML run from handleCallback (page action), not the constructor.
 */
public inherited sharing class XeroCallbackController {
    public String message { get; private set; }
    public String errorMessage { get; private set; }

    public XeroCallbackController() {
    }

    /**
     * Invoked by <apex:page action="..."/> so callouts and DML occur in the correct Visualforce lifecycle.
     */
    public void handleCallback() {
        String code = ApexPages.currentPage().getParameters().get('code');
        String oauthError = ApexPages.currentPage().getParameters().get('error');
        String oauthDesc = ApexPages.currentPage().getParameters().get('error_description');
        if (String.isNotBlank(oauthError)) {
            errorMessage = oauthError + (String.isNotBlank(oauthDesc) ? ': ' + oauthDesc : '');
            return;
        }
        if (String.isBlank(code)) {
            errorMessage = 'Missing authorization code (?code=).';
            return;
        }
        try {
            Map<String, Object> tokens = XeroService.exchangeCodeForTokens(code);
            String accessToken = (String) tokens.get('access_token');
            if (String.isBlank(accessToken)) {
                throw new XeroService.XeroServiceException('Token response did not include access_token.');
            }
            String tenantId = XeroService.getTenantId(accessToken);
            XeroService.saveTokens(tokens, tenantId);
            message = 'Successfully connected to Xero. Tokens and tenant id saved on Xero_Connection__c.';
        } catch (Exception e) {
            errorMessage = e.getMessage();
        }
    }
}
