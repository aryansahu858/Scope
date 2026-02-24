/**
 * @description Handler class for Opportunity_Team_Member__c trigger.
 * This class replicates standard Opportunity Team sharing behavior for a custom Opportunity__c object
 * using Apex Managed Sharing (Opportunity__Share) and logs DML errors to Integration_Log__c.
 */
public with sharing class OpportunityTeamMemberHandler {
    
    /**
     * @description Entry point for the after insert trigger context.
     * @param newList The list of newly created Opportunity Team Member records.
     */
    public static void handleAfterInsert(List<Opportunity_Team_Member__c> newList) {
        createShares(newList);
    }
    
    /**
     * @description Entry point for the after update trigger context. 
     * Identifies changes in critical fields to recalculate sharing access.
     * @param newList The list of updated Opportunity Team Member records.
     * @param oldMap Map of records before update for comparison.
     */
    public static void handleAfterUpdate(List<Opportunity_Team_Member__c> newList, Map<Id, Opportunity_Team_Member__c> oldMap) {
        List<Opportunity_Team_Member__c> sharesToCreate = new List<Opportunity_Team_Member__c>();
        List<Opportunity_Team_Member__c> sharesToDelete = new List<Opportunity_Team_Member__c>();
        
        for (Opportunity_Team_Member__c otm : newList) {
            Opportunity_Team_Member__c oldOtm = oldMap.get(otm.Id);
            
            // Check if fields affecting sharing have changed
            Boolean accessChanged = otm.Opportunity_Access__c != oldOtm.Opportunity_Access__c;
            Boolean userChanged = otm.User__c != oldOtm.User__c;
            Boolean opportunityChanged = otm.Opportunity__c != oldOtm.Opportunity__c;

            if (accessChanged || userChanged || opportunityChanged) {
                // If the relationship changed, remove the old access and grant new access
                sharesToDelete.add(oldOtm);
                sharesToCreate.add(otm);
            }
        }
        
        if (!sharesToDelete.isEmpty()) {
            deleteShares(sharesToDelete);
        }
        if (!sharesToCreate.isEmpty()) {
            createShares(sharesToCreate);
        }
    }
    
    /**
     * @description Entry point for the after delete trigger context.
     * @param oldList The list of Opportunity Team Member records being deleted.
     */
    public static void handleAfterDelete(List<Opportunity_Team_Member__c> oldList) {
        deleteShares(oldList);
    }
    
    /**
     * @description Grants manual access to the Custom Opportunity for the assigned User.
     * Uses Database.insert with allOrNone=false to handle partial successes.
     */
    private static void createShares(List<Opportunity_Team_Member__c> records) {
        List<Opportunity__Share> sharesToInsert = new List<Opportunity__Share>();
        
        for (Opportunity_Team_Member__c otm : records) {
            // Ensure necessary fields are populated before creating share records
            if (otm.Opportunity__c != null && otm.User__c != null && otm.Opportunity_Access__c != null) {
                sharesToInsert.add(new Opportunity__Share(
                    ParentId = otm.Opportunity__c,
                    UserOrGroupId = otm.User__c,
                    AccessLevel = otm.Opportunity_Access__c,
                    RowCause = Schema.Opportunity__Share.RowCause.Manual
                ));
            }
        }
        
        if (!sharesToInsert.isEmpty()) {
            // Perform DML and capture results for error logging
            Database.SaveResult[] srList = Database.insert(sharesToInsert, false);
            logResults(srList, 'Insert Opportunity Share');
        }
    }

    /**
     * @description Removes manual access records. Uses a composite key (ParentId + UserId)
     * to prevent accidental "Cartesian" over-deletion during bulk processing.
     */
    private static void deleteShares(List<Opportunity_Team_Member__c> records) {
        Set<Id> parentIds = new Set<Id>();
        Set<Id> userIds = new Set<Id>();
        Set<String> keysToDelete = new Set<String>();

        // Build filtering sets and composite keys
        for (Opportunity_Team_Member__c otm : records) {
            if (otm.Opportunity__c != null && otm.User__c != null) {
                parentIds.add(otm.Opportunity__c);
                userIds.add(otm.User__c);
                keysToDelete.add(String.valueOf(otm.Opportunity__c) + String.valueOf(otm.User__c));
            }
        }

        if (parentIds.isEmpty()) return;

        // Query potential share records and filter in memory using the composite key
        List<Opportunity__Share> actualSharesToDelete = new List<Opportunity__Share>();
        for (Opportunity__Share share : [SELECT Id, ParentId, UserOrGroupId FROM Opportunity__Share 
                                        WHERE ParentId IN :parentIds 
                                        AND UserOrGroupId IN :userIds 
                                        AND RowCause = 'Manual']) {
            
            String currentKey = String.valueOf(share.ParentId) + String.valueOf(share.UserOrGroupId);
            if (keysToDelete.contains(currentKey)) {
                actualSharesToDelete.add(share);
            }
        }

        if (!actualSharesToDelete.isEmpty()) {
            // Perform DML and capture results for error logging
            Database.DeleteResult[] drList = Database.delete(actualSharesToDelete, false);
            logResults(drList, 'Delete Opportunity Share');
        }
    }

    /**
     * @description Helper method to parse Database results and create Integration_Log__c records
     * if any errors were encountered during the transaction.
     * @param results List of SaveResult or DeleteResult objects.
     * @param context Context string for the Log Name (e.g., 'Insert Opportunity Share').
     */
    private static void logResults(List<Object> results, String context) {
        List<String> errorMessages = new List<String>();
        Integer successCount = 0;
        Integer failureCount = 0;

        for (Object res : results) {
            Boolean isSuccess = false;
            List<Database.Error> errors;
            
            // Extract status and errors based on the result type
            if (res instanceof Database.SaveResult) {
                Database.SaveResult sr = (Database.SaveResult)res;
                isSuccess = sr.isSuccess();
                errors = sr.getErrors();
            } else if (res instanceof Database.DeleteResult) {
                Database.DeleteResult dr = (Database.DeleteResult)res;
                isSuccess = dr.isSuccess();
                errors = dr.getErrors();
            }

            if (isSuccess) {
                successCount++;
            } else {
                failureCount++;
                for (Database.Error err : errors) {
                    errorMessages.add('Error Code: ' + err.getStatusCode() + ' - Message: ' + err.getMessage());
                }
            }
        }

        // Only commit a log record if at least one failure occurred
        if (failureCount > 0) {
            insert new Integration_Log__c(
                Name = (context + ' Log ' + DateTime.now().format()).left(80),
                Status__c = 'Failed',
                Records_Processed__c = successCount,
                Error_Message__c = String.join(errorMessages, '\n').left(32000),
                Request_End_Time__c = System.now()
            );
        }
    }
}