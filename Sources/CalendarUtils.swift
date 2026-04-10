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
