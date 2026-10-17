/**
 * Shared fixtures: two Lead queues with two reps each, plus a public group inside queue A
 * (which routing must ignore). Queue configs are injected through RoundRobinService.configOverride
 * because custom metadata records cannot be inserted in tests.
 */
@isTest
public class RoundRobinTestData {

    public static final String QUEUE_A = 'RR_Test_A';
    public static final String QUEUE_B = 'RR_Test_B';

    public static void createTeam() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String suffix = String.valueOf(System.now().getTime()) + '@rr.test';
        List<User> users = new List<User>();
        for (Integer i = 1; i <= 4; i++) {
            users.add(new User(
                LastName = 'Rep ' + i, Alias = 'rrrep' + i, Email = 'rrrep' + i + '@rr.test',
                Username = 'rrrep' + i + '.' + suffix, ProfileId = standard.Id,
                TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN',
                EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
            ));
        }
        insert users;
        List<User> reps = reps();

        Group a = new Group(Name = 'RR Test A', DeveloperName = QUEUE_A, Type = 'Queue');
        Group b = new Group(Name = 'RR Test B', DeveloperName = QUEUE_B, Type = 'Queue');
        Group publicGroup = new Group(Name = 'RR Test Public', Type = 'Regular');
        insert new List<Group>{ a, b, publicGroup };
        insert new List<QueueSobject>{
            new QueueSobject(QueueId = a.Id, SobjectType = 'Lead'),
            new QueueSobject(QueueId = b.Id, SobjectType = 'Lead')
        };
        insert new List<GroupMember>{
            new GroupMember(GroupId = a.Id, UserOrGroupId = reps[0].Id),
            new GroupMember(GroupId = a.Id, UserOrGroupId = reps[1].Id),
            new GroupMember(GroupId = a.Id, UserOrGroupId = publicGroup.Id),
            new GroupMember(GroupId = b.Id, UserOrGroupId = reps[2].Id),
            new GroupMember(GroupId = b.Id, UserOrGroupId = reps[3].Id)
        };
    }

    /** Reps in Id order: [0], [1] are in queue A; [2], [3] in queue B. Routing rotates in this order. */
    public static List<User> reps() {
        return [SELECT Id FROM User WHERE Alias LIKE 'rrrep%' ORDER BY Id];
    }

    public static Round_Robin_Queue_Config__mdt config(String queue, Integer order) {
        return build(new Map<String, Object>{
            'DeveloperName' => queue, 'MasterLabel' => queue, 'Queue_Developer_Name__c' => queue,
            'Is_Active__c' => true, 'Sort_Order__c' => order
        });
    }

    /** Returns a copy of the config with one field changed. */
    public static Round_Robin_Queue_Config__mdt with(Round_Robin_Queue_Config__mdt c, String field, Object value) {
        Map<String, Object> values = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(c));
        values.remove('attributes');
        values.put(field, value);
        return build(values);
    }

    /** A config that only accepts leads whose field value is in the comma-separated values. */
    public static Round_Robin_Queue_Config__mdt matching(String queue, Integer order, String field, String values) {
        return with(with(config(queue, order), 'Match_Field__c', field), 'Match_Values__c', values);
    }

    public static void useConfigs(List<Round_Robin_Queue_Config__mdt> configs) {
        RoundRobinService.configOverride = configs;
    }

    /** Queues A then B, no rules. */
    public static void useDefaultConfigs() {
        useConfigs(new List<Round_Robin_Queue_Config__mdt>{ config(QUEUE_A, 1), config(QUEUE_B, 2) });
    }

    /** Queue A only. */
    public static void useQueueAOnly() {
        useConfigs(new List<Round_Robin_Queue_Config__mdt>{ config(QUEUE_A, 1) });
    }

    /**
     * Assigns a permission set to the running user unless they already have it (tests see real
     * assignments, so the deploying admin often does). Wrap later calls in runAs to pick it up.
     */
    public static void grant(String permissionSetName) {
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName];
        if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :UserInfo.getUserId() AND PermissionSetId = :ps.Id] > 0) {
            return;
        }
        asAdmin(null, new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id)
        });
    }

    public static Lead lead(String lastName, Boolean route) {
        return new Lead(LastName = lastName, Company = 'Acme', Route_to_Round_Robin__c = route);
    }

    public static List<Lead> leads(Integer count, Boolean route) {
        List<Lead> result = new List<Lead>();
        for (Integer i = 0; i < count; i++) {
            result.add(lead('Lead ' + i, route));
        }
        return result;
    }

    /** Runs setup-object DML (users, permission sets) without a mixed DML error. */
    public static void asAdmin(List<SObject> toUpdate, List<SObject> toInsert) {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            if (toUpdate != null) {
                update toUpdate;
            }
            if (toInsert != null) {
                insert toInsert;
            }
        }
    }

    private static Round_Robin_Queue_Config__mdt build(Map<String, Object> values) {
        return (Round_Robin_Queue_Config__mdt) JSON.deserialize(JSON.serialize(values), Round_Robin_Queue_Config__mdt.class);
    }
}
