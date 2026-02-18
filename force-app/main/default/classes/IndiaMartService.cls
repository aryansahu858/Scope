/**
 * @description       : Service class to handle IndiaMART Lead Integration via Pull API.
 * Implements Queueable to handle asynchronous callouts and heavy processing.
 * @author            : Aryan Sahu
 * @last modified on  : 17/02/2026
 * @last modified by  : Aryan Sahu
**/
public class IndiaMartService implements Queueable, Database.AllowsCallouts {
    
    // IndiaMART API requires specific date format: DD-MMM-YYYYHH:MM:SS (e.g., 15-Feb-202410:30:00)
    private static final String IM_DATE_FMT = 'dd-MMM-yyyyHH:mm:ss'; 
    
    /**
    * @description Execute method for Queueable interface.
    * @param context QueueableContext
    */
    public void execute(QueueableContext context) {
        processLeads();
    }

    /**
    * @description Main logic to fetch configuration, calculate time windows, and initiate API Callout.
    * Uses "Rolling Overlap" strategy to ensure zero lead leakage.
    */
    public static void processLeads() {
        // 1. Retrieve System State and Configuration
        Integration_Settings__c settings = Integration_Settings__c.getOrgDefaults();
        // Note: Assumes at least one record exists in Custom Metadata Type
        IndiaMart_Config__mdt config = [SELECT API_Key__c, Base_URL__c FROM IndiaMart_Config__mdt LIMIT 1];
        
        DateTime endTime = System.now();
        // If this is the first run (settings is null), default to 24 hours ago
        DateTime lastSync = settings.Last_Sync_Time__c != null ? settings.Last_Sync_Time__c : endTime.addDays(-1);

        // 2. Rolling Overlap Strategy
        // Start 5 minutes BEFORE the last successful sync time.
        // This ensures that leads created during the milliseconds of the previous fetch are captured.
        // Deduplication in Salesforce (via External ID) handles the overlap.
        DateTime startTime = lastSync.addMinutes(-5);

        // 3. Format DateTimes to India Standard Time (IST) as required by IndiaMART API
        String startStr = startTime.format(IM_DATE_FMT, 'IST'); 
        String endStr = endTime.format(IM_DATE_FMT, 'IST');
        
        // 4. Construct Endpoint with URL Encoding
        String endpoint = config.Base_URL__c + 
                         '?glusr_crm_key=' + config.API_Key__c + 
                         '&start_time=' + EncodingUtil.urlEncode(startStr, 'UTF-8') + 
                         '&end_time=' + EncodingUtil.urlEncode(endStr, 'UTF-8');

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setTimeout(60000); // 60 seconds timeout

        Http http = new Http();
        try {
            HttpResponse res = http.send(req);
            // 200 OK indicates a successful HTTP connection (regardless of logical success)
            if (res.getStatusCode() == 200) {
                handleSuccess(res.getBody(), startTime, endTime);
            } else {
                logEntry('Failure', 'HTTP Error: ' + res.getStatusCode() + ' - ' + res.getStatus(), 0);
            }
        } catch (Exception e) {
            logEntry('Failure', 'Callout Exception: ' + e.getMessage(), 0);
        }
    }

