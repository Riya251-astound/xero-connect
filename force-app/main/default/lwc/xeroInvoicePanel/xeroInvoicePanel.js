import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getInvoiceDetails from '@salesforce/apex/XeroInvoicePdfController.getInvoiceDetails';
import fetchAndStorePdf from '@salesforce/apex/XeroInvoicePdfController.fetchAndStorePdf';
import sendInvoiceEmail from '@salesforce/apex/XeroInvoicePdfController.sendInvoiceEmail';

export default class XeroInvoicePanel extends LightningElement {
    @api recordId;

    @track isBusy = false;

    wiredInvoiceResult;

    /** Record Id for which the PAID info toast was already shown (one toast per invoice). */
    _paidNoticeShownForRecordId;

    @wire(getInvoiceDetails, { recordId: '$recordId' })
    wiredInvoice(result) {
        this.wiredInvoiceResult = result;
        const inv = result?.data;
        const rid = this.recordId;
        if (inv && rid && this._paidNoticeShownForRecordId !== rid) {
            const s = (inv.Status__c || '').trim().toUpperCase();
            if (s === 'PAID') {
                this._paidNoticeShownForRecordId = rid;
                this.showToast(
                    'PAID status',
                    'To mark this invoice paid in Xero, record a payment in Xero. Outbound sync does not push PAID (Xero requires the Payments API).',
                    'info'
                );
            }
        }
    }

    get invoice() {
        return this.wiredInvoiceResult?.data;
    }

    get effectiveInvoiceId() {
        return this.invoice?.Id;
    }

    get pdfDocumentId() {
        return this.invoice?.PDF_Document_Id__c;
    }

    get disableView() {
        return !this.effectiveInvoiceId;
    }

    get disableDownload() {
        return !this.effectiveInvoiceId || this.isBusy;
    }

    get disableEmail() {
        return !this.effectiveInvoiceId || !this.pdfDocumentId || this.isBusy;
    }

    reduceErrors(errors) {
        if (!errors || !errors.body) {
            return [errors?.message || 'Unknown error'];
        }
        const out = [];
        if (Array.isArray(errors.body)) {
            errors.body.forEach((e) => out.push(e.message));
        } else if (typeof errors.body.message === 'string') {
            out.push(errors.body.message);
        } else if (errors.body.pageErrors?.length) {
            errors.body.pageErrors.forEach((e) => out.push(e.message));
        } else if (errors.body.fieldErrors) {
            Object.values(errors.body.fieldErrors)
                .flat()
                .forEach((e) => out.push(e.message));
        }
        return out.length ? out : [JSON.stringify(errors.body)];
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    openPdfDownload(documentId) {
        if (!documentId) {
            return;
        }
        window.open('/sfc/servlet.shepherd/document/download/' + documentId, '_blank');
    }

    openPdfPreview(documentId) {
        if (!documentId) {
            return;
        }
        const base = window.location.origin;
        window.open(`${base}/lightning/r/ContentDocument/${documentId}/view`, '_blank');
    }

    handleViewPdf() {
        if (!this.effectiveInvoiceId) {
            return;
        }
        if (!this.pdfDocumentId) {
            this.showToast('Info', 'No PDF yet. Click Download to fetch it first.', 'info');
            return;
        }
        this.openPdfPreview(this.pdfDocumentId);
    }

    async handleDownloadPdf() {
        if (!this.effectiveInvoiceId) {
            return;
        }
        if (this.pdfDocumentId) {
            this.openPdfDownload(this.pdfDocumentId);
            return;
        }
        this.isBusy = true;
        try {
            const result = await fetchAndStorePdf({ xeroInvoiceRecordId: this.effectiveInvoiceId });
            if (result === 'queued') {
                this.showToast(
                    'Info',
                    'PDF is being fetched from Xero. Wait 5 seconds then click Download again.',
                    'info'
                );
                window.setTimeout(async () => {
                    try {
                        if (this.wiredInvoiceResult) {
                            await refreshApex(this.wiredInvoiceResult);
                        }
                        const docId = this.invoice?.PDF_Document_Id__c;
                        if (docId) {
                            this.openPdfDownload(docId);
                            this.showToast('Success', 'PDF ready', 'success');
                        }
                    } catch (e) {
                        this.showToast('Error', this.reduceErrors(e).join(', '), 'error');
                    } finally {
                        this.isBusy = false;
                    }
                }, 6000);
                return;
            }
        } catch (e) {
            this.showToast('Error', this.reduceErrors(e).join(', '), 'error');
        }
        this.isBusy = false;
    }

    async handleEmailPdf() {
        if (!this.effectiveInvoiceId || !this.pdfDocumentId) {
            return;
        }
        this.isBusy = true;
        try {
            const result = await sendInvoiceEmail({ xeroInvoiceRecordId: this.effectiveInvoiceId });
            if (result?.status === 'sent' && result.ownerEmail) {
                this.showToast('Success', `Invoice emailed to ${result.ownerEmail}`, 'success');
            } else if (result?.status === 'sent') {
                this.showToast('Success', 'Invoice emailed to the account owner.', 'success');
            }
        } catch (e) {
            this.showToast('Error', this.reduceErrors(e).join(', '), 'error');
        } finally {
            this.isBusy = false;
        }
    }
}
