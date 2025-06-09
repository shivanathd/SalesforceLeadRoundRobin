# Deployment Error Fixes

## Errors Fixed (January 2025)

### 1. Invalid Type: RoundRobinAssignmentHandler.AssignmentResult
**Error**: `Invalid type: RoundRobinAssignmentHandler.AssignmentResult (41:13)`
**Cause**: Inner class visibility issue in Apex
**Fix**: Changed `public class AssignmentResult` to `global class AssignmentResult` to ensure visibility across all contexts

### 2. Invalid CustomObject Names
**Errors**: 
- `Invalid fullName, must end in a custom suffix (e.g. __c)` for Lead_Audit_Fields
- `Invalid fullName, must end in a custom suffix (e.g. __c)` for Lead_RoundRobin_Fields

**Cause**: Invalid object files that shouldn't exist
**Fix**: Deleted these files as they were incorrectly structured. The fields are properly defined under the Lead object in `/objects/Lead/fields/`

### 3. ORDER BY with FOR UPDATE Error
**Errors**:
- `Explicit ORDER BY not allowed when locking rows (Id order is implied) (574:56)`
- `Explicit ORDER BY not allowed when locking rows (Id order is implied) (597:26)`

**Cause**: Salesforce doesn't allow explicit ORDER BY when using FOR UPDATE (row locking)
**Fix**: Removed `ORDER BY CreatedDate DESC` from both SOQL queries that use `FOR UPDATE`

### 4. Dependent Class Compilation Error
**Error**: `Dependent class is invalid and needs recompilation`
**Cause**: RoundRobinAssignmentHandlerTest depends on RoundRobinAssignmentHandler which had errors
**Fix**: Fixed the parent class errors, which automatically resolves the test class compilation

## Summary of Changes

1. **Removed invalid object files**:
   - `force-app/main/default/objects/Lead_Audit_Fields.object`
   - `force-app/main/default/objects/Lead_RoundRobin_Fields.object`

2. **Updated RoundRobinAssignmentHandler.cls**:
   - Line 56: Changed `public class AssignmentResult` to `global class AssignmentResult`
   - Line 603: Removed `ORDER BY CreatedDate DESC` from SOQL with FOR UPDATE
   - Line 625: Removed `ORDER BY CreatedDate DESC` from SOQL with FOR UPDATE

3. **No changes needed to package.xml** - the invalid objects were not referenced

## Deployment Commands

After these fixes, deploy using:

```bash
# Option 1: Deploy with metadata records
sf project deploy start --manifest manifest/package.xml

# Option 2: Deploy without metadata records (safer for first deployment)
sf project deploy start --manifest manifest/package-without-metadata-records.xml
```

## Post-Deployment Steps

1. Update the placeholder Queue IDs in Custom Metadata records:
   - Replace `REPLACE_WITH_ACTUAL_QUEUE_ID_1` with your actual Queue ID
   - Replace `REPLACE_WITH_ACTUAL_QUEUE_ID_2` with your actual Queue ID

2. Run all tests to ensure >75% code coverage:
   ```bash
   sf apex run test --classnames RoundRobinAssignmentHandlerTest --resultformat human
   ```

3. Validate the deployment using the RoundRobinDeploymentValidator class