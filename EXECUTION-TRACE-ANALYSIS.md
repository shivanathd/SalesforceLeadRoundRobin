# EXECUTION TRACE: Lead Round Robin Business Logic

## Complete Step-by-Step Execution Analysis

### Phase 1: Trigger Entry (LeadRoundRobinTrigger.trigger)

#### Execution Path for INSERT Context
```
Line 6:  trigger LeadRoundRobinTrigger on Lead (before insert, before update, after insert, after update)
Line 8:  if (Trigger.isBefore) → TRUE for before insert
Line 9:  List<Lead> leadsToRoute = new List<Lead>();
Line 11: if (Trigger.isInsert) → TRUE
Line 13: for (Lead newLead : Trigger.new) {
Line 14:   if (newLead.Route_to_Round_Robin__c == true && 
Line 15:       newLead.Round_Robin_Processing__c != true) {
Line 16:     leadsToRoute.add(newLead);
Line 17:   }
Line 18: }
```

**Business Rule Encoded**:
- User must check Route_to_Round_Robin__c checkbox
- System must not be already processing (Round_Robin_Processing__c != true)
- Only qualifies NEW leads (INSERT context)

#### Execution Path for UPDATE Context
```
Line 19: else if (Trigger.isUpdate) → TRUE for updates
Line 21: for (Lead newLead : Trigger.new) {
Line 22:   Lead oldLead = Trigger.oldMap.get(newLead.Id);
Line 25:   if (newLead.Route_to_Round_Robin__c == true && 
Line 26:       (oldLead.Route_to_Round_Robin__c != true) &&
Line 27:       newLead.Round_Robin_Processing__c != true) {
Line 28:     leadsToRoute.add(newLead);
Line 29:   }
Line 30: }
```

**Business Rule Encoded**:
- Checkbox must CHANGE from false/null to true
- Not triggered if checkbox already true (prevents re-processing)
- Must not be already processing

#### Main Processing Block
```
Line 34: if (!leadsToRoute.isEmpty()) {
Line 36:   for (Lead lead : leadsToRoute) {
Line 37:     lead.Round_Robin_Processing__c = true;  // Recursion prevention
Line 38:   }
Line 41:   Map<Id, RoundRobinAssignmentHandler.AssignmentResult> results = 
Line 42:     RoundRobinAssignmentHandler.assignLeads(leadsToRoute);
```

**Critical Business Logic**:
1. Processing flag set BEFORE assignment
2. Single call to handler with all qualified leads (bulk processing)
3. Results returned as Map for each lead

#### Result Processing Logic
```
Line 45: Map<String, Schema.SObjectField> fieldMap = Schema.sObjectType.Lead.fields.getMap();
Line 47: for (Lead lead : leadsToRoute) {
Line 48:   RoundRobinAssignmentHandler.AssignmentResult result = results.get(lead.Id);
Line 50:   if (result != null && result.success) {
         // SUCCESS PATH
Line 52:     lead.Route_to_Round_Robin__c = false;  // Clear checkbox
Line 53:     lead.Round_Robin_Processing__c = false; // Clear processing flag
Line 56:     if (fieldMap.containsKey('last_round_robin_error__c')) {
Line 57:       lead.put('Last_Round_Robin_Error__c', null);  // Clear error
Line 58:     }
Line 59:   } else {
         // FAILURE PATH
Line 62:     lead.Round_Robin_Processing__c = false; // Clear processing flag only
         // NOTE: Route_to_Round_Robin__c stays TRUE for retry
Line 65:     if (fieldMap.containsKey('last_round_robin_error__c') && 
Line 66:         result != null && 
Line 67:         String.isNotBlank(result.errorMessage)) {
Line 68:       lead.put('Last_Round_Robin_Error__c', result.errorMessage);
Line 69:     }
Line 72:     if (fieldMap.containsKey('last_round_robin_attempt__c')) {
Line 73:       lead.put('Last_Round_Robin_Attempt__c', System.now());
Line 74:     }
Line 75:   }
Line 76: }
```

**Critical Business Behavior**:
- **Success**: Checkbox cleared automatically → User sees success
- **Failure**: Checkbox stays checked → User can retry manually
- **Error tracking**: Optional fields capture failure details

