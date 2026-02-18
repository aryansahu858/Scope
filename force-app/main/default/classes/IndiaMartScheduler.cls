global class IndiaMartScheduler implements Schedulable {
    global void execute(SchedulableContext sc) {
        // We use Queueable to bypass the "Callouts not allowed from Schedulable" limit
        System.enqueueJob(new IndiaMartService());
    }
}


/**
// Schedule 4 jobs to run every 15 minutes
System.schedule('IndiaMART Sync :00', '0 0 * * * ?', new IndiaMartScheduler());
System.schedule('IndiaMART Sync :15', '0 15 * * * ?', new IndiaMartScheduler());
System.schedule('IndiaMART Sync :30', '0 30 * * * ?', new IndiaMartScheduler());
System.schedule('IndiaMART Sync :45', '0 45 * * * ?', new IndiaMartScheduler());
*/