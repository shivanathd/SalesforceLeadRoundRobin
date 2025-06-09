/**
 * @description Optimized handler for Lead Round Robin Assignment with Security & Error Handling
 * Assigns leads to queue members in a round-robin fashion across multiple queues
 * Each queue maintains independent user rotation
 */
public with sharing class RoundRobinAssignmentHandler {
    
    // Constants
    private static final Integer MAX_INDEX_BEFORE_RESET = 10000;
    private static final Integer DATA_LOADER_THRESHOLD = 50;
    
    // Cache for queue configurations
    private static Map<String, Round_Robin_Queue_Config__mdt> queueConfigCache;
    
    // Cache for assignment state
    private static Round_Robin_Assignment_State__c assignmentState;
    
    // Cache for queue user indices
    private static Map<String, Integer> queueUserIndices;
    
    // Cache for all queue members to avoid SOQL in loops
    private static Map<String, List<GroupMember>> queueMembersCache;
    
    // Cache for active users to avoid SOQL in loops
    private static Map<Id, Boolean> activeUsersCache;
    
    // Cache for field map to avoid repeated describes
    private static Map<String, Schema.SObjectField> leadFieldMap;
    
    // Flag to track if state needs update
    private static Boolean stateNeedsUpdate = false;
    
    // Recursion prevention - track by operation type
    private static Map<String, Set<Id>> processedLeadIdsByContext = new Map<String, Set<Id>>();
    
    // Get context-specific processed IDs
    private static Set<Id> getProcessedLeadIds() {
        String context = Trigger.isExecuting ? 
            (Trigger.isBefore ? 'BEFORE' : 'AFTER') + '_' + 
            (Trigger.isInsert ? 'INSERT' : 'UPDATE') : 
            'NON_TRIGGER';
        
        if (!processedLeadIdsByContext.containsKey(context)) {
            processedLeadIdsByContext.put(context, new Set<Id>());
        }
        return processedLeadIdsByContext.get(context);
    }
    
    // Test context support
    @TestVisible
    private static Map<String, Round_Robin_Queue_Config__mdt> testQueueConfigs;
    
    /**
     * @description Result class for assignment operations
     */
    public class AssignmentResult {
        public Boolean success;
        public String errorMessage;
        public Id assignedTo;
        
        public AssignmentResult(Boolean success) {
            this.success = success;
        }
        
        public AssignmentResult(Boolean success, String errorMessage) {
            this.success = success;
            this.errorMessage = errorMessage;
        }
    }
    
    /**
     * @description Wrapper class for sorting queue configurations
     */
    private class QueueConfigWrapper implements Comparable {
        public Round_Robin_Queue_Config__mdt config;
        
        public QueueConfigWrapper(Round_Robin_Queue_Config__mdt config) {
            this.config = config;
        }
        
        public Integer compareTo(Object compareTo) {
            if (!(compareTo instanceof QueueConfigWrapper)) {
                return 0;
            }
            
            QueueConfigWrapper compareToWrapper = (QueueConfigWrapper)compareTo;
            
            if (config.Sort_Order__c == null) return 1;
            if (compareToWrapper.config.Sort_Order__c == null) return -1;
            
            if (config.Sort_Order__c > compareToWrapper.config.Sort_Order__c) {
                return 1;
            } else if (config.Sort_Order__c < compareToWrapper.config.Sort_Order__c) {
                return -1;
            }
            return 0;
        }
    }
    
    /**
     * @description Main method to assign leads using round robin logic
     * @param newLeads List of leads to assign
     * @return Map of Lead Id to assignment result
     */
    public static Map<Id, AssignmentResult> assignLeads(List<Lead> newLeads) {
        Map<Id, AssignmentResult> results = new Map<Id, AssignmentResult>();
        
        if (newLeads == null || newLeads.isEmpty()) {
            return results;
        }
        
        try {
            // SECURITY CHECK FIRST
            validateSecurityPermissions();
            
            // Cache field map once
            leadFieldMap = Schema.sObjectType.Lead.fields.getMap();
            
            // Filter out invalid leads (converted, already owned if needed)
            List<Lead> validLeads = filterValidLeads(newLeads, results);
            if (validLeads.isEmpty()) {
                return results;
            }
            
            // Check for recursion - use context-aware tracking
            Set<Id> processedIds = getProcessedLeadIds();
            List<Lead> nonRecursiveLeads = new List<Lead>();
            for (Lead lead : validLeads) {
                if (lead.Id != null && processedIds.contains(lead.Id)) {
                    results.put(lead.Id, new AssignmentResult(false, 'Lead already processed in this context'));
                } else {
                    nonRecursiveLeads.add(lead);
                    if (lead.Id != null) {
                        processedIds.add(lead.Id);
                    }
                }
            }
            
            validLeads = nonRecursiveLeads;
            if (validLeads.isEmpty()) {
                return results;
            }
            
            // Load configurations
            loadQueueConfigurations();
            
            // Get or create assignment state
            assignmentState = getOrCreateAssignmentState();
            
            // Get active queue configurations sorted by order
            List<Round_Robin_Queue_Config__mdt> activeQueues = getActiveQueues();
            
            if (activeQueues.isEmpty()) {
                String errorMsg = 'No active queues configured for round robin assignment';
                for (Lead lead : validLeads) {
                    lead.addError(errorMsg);
                    results.put(lead.Id, new AssignmentResult(false, errorMsg));
                }
                return results;
            }
            
            // Validate queue configurations
            if (!validateQueueConfigurations(activeQueues)) {
                String errorMsg = 'Invalid queue configurations detected. Please contact your administrator.';
                for (Lead lead : validLeads) {
                    lead.addError(errorMsg);
                    results.put(lead.Id, new AssignmentResult(false, errorMsg));
                }
                return results;
            }
            
            // Initialize queue user indices if needed
            if (queueUserIndices == null) {
                queueUserIndices = new Map<String, Integer>();
            }
            
            // Pre-fetch all queue members to avoid SOQL in loop
            prefetchQueueMembers(activeQueues);
            
            // Pre-fetch active status for all users to avoid SOQL in loop
            prefetchActiveUsers();
            
            // Check if ANY queue has members
            Boolean hasAnyMembers = false;
            for (Round_Robin_Queue_Config__mdt queue : activeQueues) {
                List<GroupMember> members = queueMembersCache.get(queue.Queue_ID__c);
                if (members != null && !members.isEmpty()) {
                    hasAnyMembers = true;
                    break;
                }
            }
            
            if (!hasAnyMembers) {
                String errorMsg = 'No queues have active members. Please contact your administrator.';
                for (Lead lead : validLeads) {
                    lead.addError(errorMsg);
                    results.put(lead.Id, new AssignmentResult(false, errorMsg));
                }
                return results;
            }
            
            // Process all leads
            assignLeadsBulk(validLeads, activeQueues, results);
            
            // Mark state for update (will be done in after trigger)
            stateNeedsUpdate = true;
            
        } catch (SecurityException e) {
            // Security errors
            String errorMsg = 'Security Error: ' + e.getMessage();
            for (Lead lead : newLeads) {
                lead.addError(errorMsg);
                results.put(lead.Id, new AssignmentResult(false, errorMsg));
            }
        } catch (Exception e) {
            // All other errors
            String errorMsg = 'Assignment Error: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, 'Round Robin Assignment Error: ' + e.getMessage() + '\n' + e.getStackTraceString());
            for (Lead lead : newLeads) {
                lead.addError(errorMsg);
                results.put(lead.Id, new AssignmentResult(false, errorMsg));
            }
        }
        
        return results;
    }
    
    /**
     * @description Update assignment state - to be called from after trigger
     */
    public static void updateAssignmentStateAfterTrigger() {
        if (stateNeedsUpdate && assignmentState != null && queueUserIndices != null) {
            try {
                // Check JSON size before saving
                String jsonString = JSON.serialize(queueUserIndices);
                if (jsonString.length() > 30000) { // Leave buffer for 32KB limit
                    System.debug(LoggingLevel.WARN, 'Queue indices JSON approaching size limit: ' + jsonString.length() + ' characters');
                    // Clean up high indices to prevent overflow
                    cleanupHighIndices();
                    jsonString = JSON.serialize(queueUserIndices);
                }
                
                // Final safety check
                if (jsonString.length() > 32000) {
                    throw new ApplicationException('Queue indices JSON exceeds maximum size. Please reset queue positions.');
                }
                
                assignmentState.Queue_User_Indices__c = jsonString;
                update assignmentState;
                stateNeedsUpdate = false;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Failed to update assignment state: ' + e.getMessage());
            }
        }
    }
    
    /**
     * @description Filter out invalid leads (converted, etc)
     */
    private static List<Lead> filterValidLeads(List<Lead> leads, Map<Id, AssignmentResult> results) {
        List<Lead> validLeads = new List<Lead>();
        
        for (Lead lead : leads) {
            // Skip converted leads
            if (lead.IsConverted) {
                String errorMsg = 'Cannot assign converted lead through round robin';
                lead.addError(errorMsg);
                results.put(lead.Id, new AssignmentResult(false, errorMsg));
                continue;
            }
            
            // Optionally skip leads that already have owners (configurable)
            // if (lead.OwnerId != null && !isQueueId(lead.OwnerId)) {
            //     String errorMsg = 'Lead already has an owner';
            //     results.put(lead.Id, new AssignmentResult(false, errorMsg));
            //     continue;
            // }
            
            validLeads.add(lead);
        }
        
        return validLeads;
    }
    
    /**
     * @description Validate security permissions
     */
    private static void validateSecurityPermissions() {
        // Check object access
        if (!Schema.sObjectType.Lead.isUpdateable()) {
            throw new SecurityException('Insufficient privileges to update Lead records');
        }
        
        // Check field access
        String[] requiredFields = new String[]{
            'OwnerId', 
            'Route_to_Round_Robin__c', 
            'Round_Robin_Processing__c',
            'Assigned_Through_Round_Robin__c',
            'Round_Robin_Assignment_DateTime__c',
            'Round_Robin_Queue__c'
        };
        
        Map<String, Schema.SObjectField> fieldMap = Schema.sObjectType.Lead.fields.getMap();
        for (String fieldName : requiredFields) {
            Schema.SObjectField field = fieldMap.get(fieldName.toLowerCase());
            if (field != null && !field.getDescribe().isUpdateable()) {
                throw new SecurityException('Insufficient privileges to update field: ' + fieldName);
            }
        }
    }
    
    /**
     * @description Pre-fetch all queue members to avoid SOQL in loops
     */
    private static void prefetchQueueMembers(List<Round_Robin_Queue_Config__mdt> activeQueues) {
        queueMembersCache = new Map<String, List<GroupMember>>();
        
        Set<String> queueIds = new Set<String>();
        for (Round_Robin_Queue_Config__mdt config : activeQueues) {
            queueIds.add(config.Queue_ID__c);
        }
        
        if (queueIds.isEmpty()) {
            return;
        }
        
        // Single SOQL to get all queue members
        List<GroupMember> allMembers = [
            SELECT Id, UserOrGroupId, GroupId
            FROM GroupMember
            WHERE GroupId IN :queueIds
                AND Group.Type = 'Queue'
                AND UserOrGroupId IN (SELECT Id FROM User WHERE IsActive = true)
            ORDER BY GroupId, SystemModstamp
        ];
        
        // Organize by queue
        for (GroupMember member : allMembers) {
            if (!queueMembersCache.containsKey(member.GroupId)) {
                queueMembersCache.put(member.GroupId, new List<GroupMember>());
            }
            queueMembersCache.get(member.GroupId).add(member);
        }
        
        // Initialize empty lists for queues with no members
        for (String queueId : queueIds) {
            if (!queueMembersCache.containsKey(queueId)) {
                queueMembersCache.put(queueId, new List<GroupMember>());
            }
        }
    }
    
    /**
     * @description Pre-fetch active status for all users to avoid SOQL in loops
     */
    private static void prefetchActiveUsers() {
        activeUsersCache = new Map<Id, Boolean>();
        
        // Collect all unique user IDs
        Set<Id> allUserIds = new Set<Id>();
        for (List<GroupMember> members : queueMembersCache.values()) {
            for (GroupMember member : members) {
                allUserIds.add(member.UserOrGroupId);
            }
        }
        
        if (!allUserIds.isEmpty()) {
            // Single SOQL to check all users
            for (User u : [SELECT Id FROM User WHERE Id IN :allUserIds AND IsActive = true]) {
                activeUsersCache.put(u.Id, true);
            }
            
            // Mark non-active users as false
            for (Id userId : allUserIds) {
                if (!activeUsersCache.containsKey(userId)) {
                    activeUsersCache.put(userId, false);
                }
            }
        }
    }
    
    /**
     * @description Assign leads in bulk with optimized logic
     */
    private static void assignLeadsBulk(List<Lead> leadsToAssign, List<Round_Robin_Queue_Config__mdt> activeQueues, Map<Id, AssignmentResult> results) {
        Integer totalQueues = activeQueues.size();
        
        // Null-safe queue index retrieval
        Integer currentQueueIndex = assignmentState.Current_Queue_Index__c != null 
            ? Integer.valueOf(assignmentState.Current_Queue_Index__c) 
            : 0;
            
        DateTime currentTime = System.now();
        String triggerSource = getAssignmentSource();
        Id currentUserId = UserInfo.getUserId();
        
        // Ensure queue index is within bounds - check totalQueues > 0 first
        if (totalQueues > 0) {
            currentQueueIndex = Math.mod(currentQueueIndex, totalQueues);
        } else {
            // This shouldn't happen as we check for empty queues earlier
            System.debug(LoggingLevel.ERROR, 'No active queues available for assignment');
            return;
        }
        
        for (Lead lead : leadsToAssign) {
            Boolean assigned = false;
            Integer attempts = 0;
            Map<String, Integer> queueUserAttempts = new Map<String, Integer>();
            
            // Try each queue until we find one with active members
            while (!assigned && attempts < totalQueues) {
                Round_Robin_Queue_Config__mdt currentQueue = activeQueues[currentQueueIndex];
                List<GroupMember> members = queueMembersCache.get(currentQueue.Queue_ID__c);
                
                if (members != null && !members.isEmpty()) {
                    // Get current user index for this queue
                    Integer userIndex = queueUserIndices.containsKey(currentQueue.Queue_ID__c) 
                        ? queueUserIndices.get(currentQueue.Queue_ID__c) 
                        : 0;
                    
                    // Track attempts per queue to prevent infinite loops
                    Integer queueAttempts = queueUserAttempts.containsKey(currentQueue.Queue_ID__c) 
                        ? queueUserAttempts.get(currentQueue.Queue_ID__c) 
                        : 0;
                    
                    // Try to find an active user in this queue
                    Boolean foundActiveUser = false;
                    Integer usersChecked = 0;
                    
                    while (!foundActiveUser && usersChecked < members.size()) {
                        // Get the member to assign to
                        GroupMember assignedMember = members[Math.mod(userIndex, members.size())];
                        
                        // Check cached user active status
                        Boolean isActive = activeUsersCache.get(assignedMember.UserOrGroupId);
                        
                        if (Boolean.TRUE.equals(isActive)) {
                            // Assign to user
                            lead.OwnerId = assignedMember.UserOrGroupId;
                            lead.Assigned_Through_Round_Robin__c = true;
                            lead.Round_Robin_Assignment_DateTime__c = currentTime;
                            lead.Round_Robin_Queue__c = currentQueue.Queue_Developer_Name__c;
                            
                            // Add audit fields if they exist - use lowercase for map lookup
                            if (leadFieldMap.containsKey('round_robin_triggered_by__c')) {
                                lead.put('Round_Robin_Triggered_By__c', currentUserId);
                            }
                            if (leadFieldMap.containsKey('round_robin_source__c')) {
                                lead.put('Round_Robin_Source__c', triggerSource);
                            }
                            
                            // Update indices for this queue
                            queueUserIndices.put(currentQueue.Queue_ID__c, userIndex + 1);
                            assignmentState.Total_Assignments__c++;
                            assignmentState.Last_Assigned_User__c = assignedMember.UserOrGroupId;
                            assignmentState.Last_Assignment_DateTime__c = currentTime;
                            
                            // Record success
                            AssignmentResult result = new AssignmentResult(true);
                            result.assignedTo = assignedMember.UserOrGroupId;
                            results.put(lead.Id, result);
                            
                            assigned = true;
                            foundActiveUser = true;
                            
                            // Move to next queue for next lead
                            currentQueueIndex = Math.mod(currentQueueIndex + 1, totalQueues);
                        } else {
                            // User no longer active, try next user in this queue
                            userIndex++;
                            usersChecked++;
                        }
                    }
                    
                    // Update the queue's user index even if no active user found
                    if (!foundActiveUser) {
                        queueUserIndices.put(currentQueue.Queue_ID__c, userIndex);
                    }
                    
                    queueUserAttempts.put(currentQueue.Queue_ID__c, queueAttempts + 1);
                }
                
                // Move to next queue if not assigned
                if (!assigned) {
                    currentQueueIndex = Math.mod(currentQueueIndex + 1, totalQueues);
                    attempts++;
                }
            }
            
            if (!assigned) {
                String errorMsg = 'Could not assign lead - no active users available in any queue';
                lead.addError(errorMsg);
                results.put(lead.Id, new AssignmentResult(false, errorMsg));
            }
        }
        
        // Store the current queue position
        assignmentState.Current_Queue_Index__c = currentQueueIndex;
    }
    
    /**
     * @description Determine assignment source
     */
    private static String getAssignmentSource() {
        if (System.isBatch()) return 'Batch';
        if (System.isFuture()) return 'Future';
        if (System.isQueueable()) return 'Queueable';
        if (System.isScheduled()) return 'Scheduled';
        
        // Check if it's from Data Loader by looking at bulk size
        if (Trigger.isExecuting) {
            if (Trigger.new != null && Trigger.new.size() > DATA_LOADER_THRESHOLD) {
                return 'Data Loader';
            }
            return 'Manual';
        }
        
        return 'API';
    }
    
    /**
     * @description Load queue configurations from Custom Metadata
     */
    private static void loadQueueConfigurations() {
        if (queueConfigCache == null) {
            if (Test.isRunningTest() && testQueueConfigs != null) {
                queueConfigCache = testQueueConfigs;
            } else {
                queueConfigCache = Round_Robin_Queue_Config__mdt.getAll();
            }
        }
    }
    
    /**
     * @description Get active queue configurations sorted by order
     */
    private static List<Round_Robin_Queue_Config__mdt> getActiveQueues() {
        List<Round_Robin_Queue_Config__mdt> activeQueues = new List<Round_Robin_Queue_Config__mdt>();
        
        for (Round_Robin_Queue_Config__mdt config : queueConfigCache.values()) {
            if (config.Is_Active__c) {
                activeQueues.add(config);
            }
        }
        
        // Sort by Sort_Order__c using a wrapper class
        List<QueueConfigWrapper> wrappers = new List<QueueConfigWrapper>();
        for (Round_Robin_Queue_Config__mdt config : activeQueues) {
            wrappers.add(new QueueConfigWrapper(config));
        }
        wrappers.sort();
        
        activeQueues.clear();
        for (QueueConfigWrapper wrapper : wrappers) {
            activeQueues.add(wrapper.config);
        }
        
        return activeQueues;
    }
    
    /**
     * @description Validate queue configurations
     */
    private static Boolean validateQueueConfigurations(List<Round_Robin_Queue_Config__mdt> activeQueues) {
        Set<String> queueIds = new Set<String>();
        
        for (Round_Robin_Queue_Config__mdt config : activeQueues) {
            if (queueIds.contains(config.Queue_ID__c)) {
                System.debug(LoggingLevel.ERROR, 'Duplicate queue ID found: ' + config.Queue_ID__c);
                return false;
            }
            queueIds.add(config.Queue_ID__c);
            
            if (String.isBlank(config.Queue_ID__c)) {
                System.debug(LoggingLevel.ERROR, 'Blank queue ID found');
                return false;
            }
            
            // More robust queue ID validation
            // Allow placeholder values during deployment
            if (config.Queue_ID__c.startsWith('REPLACE_WITH_ACTUAL_QUEUE_ID')) {
                System.debug(LoggingLevel.WARN, 'Placeholder queue ID detected: ' + config.Queue_ID__c + 
                    '. Please update with actual Queue ID before use.');
            } else if (!Pattern.matches('^00G[a-zA-Z0-9]{15}$', config.Queue_ID__c)) {
                System.debug(LoggingLevel.ERROR, 'Invalid queue ID format: ' + config.Queue_ID__c);
                return false;
            }
        }
        
        return true;
    }
    
    /**
     * @description Get or create assignment state record
     */
    private static Round_Robin_Assignment_State__c getOrCreateAssignmentState() {
        List<Round_Robin_Assignment_State__c> states = [
            SELECT Id, Current_Queue_Index__c, Queue_User_Indices__c,
                   Last_Assignment_DateTime__c, Last_Assigned_User__c, Total_Assignments__c
            FROM Round_Robin_Assignment_State__c
            ORDER BY CreatedDate DESC
            LIMIT 1
            FOR UPDATE
        ];
        
        if (states.isEmpty()) {
            // Handle concurrent creation with try-catch
            Round_Robin_Assignment_State__c newState = new Round_Robin_Assignment_State__c(
                Current_Queue_Index__c = 0,
                Queue_User_Indices__c = '{}',
                Total_Assignments__c = 0
            );
            
            try {
                insert newState;
                queueUserIndices = new Map<String, Integer>();
                return newState;
            } catch (DmlException e) {
                // Another process created it, try to fetch again
                states = [
                    SELECT Id, Current_Queue_Index__c, Queue_User_Indices__c,
                           Last_Assignment_DateTime__c, Last_Assigned_User__c, Total_Assignments__c
                    FROM Round_Robin_Assignment_State__c
                    ORDER BY CreatedDate DESC
                    LIMIT 1
                    FOR UPDATE
                ];
                
                if (states.isEmpty()) {
                    throw new ApplicationException('Unable to create or retrieve assignment state');
                }
            }
        }
        
        // Parse existing queue user indices
        String indicesJson = states[0].Queue_User_Indices__c;
        if (String.isBlank(indicesJson)) {
            queueUserIndices = new Map<String, Integer>();
            states[0].Queue_User_Indices__c = '{}';
        } else {
            try {
                queueUserIndices = parseQueueUserIndices(indicesJson);
            } catch (Exception e) {
                // Don't reset on parse error - try to preserve what we can
                System.debug(LoggingLevel.ERROR, 'Error parsing queue indices, attempting recovery: ' + e.getMessage());
                queueUserIndices = new Map<String, Integer>();
                
                // Try to preserve valid entries
                try {
                    Map<String, Object> jsonMap = (Map<String, Object>) JSON.deserializeUntyped(indicesJson);
                    for (String key : jsonMap.keySet()) {
                        if (key.startsWith('00G')) { // Valid queue ID format
                            Object value = jsonMap.get(key);
                            if (value instanceof Integer) {
                                queueUserIndices.put(key, (Integer) value);
                            } else if (value instanceof Decimal) {
                                queueUserIndices.put(key, ((Decimal) value).intValue());
                            }
                        }
                    }
                } catch (Exception recoveryError) {
                    System.debug(LoggingLevel.ERROR, 'Recovery failed, starting fresh: ' + recoveryError.getMessage());
                    queueUserIndices = new Map<String, Integer>();
                }
            }
        }
        
        return states[0];
    }
    
    /**
     * @description Parse queue user indices from JSON string
     */
    private static Map<String, Integer> parseQueueUserIndices(String jsonString) {
        Map<String, Integer> result = new Map<String, Integer>();
        
        Map<String, Object> jsonMap = (Map<String, Object>) JSON.deserializeUntyped(jsonString);
        for (String key : jsonMap.keySet()) {
            Object value = jsonMap.get(key);
            if (value instanceof Integer) {
                result.put(key, (Integer) value);
            } else if (value instanceof Decimal) {
                result.put(key, ((Decimal) value).intValue());
            }
        }
        
        return result;
    }
    
    /**
     * @description Clean up high indices to prevent JSON size overflow
     */
    private static void cleanupHighIndices() {
        // Reset indices that are too high back to 0
        for (String queueId : queueUserIndices.keySet()) {
            Integer index = queueUserIndices.get(queueId);
            if (index > MAX_INDEX_BEFORE_RESET) {
                queueUserIndices.put(queueId, 0);
                System.debug(LoggingLevel.INFO, 'Reset high index for queue ' + queueId + ' from ' + index + ' to 0');
            }
        }
    }
    
    /**
     * @description Reset recursion tracking (for test context)
     */
    @TestVisible
    private static void resetRecursionTracking() {
        processedLeadIdsByContext.clear();
    }
    
    /**
     * @description Custom exception class
     */
    public class ApplicationException extends Exception {}
}