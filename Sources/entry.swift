//
//  main.swift
//  CalSync
//
//  Created by Thomas Preece on 18/10/2023.
//  Modified by Gordon Mickel on 09/01/2024.
//
import EventKit
import Foundation
import Dispatch
import ArgumentParser

@main
struct CalSync: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "CalSync",
        abstract: "A utility for syncing calendars in a way that keeps event details private",
        subcommands: [RunCommand.self, ListCommand.self, AddCommand.self, RemoveCommand.self]
    )
    func validate() throws {
        if CommandLine.arguments.count <= 1 {
            print(asciiArtBanner)
        }
    }
}

struct RunCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run configured syncs"
    )
    func run() {
        let eventStore = EKEventStore()
        
        eventStore.requestFullAccessToEvents { (granted, error) in
            if granted && error == nil {
                let calendars = eventStore.calendars(for: .event)
                let settings = read_settings()
                
                for sync in settings.syncs {
                    do {
                        guard let pullCalendar = calendars.first(where: { $0.calendarIdentifier == sync.pullCalendarIdentifier}) else {
                            throw CalSyncError.runtimeError("Could not find pull calendar \(sync.pullCalendarIdentifier) in event store")
                        }
                        guard let pushCalendar = calendars.first(where:{ $0.calendarIdentifier == sync.pushCalendarIdentifier}) else {
                            throw CalSyncError.runtimeError("Could not find push calendar \(sync.pushCalendarIdentifier) in event store")
                        }
                        
                        print("Starting sync from '\(pullCalendar.title)' to '\(pushCalendar.title)'")
                        
                        // Reconcile instead of delete-all/recreate-all: only touch events that
                        // actually changed. Nuking and rebuilding the whole calendar on every run
                        // churns the shared EventKit/CalendarAgent database unnecessarily and can
                        // race with other apps (e.g. Things) reading calendar data while events are
                        // mid-delete/mid-create.
                        let existingCalSyncEvents = getCalSyncEventsNextXDays(calendar: pushCalendar, eventStore: eventStore, numDays: sync.numDays)
                        var existingByKey: [String: EKEvent] = [:]
                        for event in existingCalSyncEvents {
                            if let key = extractSourceKey(from: event) {
                                existingByKey[key] = event
                            } else {
                                // No embedded source key (e.g. leftover from an older CalSync
                                // version) - treat as stale and remove it below.
                                existingByKey[event.eventIdentifier ?? UUID().uuidString] = event
                            }
                        }
                        
                        let sourceEvents = getNonCalSyncEventsNextXDays(calendar: pullCalendar, eventStore: eventStore, numDays: sync.numDays)
                        print("Found \(sourceEvents.count) source events, \(existingCalSyncEvents.count) previously synced events")
                        
                        var created = 0, updated = 0, unchanged = 0
                        var matchedKeys = Set<String>()
                        
                        for sourceEvent in sourceEvents {
                            let key = sourceKey(for: sourceEvent)
                            matchedKeys.insert(key)
                            
                            if let existingEvent = existingByKey[key] {
                                if needsUpdate(existing: existingEvent, source: sourceEvent) {
                                    applyDetails(from: sourceEvent, to: existingEvent, sourceKey: key)
                                    do {
                                        try eventStore.save(existingEvent, span: .thisEvent)
                                        updated += 1
                                    } catch {
                                        print("Error updating event: \(error.localizedDescription)")
                                    }
                                } else {
                                    unchanged += 1
                                }
                            } else {
                                let newEvent = EKEvent(eventStore: eventStore)
                                newEvent.calendar = pushCalendar
                                applyDetails(from: sourceEvent, to: newEvent, sourceKey: key)
                                // EventKit expands recurring events into individual occurrences
                                // when querying. We always save each occurrence as a standalone
                                // event so that deleted occurrences (exceptions) in the source
                                // calendar are not recreated in the push calendar.
                                do {
                                    try eventStore.save(newEvent, span: .thisEvent)
                                    created += 1
                                } catch {
                                    print("Error saving event: \(error.localizedDescription)")
                                }
                            }
                        }
                        
                        // Remove synced events whose source no longer exists in this horizon
                        // (e.g. deleted, declined, or moved outside the sync window).
                        let staleEvents = existingByKey.filter { !matchedKeys.contains($0.key) }.map { $0.value }
                        deleteEvents(eventStore: eventStore, events: staleEvents)
                        
                        print("Sync complete: \(created) created, \(updated) updated, \(unchanged) unchanged, \(staleEvents.count) removed")
                        
                    } catch {
                        print("Error: \(error)")
                    }
                }
                
                AddCommand.exit(withError: 0 as? Error)
            } else {
                print("Access to the Calendar data was not granted.")
            }
        }
        // Allow asynchronous events to run
        RunLoop.main.run()
    }
}

struct ListCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Lists configured syncs"
    )
    
    func run() {
        let settings = read_settings()
        printCalSyncSettings(settings: settings)
    }
}

struct AddCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a sync"
    )
    
    func run() {
        print(asciiArtBanner)
        let eventStore = EKEventStore()
        eventStore.requestFullAccessToEvents { (granted, error) in
            if granted && error == nil {
                let calendars = eventStore.calendars(for: .event)
                
                do {
                    let newSyncSetting = try createSyncSetting(calendars: calendars)
                    var settings = read_settings()
                    settings.syncs.append(newSyncSetting)
                    write_settings(settings: settings)
                } catch {
                    print("Error creating sync setting: \(error)")
                }
                AddCommand.exit(withError: 0 as? Error)
            } else {
                print("Access to the Calendar data was not granted.")
            }
        }
        // Allow asynchronous events to run
        RunLoop.main.run()
    }
}

struct RemoveCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a sync"
    )
    
    @Argument(help: "Id of sync to remove")
    var id: String
    
    func run() {
        var settings = read_settings()
        let idToDelete = UUID(uuidString: id)
        settings.syncs.removeAll(where: {$0.id == idToDelete})
        write_settings(settings: settings)
    }
}
