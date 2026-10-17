#!/usr/bin/env bash
# End-to-end smoke test against a real org, outside Apex test context: real custom metadata config,
# real queues, leads saved through the Bulk API, the REST API and the Flow action endpoint.
#
#   scripts/smoke-test.sh <org-alias>
#
# Only runs against scratch or trial orgs: it creates a user, two queues, config records and leads.
# Deploy the project to the org first (sf project deploy start --source-dir force-app ...).
set -euo pipefail
ORG=${1:?usage: scripts/smoke-test.sh <org-alias>}
export SF_DISABLE_AUTOUPDATE=true SF_HIDE_RELEASE_NOTES=true
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

apex() { # run anonymous Apex from stdin; fail the step on any compile or runtime error
  cat > "$WORK/a.apex"
  local out; out=$(sf apex run --target-org "$ORG" --file "$WORK/a.apex" --json 2>/dev/null)
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result") or d.get("data") or {}; ok=r.get("compiled") and r.get("success"); ok or print("    " + str(r.get("compileProblem") or r.get("exceptionMessage") or d.get("message"))); sys.exit(0 if ok else 1)' <<<"$out"
}
check() { # check "<description>" <<'APEX' ... asserts ... APEX
  local name=$1
  if apex; then echo "  PASS  $name"; pass=$((pass+1)); else echo "  FAIL  $name"; fail=$((fail+1)); fi
}
q() { sf data query --target-org "$ORG" --query "$1" --json 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]["records"]; print(r[0]["Id"] if r else "")'; }

echo "== guard: scratch or trial org only"
sf data query --target-org "$ORG" --query "SELECT TrialExpirationDate FROM Organization" --json 2>/dev/null \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]["records"][0]; sys.exit(0 if r["TrialExpirationDate"] else 1)' \
  || { echo "refusing: $ORG is not a scratch or trial org"; exit 2; }

echo "== setup: Round Robin Admin permission for the running user (anonymous Apex needs it to see the fields)"
apex <<'APEX'
Id ps = [SELECT Id FROM PermissionSet WHERE Name = 'Round_Robin_Admin'].Id;
if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :UserInfo.getUserId() AND PermissionSetId = :ps] == 0) {
    insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps);
}
APEX