### Phase 2: Handler Processing (RoundRobinAssignmentHandler.cls)

#### Entry Point Analysis
```
Line 105: public static Map<Id, AssignmentResult> assignLeads(List<Lead> newLeads)
Line 108: if (newLeads == null || newLeads.isEmpty()) {
Line 109:   return results; // Empty map
Line 110: }
```

#### Security Validation
```
Line 114: validateSecurityPermissions();
```
**Execution Path**:
```
Line 290: if (!Schema.sObjectType.Lead.isUpdateable()) {
Line 291:   throw new SecurityException('Insufficient privileges to update Lead records');
Line 292: }
Line 295-310: Check field-level security for required fields
```

#### Lead Filtering
```
Line 120: List<Lead> validLeads = filterValidLeads(newLeads, results);
```
**Execution Path**:
```
Line 264-270: Skip converted leads
Line 265: if (lead.IsConverted) {
Line 266:   String errorMsg = 'Cannot assign converted lead through round robin';
Line 267:   lead.addError(errorMsg);
Line 268:   results.put(lead.Id, new AssignmentResult(false, errorMsg));
Line 269:   continue;
Line 270: }
```

#### Recursion Prevention
```
Line 126: Set<Id> processedIds = getProcessedLeadIds();
Line 129: if (lead.Id != null && processedIds.contains(lead.Id)) {
Line 130:   results.put(lead.Id, new AssignmentResult(false, 'Lead already processed in this context'));
Line 134:   processedIds.add(lead.Id);
```

**Context-Aware Logic**:
```
Line 38-46: String context = Trigger.isExecuting ? 
               (Trigger.isBefore ? 'BEFORE' : 'AFTER') + '_' + 
               (Trigger.isInsert ? 'INSERT' : 'UPDATE') : 
               'NON_TRIGGER';
```

#### Configuration Loading
```
Line 145: loadQueueConfigurations();
Line 148: assignmentState = getOrCreateAssignmentState();
Line 151: List<Round_Robin_Queue_Config__mdt> activeQueues = getActiveQueues();
```

#### Queue Validation
```
Line 153-160: if (activeQueues.isEmpty()) {
               String errorMsg = 'No active queues configured for round robin assignment';
               for (Lead lead : validLeads) {
                 lead.addError(errorMsg);
                 results.put(lead.Id, new AssignmentResult(false, errorMsg));
               }
               return results;
             }
```

#### Pre-fetching for Performance
```
Line 178: prefetchQueueMembers(activeQueues);
Line 181: prefetchActiveUsers();
```

**Single Query Pattern**:
```
Line 329-336: List<GroupMember> allMembers = [
                SELECT Id, UserOrGroupId, GroupId
                FROM GroupMember
                WHERE GroupId IN :queueIds
                  AND Group.Type = 'Queue'
                  AND UserOrGroupId IN (SELECT Id FROM User WHERE IsActive = true)
                ORDER BY GroupId, SystemModstamp
              ];
```

### Phase 3: Core Assignment Algorithm

#### Main Assignment Loop
```
Line 203: assignLeadsBulk(validLeads, activeQueues, results);
```

#### Queue Index Management
```
Line 390-392: Integer currentQueueIndex = assignmentState.Current_Queue_Index__c != null 
                ? Integer.valueOf(assignmentState.Current_Queue_Index__c) 
                : 0;
Line 400: currentQueueIndex = Math.mod(currentQueueIndex, totalQueues);
```

#### Lead Assignment Logic
```
Line 407: for (Lead lead : leadsToAssign) {
Line 408:   Boolean assigned = false;
Line 409:   Integer attempts = 0;
Line 413:   while (!assigned && attempts < totalQueues) {
Line 414:     Round_Robin_Queue_Config__mdt currentQueue = activeQueues[currentQueueIndex];
Line 415:     List<GroupMember> members = queueMembersCache.get(currentQueue.Queue_ID__c);
```

#### User Selection Within Queue
```
Line 419-421: Integer userIndex = queueUserIndices.containsKey(currentQueue.Queue_ID__c) 
                ? queueUserIndices.get(currentQueue.Queue_ID__c) 
                : 0;
Line 432-434: while (!foundActiveUser && usersChecked < members.size()) {
                GroupMember assignedMember = members[Math.mod(userIndex, members.size())];
                Boolean isActive = activeUsersCache.get(assignedMember.UserOrGroupId);
```

