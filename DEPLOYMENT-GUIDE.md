# 🚀 Salesforce Lead Round Robin - Deployment Guide

## Pre-Deployment Checklist

### ✅ All Issues Fixed
1. **Metadata Structure**: All field definitions created
2. **File Extensions**: Custom metadata records renamed to `.md-meta.xml`
3. **Package Order**: Correct deployment sequence in package.xml
4. **Code Safety**: Null-safe Boolean comparison implemented
5. **Validation Tool**: DeploymentValidator class added

## 🎯 Deployment Steps

### Step 1: Create a Scratch Org (Optional)
```bash
sf org create scratch -f config/project-scratch-def.json -a rr-test -d 7
sf org open -o rr-test
```

### Step 2: Deploy Metadata
```bash
# Deploy everything at once
sf project deploy start --manifest manifest/package.xml -o YOUR_ORG_ALIAS

# OR deploy in phases for troubleshooting
# Phase 1: Schema
sf project deploy start -d force-app/main/default/objects -o YOUR_ORG_ALIAS

# Phase 2: Custom Metadata
sf project deploy start -d force-app/main/default/customMetadata -o YOUR_ORG_ALIAS

# Phase 3: Apex Code
sf project deploy start -d force-app/main/default/classes,force-app/main/default/triggers -o YOUR_ORG_ALIAS
```

### Step 3: Post-Deployment Configuration

#### 1. Create Queues
1. Go to Setup → Queues
2. Create your sales queues (e.g., "Enterprise Sales", "SMB Sales")
3. Add Lead as a supported object
4. Add queue members
5. Copy the Queue ID (starts with 00G)

#### 2. Update Custom Metadata Records
1. Go to Setup → Custom Metadata Types
2. Find "Round Robin Queue Config"
3. Update the example records with your actual Queue IDs
4. Or create new records for your queues

#### 3. Run Validation
Execute this in Developer Console (Anonymous Apex):
```apex
// Run full validation
System.debug(RoundRobinDeploymentValidator.runFullValidation());

// Test simple assignment (after queue setup)
System.debug(RoundRobinDeploymentValidator.testSimpleAssignment());
```

#### 4. Add Fields to Page Layout
1. Go to Setup → Object Manager → Lead → Page Layouts
2. Add these fields to your layout:
   - **User Section**: Route to Round Robin (checkbox)
   - **Read-Only Section**: 
     - Round Robin Assignment Date/Time
     - Round Robin Queue
     - Last Round Robin Error

### Step 4: Run Tests
```bash
# Run all tests
sf apex run test -l RunLocalTests -w 10 -o YOUR_ORG_ALIAS

# Run specific test class
sf apex run test -n RoundRobinAssignmentHandlerTest -r human -o YOUR_ORG_ALIAS
```

## 🔍 Validation Output Example

After running the validator, you should see:
```
=== ROUND ROBIN DEPLOYMENT VALIDATION REPORT ===

1. LEAD FIELDS VALIDATION:
   route_to_round_robin__c: ✅ PASS
   round_robin_processing__c: ✅ PASS
   assigned_through_round_robin__c: ✅ PASS
   round_robin_assignment_datetime__c: ✅ PASS
   round_robin_queue__c: ✅ PASS
   round_robin_triggered_by__c: ✅ PASS
   round_robin_source__c: ✅ PASS
   last_round_robin_error__c: ✅ PASS
   last_round_robin_attempt__c: ✅ PASS

2. STATE OBJECT VALIDATION:
   Round_Robin_Assignment_State__c object: ✅ PASS
   current_queue_index__c: ✅ PASS
   queue_user_indices__c: ✅ PASS
   total_assignments__c: ✅ PASS
   last_assignment_datetime__c: ✅ PASS
   last_assigned_user__c: ✅ PASS

3. METADATA TYPE VALIDATION:
   Round_Robin_Queue_Config__mdt type: ✅ PASS
   Has metadata records: ✅ PASS
```

## 🐛 Troubleshooting

### Common Deployment Errors

| Error | Cause | Solution |
|-------|-------|----------|
| "Invalid field: Route_to_Round_Robin__c" | Fields not deployed | Deploy objects folder first |
| "Dependent class is invalid" | Wrong deployment order | Use phased deployment |
| "No such column" | Case sensitivity | Check field API names |
| "Test coverage below 75%" | Tests not running | Run tests with `-l RunLocalTests` |

### Validation Failures

If the validator shows failures:
1. Check deployment logs: `sf project deploy report`
2. Verify API version compatibility
3. Ensure you're deploying to the correct org
4. Check for namespace conflicts

## 📊 Testing the System

### Manual Test
1. Create a new Lead
2. Check "Route to Round Robin"
3. Save the record
4. Verify:
   - Owner changed to a queue member
   - Checkbox is now unchecked
   - Assignment DateTime is populated
   - Queue name is recorded

### Bulk Test
```apex
// Create 50 test leads
List<Lead> testLeads = new List<Lead>();
for(Integer i = 0; i < 50; i++) {
    testLeads.add(new Lead(
        FirstName = 'Test',
        LastName = 'Lead ' + i,
        Company = 'Test Company ' + i,
        Route_to_Round_Robin__c = true
    ));
}
insert testLeads;

// Check distribution
Map<Id, Integer> ownerCounts = new Map<Id, Integer>();
for(Lead l : [SELECT OwnerId FROM Lead WHERE Id IN :testLeads]) {
    Integer count = ownerCounts.get(l.OwnerId) ?? 0;
    ownerCounts.put(l.OwnerId, count + 1);
}
System.debug('Distribution: ' + ownerCounts);
```

## ✅ Success Criteria

Your deployment is successful when:
1. All validation checks pass ✅
2. Test coverage is above 75% ✅
3. Manual lead assignment works ✅
4. Bulk operations complete without errors ✅
5. Error messages appear for invalid configurations ✅

## 🎉 Congratulations!

Your Salesforce Lead Round Robin system is now deployed and ready for use. The system will automatically distribute leads fairly across your configured queues.