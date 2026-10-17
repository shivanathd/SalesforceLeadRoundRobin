@isTest
private class RoundRobinServiceTest {

    @TestSetup
    static void setup() {
        RoundRobinTestData.createTeam();
    }

    static Map<Id, Lead> reload(List<Lead> leads) {
        return new Map<Id, Lead>([
            SELECT Id, OwnerId, Route_to_Round_Robin__c, Assigned_Through_Round_Robin__c, Round_Robin_Queue__c,
                   Round_Robin_Source__c, Round_Robin_Triggered_By__c, Round_Robin_Assignment_DateTime__c,
                   Last_Round_Robin_Error__c, Last_Round_Robin_Attempt__c
            FROM Lead WHERE Id IN :leads
        ]);
    }

    static Lead reload(Lead l) {
        return reload(new List<Lead>{ l }).get(l.Id);
    }

    static Map<Id, Integer> countByOwner(List<Lead> leads) {
        Map<Id, Integer> counts = new Map<Id, Integer>();
        for (Lead l : reload(leads).values()) {
            counts.put(l.OwnerId, (counts.containsKey(l.OwnerId) ? counts.get(l.OwnerId) : 0) + 1);
        }
        return counts;
    }

    static Round_Robin_Assignment_State__c stateRow(String key) {
        List<Round_Robin_Assignment_State__c> rows = [
            SELECT Next_Index__c, Total_Assignments__c, Last_Assigned_User__c
            FROM Round_Robin_Assignment_State__c WHERE Queue_Key__c = :key
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    static void assertNotRouted(Lead l, String expectedError) {
        Lead saved = reload(l);
        System.assertEquals(UserInfo.getUserId(), saved.OwnerId, 'Owner must stay with the creator');
        System.assertEquals(false, saved.Route_to_Round_Robin__c, 'Box is unticked even on failure');
        System.assertEquals(false, saved.Assigned_Through_Round_Robin__c);
        System.assertNotEquals(null, saved.Last_Round_Robin_Attempt__c);
        System.assert(saved.Last_Round_Robin_Error__c != null && saved.Last_Round_Robin_Error__c.startsWith(expectedError),
            'Unexpected error: ' + saved.Last_Round_Robin_Error__c);
    }

    @isTest
    static void singleLeadGoesToFirstRepOfFirstQueue() {
        RoundRobinTestData.useDefaultConfigs();
        List<User> reps = RoundRobinTestData.reps();
        Lead l = RoundRobinTestData.lead('Single', true);

        Test.startTest();
        insert l;
        Test.stopTest();

        Lead saved = reload(l);
        System.assertEquals(reps[0].Id, saved.OwnerId);
        System.assertEquals(RoundRobinTestData.QUEUE_A, saved.Round_Robin_Queue__c);
        System.assertEquals(false, saved.Route_to_Round_Robin__c);
        System.assertEquals(true, saved.Assigned_Through_Round_Robin__c);
        System.assertEquals(null, saved.Last_Round_Robin_Error__c);
        System.assertEquals(UserInfo.getUserId(), saved.Round_Robin_Triggered_By__c);
        System.assertNotEquals(null, saved.Round_Robin_Source__c);
        System.assertEquals(1, stateRow(RoundRobinTestData.QUEUE_A).Next_Index__c);
        System.assertEquals(1, stateRow(RoundRobinTestData.QUEUE_A).Total_Assignments__c);
        System.assertEquals(1, stateRow(RoundRobinService.GLOBAL_KEY).Next_Index__c, 'Next lead goes to queue B');
    }

    @isTest
    static void bulkInsertOf200SplitsEvenlyAcrossQueuesAndReps() {
        // Regression: v1 keyed results by Lead Id, which is null on insert, so every lead in a bulk
        // insert shared one result.
        RoundRobinTestData.useDefaultConfigs();
        List<Lead> leads = RoundRobinTestData.leads(200, true);

        Test.startTest();
        insert leads;
        Test.stopTest();

        Map<Id, Integer> counts = countByOwner(leads);
        System.assertEquals(4, counts.size(), 'All four reps get leads: ' + counts);
        for (User rep : RoundRobinTestData.reps()) {
            System.assertEquals(50, counts.get(rep.Id), 'Each rep gets exactly a quarter');
        }
        for (Lead l : reload(leads).values()) {
            System.assertEquals(null, l.Last_Round_Robin_Error__c);
            System.assertEquals(true, l.Assigned_Through_Round_Robin__c);
        }
        System.assertEquals(100, stateRow(RoundRobinTestData.QUEUE_A).Total_Assignments__c);
        System.assertEquals(100, stateRow(RoundRobinTestData.QUEUE_B).Total_Assignments__c);
    }

    @isTest
    static void tickingOnUpdateRoutesAndOtherEditsDoNot() {
        RoundRobinTestData.useDefaultConfigs();
        List<User> reps = RoundRobinTestData.reps();
        Lead l = RoundRobinTestData.lead('Later', false);
        insert l;
        System.assertEquals(UserInfo.getUserId(), reload(l).OwnerId, 'Unticked lead is not routed');

        Test.startTest();
        update new Lead(Id = l.Id, Route_to_Round_Robin__c = true);
        Id firstOwner = reload(l).OwnerId;
        update new Lead(Id = l.Id, Company = 'Renamed');
        Id afterEdit = reload(l).OwnerId;
        update new Lead(Id = l.Id, Route_to_Round_Robin__c = true);
        Id afterReroute = reload(l).OwnerId;
        Test.stopTest();

        System.assertEquals(reps[0].Id, firstOwner);
        System.assertEquals(firstOwner, afterEdit, 'An unrelated edit must not re-route');
        System.assertEquals(reps[2].Id, afterReroute, 'Re-ticking routes again, to the next queue');
    }

    @isTest
    static void inactiveRepIsNeverAssigned() {
        RoundRobinTestData.useQueueAOnly();
        List<User> reps = RoundRobinTestData.reps();
        RoundRobinTestData.asAdmin(new List<User>{ new User(Id = reps[0].Id, IsActive = false) }, null);
        List<Lead> leads = RoundRobinTestData.leads(4, true);

        Test.startTest();
        insert leads;
        Test.stopTest();

        System.assertEquals(new Map<Id, Integer>{ reps[1].Id => 4 }, countByOwner(leads));
    }

    @isTest
    static void unavailableRepIsSkippedButKeepsTheirPlace() {
        RoundRobinTestData.useQueueAOnly();
        List<User> reps = RoundRobinTestData.reps();
        RoundRobinTestData.asAdmin(new List<User>{ new User(Id = reps[0].Id, Round_Robin_Available__c = false) }, null);
        List<Lead> leads = RoundRobinTestData.leads(3, true);

        Test.startTest();
        insert leads;
        Test.stopTest();

        System.assertEquals(new Map<Id, Integer>{ reps[1].Id => 3 }, countByOwner(leads));
    }

    @isTest
    static void everyoneUnavailableRecordsErrorAndStillSavesTheLead() {
        RoundRobinTestData.useQueueAOnly();
        List<User> reps = RoundRobinTestData.reps();
        RoundRobinTestData.asAdmin(new List<User>{
            new User(Id = reps[0].Id, Round_Robin_Available__c = false),
            new User(Id = reps[1].Id, Round_Robin_Available__c = false)
        }, null);
        Lead l = RoundRobinTestData.lead('Web form', true);

        Test.startTest();
        insert l;
        Test.stopTest();

        assertNotRouted(l, 'No eligible rep');
    }

    @isTest
    static void weightTwoRepGetsTwiceAsMany() {
        RoundRobinTestData.useQueueAOnly();
        List<User> reps = RoundRobinTestData.reps();
        RoundRobinTestData.asAdmin(new List<User>{ new User(Id = reps[0].Id, Round_Robin_Weight__c = 2) }, null);
        List<Lead> leads = RoundRobinTestData.leads(6, true);

        Test.startTest();
        insert leads;
        Test.stopTest();

        System.assertEquals(new Map<Id, Integer>{ reps[0].Id => 4, reps[1].Id => 2 }, countByOwner(leads));
    }

    @isTest
    static void capacityCapSkipsFullRepsThenReportsWhenEveryoneIsFull() {
        Round_Robin_Queue_Config__mdt capped = RoundRobinTestData.with(
            RoundRobinTestData.config(RoundRobinTestData.QUEUE_A, 1), 'Max_Open_Leads__c', 1);
        RoundRobinTestData.useConfigs(new List<Round_Robin_Queue_Config__mdt>{ capped });
        List<User> reps = RoundRobinTestData.reps();
        Lead existing = RoundRobinTestData.lead('Already open', false);
        existing.OwnerId = reps[0].Id;
        insert existing;

        Lead first = RoundRobinTestData.lead('First', true);
        Lead second = RoundRobinTestData.lead('Second', true);
        Test.startTest();
        insert new List<Lead>{ first, second };
        Test.stopTest();

        System.assertEquals(reps[1].Id, reload(first).OwnerId, 'Rep 1 is at the cap, so rep 2 takes it');
        assertNotRouted(second, 'No eligible rep');
    }

    @isTest
    static void matchRuleSendsLeadsOnlyToMatchingQueue() {
        Round_Robin_Queue_Config__mdt india = RoundRobinTestData.matching(RoundRobinTestData.QUEUE_A, 1, 'Country', 'India, IN');
        RoundRobinTestData.useConfigs(new List<Round_Robin_Queue_Config__mdt>{ india, RoundRobinTestData.config(RoundRobinTestData.QUEUE_B, 2) });
        Lead fromIndia = RoundRobinTestData.lead('Kochi', true);
        fromIndia.Country = 'india';
        Lead fromUs1 = RoundRobinTestData.lead('Austin', true);
        fromUs1.Country = 'United States';
        Lead fromUs2 = RoundRobinTestData.lead('Boston', true);
        fromUs2.Country = 'United States';

        Test.startTest();
        insert new List<Lead>{ fromIndia, fromUs1, fromUs2 };
        Test.stopTest();

        System.assertEquals(RoundRobinTestData.QUEUE_A, reload(fromIndia).Round_Robin_Queue__c, 'Case-insensitive match');
        System.assertEquals(RoundRobinTestData.QUEUE_B, reload(fromUs1).Round_Robin_Queue__c);
        System.assertEquals(RoundRobinTestData.QUEUE_B, reload(fromUs2).Round_Robin_Queue__c, 'Skips queue A even when it is A\'s turn');
    }

    @isTest
    static void leadMatchingNoQueueRecordsError() {
        Round_Robin_Queue_Config__mdt india = RoundRobinTestData.matching(RoundRobinTestData.QUEUE_A, 1, 'Country', 'India');
        RoundRobinTestData.useConfigs(new List<Round_Robin_Queue_Config__mdt>{ india });
        Lead l = RoundRobinTestData.lead('No country', true);

        Test.startTest();
        insert l;
        Test.stopTest();

        assertNotRouted(l, 'No active queue with members matches this lead');
    }

    @isTest
    static void noActiveConfigRecordsError() {
        RoundRobinTestData.useConfigs(new List<Round_Robin_Queue_Config__mdt>{
            RoundRobinTestData.with(RoundRobinTestData.config(RoundRobinTestData.QUEUE_A, 1), 'Is_Active__c', false)
        });
        Lead l = RoundRobinTestData.lead('Unconfigured', true);

        Test.startTest();
        insert l;
        Test.stopTest();

        assertNotRouted(l, 'No active round robin queues are configured.');
    }

    @isTest
    static void unknownQueueNameIsSkipped() {
        RoundRobinTestData.useConfigs(new List<Round_Robin_Queue_Config__mdt>{
            RoundRobinTestData.config('Does_Not_Exist', 1), RoundRobinTestData.config(RoundRobinTestData.QUEUE_A, 2)
        });
        Lead l = RoundRobinTestData.lead('Typo in config', true);

        Test.startTest();
        insert l;
        Test.stopTest();

        System.assertEquals(RoundRobinTestData.QUEUE_A, reload(l).Round_Robin_Queue__c);
    }

    @isTest
    static void rotationContinuesAcrossSeparateSaves() {
        RoundRobinTestData.useDefaultConfigs();
        List<User> reps = RoundRobinTestData.reps();
        List<Lead> leads = RoundRobinTestData.leads(3, true);

        Test.startTest();
        for (Lead l : leads) {
            insert l;
        }
        Test.stopTest();

        System.assertEquals(reps[0].Id, reload(leads[0]).OwnerId);
        System.assertEquals(reps[2].Id, reload(leads[1]).OwnerId);
        System.assertEquals(reps[1].Id, reload(leads[2]).OwnerId);
        System.assertEquals(3, [SELECT COUNT() FROM Round_Robin_Assignment_State__c], 'One row per queue plus global, no duplicates');
    }

    @isTest
    static void resetStartsEveryQueueOverForAdmins() {
        RoundRobinTestData.useDefaultConfigs();
        List<User> reps = RoundRobinTestData.reps();
        RoundRobinTestData.grant('Round_Robin_Admin');
        insert RoundRobinTestData.leads(3, true);

        Integer cleared;
        Lead next = RoundRobinTestData.lead('After reset', true);
        Test.startTest();
        System.runAs(new User(Id = UserInfo.getUserId())) { // picks up the newly assigned permission
            cleared = RoundRobinService.resetRotation();
        }
        insert next;
        Test.stopTest();

        System.assertEquals(3, cleared);
        System.assertEquals(reps[0].Id, reload(next).OwnerId, 'After a reset the first rep of the first queue is next');
    }

    @isTest
    static void resetIsRefusedWithoutAdminPermission() {
        User rep = RoundRobinTestData.reps()[0];
        Boolean refused = false;
        Test.startTest();
        System.runAs(rep) {
            try {
                RoundRobinService.resetRotation();
            } catch (NoAccessException e) {
                refused = true;
            }
        }
        Test.stopTest();
        System.assert(refused, 'Reps must not be able to reset the rotation');
    }

    @isTest
    static void lowPrivilegeUserSavingALeadStillRoutes() {
        // v1 checked the saving user's field permissions and rejected the save. Integration users
        // and Site guests rarely have them.
        RoundRobinTestData.useDefaultConfigs();
        User rep = RoundRobinTestData.reps()[3];
        Lead l = RoundRobinTestData.lead('Saved by a rep', true);

        Test.startTest();
        System.runAs(rep) {
            insert l;
        }
        Test.stopTest();

        Lead saved = reload(l);
        System.assertEquals(true, saved.Assigned_Through_Round_Robin__c);
        System.assertEquals(RoundRobinTestData.reps()[0].Id, saved.OwnerId);
    }

    @isTest
    static void partialSuccessInsertCountsOnlySavedLeads() {
        // With allOrNone=false Salesforce rolls back and re-runs the trigger for the good records.
        // Rotation state must reflect only the leads that were actually saved.
        RoundRobinTestData.useDefaultConfigs();
        List<User> reps = RoundRobinTestData.reps();
        Lead good1 = RoundRobinTestData.lead('Good 1', true);
        Lead bad = new Lead(Company = 'No last name', Route_to_Round_Robin__c = true);
        Lead good2 = RoundRobinTestData.lead('Good 2', true);

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(new List<Lead>{ good1, bad, good2 }, false);
        Test.stopTest();

        System.assert(results[0].isSuccess() && !results[1].isSuccess() && results[2].isSuccess());
        System.assertEquals(reps[0].Id, reload(good1).OwnerId);
        System.assertEquals(reps[2].Id, reload(good2).OwnerId);
        System.assertEquals(1, stateRow(RoundRobinTestData.QUEUE_A).Total_Assignments__c);
        System.assertEquals(1, stateRow(RoundRobinTestData.QUEUE_B).Total_Assignments__c);
    }

    @isTest
    static void unexpectedFailureNeverBlocksTheSave() {
        RoundRobinTestData.useDefaultConfigs();
        RoundRobinService.failForTest = true;
        Lead l = RoundRobinTestData.lead('Unlucky', true);

        Test.startTest();
        insert l;
        Test.stopTest();

        assertNotRouted(l, 'Routing failed (System.DmlException)');
        System.assertEquals(0, [SELECT COUNT() FROM Round_Robin_Assignment_State__c], 'Nothing written');
    }

    @isTest
    static void notificationsAreSentWithoutAffectingTheSave() {
        Round_Robin_Queue_Config__mdt notifying = RoundRobinTestData.with(
            RoundRobinTestData.config(RoundRobinTestData.QUEUE_A, 1), 'Notify_Assignee__c', true);
        RoundRobinTestData.useConfigs(new List<Round_Robin_Queue_Config__mdt>{ notifying });
        Lead single = RoundRobinTestData.lead('Solo', true);
        List<Lead> batch = RoundRobinTestData.leads(5, true);

        Test.startTest();
        insert single;
        insert batch;
        Test.stopTest();

        System.assertEquals(true, reload(single).Assigned_Through_Round_Robin__c);
        for (Lead l : reload(batch).values()) {
            System.assertEquals(true, l.Assigned_Through_Round_Robin__c);
        }
    }

    @isTest
    static void weightIsClampedBetweenOneAndTen() {
        RoundRobinTestData.useQueueAOnly();
        List<User> reps = RoundRobinTestData.reps();
        RoundRobinTestData.asAdmin(new List<User>{
            new User(Id = reps[0].Id, Round_Robin_Weight__c = 50),
            new User(Id = reps[1].Id, Round_Robin_Weight__c = 0)
        }, null);
        List<Lead> leads = RoundRobinTestData.leads(11, true);

        Test.startTest();
        insert leads;
        Test.stopTest();

        System.assertEquals(new Map<Id, Integer>{ reps[0].Id => RoundRobinService.MAX_WEIGHT, reps[1].Id => 1 }, countByOwner(leads));
    }
}
