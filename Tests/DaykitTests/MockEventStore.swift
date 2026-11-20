import DaykitCore
import Foundation

final class MockAuditLogWriter: AuditLogWriter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var entries: [AuditEntry] = []

    func record(_ entry: AuditEntry) throws {
        lock.withLock {
            entries.append(entry)
        }
    }
}

final class MockEventStore: EventStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    var calendarsAuth: AccessStatus = .fullAccess
    var remindersAuth: AccessStatus = .fullAccess
    var session: SessionInfo = SessionInfo(isSSH: false, hasAquaGUI: true)

    var calendars: [CalendarSummary] = []
    var events: [EventRecord] = []
    var reminderLists: [ReminderListSummary] = []
    var reminders: [ReminderRecord] = []
    var sources: [String] = ["iCloud", "Work M365"]

    private(set) var requestAccessCalls: [AccessDomain] = []
    private(set) var createdEventInputs: [EventCreateInput] = []
    private(set) var updatedEventInputs: [EventUpdateInput] = []
    private(set) var deletedEventCalls: [(id: String, span: EventSpan)] = []
    private(set) var createdReminderInputs: [ReminderCreateInput] = []
    private(set) var updatedReminderInputs: [ReminderUpdateInput] = []
    private(set) var completedReminderIDs: [String] = []
    private(set) var deletedReminderIDs: [String] = []
    private(set) var listSourcesCalls: Int = 0

    func authorizationStatus(for domain: AccessDomain) -> AccessStatus {
        lock.withLock {
            domain == .calendars ? calendarsAuth : remindersAuth
        }
    }

    func sessionInfo() -> SessionInfo {
        lock.withLock { session }
    }

    func requestAccess(for domain: AccessDomain) async throws -> AccessStatus {
        lock.withLock {
            requestAccessCalls.append(domain)
            return domain == .calendars ? calendarsAuth : remindersAuth
        }
    }

    func listCalendars() async throws -> [CalendarSummary] {
        lock.withLock { calendars }
    }

    func listEvents(from: Date, to: Date, calendarIDs: [String]?) async throws -> [EventRecord] {
        lock.withLock {
            events.filter { event in
                if let calendarIDs, !calendarIDs.contains(event.calendarId) {
                    return false
                }
                return true
            }
        }
    }

    func findEvent(instanceId: String) async throws -> EventRecord? {
        try lock.withLock {
            let ref = EventInstanceRef.parse(instanceId)
            if ref.occurrenceDate == nil {
                if let match = events.first(where: { $0.seriesId == ref.seriesId || $0.instanceId == ref.seriesId }) {
                    if match.isRecurring || match.isDetached {
                        throw DaykitError(
                            code: "AMBIGUOUS_RECURRING_ID",
                            exitCode: .usageError,
                            message: "Event '\(ref.seriesId)' is recurring/detached; use the full instance_id."
                        )
                    }
                    return match
                }
                return nil
            }
            return events.first(where: { $0.instanceId == instanceId })
        }
    }

    func createEvent(_ input: EventCreateInput) async throws -> EventRecord {
        lock.withLock {
            createdEventInputs.append(input)
            let cal = calendars.first(where: { $0.id == input.calendarId })
            let tz = TimeZone(identifier: "America/Santiago")!
            var calGreg = Calendar(identifier: .gregorian)
            calGreg.timeZone = tz
            return EventRecord(
                instanceId: "evt-new-\(createdEventInputs.count)",
                seriesId: "evt-new-\(createdEventInputs.count)",
                title: input.title,
                startAt: input.allDay ? DateParsing.formatDateOnly(input.startDate, calendar: calGreg) : DateParsing.formatRFC3339(input.startDate, timeZone: tz),
                endAt: input.allDay ? DateParsing.formatDateOnly(input.endDate, calendar: calGreg) : DateParsing.formatRFC3339(input.endDate, timeZone: tz),
                allDay: input.allDay,
                timezone: input.allDay ? nil : tz.identifier,
                calendarId: input.calendarId,
                calendarTitle: cal?.title ?? "",
                location: input.location,
                notes: input.notes,
                hasNotes: !(input.notes?.isEmpty ?? true),
                notesTruncated: false,
                url: input.url,
                availability: "busy",
                status: "confirmed",
                isRecurring: false,
                isDetached: false,
                occurrenceDate: nil,
                alarmsMinutesBefore: input.alarmsMinutesBefore,
                attendees: []
            )
        }
    }

    func updateEvent(_ input: EventUpdateInput) async throws -> EventRecord {
        try lock.withLock {
            updatedEventInputs.append(input)
            guard let idx = events.firstIndex(where: { $0.instanceId == input.instanceId }) else {
                throw DaykitError(code: "EVENT_NOT_FOUND", exitCode: .notFound, message: "Event '\(input.instanceId)' not found.")
            }
            let current = events[idx]
            let destCal = input.calendarId.flatMap { cid in calendars.first(where: { $0.id == cid }) }
            let tz = TimeZone(identifier: "America/Santiago")!
            var calGreg = Calendar(identifier: .gregorian)
            calGreg.timeZone = tz
            let targetAllDay = input.allDay ?? current.allDay

            let startAt = input.startDate.map { targetAllDay ? DateParsing.formatDateOnly($0, calendar: calGreg) : DateParsing.formatRFC3339($0, timeZone: tz) } ?? current.startAt
            let endAt = input.endDate.map { targetAllDay ? DateParsing.formatDateOnly($0, calendar: calGreg) : DateParsing.formatRFC3339($0, timeZone: tz) } ?? current.endAt

            let newLocation: String?
            switch input.location {
            case .unchanged: newLocation = current.location
            case .clear: newLocation = nil
            case .set(let v): newLocation = v.isEmpty ? nil : v
            }

            let newNotes: String?
            switch input.notes {
            case .unchanged: newNotes = current.notes
            case .clear: newNotes = nil
            case .set(let v): newNotes = v.isEmpty ? nil : v
            }

            let newURL: String?
            switch input.url {
            case .unchanged: newURL = current.url
            case .clear: newURL = nil
            case .set(let v): newURL = v
            }

            let newAlarms: [Int]
            switch input.alarmsMinutesBefore {
            case .unchanged: newAlarms = current.alarmsMinutesBefore
            case .clear: newAlarms = []
            case .set(let mins): newAlarms = mins
            }

            let updated = EventRecord(
                instanceId: current.instanceId,
                seriesId: current.seriesId,
                title: input.title ?? current.title,
                startAt: startAt,
                endAt: endAt,
                allDay: targetAllDay,
                timezone: targetAllDay ? nil : (current.timezone ?? tz.identifier),
                calendarId: destCal?.id ?? current.calendarId,
                calendarTitle: destCal?.title ?? current.calendarTitle,
                location: newLocation,
                notes: newNotes,
                hasNotes: !(newNotes?.isEmpty ?? true),
                notesTruncated: false,
                url: newURL,
                availability: current.availability,
                status: current.status,
                isRecurring: current.isRecurring,
                isDetached: current.isDetached,
                occurrenceDate: current.occurrenceDate,
                alarmsMinutesBefore: newAlarms,
                attendees: current.attendees
            )
            events[idx] = updated
            return updated
        }
    }

    func deleteEvent(instanceId: String, span: EventSpan) async throws -> EventRecord {
        try lock.withLock {
            deletedEventCalls.append((instanceId, span))
            guard let idx = events.firstIndex(where: { $0.instanceId == instanceId }) else {
                throw DaykitError(code: "EVENT_NOT_FOUND", exitCode: .notFound, message: "Event '\(instanceId)' not found.")
            }
            return events.remove(at: idx)
        }
    }

    func listReminderLists() async throws -> [ReminderListSummary] {
        lock.withLock { reminderLists }
    }

    func listReminders(listIDs: [String]?, filter: ReminderCompletionFilter) async throws -> [ReminderRecord] {
        lock.withLock {
            reminders.filter { rem in
                if let listIDs, !listIDs.contains(rem.listId) {
                    return false
                }
                switch filter {
                case .open: return !rem.completed
                case .completed: return rem.completed
                case .all: return true
                }
            }
        }
    }

    func createReminder(_ input: ReminderCreateInput) async throws -> ReminderRecord {
        lock.withLock {
            createdReminderInputs.append(input)
            let list = reminderLists.first(where: { $0.id == input.listId })
            let tz = TimeZone(identifier: "America/Santiago")!
            let dueAt = input.dueComponents.map { DateParsing.formatDateComponents($0, timeZone: tz).string }
            return ReminderRecord(
                id: "rem-new-\(createdReminderInputs.count)",
                title: input.title,
                listId: input.listId,
                listTitle: list?.title ?? "",
                dueAt: dueAt,
                hasDueTime: input.hasDueTime,
                completed: false,
                completionDate: nil,
                priority: input.priority,
                notes: input.notes,
                hasNotes: !(input.notes?.isEmpty ?? true),
                notesTruncated: false,
                url: input.url,
                isRecurring: false,
                createdAt: "2026-11-20T12:00:00-03:00",
                modifiedAt: "2026-11-20T12:00:00-03:00"
            )
        }
    }

    func findReminder(id: String) async throws -> ReminderRecord? {
        lock.withLock {
            reminders.first(where: { $0.id == id })
        }
    }

    func updateReminder(_ input: ReminderUpdateInput) async throws -> ReminderRecord {
        try lock.withLock {
            updatedReminderInputs.append(input)
            guard let idx = reminders.firstIndex(where: { $0.id == input.id }) else {
                throw DaykitError(code: "REMINDER_NOT_FOUND", exitCode: .notFound, message: "Reminder '\(input.id)' not found.")
            }
            let current = reminders[idx]
            let tz = TimeZone(identifier: "America/Santiago")!
            let destList = input.listId.flatMap { lid in reminderLists.first(where: { $0.id == lid }) }

            let dueAt: String?
            let hasDueTime: Bool
            switch input.due {
            case .unchanged:
                dueAt = current.dueAt
                hasDueTime = current.hasDueTime
            case .clear:
                dueAt = nil
                hasDueTime = false
            case .set(let update):
                dueAt = DateParsing.formatDateComponents(update.dueComponents, timeZone: tz).string
                hasDueTime = update.hasDueTime
            }

            let newNotes: String?
            switch input.notes {
            case .unchanged: newNotes = current.notes
            case .clear: newNotes = nil
            case .set(let v): newNotes = v.isEmpty ? nil : v
            }

            let newURL: String?
            switch input.url {
            case .unchanged: newURL = current.url
            case .clear: newURL = nil
            case .set(let v): newURL = v
            }

            let updated = ReminderRecord(
                id: current.id,
                title: input.title ?? current.title,
                listId: destList?.id ?? current.listId,
                listTitle: destList?.title ?? current.listTitle,
                dueAt: dueAt,
                hasDueTime: hasDueTime,
                completed: current.completed,
                completionDate: current.completionDate,
                priority: input.priority ?? current.priority,
                notes: newNotes,
                hasNotes: !(newNotes?.isEmpty ?? true),
                notesTruncated: false,
                url: newURL,
                isRecurring: current.isRecurring,
                createdAt: current.createdAt,
                modifiedAt: "2026-11-20T21:00:00-03:00"
            )
            reminders[idx] = updated
            return updated
        }
    }

    func completeReminder(id: String) async throws -> CompleteReminderResult {
        try lock.withLock {
            completedReminderIDs.append(id)
            guard let rem = reminders.first(where: { $0.id == id }) else {
                throw DaykitError(code: "REMINDER_NOT_FOUND", exitCode: .notFound, message: "Reminder '\(id)' not found.")
            }
            return CompleteReminderResult(
                dryRun: false,
                action: "complete_reminder",
                completedId: rem.id,
                title: rem.title,
                alreadyCompleted: rem.completed,
                isRecurring: rem.isRecurring,
                nextOccurrenceId: rem.isRecurring ? "rem-next-occurrence" : nil,
                reminder: rem
            )
        }
    }

    func deleteReminder(id: String) async throws -> ReminderRecord {
        try lock.withLock {
            deletedReminderIDs.append(id)
            guard let idx = reminders.firstIndex(where: { $0.id == id }) else {
                throw DaykitError(code: "REMINDER_NOT_FOUND", exitCode: .notFound, message: "Reminder '\(id)' not found.")
            }
            return reminders.remove(at: idx)
        }
    }

    func listSources(eventsAuthorized: Bool, remindersAuthorized: Bool) async throws -> [String] {
        lock.withLock {
            listSourcesCalls += 1
            return (eventsAuthorized || remindersAuthorized) ? sources : []
        }
    }
}
