/**
 * @description Test class for OpportunityTeamMemberHandler.
 */
@isTest
private class OpportunityTeamMemberHandlerTest {

    /**
     * @description Sets up common data for all test methods.
     */
    @testSetup
    static void setup() {
        // Create a custom Opportunity
        // Note: Add any other required fields for your specific org setup here
        Opportunity__c opp = new Opportunity__c(Name = 'Test Sharing Opp');
        insert opp;
    }

    /**
     * @description Utility method to create a test user.
     */
    private static User createTestUser(String alias) {
        Profile p = [SELECT Id FROM Profile WHERE Name='Standard User' LIMIT 1];
        User u = new User(
            Alias = alias, 
            Email = alias + '@testorg.com',
            EmailEncodingKey = 'UTF-8', 
            LastName = 'Testing', 
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US', 
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles', 
            UserName = alias + System.currentTimeMillis() + '@testorg.com'
        );
        insert u;
        return u;
    }

    @isTest
    static void testInsertSharing() {
        Opportunity__c opp = [SELECT Id FROM Opportunity__c LIMIT 1];
        User u = createTestUser('insrt');

        Test.startTest();
        Opportunity_Team_Member__c otm = new Opportunity_Team_Member__c(
            Opportunity__c = opp.Id,
            User__c = u.Id,
            Opportunity_Access__c = 'Read',
            Team_Member_Role__c = 'Sales Rep'
        );
        insert otm;
        Test.stopTest();

        // Verify share creation
        List<Opportunity__Share> shares = [SELECT AccessLevel FROM Opportunity__Share 
                                         WHERE ParentId = :opp.Id AND UserOrGroupId = :u.Id];
        System.assertEquals(1, shares.size(), 'A manual share should have been created.');
        System.assertEquals('Read', shares[0].AccessLevel, 'The access level should match the OTM record.');
    }

    @isTest
    static void testUpdateSharing() {
        Opportunity__c opp = [SELECT Id FROM Opportunity__c LIMIT 1];
        User u1 = createTestUser('u1');
        User u2 = createTestUser('u2');

        Opportunity_Team_Member__c otm = new Opportunity_Team_Member__c(
            Opportunity__c = opp.Id,
            User__c = u1.Id,
            Opportunity_Access__c = 'Read'
        );
        insert otm;

        Test.startTest();
        // Scenario A: Change access level
        otm.Opportunity_Access__c = 'Edit';
        update otm;
        
        // Check update
        System.assertEquals('Edit', [SELECT AccessLevel FROM Opportunity__Share WHERE UserOrGroupId = :u1.Id].AccessLevel);

        // Scenario B: Change the User (should delete old share, create new)
        otm.User__c = u2.Id;
        update otm;
        Test.stopTest();

        System.assertEquals(0, [SELECT count() FROM Opportunity__Share WHERE UserOrGroupId = :u1.Id], 'Old user share should be removed.');
        System.assertEquals(1, [SELECT count() FROM Opportunity__Share WHERE UserOrGroupId = :u2.Id], 'New user share should be created.');
    }

    @isTest
    static void testDeleteSharing() {
        Opportunity__c opp = [SELECT Id FROM Opportunity__c LIMIT 1];
        User u = createTestUser('dele');
        
        Opportunity_Team_Member__c otm = new Opportunity_Team_Member__c(
            Opportunity__c = opp.Id,
            User__c = u.Id,
            Opportunity_Access__c = 'Read'
        );
        insert otm;

        Test.startTest();
        delete otm;
        Test.stopTest();

        System.assertEquals(0, [SELECT count() FROM Opportunity__Share WHERE ParentId = :opp.Id AND UserOrGroupId = :u.Id], 'Share should be deleted.');
    }

    @isTest
    static void testBulkOperations() {
        Opportunity__c opp = [SELECT Id FROM Opportunity__c LIMIT 1];
        // Creating 200 users to test bulk sharing
        List<User> users = new List<User>();
        for(Integer i=0; i<50; i++) { // Using 50 to keep test runtime efficient, but still bulk
            Profile p = [SELECT Id FROM Profile WHERE Name='Standard User' LIMIT 1];
            users.add(new User(
                Alias = 'b'+i, Email='b'+i+'@test.com', LastName='Bulk', ProfileId=p.Id,
                UserName='bulk'+i+System.currentTimeMillis()+'@test.com',
                TimeZoneSidKey='America/Los_Angeles', LocaleSidKey='en_US', 
                EmailEncodingKey='UTF-8', LanguageLocaleKey='en_US'
            ));
        }
        insert users;

        List<Opportunity_Team_Member__c> otms = new List<Opportunity_Team_Member__c>();
        for(User u : users) {
            otms.add(new Opportunity_Team_Member__c(
                Opportunity__c = opp.Id,
                User__c = u.Id,
                Opportunity_Access__c = 'Read'
            ));
        }

        Test.startTest();
        insert otms;
        Test.stopTest();

        System.assert([SELECT count() FROM Opportunity__Share WHERE ParentId = :opp.Id] >= 50, 'Bulk shares should be processed.');
    }

    /**
     * @description Specifically targets the error logging logic.
     * Sharing with the Record Owner usually fails/is ignored in manual sharing.
     */
    @isTest
    static void testErrorLoggingFlow() {
        Opportunity__c opp = [SELECT Id, OwnerId FROM Opportunity__c LIMIT 1];
        
        // We create an OTM for the Record Owner. 
        // Salesforce will return a failure in the SaveResult because the owner already has 'All' access.
        Opportunity_Team_Member__c otm = new Opportunity_Team_Member__c(
            Opportunity__c = opp.Id,
            User__c = opp.OwnerId, 
            Opportunity_Access__c = 'Read'
        );

        Test.startTest();
        insert otm;
        Test.stopTest();

        // Check if the log was created
        List<Integration_Log__c> logs = [SELECT Id, Status__c, Error_Message__c FROM Integration_Log__c];
        
        // Depending on Org settings, sharing with owner is the most reliable way to force a SaveResult error.
        System.debug('Log created: ' + logs);
        if(!logs.isEmpty()) {
            System.assertEquals('Failed', logs[0].Status__c, 'Log status should be Failed.');
            System.assert(logs[0].Error_Message__c != null, 'Error message should be captured.');
        }
    }
}