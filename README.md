## Lightning Page Setup

After deploying, go to: **Setup → Object Manager → Xero_Invoice__c → Lightning Record Pages → Edit →** drag the **xeroInvoicePanel** component onto the page → **Save & Activate**. Repeat for the **Opportunity** Lightning Record Page.

---

Execution Guide:

Step-1: Run this command >> sf project deploy start --target-org MyDevOrg >> to deploy the code to salesforce

Step-2: After you've been successfully connected to salesforce you can now run this command in the terminal to >> sf apex run --file scripts/apex/getXeroUrl.apex --target-org MyDevOrg

Step-3: Copy paste the redirect link you get from the DEBUG LINES into browser and you will get a webpage from Xero to allow the salesforce to make its connection




New way to run apex codes
>> sf apex run -o MyRepairOrg
>> System.debug('\n\n=== CLICK THIS LINK ===\n' + XeroService.getAuthUrl() + '\n=======================\n');



Newest way to run the code
sf project deploy start --target-org MyDevOrg

sf apex run --file "scripts/apex/getXeroUrl.apex" --target-org MyRepairOrg

sf apex run --file scripts/apex/checktokens.apex -o MyRepairOrg

sf apex run --file scripts/apex/test-sync.apex -o MyRepairOrg

pmd check
pmd check -d ./force-app/main/default/classes -R ./.ruleset.xml -f text --no-cache