#### Assignment Execution
```
Line 439: if (Boolean.TRUE.equals(isActive)) {
Line 441:   lead.OwnerId = assignedMember.UserOrGroupId;
Line 442:   lead.Assigned_Through_Round_Robin__c = true;
Line 443:   lead.Round_Robin_Assignment_DateTime__c = currentTime;
Line 444:   lead.Round_Robin_Queue__c = currentQueue.Queue_Developer_Name__c;
```

#### State Updates
```
Line 455: queueUserIndices.put(currentQueue.Queue_ID__c, userIndex + 1);
Line 456: assignmentState.Total_Assignments__c++;
Line 457: assignmentState.Last_Assigned_User__c = assignedMember.UserOrGroupId;
Line 458: assignmentState.Last_Assignment_DateTime__c = currentTime;
Line 469: currentQueueIndex = Math.mod(currentQueueIndex + 1, totalQueues);
```

### Phase 4: AFTER Trigger Processing

#### State Persistence
```
Line 81-84: if (Trigger.isAfter) {
              RoundRobinAssignmentHandler.updateAssignmentStateAfterTrigger();
            }
```

#### JSON State Management
```
Line 232-250: if (stateNeedsUpdate && assignmentState != null && queueUserIndices != null) {
                String jsonString = JSON.serialize(queueUserIndices);
                if (jsonString.length() > 30000) {
                  cleanupHighIndices();
                }
                assignmentState.Queue_User_Indices__c = jsonString;
                update assignmentState;
              }
```

## Critical Business Logic Discovered

### 1. Checkbox Behavior Pattern
```
USER ACTION: Checks Route_to_Round_Robin__c = TRUE
SYSTEM RESPONSE: 
  - If success → Clears checkbox (FALSE)
  - If failure → Keeps checkbox (TRUE) for retry
```

### 2. Queue Rotation Logic
```
ALGORITHM: currentQueueIndex = (currentQueueIndex + 1) % totalQueues
EFFECT: Each queue gets exactly ONE lead before rotating
BUSINESS IMPACT: Equal distribution by QUEUE, not by USER
```

### 3. User Rotation Logic  
```
ALGORITHM: userIndex = (userIndex + 1) % memberCount
PERSISTENCE: Per-queue user position maintained in JSON
BEHAVIOR: Sequential assignment within each queue
```

### 4. Recursion Prevention
```
TRACKING: processedLeadIdsByContext[context].contains(leadId)
CONTEXTS: "BEFORE_INSERT", "BEFORE_UPDATE", "AFTER_INSERT", etc.
ISOLATION: Each context tracks separately
```

### 5. Error Handling Strategy
```
SECURITY ERRORS: Block all operations, throw exception
NO QUEUES: Error all leads, return immediately  
NO USERS: Error individual lead, continue with others
STATE CORRUPTION: Attempt recovery, log, continue
```

## Execution Flow Summary

1. **Trigger Entry**: Checkbox check determines qualification
2. **Security Check**: CRUD/FLS validation
3. **Lead Filtering**: Remove converted leads
4. **Recursion Check**: Context-aware duplicate prevention
5. **Configuration Load**: Custom metadata + state retrieval
6. **Pre-fetching**: Single queries for all related data
7. **Assignment Loop**: Queue → User rotation algorithm
8. **Result Processing**: Success clears checkbox, failure keeps it
9. **State Persistence**: JSON serialization in AFTER trigger

## Business Logic Validation

✅ **Queue Fairness**: Each queue gets equal lead count
✅ **User Fairness**: Within queue, users get sequential rotation
✅ **Retry Mechanism**: Failed assignments keep checkbox for retry
✅ **Audit Trail**: Complete tracking of who, when, which queue
✅ **Performance**: Bulk processing with single queries
✅ **Security**: CRUD/FLS validation before operations
✅ **Error Handling**: Graceful degradation with clear messages

**CRITICAL FINDING**: System implements queue-balanced distribution, not user-balanced distribution. This can cause workload imbalance when teams have different sizes.