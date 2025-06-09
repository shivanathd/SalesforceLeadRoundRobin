# How to Bypass Round Robin for Specific Records

## Solution: Add a Bypass Field

### Step 1: Create New Field on Lead Object

**Field Details:**
- **Label**: Bypass Round Robin
- **API Name**: `Bypass_Round_Robin__c`
- **Type**: Checkbox
- **Default Value**: False
- **Description**: When checked, this lead will not be processed by round robin even if Route to Round Robin is checked
- **Visibility**: Available only to System Administrators

### Step 2: Modify the Trigger Logic

Update `LeadRoundRobinTrigger.trigger` to check for bypass:

```apex
trigger LeadRoundRobinTrigger on Lead (before insert, before update, after insert, after update) {
    
    if (Trigger.isBefore) {
        List<Lead> leadsToRoute = new List<Lead>();
        
        if (Trigger.isInsert) {
            for (Lead newLead : Trigger.new) {
                // ADD THIS CHECK FOR BYPASS
                if (newLead.Route_to_Round_Robin__c == true && 
                    newLead.Round_Robin_Processing__c != true &&
                    newLead.Bypass_Round_Robin__c != true) {  // ← NEW CHECK
                    leadsToRoute.add(newLead);
                }
            }
        } else if (Trigger.isUpdate) {
            for (Lead newLead : Trigger.new) {
                Lead oldLead = Trigger.oldMap.get(newLead.Id);
                
                // ADD THIS CHECK FOR BYPASS
                if (newLead.Route_to_Round_Robin__c == true && 
                    (oldLead.Route_to_Round_Robin__c != true) &&
                    newLead.Round_Robin_Processing__c != true &&
                    newLead.Bypass_Round_Robin__c != true) {  // ← NEW CHECK
                    leadsToRoute.add(newLead);
                }
            }
        }
        
        // Rest of trigger remains the same...
    }
}
```

### Step 3: Usage Examples

#### Example 1: Restore Deleted Lead with Original Owner
```apex
Lead restoredLead = new Lead(
    FirstName = 'John',
    LastName = 'Doe',
    Company = 'Acme Corp',
    OwnerId = '005xxx...',  // Original owner
    Route_to_Round_Robin__c = false,
    Bypass_Round_Robin__c = true  // Just in case
);
insert restoredLead;
```

#### Example 2: Import Historical Data
```csv
FirstName,LastName,Company,OwnerId,Bypass_Round_Robin__c
John,Doe,Acme,005xxx...,TRUE
Jane,Smith,TechCorp,005yyy...,TRUE
```

## Alternative Solutions Without Code Changes

### Option 1: Recycle Bin Recovery
If the record was recently deleted (last 15 days):
1. Go to Recycle Bin
2. Find the lead record
3. Click "Undelete"
4. Lead returns with original owner

### Option 2: Data Loader with Owner Assignment
```csv
FirstName,LastName,Company,OwnerId,Route_to_Round_Robin__c
John,Doe,Acme,005xxx...,FALSE
```
Import with OwnerId specified and Route_to_Round_Robin__c = FALSE

### Option 3: Two-Step Process
1. Insert lead without round robin checkbox
2. Manually assign to desired queue/user
3. Don't check the round robin checkbox

### Option 4: Temporary Queue Deactivation
1. Deactivate all queues except the target queue in Custom Metadata
2. Insert record with round robin (it can only go to one queue)
3. Reactivate other queues

## Best Practices for Handling Deletions

### 1. Soft Delete Pattern
Instead of deleting, consider:
- Add a "Status" field with "Cancelled" option
- Add an "Is_Deleted__c" checkbox
- Filter these out in views/reports

### 2. Audit Before Delete
Create a process that:
- Captures owner information before deletion
- Stores in a custom object or field
- Makes restoration easier

### 3. Use Recycle Bin
- Salesforce keeps deleted records for 15 days
- Undelete preserves original owner
- No round robin triggered on undelete

## Quick Decision Tree

```
Need to restore a deleted lead?
│
├─ Deleted < 15 days ago?
│  └─ YES → Use Recycle Bin Undelete
│
├─ Know original owner?
│  └─ YES → Direct assignment with OwnerId
│
├─ Want specific queue?
│  └─ YES → Query queue ID and assign directly
│
└─ Need this frequently?
   └─ YES → Implement Bypass field solution
```

## Summary

**For one-time fixes**: Use direct owner assignment or recycle bin
**For regular occurrence**: Implement the Bypass Round Robin field
**For bulk operations**: Use Data Loader with OwnerId specified

The key is to **avoid triggering the round robin checkbox** when you want to control the assignment manually.