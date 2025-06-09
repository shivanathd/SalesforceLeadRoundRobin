/**
 * @description Utility class to validate Round Robin deployment and configuration
 * Run this after deployment to ensure all components are properly installed
 */
public with sharing class RoundRobinDeploymentValidator {
    
    /**
     * @description Validates that all required fields exist on Lead object
     * @return Map of field names to validation results
     */
    public static Map<String, Boolean> validateLeadFields() {
        Map<String, Boolean> results = new Map<String, Boolean>();
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Lead.fields.getMap();
        
        // List of required fields
        List<String> requiredFields = new List<String>{
            'route_to_round_robin__c',
            'round_robin_processing__c',
            'assigned_through_round_robin__c',
            'round_robin_assignment_datetime__c',
            'round_robin_queue__c',
            'round_robin_triggered_by__c',
            'round_robin_source__c',
            'last_round_robin_error__c',
            'last_round_robin_attempt__c'
        };
        
        for (String fieldName : requiredFields) {
            results.put(fieldName, fieldMap.containsKey(fieldName));
        }
        
        return results;
    }
    
    /**
     * @description Validates Round_Robin_Assignment_State__c object and fields
     * @return Map of component names to validation results
     */
    public static Map<String, Boolean> validateStateObject() {
        Map<String, Boolean> results = new Map<String, Boolean>();
        
        try {
            // Check if object exists by attempting to describe it
            Schema.DescribeSObjectResult stateDescribe = Round_Robin_Assignment_State__c.sObjectType.getDescribe();
            results.put('Round_Robin_Assignment_State__c object', true);
            
            // Check fields
            Map<String, Schema.SObjectField> fieldMap = stateDescribe.fields.getMap();
            results.put('current_queue_index__c', fieldMap.containsKey('current_queue_index__c'));
            results.put('queue_user_indices__c', fieldMap.containsKey('queue_user_indices__c'));
            results.put('total_assignments__c', fieldMap.containsKey('total_assignments__c'));
            results.put('last_assignment_datetime__c', fieldMap.containsKey('last_assignment_datetime__c'));
            results.put('last_assigned_user__c', fieldMap.containsKey('last_assigned_user__c'));
            
        } catch (Exception e) {
            results.put('Round_Robin_Assignment_State__c object', false);
        }
        
        return results;
    }
    
    /**
     * @description Validates Round_Robin_Queue_Config__mdt and its fields
     * @return Map of component names to validation results
     */
    public static Map<String, Boolean> validateMetadataType() {
        Map<String, Boolean> results = new Map<String, Boolean>();
        
        try {
            // Check if metadata type exists
            List<Round_Robin_Queue_Config__mdt> configs = Round_Robin_Queue_Config__mdt.getAll().values();
            results.put('Round_Robin_Queue_Config__mdt type', true);
            results.put('Has metadata records', !configs.isEmpty());
            
            // Validate each config record
            for (Round_Robin_Queue_Config__mdt config : configs) {
                String recordKey = 'Config: ' + config.DeveloperName;
                Boolean isValid = String.isNotBlank(config.Queue_ID__c) 
                    && String.isNotBlank(config.Queue_Developer_Name__c)
                    && config.Sort_Order__c != null;
                results.put(recordKey, isValid);
            }
            
        } catch (Exception e) {
            results.put('Round_Robin_Queue_Config__mdt type', false);
        }
        
        return results;
    }
    
    /**
     * @description Runs all validations and returns comprehensive results
     * @return String formatted validation report
     */
    public static String runFullValidation() {
        String report = '=== ROUND ROBIN DEPLOYMENT VALIDATION REPORT ===\n\n';
        
        // Validate Lead fields
        report += '1. LEAD FIELDS VALIDATION:\n';
        Map<String, Boolean> leadResults = validateLeadFields();
        for (String field : leadResults.keySet()) {
            report += '   ' + field + ': ' + (leadResults.get(field) ? '✅ PASS' : '❌ FAIL') + '\n';
        }
        
        // Validate State object
        report += '\n2. STATE OBJECT VALIDATION:\n';
        Map<String, Boolean> stateResults = validateStateObject();
        for (String component : stateResults.keySet()) {
            report += '   ' + component + ': ' + (stateResults.get(component) ? '✅ PASS' : '❌ FAIL') + '\n';
        }
        
        // Validate Metadata type
        report += '\n3. METADATA TYPE VALIDATION:\n';
        Map<String, Boolean> metadataResults = validateMetadataType();
        for (String component : metadataResults.keySet()) {
            report += '   ' + component + ': ' + (metadataResults.get(component) ? '✅ PASS' : '❌ FAIL') + '\n';
        }
        
        // Check for active queues
        report += '\n4. QUEUE VALIDATION:\n';
        try {
            List<Group> queues = [SELECT Id, Name FROM Group WHERE Type = 'Queue' LIMIT 5];
            report += '   Found ' + queues.size() + ' queue(s) in org\n';
            for (Group q : queues) {
                report += '   - ' + q.Name + ' (ID: ' + q.Id + ')\n';
            }
        } catch (Exception e) {
            report += '   ❌ Error checking queues: ' + e.getMessage() + '\n';
        }
        
        // Summary
        report += '\n=== VALIDATION COMPLETE ===\n';
        report += 'Run this in Execute Anonymous after deployment:\n';
        report += 'System.debug(RoundRobinDeploymentValidator.runFullValidation());\n';
        
        return report;
    }
    
    /**
     * @description Test method to verify a simple round robin assignment
     * @return Success message or error details
     */
    public static String testSimpleAssignment() {
        try {
            // Create a test lead
            Lead testLead = new Lead(
                FirstName = 'Validation',
                LastName = 'Test',
                Company = 'Round Robin Validator',
                Status = 'Open - Not Contacted',
                Route_to_Round_Robin__c = true
            );
            
            insert testLead;
            
            // Retrieve and check
            Lead result = [SELECT Id, OwnerId, Route_to_Round_Robin__c, 
                          Assigned_Through_Round_Robin__c
                          FROM Lead WHERE Id = :testLead.Id];
            
            if (result.Route_to_Round_Robin__c == false && 
                result.Assigned_Through_Round_Robin__c == true) {
                return '✅ SUCCESS: Lead was properly assigned through round robin!';
            } else {
                return '❌ FAIL: Lead was not assigned. Check queue configuration.';
            }
            
        } catch (Exception e) {
            return '❌ ERROR: ' + e.getMessage();
        }
    }
}