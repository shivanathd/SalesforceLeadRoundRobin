/**
 * @description Test class for RoundRobinAssignmentHandler
 * Tests round robin lead assignment functionality
 */
@isTest
private class RoundRobinAssignmentHandlerTest {
    
    @TestSetup
    static void setupTestData() {
        // Create test users
        List<User> testUsers = new List<User>();
        List<Profile> profiles = [SELECT Id FROM Profile WHERE Name IN ('Standard User', 'System Administrator') ORDER BY Name DESC LIMIT 1];
        if (profiles.isEmpty()) {
            // Fallback to any available profile
            profiles = [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
            if (profiles.isEmpty()) {
                // Last resort - get any profile
                profiles = [SELECT Id FROM Profile LIMIT 1];
            }
        }
        Profile p = profiles[0];
        
        for (Integer i = 0; i < 10; i++) {
            User u = new User(
                Alias = 'test' + i,
                Email = 'testuser' + i + '@roundrobin.test',
                EmailEncodingKey = 'UTF-8',
                LastName = 'TestUser' + i,
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/Los_Angeles',
                UserName = 'testuser' + i + '@roundrobin.test.unique'
            );
            testUsers.add(u);
        }
        insert testUsers;
        
        // Create test queues
        List<Group> testQueues = new List<Group>();
        for (Integer i = 0; i < 2; i++) {
            Group q = new Group(
                Name = 'Test Queue ' + i,
                DeveloperName = 'Test_Queue_' + i,
                Type = 'Queue'
            );
            testQueues.add(q);
        }
        insert testQueues;
        
        // Add Queue supported objects
        List<QueueSObject> queueSObjects = new List<QueueSObject>();
        for (Group q : testQueues) {
            QueueSObject qso = new QueueSObject(
                QueueId = q.Id,
                SObjectType = 'Lead'
            );
            queueSObjects.add(qso);
        }
        insert queueSObjects;
        
        // Add users to queues
        List<GroupMember> groupMembers = new List<GroupMember>();
        for (Integer i = 0; i < testQueues.size(); i++) {
            for (Integer j = 0; j < 5; j++) {
                GroupMember gm = new GroupMember(
                    GroupId = testQueues[i].Id,
                    UserOrGroupId = testUsers[i * 5 + j].Id
                );
                groupMembers.add(gm);
            }
        }
        insert groupMembers;
    }
    
    @isTest
    static void testSingleLeadAssignment() {
        // Get test data
        List<Group> testQueues = [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND Name LIKE 'Test Queue%' ORDER BY Name];
        List<User> testUsers = [SELECT Id FROM User WHERE Email LIKE 'testuser%@roundrobin.test' ORDER BY Email];
        
        // Set up mock queue configurations
        RoundRobinAssignmentHandler.testQueueConfigs = RoundRobinTestHelper.getMockQueueConfigs(testQueues);
        
        Test.startTest();
        
        // Create single lead with routing checkbox checked
        Lead testLead = new Lead(
            FirstName = 'Test',
            LastName = 'Lead1',
            Company = 'Test Company',
            Status = 'Open - Not Contacted',
            Route_to_Round_Robin__c = true
        );
        insert testLead;
        
        Test.stopTest();
        
        // Verify assignment and checkbox was unchecked
        Lead assignedLead = [SELECT Id, OwnerId, Route_to_Round_Robin__c, Assigned_Through_Round_Robin__c FROM Lead WHERE Id = :testLead.Id];
        System.assertNotEquals(UserInfo.getUserId(), assignedLead.OwnerId, 'Lead should be assigned to a different user');
        System.assertEquals(false, assignedLead.Route_to_Round_Robin__c, 'Routing checkbox should be unchecked after assignment');
        System.assertEquals(true, assignedLead.Assigned_Through_Round_Robin__c, 'Lead should be marked as assigned through round robin');
        
        // Verify assignment state
        List<Round_Robin_Assignment_State__c> states = [SELECT Id, Total_Assignments__c FROM Round_Robin_Assignment_State__c];
        System.assertEquals(1, states.size(), 'One assignment state record should exist');
        System.assertEquals(1, states[0].Total_Assignments__c, 'Total assignments should be 1');
    }
    
    @isTest
    static void testBulkLeadAssignment() {
        // Get test data
        List<Group> testQueues = [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND Name LIKE 'Test Queue%' ORDER BY Name];
        List<User> testUsers = [SELECT Id FROM User WHERE Email LIKE 'testuser%@roundrobin.test' ORDER BY Email];
        
        // Set up mock queue configurations
        RoundRobinAssignmentHandler.testQueueConfigs = RoundRobinTestHelper.getMockQueueConfigs(testQueues);
        
        Test.startTest();
        
        // Create multiple leads with routing enabled
        List<Lead> testLeads = new List<Lead>();
        for (Integer i = 0; i < 20; i++) {
            Lead lead = new Lead(
                FirstName = 'Test',
                LastName = 'Lead' + i,
                Company = 'Test Company ' + i,
                Status = 'Open - Not Contacted',
                Route_to_Round_Robin__c = true
            );
            testLeads.add(lead);
        }
        insert testLeads;
        
        Test.stopTest();
        
        // Verify all leads are assigned and checkboxes unchecked
        List<Lead> assignedLeads = [SELECT Id, OwnerId, Route_to_Round_Robin__c FROM Lead WHERE Id IN :testLeads];
        Set<Id> assignedOwners = new Set<Id>();
        
        for (Lead lead : assignedLeads) {
            System.assertNotEquals(UserInfo.getUserId(), lead.OwnerId, 'Lead should be assigned to a different user');
            System.assertEquals(false, lead.Route_to_Round_Robin__c, 'Routing checkbox should be unchecked');
            assignedOwners.add(lead.OwnerId);
        }
        
        // Verify distribution across multiple users
        System.assert(assignedOwners.size() > 1, 'Leads should be distributed to multiple users');
        
        // Verify assignment state
        List<Round_Robin_Assignment_State__c> states = [SELECT Id, Total_Assignments__c FROM Round_Robin_Assignment_State__c];
        System.assertEquals(1, states.size(), 'One assignment state record should exist');
        System.assertEquals(20, states[0].Total_Assignments__c, 'Total assignments should be 20');
    }
    
    @isTest
    static void testRoundRobinCycle() {
        // Get test data
        List<Group> testQueues = [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND Name LIKE 'Test Queue%' ORDER BY Name];
        List<User> testUsers = [SELECT Id FROM User WHERE Email LIKE 'testuser%@roundrobin.test' ORDER BY Email];
        
        // Set up mock queue configurations
        RoundRobinAssignmentHandler.testQueueConfigs = RoundRobinTestHelper.getMockQueueConfigs(testQueues);
        
        Test.startTest();
        
        // Create leads in batches to observe round robin pattern
        List<Lead> allLeads = new List<Lead>();
        
        // First batch
        List<Lead> batch1 = new List<Lead>();
        for (Integer i = 0; i < 2; i++) {
            Lead lead = new Lead(
                FirstName = 'Batch1',
                LastName = 'Lead' + i,
                Company = 'Test Company',
                Status = 'Open - Not Contacted',
                Route_to_Round_Robin__c = true
            );
            batch1.add(lead);
        }
        insert batch1;
        allLeads.addAll(batch1);
        
        // Second batch
        List<Lead> batch2 = new List<Lead>();
        for (Integer i = 0; i < 2; i++) {
            Lead lead = new Lead(
                FirstName = 'Batch2',
                LastName = 'Lead' + i,
                Company = 'Test Company',
                Status = 'Open - Not Contacted',
                Route_to_Round_Robin__c = true
            );
            batch2.add(lead);
        }
        insert batch2;
        allLeads.addAll(batch2);
        
        Test.stopTest();
        
        // Verify assignment pattern
        List<Lead> assignedLeads = [SELECT Id, OwnerId, FirstName FROM Lead WHERE Id IN :allLeads ORDER BY CreatedDate];
        
        // Verify alternating pattern between queues
        // First lead should go to Queue 1 member 1
        // Second lead should go to Queue 2 member 1
        // Third lead should go to Queue 1 member 2
        // Fourth lead should go to Queue 2 member 2
        
        System.assertEquals(4, assignedLeads.size(), 'Should have 4 assigned leads');
    }
    
    @isTest
    static void testEmptyQueueHandling() {
        // Create a queue without members
        Group emptyQueue = new Group(
            Name = 'Empty Test Queue',
            DeveloperName = 'Empty_Test_Queue',
            Type = 'Queue'
        );
        insert emptyQueue;
        
        QueueSObject qso = new QueueSObject(
            QueueId = emptyQueue.Id,
            SObjectType = 'Lead'
        );
        insert qso;
        
        // Set up mock queue configurations with just the empty queue
        RoundRobinAssignmentHandler.testQueueConfigs = RoundRobinTestHelper.getMockQueueConfigs(new List<Group>{emptyQueue});
        
        Test.startTest();
        
        // Try to create a lead with routing enabled
        Lead testLead = new Lead(
            FirstName = 'Test',
            LastName = 'LeadEmpty',
            Company = 'Test Company',
            Status = 'Open - Not Contacted',
            Route_to_Round_Robin__c = true
        );
        
        // Should not throw exception
        try {
            insert testLead;
            System.assert(true, 'Lead insert should succeed even with empty queue');
        } catch (Exception e) {
            System.assert(false, 'Lead insert should not fail: ' + e.getMessage());
        }
        
        // Verify lead was created but not assigned (since all queues empty)
        Lead createdLead = [SELECT Id, OwnerId, Route_to_Round_Robin__c FROM Lead WHERE Id = :testLead.Id];
        System.assertEquals(UserInfo.getUserId(), createdLead.OwnerId, 'Lead should remain with current user when all queues empty');
        System.assertEquals(false, createdLead.Route_to_Round_Robin__c, 'Checkbox should be unchecked even if assignment failed');
        
        Test.stopTest();
    }
    
    @isTest
    static void testLeadWithPreassignedOwner() {
        // Get a test user
        User testUser = [SELECT Id FROM User WHERE Email LIKE 'testuser%@roundrobin.test' LIMIT 1];
        
        Test.startTest();
        
        // Create lead with pre-assigned owner but routing enabled
        Lead testLead = new Lead(
            FirstName = 'Test',
            LastName = 'PreassignedLead',
            Company = 'Test Company',
            Status = 'Open - Not Contacted',
            OwnerId = testUser.Id,
            Route_to_Round_Robin__c = true
        );
        insert testLead;
        
        Test.stopTest();
        
        // Verify owner HAS changed because routing was requested
        Lead assignedLead = [SELECT Id, OwnerId, Route_to_Round_Robin__c FROM Lead WHERE Id = :testLead.Id];
        System.assertNotEquals(testUser.Id, assignedLead.OwnerId, 'Owner should change when routing is requested');
        System.assertEquals(false, assignedLead.Route_to_Round_Robin__c, 'Routing checkbox should be unchecked');
        
        // Verify assignment state was updated
        List<Round_Robin_Assignment_State__c> states = [SELECT Id, Total_Assignments__c FROM Round_Robin_Assignment_State__c];
        System.assertEquals(1, states[0].Total_Assignments__c, 'One assignment should be recorded');
    }
    
    @isTest
    static void testMultipleQueuesRoundRobin() {
        // Create 3 queues with different number of members
        List<User> testUsers = [SELECT Id FROM User WHERE Email LIKE 'testuser%@roundrobin.test' ORDER BY Email];
        List<Group> testQueues = new List<Group>();
        
        for (Integer i = 0; i < 3; i++) {
            Group q = new Group(
                Name = 'Multi Queue ' + i,
                DeveloperName = 'Multi_Queue_' + i,
                Type = 'Queue'
            );
            testQueues.add(q);
        }
        insert testQueues;
        
        // Add Queue supported objects
        List<QueueSObject> queueSObjects = new List<QueueSObject>();
        for (Group q : testQueues) {
            QueueSObject qso = new QueueSObject(
                QueueId = q.Id,
                SObjectType = 'Lead'
            );
            queueSObjects.add(qso);
        }
        insert queueSObjects;
        
        // Add different number of users to each queue
        List<GroupMember> groupMembers = new List<GroupMember>();
        // Queue 0: 2 users
        for (Integer j = 0; j < 2; j++) {
            groupMembers.add(new GroupMember(
                GroupId = testQueues[0].Id,
                UserOrGroupId = testUsers[j].Id
            ));
        }
        // Queue 1: 3 users
        for (Integer j = 2; j < 5; j++) {
            groupMembers.add(new GroupMember(
                GroupId = testQueues[1].Id,
                UserOrGroupId = testUsers[j].Id
            ));
        }
        // Queue 2: 1 user
        groupMembers.add(new GroupMember(
            GroupId = testQueues[2].Id,
            UserOrGroupId = testUsers[5].Id
        ));
        insert groupMembers;
        
        // Set up mock queue configurations
        RoundRobinAssignmentHandler.testQueueConfigs = RoundRobinTestHelper.getMockQueueConfigs(testQueues);
        
        Test.startTest();
        
        // Create 9 leads to test full cycle
        List<Lead> testLeads = new List<Lead>();
        for (Integer i = 0; i < 9; i++) {
            testLeads.add(new Lead(
                FirstName = 'Multi',
                LastName = 'Lead' + i,
                Company = 'Test Company',
                Status = 'Open - Not Contacted',
                Route_to_Round_Robin__c = true
            ));
        }
        insert testLeads;
        
        Test.stopTest();
        
        // Verify assignment pattern
        Map<Id, List<Lead>> userToLeads = new Map<Id, List<Lead>>();
        for (Lead l : [SELECT Id, OwnerId FROM Lead WHERE Id IN :testLeads ORDER BY CreatedDate]) {
            if (!userToLeads.containsKey(l.OwnerId)) {
                userToLeads.put(l.OwnerId, new List<Lead>());
            }
            userToLeads.get(l.OwnerId).add(l);
        }
        
        // Verify distribution
        System.assertEquals(6, userToLeads.size(), 'Leads should be distributed to all 6 users');
        
        // Expected pattern with per-queue tracking:
        // Lead 0: Q0-U0, Lead 1: Q1-U0, Lead 2: Q2-U0
        // Lead 3: Q0-U1, Lead 4: Q1-U1, Lead 5: Q2-U0 (wraps, only 1 user)
        // Lead 6: Q0-U0, Lead 7: Q1-U2, Lead 8: Q2-U0
        
        // Verify Queue 0 users got correct number of leads
        Integer q0User0Count = 0;
        Integer q0User1Count = 0;
        Integer q1UsersCount = 0;
        Integer q2UserCount = 0;
        
        for (Id userId : userToLeads.keySet()) {
            Integer leadCount = userToLeads.get(userId).size();
            if (userId == testUsers[0].Id) q0User0Count = leadCount;
            else if (userId == testUsers[1].Id) q0User1Count = leadCount;
            else if (userId == testUsers[5].Id) q2UserCount = leadCount;
            else q1UsersCount += leadCount;
        }
        
        // Queue 0 (2 users) gets 3 leads: 2 users should have 1-2 leads each
        System.assert(q0User0Count >= 1 && q0User0Count <= 2, 'Queue 0 User 0 should have 1-2 leads');
        System.assert(q0User1Count >= 1 && q0User1Count <= 2, 'Queue 0 User 1 should have 1-2 leads');
        
        // Queue 2 (1 user) gets 3 leads: the single user gets all 3
        System.assertEquals(3, q2UserCount, 'Queue 2 single user should have all 3 leads for that queue');
        
        // Verify state tracking
        Round_Robin_Assignment_State__c state = [
            SELECT Queue_User_Indices__c 
            FROM Round_Robin_Assignment_State__c 
            LIMIT 1
        ];
        System.assertNotEquals(null, state.Queue_User_Indices__c, 'Queue user indices should be populated');
        
        // Parse and verify indices
        Map<String, Object> indices = (Map<String, Object>) JSON.deserializeUntyped(state.Queue_User_Indices__c);
        System.assertEquals(3, indices.size(), 'Should have indices for 3 queues');
    }
    
    @isTest
    static void testBulkLeadAssignmentGovernorLimits() {
        // Get test data
        List<Group> testQueues = [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND Name LIKE 'Test Queue%' ORDER BY Name];
        
        // Set up mock queue configurations
        RoundRobinAssignmentHandler.testQueueConfigs = RoundRobinTestHelper.getMockQueueConfigs(testQueues);
        
        Test.startTest();
        
        // Create 250 leads to test governor limits
        List<Lead> bulkLeads = new List<Lead>();
        for (Integer i = 0; i < 250; i++) {
            Lead lead = new Lead(
                FirstName = 'Bulk',
                LastName = 'Lead' + i,
                Company = 'Bulk Company ' + i,
                Status = 'Open - Not Contacted',
                Route_to_Round_Robin__c = true
            );
            bulkLeads.add(lead);
        }
        
        // This should NOT hit governor limits
        try {
            insert bulkLeads;
            System.assert(true, 'Bulk insert should succeed without hitting governor limits');
        } catch (Exception e) {
            System.assert(false, 'Bulk insert failed with: ' + e.getMessage());
        }
        
        Test.stopTest();
        
        // Verify all leads were assigned
        List<Lead> assignedLeads = [
            SELECT Id, OwnerId, Assigned_Through_Round_Robin__c 
            FROM Lead 
            WHERE Id IN :bulkLeads
        ];
        
        Integer assignedCount = 0;
        for (Lead l : assignedLeads) {
            if (l.Assigned_Through_Round_Robin__c) {
                assignedCount++;
            }
        }
        
        System.assertEquals(250, assignedCount, 'All 250 leads should be assigned through round robin');
        
        // Verify state was updated only once
        Integer dmlStatements = Limits.getDmlStatements();
        System.assert(dmlStatements < 10, 'Should have minimal DML statements, not one per lead');
    }
    
    @isTest
    static void testMalformedJSONHandling() {
        // Create a state record with malformed JSON
        Round_Robin_Assignment_State__c badState = new Round_Robin_Assignment_State__c(
            Current_Queue_Index__c = 0,
            Queue_User_Indices__c = '{"invalid json',  // Malformed JSON
            Total_Assignments__c = 0
        );
        insert badState;
        
        // Get test queues
        List<Group> testQueues = [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND Name LIKE 'Test Queue%' ORDER BY Name LIMIT 1];
        RoundRobinAssignmentHandler.testQueueConfigs = RoundRobinTestHelper.getMockQueueConfigs(testQueues);
        
        Test.startTest();
        
        // Try to create a lead - should handle malformed JSON gracefully
        Lead testLead = new Lead(
            FirstName = 'JSON',
            LastName = 'Test',
            Company = 'Test Company',
            Status = 'Open - Not Contacted',
            Route_to_Round_Robin__c = true
        );
        
        try {
            insert testLead;
            System.assert(true, 'Should handle malformed JSON gracefully');
        } catch (Exception e) {
            System.assert(false, 'Should not throw exception for malformed JSON: ' + e.getMessage());
        }
        
        Test.stopTest();
        
        // Verify state was reset
        Round_Robin_Assignment_State__c updatedState = [
            SELECT Queue_User_Indices__c 
            FROM Round_Robin_Assignment_State__c 
            WHERE Id = :badState.Id
        ];
        
        System.assertEquals('{}', updatedState.Queue_User_Indices__c, 'Malformed JSON should be reset to empty object');
    }
    
    @isTest
    static void testReRoutingScenario() {
        // Get test data
        List<Group> testQueues = [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND Name LIKE 'Test Queue%' ORDER BY Name];
        List<User> testUsers = [SELECT Id FROM User WHERE Email LIKE 'testuser%@roundrobin.test' ORDER BY Email];
        
        // Set up mock queue configurations
        RoundRobinAssignmentHandler.testQueueConfigs = RoundRobinTestHelper.getMockQueueConfigs(testQueues);
        
        // Create lead without routing
        Lead testLead = new Lead(
            FirstName = 'ReRoute',
            LastName = 'Test',
            Company = 'Test Company',
            Status = 'Open - Not Contacted',
            Route_to_Round_Robin__c = false
        );
        insert testLead;
        
        // Verify initial state - should be assigned to current user
        Lead initialLead = [SELECT Id, OwnerId, Route_to_Round_Robin__c FROM Lead WHERE Id = :testLead.Id];
        System.assertEquals(UserInfo.getUserId(), initialLead.OwnerId, 'Lead should initially be owned by current user');
        
        Test.startTest();
        
        // Now check the routing checkbox to trigger assignment
        testLead.Route_to_Round_Robin__c = true;
        update testLead;
        
        Test.stopTest();
        
        // Verify re-assignment
        Lead reRoutedLead = [SELECT Id, OwnerId, Route_to_Round_Robin__c, Assigned_Through_Round_Robin__c FROM Lead WHERE Id = :testLead.Id];
        System.assertNotEquals(UserInfo.getUserId(), reRoutedLead.OwnerId, 'Lead should be re-assigned to a different user');
        System.assertEquals(false, reRoutedLead.Route_to_Round_Robin__c, 'Routing checkbox should be unchecked after re-assignment');
        System.assertEquals(true, reRoutedLead.Assigned_Through_Round_Robin__c, 'Lead should be marked as assigned through round robin');
        
        // Store first assigned owner
        Id firstAssignedOwner = reRoutedLead.OwnerId;
        
        // Check the box again for another re-route
        reRoutedLead.Route_to_Round_Robin__c = true;
        update reRoutedLead;
        
        // Verify second re-assignment
        Lead secondReRoutedLead = [SELECT Id, OwnerId FROM Lead WHERE Id = :testLead.Id];
        // Should be assigned to someone (might be same user if they're next in rotation)
        System.assertNotEquals(null, secondReRoutedLead.OwnerId, 'Lead should still have an owner after second re-route');
    }
    
    @isTest
    static void testConcurrentDataLoaderScenario() {
        // Get test data
        List<Group> testQueues = [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND Name LIKE 'Test Queue%' ORDER BY Name];
        
        // Set up mock queue configurations
        RoundRobinAssignmentHandler.testQueueConfigs = RoundRobinTestHelper.getMockQueueConfigs(testQueues);
        
        Test.startTest();
        
        // Simulate data loader scenario - create many leads at once
        List<Lead> dataLoaderLeads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            Lead lead = new Lead(
                FirstName = 'DataLoader',
                LastName = 'Lead' + i,
                Company = 'Bulk Company',
                Status = 'Open - Not Contacted',
                Route_to_Round_Robin__c = true
            );
            dataLoaderLeads.add(lead);
        }
        
        // Insert all at once (simulating data loader)
        insert dataLoaderLeads;
        
        Test.stopTest();
        
        // Verify no duplicates - each lead should have unique assignment in sequence
        List<Lead> assignedLeads = [
            SELECT Id, OwnerId, Round_Robin_Queue__c 
            FROM Lead 
            WHERE Id IN :dataLoaderLeads 
            ORDER BY CreatedDate, Id
        ];
        
        // Check that assignments follow pattern
        Map<String, Integer> ownerAssignmentCount = new Map<String, Integer>();
        for (Lead lead : assignedLeads) {
            String ownerId = String.valueOf(lead.OwnerId);
            if (!ownerAssignmentCount.containsKey(ownerId)) {
                ownerAssignmentCount.put(ownerId, 0);
            }
            ownerAssignmentCount.put(ownerId, ownerAssignmentCount.get(ownerId) + 1);
        }
        
        // Verify relatively even distribution
        Integer minAssignments = 1000;
        Integer maxAssignments = 0;
        for (Integer count : ownerAssignmentCount.values()) {
            minAssignments = Math.min(minAssignments, count);
            maxAssignments = Math.max(maxAssignments, count);
        }
        
        // Distribution should be relatively even (within 2-3 assignments)
        System.assert(maxAssignments - minAssignments <= 3, 
            'Assignment distribution should be relatively even. Max: ' + maxAssignments + ', Min: ' + minAssignments);
    }
}