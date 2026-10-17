# Changelog

## [2.0.0] - 2026-10-17

A rebuild. Version 1 never deployed: the handler did not compile (a `global` inner class inside a `public` class, and `Boolean.TRUE`, which Apex doesn't have), and the two sample queue configs held placeholder IDs longer than the 18-character field. Its "production ready" and "90%+ coverage" claims were never measured.

### Fixed (v1 behaviour)
- Bulk inserts: results were keyed by Lead Id, which is null before insert, so every lead in a batch shared one result.
- A lead that couldn't be assigned was rejected with `addError`, losing web-to-lead and integration submissions. It now saves, and the reason is recorded.
- Routing checked the saving user's field permissions, so Site guests and integration users couldn't create routed leads.
- Rotation state was read with sharing; a user who couldn't see it created a second state record and forked the rotation.
- Rotation positions grew without limit and were reset at 10,000, skewing fairness.
- `Total_Assignments__c++` threw a null pointer exception on a blank counter.
- Static recursion tracking broke under partial-success saves.

### Added
- Rep availability (`Round Robin Available` on User): skip reps on leave without removing them from queues.
- Rep weight (`Round Robin Weight` on User, 1 to 10).
- Capacity cap per queue (`Max Open Leads per Rep`).
- Match rules per queue (`Match Field` and `Match Values`).
- Notifications to the assigned rep (bell and mobile), summarised for bulk saves.
- Flow actions: **Route Leads (Round Robin)** and **Reset Round Robin Rotation**.
- `RoundRobinSetupCheck.run()` health report.
- Permission sets **Round Robin Admin** and **Round Robin User**, a **Round Robin Errors** list view, and a `Round_Robin_Admin` custom permission guarding reset.
- 25 Apex tests (95% coverage) covering real scenarios: bulk loads, partial-success saves, low-privilege users, forced failures.
- `scripts/smoke-test.sh`: live end-to-end check in a scratch org through the Bulk API, REST API and Flow action endpoint.
- `LICENSE` (MIT), regenerated `manifest/package.xml`.

### Changed
- Queue config references queues by API name instead of ID, so one config works in every org.
- Rotation state is one row per queue plus a global row, instead of a JSON map in one record.
- `Round Robin Source` records the real execution context (`Request.getQuiddity()`) instead of guessing "Data Loader" from batch size.
- API version 62.0.
- `sfdx-project.json` no longer declares a package with a placeholder ID.

### Removed
- `Round_Robin_Processing__c`, `Queue_ID__c`, `Current_Queue_Index__c`, `Queue_User_Indices__c`.
- `RoundRobinAssignmentHandler`, `RoundRobinDeploymentValidator` (it inserted a real lead to test itself), `RoundRobinTestHelper`.
- Legacy `.object` files that duplicated and contradicted the source-format metadata.
- The 20 analysis documents describing v1; they remain in git history.

## [1.1.0] - 2025-01-06
## [1.0.0] - 2025-01-05
Initial versions. See git history.
