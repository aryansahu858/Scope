/**
 * @description       : Test class for LeadConverterController.
 * Validates the fetching, searching, and conversion (including deletion) 
 * of custom Lead__c records into Accounts, Contacts, and Opportunities.
 * @author            : Aryan Sahu
 * @last modified on  : 2026-02-24
 * @version           : 2.2
**/
@isTest
private class LeadConverterControllerTest {
    
    /**
     * @description Sets up baseline data for all test methods.
     * Ensures all org-required fields are populated to avoid DML exceptions.
     */
    @testSetup
    static void setupTestData() {
        
        
        // Get field describe
        Schema.DescribeFieldResult fieldResult = 
            Lead__c.Lead_Source__c.getDescribe();
        
        // Get picklist values
        List<Schema.PicklistEntry> picklistValues = 
            fieldResult.getPicklistValues();
        
        // 1. Create a Custom Lead with ALL required fields populated
        Lead__c testLead = new Lead__c(
            Name                    = 'Test Lead',
            Company__c              = 'Test Corp',
            Email__c                = 'test@example.com',
            Phone__c                = '555-1234',
            Lead_Source__c          = picklistValues[0].getLabel(),
            Title__c                = 'Director of Operations',
            Location__c             = 'Main Office', 
            Address__Street__s      = '123 Test Boulevard',
            Address__City__s        = 'Innovation City',
            Address__StateCode__s   = 'CA',
            Address__PostalCode__s  = '90210',
            Address__CountryCode__s = 'US'
        );
        insert testLead;

        // 2. Create an Account for search and existing record conversion tests
        Account testAcc = new Account(Name = 'Global Tech', Location_Site__c = 'Street 1');
        insert testAcc;

        // 3. Create a Contact for search and existing record conversion tests
        Contact testCon = new Contact(
            FirstName = 'John',
            LastName  = 'Doe',
            AccountId = testAcc.Id
        );
        insert testCon;
    }

    /**
     * @description Tests that the getLead method correctly fetches the lead and its fields.
     */
    @isTest
    static void testGetLead() {
        Lead__c insertedLead = [SELECT Id FROM Lead__c LIMIT 1];
        
        Test.startTest();
        Lead__c result = LeadConverterController.getLead(insertedLead.Id);
        Test.stopTest();
        
        Assert.isNotNull(result, 'Lead should be returned by the controller');
        Assert.areEqual('test@example.com', result.Email__c, 'Email__c should match the setup data');
        Assert.areEqual('Test Corp', result.Company__c, 'Company__c should match the setup data');
    }

    /**
     * @description Tests the SOQL search functionalities for Accounts and Contacts.
     */
    @isTest
    static void testSearchAccountsAndContacts() {
        Test.startTest();
        List<Account> accs = LeadConverterController.searchAccounts('Global');
        List<Contact> cons = LeadConverterController.searchContacts('Doe');
        Test.stopTest();
        
        Assert.areEqual(1, accs.size(), 'Should find exactly 1 Account matching "Global"');
        Assert.areEqual(1, cons.size(), 'Should find exactly 1 Contact matching "Doe"');
    }

