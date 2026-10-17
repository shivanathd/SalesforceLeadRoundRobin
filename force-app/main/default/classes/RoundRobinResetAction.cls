/**
 * Flow action: start the rotation over, so every queue's next lead goes to its first rep.
 * Use after reorganising a team. Requires the Round Robin Admin permission.
 */
public with sharing class RoundRobinResetAction {

    @InvocableMethod(
        label='Reset Round Robin Rotation'
        description='Clears saved rotation positions. Requires the Round Robin Admin permission. Returns the number of state rows cleared.'
        category='Round Robin'
    )
    public static List<Integer> reset(List<String> ignored) {
        return new List<Integer>{ RoundRobinService.resetRotation() };
    }
}
