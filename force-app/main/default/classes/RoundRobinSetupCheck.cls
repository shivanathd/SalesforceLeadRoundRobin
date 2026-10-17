/**
 * Read-only health check for admins. In Developer Console, Execute Anonymous:
 *
 *     System.debug(RoundRobinSetupCheck.run());
 *
 * Reports every active queue config, whether its queue exists, how many reps can take leads, and
 * any rule or capacity problem. Changes nothing.
 */
public with sharing class RoundRobinSetupCheck {

    public static String run() {
        List<String> lines = new List<String>{ 'Round robin setup check' };
        List<Round_Robin_Queue_Config__mdt> configs = RoundRobinService.activeConfigs();
        if (configs.isEmpty()) {
            lines.add('PROBLEM: no active Round Robin Queue Config records. Leads will not be routed.');
            return String.join(lines, '\n');
        }
        Set<String> names = new Set<String>();
        for (Round_Robin_Queue_Config__mdt c : configs) {
            names.add(c.Queue_Developer_Name__c);
        }
        Map<String, Id> queueIds = new Map<String, Id>();
        for (Group g : [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND DeveloperName IN :names]) {
            queueIds.put(g.DeveloperName, g.Id);
        }
        Set<Id> leadQueues = new Set<Id>();
        for (QueueSobject q : [SELECT QueueId FROM QueueSobject WHERE SobjectType = 'Lead' AND QueueId IN :queueIds.values()]) {
            leadQueues.add(q.QueueId);
        }
        Map<Id, List<User>> repsByQueue = new Map<Id, List<User>>();
        Map<Id, Set<Id>> userIdsByQueue = new Map<Id, Set<Id>>();
        Set<Id> userIds = new Set<Id>();
        for (GroupMember m : [SELECT GroupId, UserOrGroupId FROM GroupMember WHERE GroupId IN :queueIds.values()]) {
            if (m.UserOrGroupId.getSobjectType() == User.SObjectType) {
                if (!userIdsByQueue.containsKey(m.GroupId)) {
                    userIdsByQueue.put(m.GroupId, new Set<Id>());
                }
                userIdsByQueue.get(m.GroupId).add(m.UserOrGroupId);
                userIds.add(m.UserOrGroupId);
            }
        }
        Map<Id, User> users = new Map<Id, User>([
            SELECT Id, IsActive, Round_Robin_Available__c FROM User WHERE Id IN :userIds
        ]);

        Integer problems = 0;
        for (Round_Robin_Queue_Config__mdt c : configs) {
            String name = c.Queue_Developer_Name__c;
            Id queueId = queueIds.get(name);
            String line = '- ' + name + ' (order ' + (c.Sort_Order__c == null ? 'none' : String.valueOf(c.Sort_Order__c.intValue())) + '): ';
            if (queueId == null) {
                lines.add(line + 'PROBLEM: no queue with API name ' + name);
                problems++;
                continue;
            }
            Integer active = 0;
            Integer available = 0;
            for (Id uid : userIdsByQueue.containsKey(queueId) ? userIdsByQueue.get(queueId) : new Set<Id>()) {
                User u = users.get(uid);
                if (u != null && u.IsActive) {
                    active++;
                    if (u.Round_Robin_Available__c != false) {
                        available++;
                    }
                }
            }
            line += active + ' active reps, ' + available + ' available';
            if (!leadQueues.contains(queueId)) {
                line += '; PROBLEM: queue does not support Lead';
                problems++;
            }
            if (available == 0) {
                line += '; PROBLEM: nobody can receive leads';
                problems++;
            }
            if (String.isNotBlank(c.Match_Field__c)) {
                if (!RoundRobinService.isLeadField(c.Match_Field__c)) {
                    line += '; PROBLEM: Match Field ' + c.Match_Field__c + ' is not a Lead field';
                    problems++;
                } else {
                    line += '; only leads where ' + c.Match_Field__c + ' in (' + c.Match_Values__c + ')';
                }
            }
            if (c.Max_Open_Leads__c != null) {
                line += '; cap ' + c.Max_Open_Leads__c.intValue() + ' open leads per rep';
            }
            lines.add(line);
        }
        if ([SELECT COUNT() FROM CustomNotificationType WHERE DeveloperName = :RoundRobinService.NOTIFICATION_TYPE] == 0) {
            lines.add('NOTE: notification type ' + RoundRobinService.NOTIFICATION_TYPE + ' is missing; Notify Assignee does nothing.');
        }
        lines.add(problems == 0 ? 'OK: no problems found.' : problems + ' problem(s) found.');
        return String.join(lines, '\n');
    }
}
