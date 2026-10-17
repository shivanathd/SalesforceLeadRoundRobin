@isTest
private class RoundRobinActionsTest {

    @TestSetup
    static void setup() {
        RoundRobinTestData.createTeam();
    }

    static RoundRobinActions.Request request(Id leadId) {
        RoundRobinActions.Request r = new RoundRobinActions.Request();
        r.leadId = leadId;
        return r;
    }

    @isTest
    static void flowActionRoutesLeadsAndReportsEachOutcome() {
        RoundRobinTestData.useConfigs(new List<Round_Robin_Queue_Config__mdt>{
            RoundRobinTestData.matching(RoundRobinTestData.QUEUE_A, 1, 'LeadSource', 'Web')
        });
        Lead web = RoundRobinTestData.lead('From web', false);
        web.LeadSource = 'Web';
        Lead phone = RoundRobinTestData.lead('From phone', false);
        phone.LeadSource = 'Phone Inquiry';
        insert new List<Lead>{ web, phone };
        Lead deleted = RoundRobinTestData.lead('Deleted', false);
        insert deleted;
        delete deleted;

        RoundRobinTestData.grant('Round_Robin_User');
        List<RoundRobinActions.Result> results;
        Test.startTest();
        System.runAs(new User(Id = UserInfo.getUserId())) { // runs in user mode with the new permission set
            results = RoundRobinActions.routeLeads(new List<RoundRobinActions.Request>{
                request(web.Id), request(phone.Id), request(deleted.Id)
            });
        }
        Test.stopTest();

        System.assertEquals(true, results[0].routed);
        System.assertEquals(RoundRobinTestData.reps()[0].Id, results[0].ownerId);
        System.assertEquals(RoundRobinTestData.QUEUE_A, results[0].queue);
        System.assertEquals(null, results[0].error);

        System.assertEquals(false, results[1].routed);
        System.assert(results[1].error.startsWith('No active queue'), results[1].error);

        System.assertEquals(false, results[2].routed, 'A deleted lead cannot be routed');
        System.assertNotEquals(null, results[2].error);
    }

    @isTest
    static void flowActionRespectsTheUsersFieldAccess() {
        RoundRobinTestData.useDefaultConfigs();
        Lead l = RoundRobinTestData.lead('No permission', false);
        insert l;
        User rep = RoundRobinTestData.reps()[0];
        List<RoundRobinActions.Result> results;
        Test.startTest();
        System.runAs(rep) { // Standard User without the Round Robin User permission set
            results = RoundRobinActions.routeLeads(new List<RoundRobinActions.Request>{ request(l.Id) });
        }
        Test.stopTest();
        System.assertEquals(false, results[0].routed);
        System.assert(results[0].error.contains('Route_to_Round_Robin__c'), 'Names the field the user lacks: ' + results[0].error);
        System.assertEquals(UserInfo.getUserId(), [SELECT OwnerId FROM Lead WHERE Id = :l.Id].OwnerId, 'Nothing was routed');
    }

    @isTest
    static void resetActionClearsRotationForAdmins() {
        RoundRobinTestData.useDefaultConfigs();
        RoundRobinTestData.grant('Round_Robin_Admin');
        insert RoundRobinTestData.lead('Before reset', true);

        List<Integer> cleared;
        Test.startTest();
        System.runAs(new User(Id = UserInfo.getUserId())) { // picks up the newly assigned permission
            cleared = RoundRobinResetAction.reset(new List<String>{ '' });
        }
        Test.stopTest();

        System.assertEquals(2, cleared[0], 'Global row plus queue A');
        System.assertEquals(0, [SELECT COUNT() FROM Round_Robin_Assignment_State__c]);
    }

    @isTest
    static void setupCheckReportsHealthyAndBrokenQueues() {
        RoundRobinTestData.useConfigs(new List<Round_Robin_Queue_Config__mdt>{
            RoundRobinTestData.with(RoundRobinTestData.config(RoundRobinTestData.QUEUE_A, 1), 'Max_Open_Leads__c', 25),
            RoundRobinTestData.config('Missing_Queue', 2),
            RoundRobinTestData.matching(RoundRobinTestData.QUEUE_B, 3, 'Not_A_Field__c', 'x')
        });

        Test.startTest();
        String report = RoundRobinSetupCheck.run();
        Test.stopTest();

        System.assert(report.contains(RoundRobinTestData.QUEUE_A + ' (order 1): 2 active reps, 2 available; cap 25'), report);
        System.assert(report.contains('PROBLEM: no queue with API name Missing_Queue'), report);
        System.assert(report.contains('Match Field Not_A_Field__c is not a Lead field'), report);
        System.assert(report.contains('2 problem(s) found.'), report);
    }

    @isTest
    static void setupCheckWithNothingConfigured() {
        RoundRobinTestData.useConfigs(new List<Round_Robin_Queue_Config__mdt>());
        System.assert(RoundRobinSetupCheck.run().contains('no active Round Robin Queue Config records'));
    }
}
