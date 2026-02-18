@isTest
public class IndiaMartSchedulerTest {
    
    @isTest
    static void testScheduler() {
        Test.setMock(HttpCalloutMock.class, new IndiaMartMock(200, 'OK', '{}'));
        
        Test.startTest();
        String cronExp = '0 0 0 15 3 ? 2099';
        String jobId = System.schedule('Test IndiaMart Sync', cronExp, new IndiaMartScheduler());
        Test.stopTest();
        
        // Verify job is scheduled
        CronTrigger ct = [SELECT Id, CronExpression, TimesTriggered FROM CronTrigger WHERE Id = :jobId];
        System.assertEquals(cronExp, ct.CronExpression);
        System.assertEquals(0, ct.TimesTriggered);
    }
}