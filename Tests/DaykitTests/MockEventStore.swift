import DaykitCore
import Foundation

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
    private(set) var createdReminderInputs: [ReminderCreateInput] = []
    private(set) var completedReminderIDs: [String] = []
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

    func listSources(eventsAuthorized: Bool, remindersAuthorized: Bool) async throws -> [String] {
        lock.withLock {
            listSourcesCalls += 1
            return (eventsAuthorized || remindersAuthorized) ? sources : []
        }
    }
}
