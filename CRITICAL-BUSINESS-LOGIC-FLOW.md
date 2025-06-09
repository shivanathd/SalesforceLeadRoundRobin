# CRITICAL BUSINESS LOGIC FLOW - Lead Round Robin System

## Business Logic Decision Tree (Actual Implementation)

```
START: Lead Record Change
│
├─ DECISION: Is this a BEFORE trigger?
│   │
│   ├─ YES: Continue to assignment logic
│   │   │
│   │   ├─ DECISION: Is this INSERT or UPDATE?
│   │   │   │
│   │   │   ├─ INSERT: Check if Route_to_Round_Robin__c = TRUE
│   │   │   │   │
│   │   │   │   ├─ TRUE + Processing Flag FALSE → ADD TO QUEUE
│   │   │   │   └─ FALSE or Processing Flag TRUE → SKIP
│   │   │   │
│   │   │   └─ UPDATE: Check if checkbox CHANGED to TRUE
│   │   │       │
│   │   │       ├─ Changed FALSE→TRUE + Processing Flag FALSE → ADD TO QUEUE
│   │   │       └─ Already TRUE or Processing Flag TRUE → SKIP
│   │   │
│   │   └─ PROCESS QUEUED LEADS
│   │
│   └─ NO: Is this AFTER trigger?
│       │
│       └─ YES: Update State Record (async)
│
└─ END
```

## Detailed Business Logic Implementation

### 1. LEAD QUALIFICATION LOGIC
```
BUSINESS RULE: Which leads qualify for round-robin?

INPUT: Lead Record
LOGIC:
  IF (Lead.IsConverted = TRUE) THEN
    REJECT with error "Cannot assign converted lead"
    RETURN
  
  IF (Trigger.isInsert) THEN
    IF (Lead.Route_to_Round_Robin__c = TRUE AND 
        Lead.Round_Robin_Processing__c ≠ TRUE) THEN
      QUALIFY for assignment
    END IF
  
  ELSE IF (Trigger.isUpdate) THEN
    IF (OLD.Route_to_Round_Robin__c ≠ TRUE AND
        NEW.Route_to_Round_Robin__c = TRUE AND
        NEW.Round_Robin_Processing__c ≠ TRUE) THEN
      QUALIFY for assignment
    END IF
  END IF

OUTPUT: List of qualified leads
```

### 2. RECURSION PREVENTION LOGIC
```
BUSINESS RULE: Prevent infinite loops and duplicate processing

CONTEXT TRACKING:
  Context = TriggerOperation + "_" + TriggerTiming
  Examples: "BEFORE_INSERT", "AFTER_UPDATE", "NON_TRIGGER"

LOGIC:
  FOR each Lead:
    IF (Lead.Id EXISTS in ProcessedIds[Context]) THEN
      SKIP with message "Lead already processed in this context"
    ELSE
      ADD Lead.Id to ProcessedIds[Context]
      PROCESS Lead
    END IF
```

### 3. QUEUE SELECTION LOGIC
```
BUSINESS RULE: Determine which queue gets the next lead

STATE VARIABLES:
  - Current_Queue_Index (persistent)
  - Active_Queues[] (sorted by Sort_Order)

LOGIC:
  1. LOAD Current_Queue_Index from database (default: 0)
  2. VALIDATE index: Current_Queue_Index = Current_Queue_Index MOD Queue_Count
  3. SELECT queue: Selected_Queue = Active_Queues[Current_Queue_Index]
  4. AFTER assignment: Current_Queue_Index = (Current_Queue_Index + 1) MOD Queue_Count

CRITICAL: Each queue gets exactly ONE lead before moving to next queue
```

### 4. USER SELECTION WITHIN QUEUE LOGIC
```
BUSINESS RULE: Determine which user in the queue gets the lead

STATE VARIABLES (per queue):
  - Queue_User_Indices{QueueId: UserIndex} (persistent JSON)

LOGIC:
  1. GET UserIndex = Queue_User_Indices[QueueId] OR 0
  2. GET QueueMembers[] for current queue
  3. LOOP starting at UserIndex:
     Member = QueueMembers[UserIndex MOD MemberCount]
     
     IF (Member.User.IsActive = TRUE) THEN
       ASSIGN Lead.OwnerId = Member.UserId
       Queue_User_Indices[QueueId] = UserIndex + 1
       RETURN success
     ELSE
       UserIndex = UserIndex + 1
       CONTINUE
     END IF
     
     IF (checked all members) THEN
       BREAK
     END IF
  4. IF no active user found:
     Queue_User_Indices[QueueId] = UserIndex (preserve position)
     TRY next queue
```

