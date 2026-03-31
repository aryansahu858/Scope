import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import savePdfFromLwc from '@salesforce/apex/QuotePdfController.savePdfFromLwc';

export default class QuotePdfSaver extends LightningElement {
    @api recordId;
    isSaving = false;

    get pdfUrl() {
        return `/apex/QuotePDFGenerator?id=${this.recordId}`;
    }

    handleCancel() {
        // This fires the native command to close the quick action modal
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleSave() {
        this.isSaving = true;
        
        savePdfFromLwc({ quoteId: this.recordId })
            .then(() => {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Success',
                        message: 'Quotation PDF has been saved successfully.',
                        variant: 'success'
                    })
                );
                // Close the modal upon successful save
                this.dispatchEvent(new CloseActionScreenEvent());
            })
            .catch(error => {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Error saving PDF',
                        message: error.body ? error.body.message : 'Unknown error occurred.',
                        variant: 'error'
                    })
                );
            })
            .finally(() => {
                this.isSaving = false;
            });
    }
}