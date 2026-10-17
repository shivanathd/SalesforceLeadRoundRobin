/**
 * Flow action: route leads through round robin, for example from a record-triggered or screen flow.
 * Runs in user mode: the flow user needs edit access to the lead and to Route to Round Robin
 * (the Round Robin User permission set grants the field). The routing itself then runs in system mode.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public with sharing class RoundRobinActions {

    public class Request {
        @InvocableVariable(label='Lead ID' required=true)
        public Id leadId;
    }

    public class Result {
        @InvocableVariable(label='Routed' description='True when the lead got a new owner.')
        public Boolean routed;
        @InvocableVariable(label='Owner ID')
        public Id ownerId;
        @InvocableVariable(label='Queue' description='API name of the queue the owner came from.')
        public String queue;
        @InvocableVariable(label='Error' description='Why the lead was not routed.')
        public String error;
    }

    @InvocableMethod(
        label='Route Leads (Round Robin)'
        description='Assigns each lead to the next eligible rep in round robin order. A failed lead is not an error: check Routed and Error.'
        category='Round Robin'
    )
    public static List<Result> routeLeads(List<Request> requests) {
        List<Lead> leads = new List<Lead>();
        for (Request r : requests) {
            // The trigger routes on a change from unticked to ticked and always unticks it again,
            // so ticking it here routes the lead every time the action runs.
            leads.add(new Lead(Id = r.leadId, Route_to_Round_Robin__c = true));
        }
        List<Database.SaveResult> saves = Database.update(leads, false, AccessLevel.USER_MODE);

        // System mode on purpose: the outcome fields may be hidden from the user, and only leads they
        // just saved are reported. The trigger always unticks the box, so a lead still ticked after a
        // successful save was not routed (trigger inactive, or it was already ticked).
        Map<Id, Lead> after = new Map<Id, Lead>([
            SELECT Id, OwnerId, Route_to_Round_Robin__c, Round_Robin_Queue__c, Last_Round_Robin_Error__c
            FROM Lead WHERE Id IN :leads
        ]);
        List<Result> results = new List<Result>();
        for (Integer i = 0; i < requests.size(); i++) {
            Result res = new Result();
            Lead l = after.get(requests[i].leadId);
            if (saves[i].isSuccess() && l == null) {
                res.routed = false;
                res.error = 'Lead not found after saving it.';
            } else if (!saves[i].isSuccess()) {
                res.routed = false;
                res.error = saves[i].getErrors()[0].getMessage();
            } else if (l.Route_to_Round_Robin__c) {
                res.routed = false;
                res.error = 'Not routed: the round robin trigger did not run for this lead.';
            } else {
                res.routed = String.isBlank(l.Last_Round_Robin_Error__c);
                res.ownerId = l.OwnerId;
                res.queue = res.routed ? l.Round_Robin_Queue__c : null;
                res.error = l.Last_Round_Robin_Error__c;
            }
            results.add(res);
        }
        return results;
    }
}