### 5. ASSIGNMENT EXECUTION LOGIC
```
BUSINESS RULE: Perform the actual lead assignment

FOR each Lead:
  Attempts = 0
  Assigned = FALSE
  
  WHILE (NOT Assigned AND Attempts < TotalQueues):
    CurrentQueue = GetNextQueue()
    
    IF (CurrentQueue has members) THEN
      SelectedUser = GetNextUserInQueue(CurrentQueue)
      
      IF (SelectedUser found) THEN
        // Core Assignment
        Lead.OwnerId = SelectedUser.Id
        Lead.Assigned_Through_Round_Robin__c = TRUE
        Lead.Round_Robin_Assignment_DateTime__c = NOW()
        Lead.Round_Robin_Queue__c = CurrentQueue.DeveloperName
        
        // Audit Fields (if exist)
        Lead.Round_Robin_Triggered_By__c = CurrentUser.Id
        Lead.Round_Robin_Source__c = DetermineSource()
        
        // Update State
        IncrementQueueIndex()
        IncrementUserIndex(CurrentQueue)
        State.Total_Assignments__c++
        State.Last_Assigned_User__c = SelectedUser.Id
        State.Last_Assignment_DateTime__c = NOW()
        
        Assigned = TRUE
      END IF
    END IF
    
    IF (NOT Assigned) THEN
      MoveToNextQueue()
      Attempts++
    END IF
  END WHILE
  
  IF (NOT Assigned) THEN
    ERROR "No active users in any queue"
  END IF
```

### 6. CHECKBOX BEHAVIOR LOGIC
```
BUSINESS RULE: Checkbox acts as trigger and retry mechanism

SUCCESS PATH:
  1. User checks Route_to_Round_Robin__c = TRUE
  2. System assigns lead
  3. System sets Route_to_Round_Robin__c = FALSE
  4. User sees checkbox cleared = success indicator

FAILURE PATH:
  1. User checks Route_to_Round_Robin__c = TRUE
  2. System fails to assign (no active users)
  3. System keeps Route_to_Round_Robin__c = TRUE
  4. System sets Last_Round_Robin_Error__c = error message
  5. System sets Last_Round_Robin_Attempt__c = NOW()
  6. User sees checkbox still checked = retry needed
```

### 7. STATE PERSISTENCE LOGIC
```
BUSINESS RULE: Maintain assignment position across transactions

DATA STRUCTURE:
  Round_Robin_Assignment_State__c {
    Current_Queue_Index__c: Number
    Queue_User_Indices__c: JSON String (max 32KB)
    Total_Assignments__c: Number
    Last_Assignment_DateTime__c: DateTime
    Last_Assigned_User__c: User Lookup
  }

JSON FORMAT:
  {
    "00G5f000004CSV1": 5,    // Queue1 at user index 5
    "00G5f000004CSV2": 12,   // Queue2 at user index 12
    "00G5f000004CSV3": 0     // Queue3 at user index 0
  }

CLEANUP LOGIC:
  IF (JSON.length > 30KB) THEN
    FOR each QueueId in indices:
      IF (index > 10000) THEN
        RESET to 0
      END IF
  END IF
```

### 8. SOURCE DETERMINATION LOGIC
```
BUSINESS RULE: Track how the assignment was triggered

LOGIC:
  IF (System.isBatch()) RETURN "Batch"
  ELSE IF (System.isFuture()) RETURN "Future"
  ELSE IF (System.isQueueable()) RETURN "Queueable"
  ELSE IF (System.isScheduled()) RETURN "Scheduled"
  ELSE IF (Trigger.isExecuting) THEN
    IF (Trigger.new.size() > 50) RETURN "Data Loader"
    ELSE RETURN "Manual"
  ELSE
    RETURN "API"
```