echo "== setup: rep user, queues RR_Smoke_Sales (admin + rep) and RR_Smoke_India (rep)"
apex <<'APEX'
User admin = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
List<User> reps = [SELECT Id FROM User WHERE Alias = 'rrsmoke'];
if (reps.isEmpty()) {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User'];
    reps.add(new User(LastName = 'Smoke Rep', Alias = 'rrsmoke', Email = 'rrsmoke@example.com',
        Username = 'rrsmoke.' + UserInfo.getOrganizationId() + '@example.com', ProfileId = p.Id,
        TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'));
    insert reps;
}
update new List<User>{
    new User(Id = admin.Id, Round_Robin_Available__c = true, Round_Robin_Weight__c = 1),
    new User(Id = reps[0].Id, Round_Robin_Available__c = true, Round_Robin_Weight__c = 1)
};
Map<String, Group> queues = new Map<String, Group>();
for (Group g : [SELECT Id, DeveloperName FROM Group WHERE DeveloperName IN ('RR_Smoke_Sales', 'RR_Smoke_India')]) queues.put(g.DeveloperName, g);
for (String name : new List<String>{ 'RR_Smoke_Sales', 'RR_Smoke_India' }) {
    if (!queues.containsKey(name)) {
        Group g = new Group(Name = name.replace('_', ' '), DeveloperName = name, Type = 'Queue');
        insert g;
        insert new QueueSobject(QueueId = g.Id, SobjectType = 'Lead');
        queues.put(name, g);
    }
}
delete [SELECT Id FROM GroupMember WHERE GroupId IN :queues.values()];
insert new List<GroupMember>{
    new GroupMember(GroupId = queues.get('RR_Smoke_Sales').Id, UserOrGroupId = admin.Id),
    new GroupMember(GroupId = queues.get('RR_Smoke_Sales').Id, UserOrGroupId = reps[0].Id),
    new GroupMember(GroupId = queues.get('RR_Smoke_India').Id, UserOrGroupId = reps[0].Id)
};
APEX

echo "== setup: real custom metadata config (deployed, not injected)"
mkdir -p "$WORK/p/force-app/main/default/customMetadata"
echo '{"packageDirectories":[{"path":"force-app","default":true}],"sourceApiVersion":"62.0"}' > "$WORK/p/sfdx-project.json"
cmdt() { # name order notify matchField matchValues
  cat > "$WORK/p/force-app/main/default/customMetadata/Round_Robin_Queue_Config.$1.md-meta.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>$1</label>
    <protected>false</protected>
    <values><field>Is_Active__c</field><value xsi:type="xsd:boolean">true</value></values>
    <values><field>Queue_Developer_Name__c</field><value xsi:type="xsd:string">$1</value></values>
    <values><field>Sort_Order__c</field><value xsi:type="xsd:double">$2</value></values>
    <values><field>Notify_Assignee__c</field><value xsi:type="xsd:boolean">$3</value></values>
    <values><field>Match_Field__c</field><value xsi:type="xsd:string">$4</value></values>
    <values><field>Match_Values__c</field><value xsi:type="xsd:string">$5</value></values>
</CustomMetadata>
XML
}
cmdt RR_Smoke_Sales 1 true "" ""
cmdt RR_Smoke_India 2 true Country "India, IN"
(cd "$WORK/p" && sf project deploy start --source-dir force-app --target-org "$ORG" --wait 10 --ignore-conflicts --json > "$WORK/deploy.json" 2>/dev/null) || { echo "config deploy failed:"; python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("message"), json.dumps(d.get("data") or d.get("result"))[:500])' "$WORK/deploy.json"; exit 1; }

echo "== reset rotation and clear earlier smoke leads"
apex <<'APEX'
delete [SELECT Id FROM Lead WHERE Company = 'RR Smoke'];
RoundRobinService.resetRotation();
APEX

echo "== scenarios"
# 1. Bulk API: 20 leads without a country. Only the Sales queue accepts them, alternating admin and rep.
{ echo "LastName,Company,Route_to_Round_Robin__c"; for i in $(seq 1 20); do echo "Bulk $i,RR Smoke,true"; done; } > "$WORK/bulk.csv"
sf data import bulk --sobject Lead --file "$WORK/bulk.csv" --target-org "$ORG" --wait 10 >/dev/null 2>&1
check "Bulk API: 20 leads routed, split 10/10, queue Sales, source BULK_API" <<'APEX'
List<Lead> leads = [SELECT OwnerId, Round_Robin_Queue__c, Round_Robin_Source__c, Route_to_Round_Robin__c, Last_Round_Robin_Error__c FROM Lead WHERE Company = 'RR Smoke' AND LastName LIKE 'Bulk %'];
System.assertEquals(20, leads.size());
Map<Id, Integer> byOwner = new Map<Id, Integer>();
for (Lead l : leads) {
    System.assertEquals('RR_Smoke_Sales', l.Round_Robin_Queue__c);
    System.assertEquals(false, l.Route_to_Round_Robin__c);
    System.assertEquals(null, l.Last_Round_Robin_Error__c);
    System.assert(l.Round_Robin_Source__c.startsWith('BULK'), l.Round_Robin_Source__c);
    byOwner.put(l.OwnerId, (byOwner.containsKey(l.OwnerId) ? byOwner.get(l.OwnerId) : 0) + 1);
}
System.assertEquals(new Set<Integer>{ 10 }, new Set<Integer>(byOwner.values()), String.valueOf(byOwner));
APEX

# 2. REST API: a lead from India goes to the India desk.
sf data create record --sobject Lead --target-org "$ORG" --values "LastName='Kochi' Company='RR Smoke' Country='india' Route_to_Round_Robin__c=true" >/dev/null 2>&1
check "REST API: India lead goes to RR_Smoke_India (case-insensitive match)" <<'APEX'
Lead l = [SELECT Owner.Alias, Round_Robin_Queue__c, Round_Robin_Source__c FROM Lead WHERE Company = 'RR Smoke' AND LastName = 'Kochi'];
System.assertEquals('RR_Smoke_India', l.Round_Robin_Queue__c);
System.assertEquals('rrsmoke', l.Owner.Alias);
APEX

# 3. Rep on leave is skipped; 4. nobody available: the lead still saves, with the reason recorded.
check "Rep on leave: both leads go to the admin" <<'APEX'
User rep = [SELECT Id FROM User WHERE Alias = 'rrsmoke'];
update new User(Id = rep.Id, Round_Robin_Available__c = false);
insert new List<Lead>{ new Lead(LastName = 'Leave 1', Company = 'RR Smoke', Route_to_Round_Robin__c = true),
                       new Lead(LastName = 'Leave 2', Company = 'RR Smoke', Route_to_Round_Robin__c = true) };
for (Lead l : [SELECT OwnerId FROM Lead WHERE Company = 'RR Smoke' AND LastName LIKE 'Leave %']) {
    System.assertEquals(UserInfo.getUserId(), l.OwnerId);
}
APEX
check "Nobody available: lead saves unassigned, box unticked, reason recorded" <<'APEX'
update new User(Id = UserInfo.getUserId(), Round_Robin_Available__c = false);
Lead l = new Lead(LastName = 'Nobody', Company = 'RR Smoke', Route_to_Round_Robin__c = true);
insert l;
l = [SELECT Route_to_Round_Robin__c, Assigned_Through_Round_Robin__c, Last_Round_Robin_Error__c FROM Lead WHERE Id = :l.Id];
System.assertEquals(false, l.Route_to_Round_Robin__c);
System.assertEquals(false, l.Assigned_Through_Round_Robin__c);
System.assert(l.Last_Round_Robin_Error__c.startsWith('No eligible rep'), l.Last_Round_Robin_Error__c);
User rep = [SELECT Id FROM User WHERE Alias = 'rrsmoke'];
update new List<User>{ new User(Id = UserInfo.getUserId(), Round_Robin_Available__c = true), new User(Id = rep.Id, Round_Robin_Available__c = true) };
APEX

# 5. Flow action over REST: re-route the unassigned lead now that reps are back.
LEAD=$(q "SELECT Id FROM Lead WHERE Company = 'RR Smoke' AND LastName = 'Nobody'")
RESP=$(sf api request rest "/services/data/v62.0/actions/custom/apex/RoundRobinActions" --method POST \
  --body "{\"inputs\":[{\"leadId\":\"$LEAD\"}]}" --target-org "$ORG" 2>/dev/null || true)
if python3 -c 'import json,sys; o=json.loads(sys.argv[1])[0]; sys.exit(0 if o["isSuccess"] and o["outputValues"]["routed"] else 1)' "$RESP" 2>/dev/null; then
  echo "  PASS  Flow action endpoint: Route Leads (Round Robin) routes the failed lead"; pass=$((pass+1))
else echo "  FAIL  Flow action endpoint: $RESP"; fail=$((fail+1)); fi

# 6. Rotation state is one row per queue plus the global row, and the setup check is clean.
check "State rows and setup check" <<'APEX'
Set<String> keys = new Set<String>();
for (Round_Robin_Assignment_State__c s : [SELECT Queue_Key__c FROM Round_Robin_Assignment_State__c]) keys.add(s.Queue_Key__c);
System.assert(keys.containsAll(new Set<String>{ '__GLOBAL__', 'RR_Smoke_Sales', 'RR_Smoke_India' }), String.valueOf(keys));
String report = RoundRobinSetupCheck.run();
System.debug(report);
System.assert(report.contains('RR_Smoke_Sales (order 1): 2 active reps, 2 available'), report);
APEX

echo "== cleanup: smoke leads"
apex <<'APEX'
delete [SELECT Id FROM Lead WHERE Company = 'RR Smoke'];
APEX

echo
echo "smoke test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
