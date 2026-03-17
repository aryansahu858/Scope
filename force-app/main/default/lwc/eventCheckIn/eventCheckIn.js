import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import updateEventLocation from '@salesforce/apex/EventGeotagController.updateEventLocation';

export default class EventCheckIn extends LightningElement {
    @api recordId;

    // This method is automatically called when the Quick Action is clicked
    @api invoke() {
        if (navigator.geolocation) {
            navigator.geolocation.getCurrentPosition(
                (position) => {
                    this.saveRecord(position.coords.latitude, position.coords.longitude);
                },
                (error) => {
                    this.showToast('Error', 'Location access denied: ' + error.message, 'error');
                },
                { enableHighAccuracy: true }
            );
        } else {
            this.showToast('Error', 'Geolocation not supported', 'error');
        }
    }

    saveRecord(lat, long) {
        updateEventLocation({ 
            recordId: this.recordId, 
            actionType: 'Check-In', 
            latitude: lat, 
            longitude: long 
        })
        .then(() => {
            this.showToast('Success', 'Check-In successful!', 'success');
            notifyRecordUpdateAvailable([{recordId: this.recordId}]);
        })
        .catch(error => {
            this.showToast('Error', error.body.message, 'error');
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}