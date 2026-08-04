//
//  CalendarUtils.swift
//  CalSync
//
//  Created by Thomas Preece on 24/10/2023.
//  Modified by Gordon Mickel on 09/01/2024.
//

import Foundation
import EventKit

let today = Calendar.current.startOfDay(for: Date())

enum CalSyncError: Error {
    case runtimeError(String)
}

func createSyncSetting(calendars: [EKCalendar]) throws -> SyncSetting {
    guard !calendars.isEmpty else {
        print("No calendars available.")
        throw CalSyncError.runtimeError("No calendars available.")
    }
    
    printCalendars(calendars: calendars)
            
    print("\nEnter the number of the calendar you want to pull events from:")
    guard let pullCalendar = try? selectCalendar(calendars:calendars) else {
        throw CalSyncError.runtimeError("Invalid pull calendar selection")
    }
    
    print("\nEnter the number of the calendar you want to push to:")
    guard let pushCalendar = try? selectCalendar(calendars:calendars) else {
        throw CalSyncError.runtimeError("Invalid push calendar selection")
    }
    
    print("\nEnter the number of days you want to sync:")
    let numDays = selectNumDays()
    
  
    let newSync = SyncSetting(
        pullCalendarIdentifier: pullCalendar.calendarIdentifier,
        pullCalendarTitle: pullCalendar.title,
        pushCalendarIdentifier: pushCalendar.calendarIdentifier,
        pushCalendarTitle: pushCalendar.title,
        numDays: numDays
    )
    return newSync
}


func printCalendars(calendars: [EKCalendar]) {
    for (index, calendar) in calendars.enumerated() {
        print("\(index + 1). \(calendar.title) - \(calendar.source.title)")
    }
}

func selectCalendar(calendars: [EKCalendar]) throws -> EKCalendar {
    guard !calendars.isEmpty else {
        print("No calendars available.")
        throw CalSyncError.runtimeError("No calendars available.")
    }
    
    while true {
        if let input = readLine(), let selectedCalendarIndex = Int(input) {
            let selectedIndex = selectedCalendarIndex - 1
            if selectedIndex >= 0 && selectedIndex < calendars.count {
                return calendars[selectedIndex]
            } else {
                print("Invalid calendar number. Please select a valid option.")
            }
        } else {
            print("Invalid input. Please enter the number corresponding to the calendar.")
        }
    }
}

func selectNumDays() -> Int {
    while true {
        if let input = readLine(), let selectedNumDays = Int(input) {
            return selectedNumDays
        } else {
            print("Invalid input. Please enter a number")
        }
    }
}

func getEventsNextXDays(calendar: EKCalendar, eventStore: EKEventStore, numDays: Int) -> [EKEvent] {
    
    let endOfHorizon = Calendar.current.date(byAdding: .day, value: numDays, to: today)!
    let predicate = eventStore.predicateForEvents(withStart: today, end: endOfHorizon, calendars: [calendar])
    let events = eventStore.events(matching: predicate)
    return events
}

// Title prefixes that Exchange/Apple Calendar adds for declined or cancelled events.
// These cover the most common locales; extend as needed.
private let declinedOrCancelledPrefixes = [
    "Abgelehnt:",    // German: Declined
    "Declined:",     // English: Declined
    "Abgesagt:",     // German: Cancelled
    "Canceled:",     // English (US): Cancelled
    "Cancelled:",    // English (UK): Cancelled
    "Refusé:",       // French: Declined
    "Annulé:",       // French: Cancelled
]

func getNonCalSyncEventsNextXDays(calendar: EKCalendar, eventStore: EKEventStore, numDays: Int) -> [EKEvent] {
    let events = getEventsNextXDays(calendar: calendar, eventStore: eventStore, numDays: numDays)
    let nonCalSyncEvents = events.filter { event in
        // Skip CalSync-created events
        if event.notes?.contains("Made by CalSync") == true { return false }
        // Skip cancelled events via EventKit status
        if event.status == .canceled { return false }
        // Skip events the current user has declined via attendee status
        if let selfAttendee = event.attendees?.first(where: { $0.isCurrentUser }),
           selfAttendee.participantStatus == .declined { return false }
        // Skip events where Apple Calendar has added a declined/cancelled prefix
        // (Exchange sync populates these prefixes when attendee status isn't reliably available)
        if let title = event.title,
           declinedOrCancelledPrefixes.contains(where: { title.hasPrefix($0) }) { return false }
        return true
    }
    return nonCalSyncEvents
}

