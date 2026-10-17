/**
 * Routes leads to queue members in weighted round robin order.
 *
 *   lead ─▶ queues whose rule matches ─▶ next queue (GLOBAL row) ─▶ next rep slot (queue row)
 *                                                                  skips: unavailable, at capacity
 *
 * Runs without sharing on purpose. Routing is a system process: a rep, an integration user and a
 * Site guest saving the same lead must get the same result, and every caller must see the same
 * rotation state or the rotation forks.
 *
 * Holds no routing state between calls, so it stays correct when Salesforce retries a
 * partial-success save (allOrNone=false): the retry re-runs triggers but keeps statics.
 *
 * A lead save is never blocked by routing. Every failure unticks Route to Round Robin and writes
 * the reason to Last Round Robin Error, which the Round Robin Errors list view shows.
 *
 * CRUD/FLS checks are suppressed for the same reason as sharing: the saving user's permissions
 * must not decide whether a lead gets routed. Reset is gated by the Round_Robin_Admin custom permission.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class RoundRobinService {

    public static final String GLOBAL_KEY = '__GLOBAL__';
    public static final String NOTIFICATION_TYPE = 'Round_Robin_Lead_Assigned';
    @TestVisible static final Integer MAX_WEIGHT = 10;

    @TestVisible static List<Round_Robin_Queue_Config__mdt> configOverride;
    @TestVisible static Boolean failForTest = false; // the only way to reach the catch-all from a test

    // Leads already notified in this transaction. A workflow field update re-runs the after trigger
    // with the original Trigger.old, which would otherwise notify the rep twice.
    private static final Set<Id> NOTIFIED = new Set<Id>();
    private static final Map<String, Schema.SObjectField> LEAD_FIELDS = Schema.SObjectType.Lead.fields.getMap();

    /** Leads that should be routed in this save: ticked on insert, or ticked (false to true) on update. */
    public static List<Lead> leadsToRoute(List<Lead> leads, Map<Id, Lead> oldMap) {
        List<Lead> result = new List<Lead>();
        for (Lead l : leads) {
            Boolean wasTicked = oldMap != null && oldMap.get(l.Id).Route_to_Round_Robin__c == true;
            if (l.Route_to_Round_Robin__c == true && !wasTicked && !l.IsConverted) {
                result.add(l);
            }
        }
        return result;
    }

    /** Assigns owners on the given in-memory leads (call from a before trigger). */
    public static void route(List<Lead> leads) {
        if (leads.isEmpty()) {
            return;
        }
        List<Assignment> plan;
        try {
            plan = new Router(activeConfigs()).plan(leads);
        } catch (Exception e) {
            // Deliberately broad: whatever went wrong, the lead must still save. Nothing needs undoing:
            // the only write is the single all-or-nothing state upsert at the end of plan().
            System.debug(LoggingLevel.ERROR, 'Round robin routing failed: ' + e.getTypeName() + ': '
                + e.getMessage() + '\n' + e.getStackTraceString());
            plan = failAll(leads.size(), 'Routing failed (' + e.getTypeName() + '): ' + e.getMessage());
        }
        apply(leads, plan);
    }

    /** Clears the rotation so every queue starts again from its first rep. Needs the Round Robin Admin permission. */
    public static Integer resetRotation() {
        if (!FeatureManagement.checkPermission('Round_Robin_Admin')) {
            throw new NoAccessException();
        }
        List<Round_Robin_Assignment_State__c> rows = [SELECT Id FROM Round_Robin_Assignment_State__c FOR UPDATE];
        delete rows;
        return rows.size();
    }

    /** Sends a bell and mobile notification to reps who were just assigned leads (call from an after trigger). */
    public static void notifyAssignees(List<Lead> leads, Map<Id, Lead> oldMap) {
        Map<Id, List<Lead>> byOwner = justAssignedByOwner(leads, oldMap);
        if (byOwner.isEmpty()) {
            return;
        }
        List<CustomNotificationType> types = [SELECT Id FROM CustomNotificationType WHERE DeveloperName = :NOTIFICATION_TYPE LIMIT 1];
        if (types.isEmpty()) {
            System.debug(LoggingLevel.WARN, 'Round robin: notification type ' + NOTIFICATION_TYPE + ' is missing; no notifications sent.');
            return;
        }
        for (Id ownerId : byOwner.keySet()) {
            send(types[0].Id, ownerId, byOwner.get(ownerId));
        }
    }

    /** Active queue configs in rotation order. */
    public static List<Round_Robin_Queue_Config__mdt> activeConfigs() {
        List<Round_Robin_Queue_Config__mdt> all = configOverride != null
            ? configOverride
            : Round_Robin_Queue_Config__mdt.getAll().values();
        List<ConfigOrder> ordered = new List<ConfigOrder>();
        for (Round_Robin_Queue_Config__mdt c : all) {
            if (c.Is_Active__c && String.isNotBlank(c.Queue_Developer_Name__c)) {
                ordered.add(new ConfigOrder(c));
            }
        }
        ordered.sort();
        List<Round_Robin_Queue_Config__mdt> result = new List<Round_Robin_Queue_Config__mdt>();
        for (ConfigOrder o : ordered) {
            result.add(o.config);
        }
        return result;
    }

    /** Whether a config's Match Field names a real Lead field. */
    public static Boolean isLeadField(String fieldName) {
        return String.isNotBlank(fieldName) && LEAD_FIELDS.containsKey(fieldName.trim().toLowerCase());
    }

    private static Map<Id, List<Lead>> justAssignedByOwner(List<Lead> leads, Map<Id, Lead> oldMap) {
        Map<Id, List<Lead>> byOwner = new Map<Id, List<Lead>>();
        List<Lead> assigned = new List<Lead>();
        for (Lead l : leads) {
            Datetime before = oldMap == null ? null : oldMap.get(l.Id).Round_Robin_Assignment_DateTime__c;
            if (l.Round_Robin_Assignment_DateTime__c != null && l.Round_Robin_Assignment_DateTime__c != before && !NOTIFIED.contains(l.Id)) {
                assigned.add(l);
            }
        }
        if (assigned.isEmpty()) {
            return byOwner; // the common case: most Lead saves skip the config load entirely
        }
        Set<String> notifyingQueues = new Set<String>();
        for (Round_Robin_Queue_Config__mdt c : activeConfigs()) {
            if (c.Notify_Assignee__c) {
                notifyingQueues.add(c.Queue_Developer_Name__c);
            }
        }
        for (Lead l : assigned) {
            if (!notifyingQueues.contains(l.Round_Robin_Queue__c)) {
                continue;
            }
            NOTIFIED.add(l.Id);
            List<Lead> owned = byOwner.get(l.OwnerId);
            if (owned == null) {
                owned = new List<Lead>();
                byOwner.put(l.OwnerId, owned);
            }
            owned.add(l);
        }
        return byOwner;
    }

    private static void send(Id typeId, Id ownerId, List<Lead> assigned) {
        Lead first = assigned[0];
        String who = (String.isBlank(first.FirstName) ? '' : first.FirstName + ' ') + first.LastName
            + (String.isBlank(first.Company) ? '' : ', ' + first.Company);
        Messaging.CustomNotification n = new Messaging.CustomNotification();
        n.setNotificationTypeId(typeId);
        n.setTargetId(first.Id);
        n.setTitle(assigned.size() == 1 ? 'New lead assigned to you' : assigned.size() + ' new leads assigned to you');
        n.setBody(assigned.size() == 1 ? who : 'Including ' + who);
        try {
            n.send(new Set<String>{ ownerId });
        } catch (Exception e) {
            // A notification is a courtesy. The lead is already routed, so never fail the save for it.
            System.debug(LoggingLevel.ERROR, 'Round robin notification to ' + ownerId + ' failed: ' + e.getMessage());
        }
    }

    private static List<Assignment> failAll(Integer count, String reason) {
        List<Assignment> result = new List<Assignment>();
        for (Integer i = 0; i < count; i++) {
            result.add(new Assignment(null, null, reason));
        }
        return result;
    }

    private static void apply(List<Lead> leads, List<Assignment> plan) {
        Datetime now = System.now();
        String source = String.valueOf(Request.getCurrent().getQuiddity());
        Id triggeredBy = UserInfo.getUserId();
        for (Integer i = 0; i < leads.size(); i++) {
            Lead l = leads[i];
            Assignment a = plan[i];
            l.Route_to_Round_Robin__c = false;
            l.Last_Round_Robin_Attempt__c = now;
            if (a.ownerId == null) {
                l.Last_Round_Robin_Error__c = a.error.abbreviate(255);
                continue;
            }
            l.OwnerId = a.ownerId;
            l.Assigned_Through_Round_Robin__c = true;
            l.Round_Robin_Assignment_DateTime__c = now;
            l.Round_Robin_Queue__c = a.queue;
            l.Round_Robin_Source__c = source;
            l.Round_Robin_Triggered_By__c = triggeredBy;
            l.Last_Round_Robin_Error__c = null;
        }
    }

    /** One routing pass: loads everything it needs in a fixed number of queries, then plans each lead in memory. */
    private without sharing class Router {
        private final List<Round_Robin_Queue_Config__mdt> configs;
        private final Map<String, Set<String>> matchValues = new Map<String, Set<String>>(); // queue -> allowed values, only for queues with a rule
        private final Map<String, List<Id>> slotsByQueue = new Map<String, List<Id>>();
        private final Map<Id, User> reps = new Map<Id, User>();
        private final Map<Id, Integer> openLeads = new Map<Id, Integer>();
        private final Map<String, Round_Robin_Assignment_State__c> state = new Map<String, Round_Robin_Assignment_State__c>();
        private final Set<String> touched = new Set<String>();

        Router(List<Round_Robin_Queue_Config__mdt> configs) {
            this.configs = configs;
            for (Round_Robin_Queue_Config__mdt c : configs) {
                if (String.isBlank(c.Match_Field__c)) {
                    continue;
                }
                Set<String> values = new Set<String>(); // a misconfigured field leaves this empty: nothing matches
                if (isLeadField(c.Match_Field__c) && String.isNotBlank(c.Match_Values__c)) {
                    for (String v : c.Match_Values__c.split(',')) {
                        values.add(v.trim().toLowerCase());
                    }
                }
                matchValues.put(c.Queue_Developer_Name__c, values);
            }
        }

        List<Assignment> plan(List<Lead> leads) {
            if (configs.isEmpty()) {
                return failAll(leads.size(), 'No active round robin queues are configured.');
            }
            loadMembers();
            loadOpenLeads();
            loadState();
            if (failForTest) {
                throw new DmlException('Forced failure for test');
            }
            List<Assignment> result = new List<Assignment>();
            for (Lead l : leads) {
                result.add(assign(l));
            }
            upsert stateToSave() Queue_Key__c;
            return result;
        }

        private Boolean matches(Lead l, Round_Robin_Queue_Config__mdt c) {
            Set<String> allowed = matchValues.get(c.Queue_Developer_Name__c);
            if (allowed == null) {
                return true; // no rule
            }
            Object value = allowed.isEmpty() ? null : l.get(c.Match_Field__c.trim());
            return value != null && allowed.contains(String.valueOf(value).trim().toLowerCase());
        }

        private Assignment assign(Lead l) {
            Boolean anyQueueMatched = false;
            Round_Robin_Assignment_State__c globalRow = state.get(GLOBAL_KEY);
            Integer start = globalRow.Next_Index__c.intValue();
            for (Integer k = 0; k < configs.size(); k++) {
                Integer position = Math.mod(start + k, configs.size());
                Round_Robin_Queue_Config__mdt c = configs[position];
                if (!slotsByQueue.containsKey(c.Queue_Developer_Name__c) || !matches(l, c)) {
                    continue;
                }
                anyQueueMatched = true;
                Id rep = nextRep(c);
                if (rep != null) {
                    globalRow.Next_Index__c = Math.mod(position + 1, configs.size());
                    touched.add(GLOBAL_KEY);
                    return new Assignment(rep, c.Queue_Developer_Name__c, null);
                }
            }
            return new Assignment(null, null, anyQueueMatched
                ? 'No eligible rep: everyone in the matching queues is unavailable or at capacity.'
                : 'No active queue with members matches this lead.');
        }

        private Id nextRep(Round_Robin_Queue_Config__mdt c) {
            String key = c.Queue_Developer_Name__c;
            List<Id> slots = slotsByQueue.get(key);
            Round_Robin_Assignment_State__c row = state.get(key);
            Integer start = Math.mod(row.Next_Index__c.intValue(), slots.size());
            for (Integer j = 0; j < slots.size(); j++) {
                Integer index = Math.mod(start + j, slots.size());
                Id rep = slots[index];
                if (reps.get(rep).Round_Robin_Available__c == false || atCapacity(rep, c)) {
                    continue;
                }
                row.Next_Index__c = Math.mod(index + 1, slots.size());
                row.Total_Assignments__c++;
                row.Last_Assigned_User__c = rep;
                row.Last_Assignment_DateTime__c = System.now();
                touched.add(key);
                openLeads.put(rep, openCount(rep) + 1);
                return rep;
            }
            return null;
        }

        private Boolean atCapacity(Id rep, Round_Robin_Queue_Config__mdt c) {
            return c.Max_Open_Leads__c != null && openCount(rep) >= c.Max_Open_Leads__c;
        }

        private Integer openCount(Id rep) {
            Integer n = openLeads.get(rep);
            return n == null ? 0 : n;
        }

        /** Active users in each queue, one slot per unit of weight, in a stable order. */
        private void loadMembers() {
            Set<String> names = new Set<String>();
            for (Round_Robin_Queue_Config__mdt c : configs) {
                names.add(c.Queue_Developer_Name__c);
            }
            List<GroupMember> members = [
                SELECT Group.DeveloperName, UserOrGroupId FROM GroupMember
                WHERE Group.Type = 'Queue' AND Group.DeveloperName IN :names
                ORDER BY UserOrGroupId
            ];
            Set<Id> userIds = new Set<Id>();
            for (GroupMember m : members) {
                userIds.add(m.UserOrGroupId); // roles and public groups never match a User below
            }
            reps.putAll([
                SELECT Id, Round_Robin_Available__c, Round_Robin_Weight__c FROM User
                WHERE Id IN :userIds AND IsActive = true
            ]);
            for (GroupMember m : members) {
                User u = reps.get(m.UserOrGroupId);
                if (u == null) {
                    continue; // inactive user, role or public group
                }
                List<Id> slots = slotsByQueue.get(m.Group.DeveloperName);
                if (slots == null) {
                    slots = new List<Id>();
                    slotsByQueue.put(m.Group.DeveloperName, slots);
                }
                for (Integer w = 0; w < weight(u); w++) {
                    slots.add(u.Id);
                }
            }
        }

        private Integer weight(User u) {
            Integer w = u.Round_Robin_Weight__c == null ? 1 : u.Round_Robin_Weight__c.intValue();
            return Math.max(1, Math.min(MAX_WEIGHT, w));
        }

        /** Open leads per rep, counted only for reps in capped queues (each counted row uses query-row limit). */
        private void loadOpenLeads() {
            Set<Id> capped = new Set<Id>();
            for (Round_Robin_Queue_Config__mdt c : configs) {
                if (c.Max_Open_Leads__c != null && slotsByQueue.containsKey(c.Queue_Developer_Name__c)) {
                    capped.addAll(slotsByQueue.get(c.Queue_Developer_Name__c));
                }
            }
            if (capped.isEmpty()) {
                return;
            }
            for (AggregateResult r : [
                SELECT OwnerId owner, COUNT(Id) total FROM Lead
                WHERE OwnerId IN :capped AND IsConverted = false AND (NOT Status LIKE 'Closed%')
                GROUP BY OwnerId
            ]) {
                openLeads.put((Id) r.get('owner'), (Integer) r.get('total'));
            }
        }

        /** Locks the rotation rows for this transaction; starts any that don't exist yet at zero. */
        private void loadState() {
            Set<String> keys = new Set<String>(slotsByQueue.keySet());
            keys.add(GLOBAL_KEY);
            for (Round_Robin_Assignment_State__c row : [
                SELECT Id, Queue_Key__c, Next_Index__c, Total_Assignments__c
                FROM Round_Robin_Assignment_State__c
                WHERE Queue_Key__c IN :keys
                FOR UPDATE
            ]) {
                state.put(row.Queue_Key__c, row);
            }
            for (String key : keys) {
                Round_Robin_Assignment_State__c row = state.get(key);
                if (row == null) {
                    row = new Round_Robin_Assignment_State__c(Queue_Key__c = key);
                    state.put(key, row);
                }
                row.Next_Index__c = row.Next_Index__c == null ? 0 : row.Next_Index__c;
                row.Total_Assignments__c = row.Total_Assignments__c == null ? 0 : row.Total_Assignments__c;
            }
        }

        private List<Round_Robin_Assignment_State__c> stateToSave() {
            List<Round_Robin_Assignment_State__c> changed = new List<Round_Robin_Assignment_State__c>();
            for (String key : touched) {
                changed.add(state.get(key));
            }
            return changed;
        }
    }

    /** Outcome for one lead: an owner, or the reason there isn't one. */
    private class Assignment {
        Id ownerId;
        String queue;
        String error;

        Assignment(Id ownerId, String queue, String error) {
            this.ownerId = ownerId;
            this.queue = queue;
            this.error = error;
        }
    }

    /** Sort Order ascending, blanks last, then queue name so the order never depends on query order. */
    private class ConfigOrder implements Comparable {
        final Round_Robin_Queue_Config__mdt config;

        ConfigOrder(Round_Robin_Queue_Config__mdt config) {
            this.config = config;
        }

        public Integer compareTo(Object other) {
            Round_Robin_Queue_Config__mdt that = ((ConfigOrder) other).config;
            Decimal a = config.Sort_Order__c;
            Decimal b = that.Sort_Order__c;
            if (a != b) {
                if (a == null) {
                    return 1;
                }
                if (b == null) {
                    return -1;
                }
                return a < b ? -1 : 1;
            }
            return config.Queue_Developer_Name__c.compareTo(that.Queue_Developer_Name__c);
        }
    }
}
