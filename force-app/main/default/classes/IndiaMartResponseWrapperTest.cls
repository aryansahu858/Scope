@isTest
public class IndiaMartResponseWrapperTest {
    @isTest
    static void testParse() {
        String json = '{' +
            '"CODE": 200,' +
            '"STATUS": "SUCCESS",' +
            '"TOTAL_RECORDS": 1,' +
            '"RESPONSE": [{' +
                '"UNIQUE_QUERY_ID": "123",' +
                '"SENDER_NAME": "Test"' +
            '}]' +
        '}';
        
        IndiaMartResponseWrapper obj = (IndiaMartResponseWrapper) System.JSON.deserialize(json, IndiaMartResponseWrapper.class);
        System.assertEquals(200, obj.CODE);
        System.assertEquals(1, obj.RESPONSE.size());
        System.assertEquals('123', obj.RESPONSE[0].UNIQUE_QUERY_ID);
    }
}