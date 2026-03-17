public with sharing class EventGeotagController {
    
    @AuraEnabled
    public static void updateEventLocation(String recordId, String actionType, Double latitude, Double longitude) {
        try {
            Event eventToUpdate = new Event(Id = recordId);
            DateTime now = DateTime.now();

            if (actionType == 'Check-In') {
                eventToUpdate.Check_in_Time__c = now;
                // For geolocation fields in Apex, update the Latitude__s and Longitude__s components directly
                eventToUpdate.Check_in_Location__Latitude__s = latitude;
                eventToUpdate.Check_in_Location__Longitude__s = longitude;
            } else if (actionType == 'Check-Out') {
                eventToUpdate.Check_out_Time__c = now;
                eventToUpdate.Check_out_Location__Latitude__s = latitude;
                eventToUpdate.Check_out_Location__Longitude__s = longitude;
            }

            update eventToUpdate;
        } catch (Exception e) {
            throw new AuraHandledException('Error updating event: ' + e.getMessage());
        }
    }
}