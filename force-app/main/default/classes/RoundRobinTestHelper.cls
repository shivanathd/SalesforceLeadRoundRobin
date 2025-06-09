/**
 * @description Helper class for Round Robin tests
 * Provides mock implementations for Custom Metadata
 */
@isTest
public class RoundRobinTestHelper {
    
    /**
     * @description Mock implementation of queue configurations for testing
     * Uses JSON deserialization to create test instances of Custom Metadata
     */
    public static Map<String, Round_Robin_Queue_Config__mdt> getMockQueueConfigs(List<Group> testQueues) {
        Map<String, Round_Robin_Queue_Config__mdt> mockConfigs = new Map<String, Round_Robin_Queue_Config__mdt>();
        
        Integer sortOrder = 1;
        for (Group queue : testQueues) {
            // Use JSON deserialization to create test instances
            Map<String, Object> configMap = new Map<String, Object>{
                'DeveloperName' => queue.DeveloperName,
                'MasterLabel' => queue.Name,
                'Queue_ID__c' => queue.Id,
                'Queue_Developer_Name__c' => queue.DeveloperName,
                'Is_Active__c' => true,
                'Sort_Order__c' => sortOrder++
            };
            
            String jsonString = JSON.serialize(configMap);
            Round_Robin_Queue_Config__mdt config = (Round_Robin_Queue_Config__mdt) JSON.deserialize(
                jsonString, 
                Round_Robin_Queue_Config__mdt.class
            );
            
            mockConfigs.put(queue.DeveloperName, config);
        }
        
        return mockConfigs;
    }
}