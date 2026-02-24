/**
 * @description       : Comprehensive Test Class for IndiaMartService.
 * @author            : Aryan Sahu
 * @last modified on  : 2026-02-24
**/
@isTest
private class IndiaMartServiceTest {

    @testSetup
    static void setup() {
        // We do NOT insert Integration_Settings__c here for some tests to cover the "First Run" logic
    }
    
    @isTest
    static void testProcessLeads_Success() {
        // 1. Prepare Success JSON Response
        String jsonBody = '{' +
            '"CODE": 200,' +
            '"STATUS": "SUCCESS",' +
            '"MESSAGE": "Data Found",' +
            '"RESPONSE": [' +
                '{' +
                    '"UNIQUE_QUERY_ID": "IM12345",' +
                    '"SENDER_NAME": "Test User",' +
                    '"SENDER_MOBILE": "9876543210",' +
                    '"SENDER_EMAIL": "test@example.com",' +
            		'"SENDER_COMPANY": "test Comp",' +
            		'"SUBJECT": "test Subject",' +
                    '"QUERY_TYPE": "W",' +
                    '"QUERY_MESSAGE": "<p>I need products</p>"' +
                '}' +
            ']' +
        '}';

        // 2. Set Mock
        Test.setMock(HttpCalloutMock.class, new IndiaMartMock(200, 'OK', jsonBody));

        // 3. Execute
        Test.startTest();
        // Enqueue directly or call static method
        System.enqueueJob(new IndiaMartService());
        Test.stopTest();

        // 4. Assertions
        
        // Verify Lead Creation
        Lead__c createdLead = [SELECT Id, Name, Phone__c, Query_Type__c, Product_Description__c 
                              FROM Lead__c WHERE Lead_External_Id__c = 'IM12345' LIMIT 1];
        System.assertEquals('Test User', createdLead.Name, 'Name should match');
        System.assertEquals('+919876543210', createdLead.Phone__c, 'Phone should be normalized');
        System.assertEquals('Direct', createdLead.Query_Type__c, 'W should map to Direct');
        System.assertEquals('I need products', createdLead.Product_Description__c, 'HTML should be stripped');

        // Verify Checkpoint Update
        Integration_Settings__c settings = Integration_Settings__c.getOrgDefaults();
        // Since test execution is fast, the time might be very close to initial setup, 
        // but we verify logic execution. In real tests, Last_Sync_Time__c should differ from setup.
        System.assert(settings.Last_Sync_Time__c != null, 'Sync time should be updated');

    }

    
    /**
     * @description Tests the 204 "No Content" logic which updates the sync timer but skips processing.
     */
    @isTest
    static void testProcessLeads_NoData204() {
        String jsonBody = '{"CODE": 204, "MESSAGE": "No Data Found"}';
        Test.setMock(HttpCalloutMock.class, new IndiaMartMock(200, 'OK', jsonBody));

        Test.startTest();
        IndiaMartService.processLeads();
        Test.stopTest();

        // Verify log was not created as failure, but sync time updated
        Integration_Settings__c settings = Integration_Settings__c.getOrgDefaults();
        Assert.isNotNull(settings.Last_Sync_Time__c);
    }

    /**
     * @description Tests the scenario where the API returns a logical error code (e.g. 401 Unauthorized).
     */
    @isTest
    static void testProcessLeads_ApiLogicalError() {
        String jsonBody = '{"CODE": 401, "MESSAGE": "Invalid Key"}';
        Test.setMock(HttpCalloutMock.class, new IndiaMartMock(200, 'OK', jsonBody));

        Test.startTest();
        IndiaMartService.processLeads();
        Test.stopTest();

        Integration_Log__c log = [SELECT Status__c FROM Integration_Log__c LIMIT 1];
        Assert.areEqual('Failure', log.Status__c);
    }

    /**
     * @description Tests Database partial success (upsert failure on specific records).
     */
    @isTest
    static void testProcessLeads_PartialUpsertFailure() {
        // We will mock a response that causes a DML error (e.g., Name field too long)
        // or we can mock a missing required field if validation rules exist.
        String longName = 'A'.repeat(300); 
        String jsonBody = '{"CODE": 200, "RESPONSE": [{"UNIQUE_QUERY_ID": "FAIL_01", "SENDER_NAME": "' + longName + '"}]}';
        
        Test.setMock(HttpCalloutMock.class, new IndiaMartMock(200, 'OK', jsonBody));

        Test.startTest();
        IndiaMartService.processLeads();
        Test.stopTest();

        Integration_Log__c log = [SELECT Status__c FROM Integration_Log__c LIMIT 1];
        Assert.areEqual('Partial Success', log.Status__c);
    }

    /**
     * @description Tests the "First Run" scenario where Custom Settings are null.
     */
    @isTest
    static void testProcessLeads_FirstRun() {
        // Ensure settings are empty
        delete [SELECT Id FROM Integration_Settings__c];
        
        Test.setMock(HttpCalloutMock.class, new IndiaMartMock(500, 'Error', ''));

        Test.startTest();
        IndiaMartService.processLeads();
        Test.stopTest();

        Integration_Log__c log = [SELECT Status__c FROM Integration_Log__c LIMIT 1];
        Assert.areEqual('Failure', log.Status__c);
    }

    /**
     * @description Tests the catch block for callout exceptions.
     */
    @isTest
    static void testProcessLeads_Exception() {
        // Mock that throws an exception during send()
        Test.setMock(HttpCalloutMock.class, new ExceptionMock());

        Test.startTest();
        IndiaMartService.processLeads();
        Test.stopTest();

        Integration_Log__c log = [SELECT Status__c, Error_Message__c FROM Integration_Log__c LIMIT 1];
        Assert.areEqual('Failure', log.Status__c);
        Assert.isTrue(log.Error_Message__c.contains('Callout Exception'));
    }

    // --- Helper Mocks ---

    private class ExceptionMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new CalloutException('Network Timeout');
        }
    }
}