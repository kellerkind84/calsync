# Investigation: Things 3 hanging, and its link to CalSync

**Date:** 2026-08-04
**Status:** Fix applied and pushed (`7cfe769`); monitoring for confirmation.

## Symptom

Things 3 (macOS task manager) was freezing after running in the background
for a while, requiring a restart to recover. It was not reproducible on
demand and left no crash/hang report in
`~/Library/Logs/DiagnosticReports`.

## Investigation

- `ps`/`launchctl` showed no rogue processes hammering Things via its
  CLI/URL-scheme API.
- `log show --predicate 'process == "Things3"'` over the prior 24h showed
  116 occurrences of:
  ```
  [com.apple.eventkit:EventKit] Error loading to-many relation attendeesRaw
  from daemon: Error Domain=EKCADErrorDomain Code=1010
  ```
  This is EventKit failing to read an event's attendee relation from the
  CalendarAgent daemon — the classic signature of reading an event that is
  being deleted/recreated concurrently. Culturedcode's own support docs
  ("Things opens very slowly") document that Things's calendar integration
  can hang the app when the Calendar daemon is slow or misbehaving on an
  integrated calendar.
- Things has calendar integration enabled for the "Kalender" and "Work"
  calendars — the exact same two calendars that `tech.mickel.calsync`
  (this repo, built from `~/projects/CalSync`, invoked every 15 minutes via
  the `calsync-watchdog` launch agent at
  `~/Library/Application Support/CalSync/watchdog/`) syncs between.
- `entry.swift`'s `RunCommand` (pre-fix) deleted **every** CalSync-created
  event in the push calendar and recreated **all** of them from scratch on
  every run, regardless of whether anything had changed — roughly 64
  EventKit mutations every 15 minutes, indefinitely, on the calendars
  Things was polling.

## Root cause (hypothesis, strongly supported by evidence)

CalSync's delete-all/recreate-all sync strategy repeatedly churned the
EventKit/CalendarAgent database on the "Kalender"/"Work" calendars. This
raced with Things's own EventKit polling of the same calendars, producing
the `EKCADErrorDomain Code=1010` errors and, most likely, the resulting UI
hangs when Things's main thread blocked on a CalendarAgent read that lost
its underlying event mid-flight.

## Fix

Commit `7cfe769` ("Reconcile calendar sync instead of delete-all/recreate-all
every run") on `main`, pushed to `kellerkind84/CalSync`. See
`Sources/CalendarUtils.swift` and `Sources/entry.swift`.

- Each synced event's notes now embed a stable source key
  (`title|startISO8601|endISO8601`) rather than relying on
  `EKEvent.eventIdentifier`, which is **not** stable across process runs for
  Exchange/CalDAV-backed recurring occurrences (confirmed empirically: an
  identifier-based key still caused a full delete/recreate on every run).
- On each run, CalSync now diffs source events against previously-synced
  events by that key:
  - Matching + identical -> left untouched.
  - Matching + changed -> updated in place (single `save`, no delete).
  - No match in existing -> created.
  - Existing with no matching source -> deleted (event removed/moved out of
    horizon on the source side).
- Verified against the real calendars: after a one-time migration run (old
  events lack the new marker so get recreated once), three consecutive runs
  all reported `0 created, 0 updated, 32 unchanged, 0 removed` — a true
  no-op when nothing changed, versus the previous 32 deletes + 32 creates
  on every single run.

## How to check if this actually fixed the Things hang

```bash
# EventKit error rate in the last hour - compare over the following days
# to the baseline of ~116/24h seen before the fix.
log show --predicate 'process == "Things3"' --last 1h | grep -c EKCADErrorDomain
```

If Things stops hanging and this error rate drops toward zero, the fix is
confirmed. If Things still hangs despite the sync churn being gone, the
calendar-integration theory needs revisiting — next step would be running
`sample Things3` (or `spindump`) while it's actually frozen to get a stack
trace of what's blocking the main thread.

## Follow-up

- Confirm event updates (title/time changes on the source) are reflected
  correctly by the new update-in-place path over the next few sync cycles.
- If this fix is validated, consider upstreaming the reconciliation
  approach to `gmickel/CalSync` (currently only on this fork, commit
  `7cfe769`).
