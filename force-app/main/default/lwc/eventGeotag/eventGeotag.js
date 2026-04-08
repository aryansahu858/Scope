import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import updateEventLocation from '@salesforce/apex/EventGeotagController.updateEventLocation';

export default class EventGeotag extends LightningElement {
    @api recordId;
    isLoading = false;

    handleCheckIn() {
        this.processAction('Check-In');
    }

    handleCheckOut() {
        this.processAction('Check-Out');
    }

    processAction(actionType) {
        this.isLoading = true;

        if (navigator.geolocation) {
            navigator.geolocation.getCurrentPosition(
                (position) => {
                    const latitude = position.coords.latitude;
                    const longitude = position.coords.longitude;
                    
                    // Call the Apex Method
                    this.saveRecord(actionType, latitude, longitude);
                },
                (error) => {
                    this.isLoading = false;
                    this.showToast('Error', 'Error retrieving location: ' + error.message, 'error');
                },
                {
                    enableHighAccuracy: true
                }
            );
        } else {
            this.isLoading = false;
            this.showToast('Error', 'Geolocation is not supported by this browser.', 'error');
        }
    }

    saveRecord(actionType, latitude, longitude) {
        updateEventLocation({ 
            recordId: this.recordId, 
            actionType: actionType, 
            latitude: latitude, 
            longitude: longitude 
        })
        .then(() => {
            this.showToast('Success', `${actionType} recorded successfully!`, 'success');
            
            // Refreshes the record page so the new values appear immediately
            notifyRecordUpdateAvailable([{recordId: this.recordId}]);

            window.location.reload();
        })
        .catch(error => {
            let message = 'Unknown error';
            if (error.body && error.body.message) {
                message = error.body.message;
            }
            this.showToast('Error', message, 'error');
        })
        .finally(() => {
            this.isLoading = false;
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant
            })
        );
    }
}