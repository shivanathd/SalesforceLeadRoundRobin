/**
 * Routes leads when Route to Round Robin is ticked (on create, or changed from unticked to ticked),
 * then notifies the assigned reps. All logic lives in RoundRobinService.
 */
trigger LeadRoundRobinTrigger on Lead (before insert, before update, after insert, after update) {
    if (Trigger.isBefore) {
        RoundRobinService.route(RoundRobinService.leadsToRoute(Trigger.new, Trigger.oldMap));
    } else {
        RoundRobinService.notifyAssignees(Trigger.new, Trigger.oldMap);
    }
}