    /**
     * @description Tests creating a NEW Account, Contact, and Opportunity, 
     * verifies Record Type logic, and ensures deletion of the original Lead.
     */
    @isTest
    static void testConvertLead_CreateNewRecords() {
        Lead__c leadToConvert = [SELECT Id FROM Lead__c LIMIT 1];
        
        // Build the payload Map simulating the data sent from the LWC frontend
        Map<String, Object> payload = new Map<String, Object>();
        payload.put('leadId', String.valueOf(leadToConvert.Id));
        
        payload.put('createAccount', true);
        payload.put('accountDetails', new Map<Object, Object>{
            'name' => 'Newly Created Account'
        });
        
        payload.put('createContact', true);
        payload.put('contactDetails', new Map<Object, Object>{
            'firstName' => 'Jane',
            'lastName'  => 'Smith'
        });
        
        payload.put('createOpportunity', true);
        payload.put('opportunityDetails', new Map<Object, Object>{
            'name'      => 'New Deal',
            'stageName' => 'Indent Pending',
            'closeDate' => String.valueOf(Date.today().addDays(30))
        });
        
        System.debug(payload);

        Test.startTest();
        Map<String, Object> response = LeadConverterController.convertLead(payload);
        Test.stopTest();
        
        System.debug(response);

        // 1. Verify a successful response was returned
        Assert.areEqual(true, response.get('success'), 'The conversion process should report success');

        // 2. Verify Records Were Created
        Integer accCount = [SELECT COUNT() FROM Account WHERE Name = 'Newly Created Account'];
        Integer conCount = [SELECT COUNT() FROM Contact WHERE LastName = 'Smith'];
        
        Assert.areEqual(1, accCount, 'One new Account should have been inserted');
        Assert.areEqual(1, conCount, 'One new Contact should have been inserted');

        // 3. Verify Opportunity Creation and Correct Record Type Assignment
        Opportunity__c createdOpp = [SELECT Id, Name, RecordTypeId FROM Opportunity__c WHERE Name = 'New Deal' LIMIT 1];
        Id expectedPreSalesRtId = Schema.SObjectType.Opportunity__c.getRecordTypeInfosByDeveloperName().get('Pre_Sales').getRecordTypeId();
        
        Assert.isNotNull(createdOpp, 'One new Opportunity__c should have been inserted');
        Assert.areEqual(expectedPreSalesRtId, createdOpp.RecordTypeId, 'Opportunity should be assigned to the Pre_Sales Record Type');

        // 4. Verify the core requirement: The original Lead was deleted
        Integer leadCount = [SELECT COUNT() FROM Lead__c WHERE Id = :leadToConvert.Id];
        Assert.areEqual(0, leadCount, 'The custom Lead__c record should be deleted after a successful conversion');
    }

    /**
     * @description Tests the path where the user selects an EXISTING Account and Contact 
     * instead of creating new ones, verifying the Lead is still deleted.
     */
    @isTest
    static void testConvertLead_UseExistingRecords() {
        Lead__c leadToConvert = [SELECT Id FROM Lead__c LIMIT 1];
        Account existingAcc   = [SELECT Id FROM Account LIMIT 1];
        Contact existingCon   = [SELECT Id FROM Contact LIMIT 1];
        
        Map<String, Object> payload = new Map<String, Object>();
        payload.put('leadId', String.valueOf(leadToConvert.Id));
        
        payload.put('createAccount', false);
        payload.put('existingAccountId', String.valueOf(existingAcc.Id));
        
        payload.put('createContact', false);
        payload.put('existingContactId', String.valueOf(existingCon.Id));
        
        payload.put('createOpportunity', false);

        Test.startTest();
        Map<String, Object> response = LeadConverterController.convertLead(payload);
        Test.stopTest();

        Assert.areEqual(true, response.get('success'), 'Conversion utilizing existing records should succeed');
        
        Integer leadCount = [SELECT COUNT() FROM Lead__c WHERE Id = :leadToConvert.Id];
        Assert.areEqual(0, leadCount, 'The custom Lead__c should be deleted even when merging into existing records');
    }

    /**
     * @description Tests the transaction rollback mechanism. Forces an error to ensure 
     * bad data doesn't partially convert the lead or delete the record.
     */
    @isTest
    static void testConvertLead_ErrorRollback() {
        Lead__c leadToConvert = [SELECT Id FROM Lead__c LIMIT 1];
        
        Map<String, Object> payload = new Map<String, Object>();
        payload.put('leadId', String.valueOf(leadToConvert.Id));
        payload.put('createAccount', true);
        payload.put('accountDetails', new Map<Object, Object>{ 
            // Intentionally empty to cause a DML exception on Account insert
        });
        
        Test.startTest();
        Map<String, Object> response = LeadConverterController.convertLead(payload);
        Test.stopTest();

        Assert.areEqual(false, response.get('success'), 'The conversion should fail due to missing Account name');
        Assert.isNotNull(response.get('error'), 'An error message should be populated in the response');

        Integer leadCount = [SELECT COUNT() FROM Lead__c WHERE Id = :leadToConvert.Id];
        Assert.areEqual(1, leadCount, 'The custom Lead__c should NOT be deleted because the transaction rolled back');
    }
}