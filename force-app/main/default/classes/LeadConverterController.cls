/**
 * @description       : Controller for Lead Conversion LWC. Handles the transformation of 
 * custom Lead__c records into Accounts, Contacts, and Opportunities.
 * @author            : Aryan Sahu
 * @last modified on  : 2026-02-24
 * @version           : 2.2
**/
public with sharing class LeadConverterController {

    /**
     * @description Fetches initial Lead data to prepopulate the LWC conversion form.
     * @param leadId ID of the custom Lead record.
     * @return Lead__c record containing company, name, and address details.
     */
    @AuraEnabled(cacheable=true)
    public static Lead__c getLead(Id leadId) {
        return [
            SELECT Id, Name, Company__c, Lead_Status__c, Has_Converted__c,
                   Title__c, Email__c, Phone__c, Lead_Source__c,
                   Address__Street__s, Address__City__s, Address__StateCode__s, Address__PostalCode__s, Address__CountryCode__s
            FROM Lead__c 
            WHERE Id = :leadId 
            WITH USER_MODE
        ];
    }

    /**
     * @description Searches for existing Accounts based on a search term.
     */
    @AuraEnabled(cacheable=true)
    public static List<Account> searchAccounts(String searchTerm) {
        String key = '%' + searchTerm + '%';
        return [SELECT Id, Name FROM Account WHERE Name LIKE :key WITH USER_MODE LIMIT 10];
    }

    /**
     * @description Searches for existing Contacts based on a search term.
     */
    @AuraEnabled(cacheable=true)
    public static List<Contact> searchContacts(String searchTerm) {
        String key = '%' + searchTerm + '%';
        return [SELECT Id, Name, Account.Name FROM Contact WHERE Name LIKE :key WITH USER_MODE LIMIT 10];
    }

    /**
     * @description Primary conversion engine. Handles transactional creation of Account, 
     * Contact, and Opportunity while mapping all Lead fields to their targets.
     * @param payload Map containing conversion configurations and record details.
     * @return Map containing success status and resulting Account ID or error message.
     */
    @AuraEnabled
    public static Map<String, Object> convertLead(Map<String, Object> payload) {
        Map<String, Object> response = new Map<String, Object>();
        
        // Define a Savepoint to ensure atomicity (all or nothing)
        Savepoint sp = Database.setSavepoint();

        try {
            String leadId = (String) payload.get('leadId');
            
            // Re-fetch the Lead to ensure we have the most recent data for backend mapping
            Lead__c sourceLead = [
                SELECT Title__c, Email__c, Phone__c, Lead_Source__c, Location__c,
                       Address__Street__s, Address__City__s, Address__StateCode__s, Address__PostalCode__s, Address__CountryCode__s
                FROM Lead__c 
                WHERE Id = :leadId 
                LIMIT 1
            ];

            // --- 1. ACCOUNT LOGIC ---
            Id finalAccountId;
            if ((Boolean) payload.get('createAccount')) {
                Map<Object, Object> accData = (Map<Object, Object>) payload.get('accountDetails');
                
                Account newAcc = new Account(
                    Name               = (String) accData.get('name'),
                    Phone              = sourceLead.Phone__c,
                    BillingStreet      = sourceLead.Address__Street__s,
                    BillingCity        = sourceLead.Address__City__s,
                    BillingStateCode   = sourceLead.Address__StateCode__s,
                    BillingPostalCode  = sourceLead.Address__PostalCode__s,
                    BillingCountryCode = sourceLead.Address__CountryCode__s,
                    Location_Site__c   = sourceLead.Location__c
                );
                insert newAcc; 
                finalAccountId = newAcc.Id;
            } else {
                finalAccountId = (String) payload.get('existingAccountId');
            }

            // --- 2. CONTACT LOGIC ---
            Id finalContactId;
            if ((Boolean) payload.get('createContact')) {
                Map<Object, Object> conData = (Map<Object, Object>) payload.get('contactDetails');
                
                Contact newCon = new Contact(
                    FirstName          = (String) conData.get('firstName'),
                    LastName           = (String) conData.get('lastName'),
                    AccountId          = finalAccountId,
                    Title              = sourceLead.Title__c,
                    Email              = sourceLead.Email__c,
                    Phone              = sourceLead.Phone__c,
                    LeadSource         = sourceLead.Lead_Source__c,
                    MailingStreet      = sourceLead.Address__Street__s,
                    MailingCity        = sourceLead.Address__City__s,
                    MailingStateCode   = sourceLead.Address__StateCode__s,
                    MailingPostalCode  = sourceLead.Address__PostalCode__s,
                    MailingCountryCode = sourceLead.Address__CountryCode__s,
                    Location_Site__c   = sourceLead.Location__c
                );
                insert newCon;
                finalContactId = newCon.Id;
            } else {
                finalContactId = (String) payload.get('existingContactId');
                
                // Link existing Contact to the current Account and update key info
                Contact existingCon = new Contact(
                    Id        = finalContactId, 
                    AccountId = finalAccountId
                );
                update existingCon;
            }

            // --- 3. OPPORTUNITY LOGIC ---
            Id oppId = null;
            if ((Boolean) payload.get('createOpportunity')) {
                Map<Object, Object> oppData = (Map<Object, Object>) payload.get('opportunityDetails');
                
                // Fetch the Record Type ID dynamically using the Schema approach (avoids SOQL limits)
                Id preSalesRecordTypeId = Schema.SObjectType.Opportunity__c.getRecordTypeInfosByDeveloperName().get('Pre_Sales').getRecordTypeId();
                
                Opportunity__c newOpp = new Opportunity__c(
                    RecordTypeId     = preSalesRecordTypeId, // Assigned here
                    Name             = (String) oppData.get('name'),
                    Stage__c         = (String) oppData.get('stageName'),
                    Close_Date__c    = Date.valueOf((String)oppData.get('closeDate')),
                    Account_Name__c  = finalAccountId,
                    Lead_Source__c   = sourceLead.Lead_Source__c
                );
                insert newOpp;
                oppId = newOpp.Id;
            }

            // --- 4. FINALIZE LEAD STATUS (DELETION) ---
            Lead__c leadToDelete = new Lead__c(Id = leadId);
            delete leadToDelete;

            // Success Response
            response.put('success', true);
            response.put('accountId', finalAccountId);

        } catch (Exception e) {
            // Rollback to Savepoint in case of any error within the transaction
            Database.rollback(sp);
            
            response.put('success', false);
            response.put('error', e.getMessage());
            System.debug('Lead Conversion Error: ' + e.getMessage());
        }

        return response;
    }
}