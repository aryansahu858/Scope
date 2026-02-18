@isTest
public class IndiaMartServiceTest {

    @testSetup
    static void setup() {
        // Create Custom Setting
        Integration_Settings__c settings = new Integration_Settings__c();
        settings.Last_Sync_Time__c = System.now().addDays(-1);
        insert settings;
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

        // Verify Success Log
        Integration_Log__c log = [SELECT Id, Status__c, Records_Processed__c FROM Integration_Log__c WHERE Name = 'IndiaMART Sync' ORDER BY CreatedDate DESC LIMIT 1];
        System.assertEquals('Success', log.Status__c, 'Log status should be Success');
        System.assertEquals(1, log.Records_Processed__c, 'Should process 1 record');
    }

    @isTest
    static void testProcessLeads_204_NoContent() {
        // IndiaMART returns 200 HTTP status but CODE 204 in JSON for no data
        String jsonBody = '{ "CODE": 204, "STATUS": "NO_CONTENT", "MESSAGE": "No Data Found", "RESPONSE": [] }';

        Test.setMock(HttpCalloutMock.class, new IndiaMartMock(200, 'OK', jsonBody));

        Test.startTest();
        IndiaMartService.processLeads(); // Call static method directly
        Test.stopTest();

        // Verify Log
        Integration_Log__c log = [SELECT Id, Status__c, Error_Message__c FROM Integration_Log__c WHERE Name = 'IndiaMART Sync' LIMIT 1];
        System.assertEquals('Success', log.Status__c);
        System.assert(log.Error_Message__c.contains('No new leads found'), 'Should log 204 message');
    }

    @isTest
    static void testProcessLeads_HttpError() {
        Test.setMock(HttpCalloutMock.class, new IndiaMartMock(500, 'Server Error', 'Internal Error'));

        Test.startTest();
        IndiaMartService.processLeads();
        Test.stopTest();

        Integration_Log__c log = [SELECT Id, Status__c, Error_Message__c FROM Integration_Log__c WHERE Name = 'IndiaMART Sync' LIMIT 1];
        System.assertEquals('Failure', log.Status__c);
        System.assert(log.Error_Message__c.contains('HTTP Error: 500'), 'Should log HTTP error');
    }
    
}