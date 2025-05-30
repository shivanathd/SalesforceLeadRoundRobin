/**
 * @description Helper class for Round Robin tests
 * Provides mock implementations for Custom Metadata
 */
@isTest
public class RoundRobinTestHelper {
    
    /**
     * @description Mock implementation of queue configurations for testing
     */
    public static Map<String, Round_Robin_Queue_Config__mdt> getMockQueueConfigs(List<Group> testQueues) {
        Map<String, Round_Robin_Queue_Config__mdt> mockConfigs = new Map<String, Round_Robin_Queue_Config__mdt>();
        
        Integer sortOrder = 1;
        for (Group queue : testQueues) {
            Round_Robin_Queue_Config__mdt config = new Round_Robin_Queue_Config__mdt(
                DeveloperName = queue.DeveloperName,
                MasterLabel = queue.Name,
                Queue_ID__c = queue.Id,
                Queue_Developer_Name__c = queue.DeveloperName,
                Is_Active__c = true,
                Sort_Order__c = sortOrder++
            );
            mockConfigs.put(config.DeveloperName, config);
        }
        
        return mockConfigs;
    }
}