trigger OpportunityTeamMemberTrigger on Opportunity_Team_Member__c (after insert, after update, after delete) {
    
    if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            OpportunityTeamMemberHandler.handleAfterInsert(Trigger.new);
        } 
        else if (Trigger.isUpdate) {
            OpportunityTeamMemberHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
        } 
        else if (Trigger.isDelete) {
            OpportunityTeamMemberHandler.handleAfterDelete(Trigger.old);
        }
    }
}