func getCalSyncEventsNextXDays(calendar: EKCalendar, eventStore: EKEventStore, numDays: Int) -> [EKEvent] {
    let events = getEventsNextXDays(calendar: calendar, eventStore: eventStore, numDays: numDays)
    let calSyncEvents = events.filter { event in
        return event.notes?.contains("Made by CalSync") == true
    }
    return calSyncEvents
}

func deleteEvents(eventStore: EKEventStore, events: [EKEvent]) {
    for event in events {
        do {
            if event.notes?.contains("Made by CalSync") == true {
                try eventStore.remove(event, span: .thisEvent)
                print("Deleted event: \(event.title ?? "Untitled")")
            } else {
                print("Warning: Attempted to delete non-CalSync event: \(event.title ?? "Untitled")")
            }
        } catch {
            print("Error deleting event: \(event.title ?? "Untitled") \(error.localizedDescription)")
        }
    }
}

// MARK: - Reconciliation (diff-based sync)
//
// Rather than deleting every CalSync-created event and recreating it from
// scratch on every run (which churns the shared EventKit/CalendarAgent
// database and can race with other apps reading calendar data, e.g. Things
// failing with EKCADErrorDomain Code=1010 while an event it's reading gets
// deleted out from under it), we embed a stable source key in each synced
// event's notes and only create/update/delete events that actually changed.

private let sourceKeyMarkerPrefix = "SourceID: "

/// A stable key identifying a specific occurrence of a source event, used to
/// match previously-synced events across runs.
///
/// We deliberately do NOT use `event.eventIdentifier` here: for
/// Exchange/CalDAV-backed calendars, EventKit does not guarantee stable
/// identifiers for expanded recurring occurrences across separate fetches
/// (each process run can mint different identifiers for the same logical
/// occurrence), which would defeat reconciliation entirely. Title + start +
/// end time is stable across runs and uniquely identifies an occurrence in
/// practice.
func sourceKey(for event: EKEvent) -> String {
    let formatter = ISO8601DateFormatter()
    let start = event.startDate.map { formatter.string(from: $0) } ?? "unknown"
    let end = event.endDate.map { formatter.string(from: $0) } ?? "unknown"
    return "\(event.title ?? "untitled")|\(start)|\(end)"
}

/// Extracts the source key previously embedded in a CalSync-created event's notes.
func extractSourceKey(from event: EKEvent) -> String? {
    guard let notes = event.notes else { return nil }
    for line in notes.split(separator: "\n") {
        if line.hasPrefix(sourceKeyMarkerPrefix) {
            return String(line.dropFirst(sourceKeyMarkerPrefix.count))
        }
    }
    return nil
}

private func buildNotes(sourceKey: String, sourceNotes: String?) -> String {
    "Made by CalSync\n\(sourceKeyMarkerPrefix)\(sourceKey)\n\n" + (sourceNotes ?? "")
}

/// Copies all synced fields from `source` onto `target`, embedding the
/// source key so future runs can recognize this event again.
func applyDetails(from source: EKEvent, to target: EKEvent, sourceKey: String) {
    target.title = source.title
    target.notes = buildNotes(sourceKey: sourceKey, sourceNotes: source.notes)
    target.startDate = source.startDate
    target.endDate = source.endDate
    target.location = source.location
    target.url = source.url
    target.isAllDay = source.isAllDay
    target.availability = source.availability
    target.alarms = source.alarms?.map { EKAlarm(relativeOffset: $0.relativeOffset) }
}

/// Whether `existing` (a previously-synced event) is out of date relative to `source`.
func needsUpdate(existing: EKEvent, source: EKEvent) -> Bool {
    if existing.title != source.title { return true }
    if existing.startDate != source.startDate { return true }
    if existing.endDate != source.endDate { return true }
    if existing.location != source.location { return true }
    if existing.url != source.url { return true }
    if existing.isAllDay != source.isAllDay { return true }
    if existing.availability != source.availability { return true }

    let existingOffsets = Set((existing.alarms ?? []).map { $0.relativeOffset })
    let sourceOffsets = Set((source.alarms ?? []).map { $0.relativeOffset })
    if existingOffsets != sourceOffsets { return true }

    let sourceNotesBody = source.notes ?? ""
    let existingNotesBody = (existing.notes ?? "")
        .components(separatedBy: "\n\n")
        .dropFirst()
        .joined(separator: "\n\n")
    if existingNotesBody != sourceNotesBody { return true }

    return false
}
