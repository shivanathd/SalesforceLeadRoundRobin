/**
 * @description Trigger for Lead Round Robin Assignment
 * Processes leads when Route_to_Round_Robin__c checkbox is checked
 * Handles assignment results and maintains audit trail
 */
trigger LeadRoundRobinTrigger on Lead (before insert, before update, after insert, after update) {
    
    if (Trigger.isBefore) {
        List<Lead> leadsToRoute = new List<Lead>();
        
        if (Trigger.isInsert) {
            // On insert, process if checkbox is checked
            for (Lead newLead : Trigger.new) {
                if (newLead.Route_to_Round_Robin__c == true && 
                    newLead.Round_Robin_Processing__c != true) {
                    leadsToRoute.add(newLead);
                }
            }
        } else if (Trigger.isUpdate) {
            // On update, process only if checkbox changed from false to true
            for (Lead newLead : Trigger.new) {
                Lead oldLead = Trigger.oldMap.get(newLead.Id);
                
                // Check if Route_to_Round_Robin__c changed from false/null to true
                if (newLead.Route_to_Round_Robin__c == true && 
                    (oldLead.Route_to_Round_Robin__c != true) &&
                    newLead.Round_Robin_Processing__c != true) {
                    leadsToRoute.add(newLead);
                }
            }
        }
        
        // Process leads if any need routing
        if (!leadsToRoute.isEmpty()) {
            // Set processing flag to prevent recursion
            for (Lead lead : leadsToRoute) {
                lead.Round_Robin_Processing__c = true;
            }
            
            // Perform round-robin assignment and get results
            Map<Id, RoundRobinAssignmentHandler.AssignmentResult> results = 
                RoundRobinAssignmentHandler.assignLeads(leadsToRoute);
            
            // Process results for each lead
            Map<String, Schema.SObjectField> fieldMap = Schema.sObjectType.Lead.fields.getMap();
            
            for (Lead lead : leadsToRoute) {
                RoundRobinAssignmentHandler.AssignmentResult result = results.get(lead.Id);
                
                if (result != null && result.success) {
                    // Successful assignment - clear checkbox
                    lead.Route_to_Round_Robin__c = false;
                    lead.Round_Robin_Processing__c = false;
                    
                    // Clear any previous error
                    if (fieldMap.containsKey('last_round_robin_error__c')) {
                        lead.put('Last_Round_Robin_Error__c', null);
                    }
                } else {
                    // Failed assignment - keep checkbox checked for retry
                    // Only clear the processing flag
                    lead.Round_Robin_Processing__c = false;
                    
                    // Record error message if field exists
                    if (fieldMap.containsKey('last_round_robin_error__c') && 
                        result != null && 
                        String.isNotBlank(result.errorMessage)) {
                        lead.put('Last_Round_Robin_Error__c', result.errorMessage);
                    }
                    
                    // Record attempt timestamp if field exists
                    if (fieldMap.containsKey('last_round_robin_attempt__c')) {
                        lead.put('Last_Round_Robin_Attempt__c', System.now());
                    }
                }
            }
        }
    }
    
    // After trigger - update assignment state
    if (Trigger.isAfter) {
        // Update the assignment state record if needed
        RoundRobinAssignmentHandler.updateAssignmentStateAfterTrigger();
    }
}