### 9. ERROR HANDLING BUSINESS LOGIC
```
BUSINESS RULE: Graceful degradation and clear error communication

ERROR HIERARCHY:
  1. Security Errors → Block all operations
  2. No Active Queues → Inform admin
  3. No Queue Members → Inform admin
  4. No Active Users → Keep for retry
  5. State Corruption → Attempt recovery

RECOVERY LOGIC:
  IF (State JSON corrupted) THEN
    1. Try to parse and preserve valid entries
    2. If fails, start fresh but log error
    3. Continue operation (don't block business)
  END IF
```

### 10. DISTRIBUTION FAIRNESS LOGIC
```
BUSINESS RULE: Equal distribution BY QUEUE, not by user

MATHEMATICAL PROOF:
  Given:
    - Queue A: 2 users
    - Queue B: 20 users
    - 1000 leads to assign
  
  Result:
    - Queue A: 500 leads (250 per user)
    - Queue B: 500 leads (25 per user)
  
  IMPLICATION: Users in smaller queues get MORE leads
```

## Critical Business Logic Discoveries

### 1. ASSIGNMENT PATTERN
```
Lead 1 → Queue1.User1
Lead 2 → Queue2.User1
Lead 3 → Queue3.User1
Lead 4 → Queue1.User2  // Back to Queue1, next user
Lead 5 → Queue2.User2
Lead 6 → Queue3.User2
...continues...
```

### 2. SKIP PATTERNS
```
IF Queue2.User2 is inactive:
  Lead 5 → Queue2.User3 (skip inactive)
  
IF Queue2 has NO active users:
  Lead 2 → Queue3.User1 (skip entire queue)
  Lead 5 → Queue3.User2 (Queue2 still skipped)
```

### 3. STATE RECOVERY
```
IF System crashes after Lead 3:
  State preserved:
    Current_Queue_Index = 0 (back to Queue1)
    Queue1.UserIndex = 2
    Queue2.UserIndex = 1
    Queue3.UserIndex = 1
  
  Next assignment:
    Lead 4 → Queue1.User2 (continues from saved state)
```

### 4. EDGE CASES HANDLED
```
1. All users inactive in one queue → Skip to next queue
2. All users inactive in ALL queues → Error, keep checkbox
3. Queue deleted from config → Skip gracefully
4. User deactivated mid-process → Skip to next user
5. State record locked → Retry with new query
6. JSON too large → Cleanup high indices
```

### 5. BUSINESS ASSUMPTIONS CODED
```
1. All queues deserve equal lead flow
2. Active in Salesforce = Available for leads
3. Failed assignments should be manually retried
4. Historical position more important than current availability
5. No business hours consideration needed
6. No skill matching required
7. No workload balancing needed
8. No lead quality scoring
```

## Business Logic Validation Points

### Entry Validation
- ✓ Lead not converted
- ✓ Checkbox is checked (INSERT) or changed to checked (UPDATE)
- ✓ Not already processing (recursion check)

### Configuration Validation
- ✓ At least one active queue exists
- ✓ At least one queue has members
- ✓ Queue IDs are valid format
- ✓ Sort order provides deterministic sequence

### Assignment Validation
- ✓ Selected user is active
- ✓ User can own leads (implicit by queue membership)
- ✓ State updates are atomic

### Exit Validation
- ✓ Success: Lead assigned, checkbox cleared
- ✓ Failure: Lead not assigned, checkbox retained, error logged

## Business Impact Analysis

### Positive Business Outcomes
1. Automated lead distribution (reduces manual work)
2. Fair rotation within queues (equal opportunity)
3. Audit trail for compliance (who assigned what when)
4. Retry mechanism for failures (checkbox stays checked)

### Negative Business Impacts
1. Unequal distribution between different-sized teams
2. No consideration of user availability/capacity
3. No intelligent routing based on skills/geography
4. Manual intervention required for all failures
5. Hard limit on scalability (32KB JSON storage)

## Critical Business Logic Summary

**The system implements a strict round-robin that:**
1. Rotates between QUEUES first (each queue gets one lead)
2. Rotates between USERS within each queue second
3. Preserves position even when users are skipped
4. Treats all queues equally regardless of size
5. Provides checkbox-based triggering and retry
6. Maintains complete audit trail
7. Fails gracefully with clear error messages

**This is NOT a user-balanced distribution system - it's a queue-balanced system that can create significant workload imbalances.**