    /**
    * @description Parses JSON response and handles Upsert logic.
    * @param jsonResponse The raw JSON body from API
    * @param fetchStartTime The start time of this batch (for logging)
    * @param fetchEndTime The end time of this batch (to update checkpoint)
    */
    private static void handleSuccess(String jsonResponse, DateTime fetchStartTime, DateTime fetchEndTime) {
        if (String.isBlank(jsonResponse)) return;
        
        IndiaMartResponseWrapper wrapper = (IndiaMartResponseWrapper) JSON.deserialize(jsonResponse, IndiaMartResponseWrapper.class);
        
        // Handle IndiaMART Specific Logical Return Codes
        if (wrapper.CODE != 200 && wrapper.CODE != null) {
            if (wrapper.CODE == 204) { 
                // Code 204: Request successful but no data found in this time range.
                // Treat as success and advance the time cursor.
                //logEntry('Success', 'No new leads found (Code 204)', 0);
                updateLastSyncTime(fetchEndTime); 
                return;
            }
            // Other codes (400, 401, etc.) embedded in JSON body
            logEntry('Failure', 'IndiaMART API Error: ' + wrapper.CODE + ' - ' + wrapper.MESSAGE, 0);
            return;
        }

        if (wrapper.RESPONSE == null || wrapper.RESPONSE.isEmpty()) {
            logEntry('Success', 'Response 200 OK but empty list', 0);
            updateLastSyncTime(fetchEndTime);
            return;
        }

        // Map Wrapper objects to Salesforce SObjects
        List<Lead__c> leadsToUpsert = new List<Lead__c>();
        for (IndiaMartResponseWrapper.LeadDetail item : wrapper.RESPONSE) {
            leadsToUpsert.add(mapToLead(item));
        }

        if (!leadsToUpsert.isEmpty()) {
            // Upsert based on Lead_External_Id__c (Mapped to UNIQUE_QUERY_ID)
            // allOrNone = false allows partial success handling
            Schema.SObjectField externalIdField = Lead__c.Fields.Lead_External_Id__c;
            Database.UpsertResult[] results = Database.upsert(leadsToUpsert, externalIdField, false);
            
            // Analyze results for Logging
            Integer successCount = 0;
            Integer failCount = 0;
            String errorDetails = '';

            for (Database.UpsertResult r : results) {
                if (r.isSuccess()) {
                    successCount++;
                } else {
                    failCount++;
                    errorDetails += r.getErrors()[0].getMessage() + '; ';
                }
            }

            // Log Summary
            String logMsg = 'Processed ' + leadsToUpsert.size() + ' leads. Inserted/Updated: ' + successCount + '. Failed: ' + failCount;
            if (failCount > 0) logMsg += ' Errors: ' + errorDetails;

            logEntry(failCount > 0 ? 'Partial Success' : 'Success', logMsg, successCount);
            
            // Only update the "Last Sync Time" if we attempted to process records
            updateLastSyncTime(fetchEndTime);
        }
    }

    /**
    * @description Maps a single JSON node to a Lead__c record.
    * @param item The LeadDetail object from the wrapper
    * @return Lead__c The populated Salesforce record
    */
    private static Lead__c mapToLead(IndiaMartResponseWrapper.LeadDetail item) {
        Lead__c ld = new Lead__c();
        ld.Lead_External_Id__c = item.UNIQUE_QUERY_ID; 
        ld.Name = item.SENDER_NAME;
        ld.Phone__c = normalizePhone(item.SENDER_MOBILE);
        ld.Email__c = item.SENDER_EMAIL;
        ld.Company__c = item.SENDER_COMPANY;
        ld.Subject__c = item.SUBJECT;
        ld.City__c = item.SENDER_CITY;
        ld.State_Province__c = item.SENDER_STATE;
        ld.Zip_Postal_Code__c = item.SENDER_PINCODE;
        ld.Country__c = item.SENDER_COUNTRY_ISO;
        ld.Product_Interest__c = item.QUERY_PRODUCT_NAME;
        ld.Product_Category__c = item.QUERY_MCAT_NAME;
        
        // Transform Single Character Codes to Readable Labels
        if (String.isNotBlank(item.QUERY_TYPE)) {
            switch on item.QUERY_TYPE.toUpperCase() {
                when 'W' { ld.Query_Type__c = 'Direct'; }
                when 'B' { ld.Query_Type__c = 'Buy-Leads'; }
                when 'P' { ld.Query_Type__c = 'PNS Calls'; }
                when else { ld.Query_Type__c = item.QUERY_TYPE; }
            }
        }
        
        // Clean HTML tags from multi-line messages
        if (item.QUERY_MESSAGE != null) {
            ld.Product_Description__c = item.QUERY_MESSAGE.stripHtmlTags();
        }
        return ld;
    }

    /**
    * @description Updates the Custom Setting with the timestamp of this successful run.
    * @param newTime The End Time of the API window we just finished processing.
    */
    private static void updateLastSyncTime(DateTime newTime) {
        Integration_Settings__c settings = Integration_Settings__c.getOrgDefaults();
        settings.Last_Sync_Time__c = newTime;
        upsert settings;
    }
    
    /**
    * @description Centralized logging method.
    */
    private static void logEntry(String status, String message, Integer recordCount) {
        insert new Integration_Log__c(
            Status__c = status,
            Error_Message__c = message, 
            Records_Processed__c = recordCount,
            Request_End_Time__c = System.now(),
            Name = 'IndiaMART Sync'
        );
    }
    
    /**
    * @description Normalizes phone numbers to ensure they start with +91 if 10 digits.
    */
    private static String normalizePhone(String phone) {
        if (String.isBlank(phone)) return null;
        String clean = phone.replaceAll('[^0-9]', '');
        return (clean.length() == 10) ? '+91' + clean : phone;
    }
}