# Xero Webhooks — Deploy and Configuration

## 1. Deploy new components (CLI)

From the project root, deploy the new Apex classes, field metadata, and tests:

```bash
sf project deploy start --source-dir force-app/main/default/classes/XeroInboundSyncSuppressor.cls --source-dir force-app/main/default/classes/XeroInboundSyncSuppressor.cls-meta.xml --source-dir force-app/main/default/classes/XeroWebhookListener.cls --source-dir force-app/main/default/classes/XeroWebhookListener.cls-meta.xml --source-dir force-app/main/default/classes/XeroWebhookHandler.cls --source-dir force-app/main/default/classes/XeroWebhookHandler.cls-meta.xml --source-dir force-app/main/default/classes/XeroWebhookListenerTest.cls --source-dir force-app/main/default/classes/XeroWebhookListenerTest.cls-meta.xml --source-dir force-app/main/default/classes/XeroWebhookHandlerTest.cls --source-dir force-app/main/default/classes/XeroWebhookHandlerTest.cls-meta.xml --target-org YOUR_ORG_ALIAS
```

Or deploy the whole project (recommended if you keep everything in sync):

```bash
sf project deploy start --target-org YOUR_ORG_ALIAS
```

Deploy the `Webhook_Key__c` field if it is not already on `Xero_Connection__c`:

```bash
sf project deploy start --source-dir force-app/main/default/objects/Xero_Connection__c/fields/Webhook_Key__c.field-meta.xml --target-org YOUR_ORG_ALIAS
```

Run tests:

```bash
sf apex run test --tests XeroWebhookListenerTest,XeroWebhookHandlerTest --target-org YOUR_ORG_ALIAS --result-format human --code-coverage --wait 10
```

---

## 2. Salesforce: Webhook_Key__c

1. Open the **Primary** `Xero_Connection__c` record (the single row used by the integration).
2. Set **Webhook Key** (`Webhook_Key__c`) to the **Webhook key** shown in the Xero Developer Portal for your app (same secret used to validate `x-xero-signature`).

---

## 3. Salesforce Site (public HTTPS URL for Xero)

Xero must call a **public** URL. Typical pattern: **Experience Cloud Site** or **Force.com Site** that exposes the Apex REST service.

### Site guest / profile access

Grant the **Guest User** profile used by the Site (or the relevant **Site Guest User**):

- **Apex Class Access**: `XeroWebhookListener` (and ensure the queueable `XeroWebhookHandler` can run — usually allowed when enqueued from the same org).
- **Custom Object** `Xero_Connection__c`: **Read** (at minimum `Webhook_Key__c`, `Tenant_ID__c`; the async job runs in the same org and uses the integration user’s credentials via `XeroService` when the handler runs — **verify** whether the enqueuing user is Guest: you may need **Allow Callouts** on that profile, or run the webhook through an integration path that uses a full user — see note below).
- **Standard objects** updated by the handler (`Account`, `Product2`, `Opportunity`): the **Queueable** runs as the user who queued the job; adjust **OWD**, **sharing**, and **FLS** so that user can update the integrated records (often a dedicated integration user or elevated Site guest is not allowed to update Accounts — **test in a sandbox**).

**Important:** If the Site Guest User cannot perform **HTTP callouts** or **DML** on your objects, use one of:

- A **middleware** (e.g. small Heroku/AWS Lambda) that receives the Xero webhook and calls Salesforce with a **Named Credential** / **integration user**, or  
- An **authenticated** endpoint (not guest) suitable for your security model.

### Webhook URL for Xero

After the Site is active, your listener URL shape is:

```text
https://YOUR_SITE_DOMAIN/services/apexrest/xero_events/
```

Use the **HTTPS** domain shown on the Site’s **URL** settings (may be `*.force.com`, `*.site.com`, or your custom domain).

**Intent to receive:** Xero sends **POST** requests. **GET** on the same path returns `200` with an empty body (connectivity only).

---

## 4. Xero Developer Portal

1. Open your app → **Webhooks** (or **App** → webhook settings).
2. Create a webhook with:
   - **Delivery URL**: `https://YOUR_SITE_DOMAIN/services/apexrest/xero_events/`
   - **Events**: at least **Contact**, **Item**, **Invoice** (match `CONTACT`, `ITEM`, `INVOICE` in code).
3. Complete **Intent to receive** / validation:
   - Xero sends signed requests; invalid signatures must get **401** with no body; valid signatures must get **200** with an empty body (implementation follows this).
4. Copy the **Webhook key** into Salesforce `Xero_Connection__c.Webhook_Key__c`.

---

## 5. Connected Site / CSP (if applicable)

Ensure **Remote Site Settings** (or **CSP Trusted Sites** for newer models) already allow `https://api.xero.com` for callouts from `XeroService` (same as the rest of the integration).

---

## 6. Behaviour summary

| Step | Behaviour |
|------|-------------|
| Listener | Reads raw body, verifies **HMAC-SHA256** of the raw body vs `x-xero-signature` using `Webhook_Key__c`. |
| Success | **200**, empty body; enqueues `XeroWebhookHandler` with the raw JSON string. |
| Failure | **401**, empty body. |
| Handler (async) | For each event, **GET** from Xero by `resourceId`, then updates **Account** / **Product2** by `Xero_Contact_ID__c` / `Xero_Item_Code__c`. For **INVOICE**, upserts **`Xero_Invoice__c`** by `Xero_Invoice_ID__c` (mirror), refreshes **`Xero_Invoice_Line__c`** from the GET payload, and links to **Opportunity** when a matching mirror row exists (`Opportunity__c`). |
| Recursion | `XeroInboundSyncSuppressor` wraps inbound DML so **AccountXeroTriggerHandler**, **ProductXeroTriggerHandler**, and **OpportunityXeroTriggerHandler** do not enqueue outbound sync. |
