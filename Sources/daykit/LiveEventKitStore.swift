import DaykitCore
@preconcurrency import CoreGraphics
@preconcurrency import EventKit
import Foundation

private final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func finish(with result: Result<T, Error>) {
        lock.lock()
        let shouldResume = !finished
        if shouldResume {
            finished = true
        }
        lock.unlock()

        if shouldResume {
            continuation.resume(with: result)
        }
    }
}

public final class LiveEventKitStore: EventStoreProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.gabrielcabrera.daykit.eventkit")
    private var cachedStore: EKEventStore?

    public init() {}

    public func authorizationStatus(for domain: AccessDomain) -> AccessStatus {
        let entityType: EKEntityType = (domain == .calendars) ? .event : .reminder
        return Self.mapAuthStatus(EKEventStore.authorizationStatus(for: entityType))
    }

    public func sessionInfo() -> SessionInfo {
        let env = ProcessInfo.processInfo.environment
        let isSSH = (env["SSH_CLIENT"] != nil) || (env["SSH_TTY"] != nil) || (env["SSH_CONNECTION"] != nil)
        let hasAquaGUI = CGSessionCopyCurrentDictionary() != nil
        return SessionInfo(isSSH: isSSH, hasAquaGUI: hasAquaGUI)
    }

    public func requestAccess(for domain: AccessDomain) async throws -> AccessStatus {
        let initial = authorizationStatus(for: domain)
        if initial == .fullAccess {
            return .fullAccess
        }

        return try await runWithTimeout(seconds: 30, code: "TCC_TIMEOUT", message: "Timed out waiting for \(domain.rawValue) permission prompt.") { gate in
            self.queue.async {
                let store = self.storeOnQueue()
                let completion: @Sendable (Bool, (any Error)?) -> Void = { granted, error in
                    self.queue.async {
                        if granted {
                            self.cachedStore?.reset()
                        }
                        if let error {
                            gate(.failure(DaykitError(
                                code: "TCC_REQUEST_FAILED",
                                exitCode: .permissionOrPolicyDenied,
                                message: "Failed requesting \(domain.rawValue) permission: \(error.localizedDescription)"
                            )))
                            return
                        }
                        gate(.success(self.authorizationStatus(for: domain)))
                    }
                }
                if domain == .calendars {
                    store.requestFullAccessToEvents(completion: completion)
                } else {
                    store.requestFullAccessToReminders(completion: completion)
                }
            }
        }
    }

    public func listCalendars() async throws -> [CalendarSummary] {
        try await runOnQueue { store in
            let defaultId = store.defaultCalendarForNewEvents?.calendarIdentifier
            return store.calendars(for: .event)
                .map { cal in
                    CalendarSummary(
                        id: cal.calendarIdentifier,
                        title: cal.title,
                        sourceName: cal.source?.title ?? "Local",
                        sourceType: Self.mapSourceType(cal.source?.sourceType),
                        colorHex: Self.hexColor(from: cal.cgColor),
                        writable: cal.allowsContentModifications,
                        isDefault: cal.calendarIdentifier == defaultId,
                        isSubscribed: cal.isSubscribed,
                        isImmutable: cal.isImmutable
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.sourceName != rhs.sourceName { return lhs.sourceName < rhs.sourceName }
                    if lhs.title != rhs.title { return lhs.title < rhs.title }
                    return lhs.id < rhs.id
                }
        }
    }

    public func listEvents(from: Date, to: Date, calendarIDs: [String]?) async throws -> [EventRecord] {
        try await runOnQueue { store in
            let targetCalendars: [EKCalendar]?
            if let calendarIDs {
                let idSet = Set(calendarIDs)
                targetCalendars = store.calendars(for: .event).filter { idSet.contains($0.calendarIdentifier) }
                if targetCalendars?.isEmpty == true {
                    return []
                }
            } else {
                targetCalendars = nil
            }

            let calendar = Calendar.current
            let timeZone = TimeZone.current
            var recordsByInstanceID: [String: EventRecord] = [:]
            var chunkStart = from
            let maxSpanDays = 365

            while chunkStart < to {
                let nextChunk = calendar.date(byAdding: .day, value: maxSpanDays, to: chunkStart) ?? to
                let chunkEnd = min(nextChunk, to)
                let predicate = store.predicateForEvents(withStart: chunkStart, end: chunkEnd, calendars: targetCalendars)
                let events = store.events(matching: predicate)
                for event in events {
                    let mapped = Self.mapEvent(event, calendar: calendar, defaultTimeZone: timeZone)
                    recordsByInstanceID[mapped.instanceId] = mapped
                }
                if chunkEnd <= chunkStart { break }
                chunkStart = chunkEnd
            }

            return recordsByInstanceID.values.sorted { lhs, rhs in
                if lhs.startAt != rhs.startAt { return lhs.startAt < rhs.startAt }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.instanceId < rhs.instanceId
            }
        }
    }

    public func findEvent(instanceId: String) async throws -> EventRecord? {
        try await runOnQueue { store in
            guard let event = try Self.resolveEKEventOnQueue(store: store, instanceId: instanceId) else {
                return nil
            }
            return Self.mapEvent(event, calendar: Calendar.current, defaultTimeZone: TimeZone.current)
        }
    }

    public func createEvent(_ input: EventCreateInput) async throws -> EventRecord {
        try await runOnQueue { store in
            guard let targetCalendar = store.calendars(for: .event).first(where: { $0.calendarIdentifier == input.calendarId }) else {
                throw DaykitError(code: "CALENDAR_NOT_FOUND", exitCode: .notFound, message: "Calendar '\(input.calendarId)' not found.")
            }
            guard targetCalendar.allowsContentModifications else {
                throw DaykitError(code: "CALENDAR_READ_ONLY", exitCode: .permissionOrPolicyDenied, message: "Calendar '\(targetCalendar.title)' is read-only.")
            }

            let event = EKEvent(eventStore: store)
            event.calendar = targetCalendar
            event.title = input.title
            event.isAllDay = input.allDay
            event.startDate = input.startDate
            event.endDate = input.endDate
            event.location = input.location
            event.notes = input.notes
            if let urlStr = input.url {
                event.url = URL(string: urlStr)
            }
            if !input.allDay {
                event.timeZone = TimeZone.current
            }
            for minutes in input.alarmsMinutesBefore {
                event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
            }

            try store.save(event, span: .thisEvent, commit: true)
            return Self.mapEvent(event, calendar: Calendar.current, defaultTimeZone: TimeZone.current)
        }
    }

    public func updateEvent(_ input: EventUpdateInput) async throws -> EventRecord {
        try await runOnQueue { store in
            guard let event = try Self.resolveEKEventOnQueue(store: store, instanceId: input.instanceId) else {
                throw DaykitError(code: "EVENT_NOT_FOUND", exitCode: .notFound, message: "Event '\(input.instanceId)' not found.")
            }
            guard event.calendar?.allowsContentModifications == true else {
                throw DaykitError(code: "CALENDAR_READ_ONLY", exitCode: .permissionOrPolicyDenied, message: "Event calendar is read-only.")
            }

            if let destinationCalendarId = input.calendarId {
                guard let destCal = store.calendars(for: .event).first(where: { $0.calendarIdentifier == destinationCalendarId }) else {
                    throw DaykitError(code: "CALENDAR_NOT_FOUND", exitCode: .notFound, message: "Calendar '\(destinationCalendarId)' not found.")
                }
                guard destCal.allowsContentModifications else {
                    throw DaykitError(code: "CALENDAR_READ_ONLY", exitCode: .permissionOrPolicyDenied, message: "Calendar '\(destCal.title)' is read-only.")
                }
                event.calendar = destCal
            }

            if let title = input.title {
                event.title = title
            }
            if let allDay = input.allDay {
                event.isAllDay = allDay
            }
            if let startDate = input.startDate {
                event.startDate = startDate
            }
            if let endDate = input.endDate {
                event.endDate = endDate
            }
            if !event.isAllDay && event.timeZone == nil {
                event.timeZone = TimeZone.current
            }

            switch input.location {
            case .unchanged: break
            case .clear: event.location = nil
            case .set(let val): event.location = val.isEmpty ? nil : val
            }

            switch input.notes {
            case .unchanged: break
            case .clear: event.notes = nil
            case .set(let val): event.notes = val.isEmpty ? nil : val
            }

            switch input.url {
            case .unchanged: break
            case .clear: event.url = nil
            case .set(let val): event.url = URL(string: val)
            }

            switch input.alarmsMinutesBefore {
            case .unchanged:
                break
            case .clear:
                for alarm in (event.alarms ?? []) {
                    event.removeAlarm(alarm)
                }
            case .set(let mins):
                for alarm in (event.alarms ?? []) {
                    event.removeAlarm(alarm)
                }
                for m in mins {
                    event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-m * 60)))
                }
            }

            let ekSpan: EKSpan = (input.span == .future) ? .futureEvents : .thisEvent
            try store.save(event, span: ekSpan, commit: true)
            return Self.mapEvent(event, calendar: Calendar.current, defaultTimeZone: TimeZone.current)
        }
    }

    public func deleteEvent(instanceId: String, span: EventSpan) async throws -> EventRecord {
        try await runOnQueue { store in
            guard let event = try Self.resolveEKEventOnQueue(store: store, instanceId: instanceId) else {
                throw DaykitError(code: "EVENT_NOT_FOUND", exitCode: .notFound, message: "Event '\(instanceId)' not found.")
            }
            guard event.calendar?.allowsContentModifications == true else {
                throw DaykitError(code: "CALENDAR_READ_ONLY", exitCode: .permissionOrPolicyDenied, message: "Event calendar is read-only.")
            }
            let snapshot = Self.mapEvent(event, calendar: Calendar.current, defaultTimeZone: TimeZone.current)
            let ekSpan: EKSpan = (span == .future) ? .futureEvents : .thisEvent
            try store.remove(event, span: ekSpan, commit: true)
            return snapshot
        }
    }

    public func listReminderLists() async throws -> [ReminderListSummary] {
        try await runOnQueue { store in
            let defaultId = store.defaultCalendarForNewReminders()?.calendarIdentifier
            return store.calendars(for: .reminder)
                .map { list in
                    ReminderListSummary(
                        id: list.calendarIdentifier,
                        title: list.title,
                        sourceName: list.source?.title ?? "Local",
                        sourceType: Self.mapSourceType(list.source?.sourceType),
                        colorHex: Self.hexColor(from: list.cgColor),
                        writable: list.allowsContentModifications,
                        isDefault: list.calendarIdentifier == defaultId
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.sourceName != rhs.sourceName { return lhs.sourceName < rhs.sourceName }
                    if lhs.title != rhs.title { return lhs.title < rhs.title }
                    return lhs.id < rhs.id
                }
        }
    }

    public func listReminders(listIDs: [String]?, filter: ReminderCompletionFilter) async throws -> [ReminderRecord] {
        try await runWithTimeout(seconds: 15, code: "EVENTKIT_TIMEOUT", message: "Timed out fetching reminders from EventKit.") { finish in
            self.queue.async {
                let store = self.storeOnQueue()
                let targetCals: [EKCalendar]?
                if let listIDs {
                    let idSet = Set(listIDs)
                    let matched = store.calendars(for: .reminder).filter { idSet.contains($0.calendarIdentifier) }
                    if matched.isEmpty {
                        finish(.success([]))
                        return
                    }
                    targetCals = matched
                } else {
                    targetCals = nil
                }

                let predicate: NSPredicate
                switch filter {
                case .open:
                    predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: targetCals)
                case .completed:
                    predicate = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: targetCals)
                case .all:
                    predicate = store.predicateForReminders(in: targetCals)
                }

                store.fetchReminders(matching: predicate) { ekReminders in
                    let timeZone = TimeZone.current
                    let mapped = (ekReminders ?? [])
                        .map { Self.mapReminder($0, timeZone: timeZone) }
                        .sorted { lhs, rhs in
                            switch (lhs.dueAt, rhs.dueAt) {
                            case (.some(let l), .some(let r)):
                                if l != r { return l < r }
                            case (.some, .none):
                                return true
                            case (.none, .some):
                                return false
                            case (.none, .none):
                                break
                            }
                            if lhs.title != rhs.title { return lhs.title < rhs.title }
                            return lhs.id < rhs.id
                        }
                    finish(.success(mapped))
                }
            }
        }
    }

    public func createReminder(_ input: ReminderCreateInput) async throws -> ReminderRecord {
        try await runOnQueue { store in
            guard let targetList = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == input.listId }) else {
                throw DaykitError(code: "LIST_NOT_FOUND", exitCode: .notFound, message: "Reminder list '\(input.listId)' not found.")
            }
            guard targetList.allowsContentModifications else {
                throw DaykitError(code: "LIST_READ_ONLY", exitCode: .permissionOrPolicyDenied, message: "Reminder list '\(targetList.title)' is read-only.")
            }

            let reminder = EKReminder(eventStore: store)
            reminder.calendar = targetList
            reminder.title = input.title
            reminder.priority = input.priority.eventKitValue
            reminder.notes = input.notes
            if let dueComponents = input.dueComponents {
                reminder.dueDateComponents = dueComponents
            }
            if let alarmDate = input.dueAlarmDate {
                reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
            }
            if let urlStr = input.url {
                reminder.url = URL(string: urlStr)
            }

            try store.save(reminder, commit: true)
            return Self.mapReminder(reminder, timeZone: TimeZone.current)
        }
    }

    public func findReminder(id: String) async throws -> ReminderRecord? {
        try await runOnQueue { store in
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                return nil
            }
            return Self.mapReminder(reminder, timeZone: TimeZone.current)
        }
    }

    public func updateReminder(_ input: ReminderUpdateInput) async throws -> ReminderRecord {
        try await runOnQueue { store in
            guard let reminder = store.calendarItem(withIdentifier: input.id) as? EKReminder else {
                throw DaykitError(code: "REMINDER_NOT_FOUND", exitCode: .notFound, message: "Reminder '\(input.id)' not found.")
            }
            guard reminder.calendar?.allowsContentModifications == true else {
                throw DaykitError(code: "LIST_READ_ONLY", exitCode: .permissionOrPolicyDenied, message: "Reminder list is read-only.")
            }

            if let destListId = input.listId {
                guard let destList = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == destListId }) else {
                    throw DaykitError(code: "LIST_NOT_FOUND", exitCode: .notFound, message: "Reminder list '\(destListId)' not found.")
                }
                guard destList.allowsContentModifications else {
                    throw DaykitError(code: "LIST_READ_ONLY", exitCode: .permissionOrPolicyDenied, message: "Reminder list '\(destList.title)' is read-only.")
                }
                reminder.calendar = destList
            }

            if let title = input.title {
                reminder.title = title
            }
            if let priority = input.priority {
                reminder.priority = priority.eventKitValue
            }

            switch input.due {
            case .unchanged:
                break
            case .clear:
                reminder.dueDateComponents = nil
                Self.removeAbsoluteAlarms(from: reminder)
            case .set(let dueUpdate):
                reminder.dueDateComponents = dueUpdate.dueComponents
                Self.removeAbsoluteAlarms(from: reminder)
                if let alarmDate = dueUpdate.dueAlarmDate {
                    reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
                }
            }

            switch input.notes {
            case .unchanged: break
            case .clear: reminder.notes = nil
            case .set(let val): reminder.notes = val.isEmpty ? nil : val
            }

            switch input.url {
            case .unchanged: break
            case .clear: reminder.url = nil
            case .set(let val): reminder.url = URL(string: val)
            }

            try store.save(reminder, commit: true)
            return Self.mapReminder(reminder, timeZone: TimeZone.current)
        }
    }

    public func completeReminder(id: String) async throws -> CompleteReminderResult {
        let initial: (result: CompleteReminderResult?, listId: String, title: String, isRecurring: Bool) = try await runOnQueue { store in
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                throw DaykitError(code: "REMINDER_NOT_FOUND", exitCode: .notFound, message: "Reminder '\(id)' not found.")
            }
            guard let list = reminder.calendar, list.allowsContentModifications else {
                throw DaykitError(code: "LIST_READ_ONLY", exitCode: .permissionOrPolicyDenied, message: "Reminder list is read-only.")
            }
            let title = reminder.title ?? ""
            let isRecurring = reminder.hasRecurrenceRules
            let listId = list.calendarIdentifier
            if reminder.isCompleted {
                let mapped = Self.mapReminder(reminder, timeZone: TimeZone.current)
                return (
                    CompleteReminderResult(
                        dryRun: false,
                        action: "complete_reminder",
                        completedId: id,
                        title: title,
                        alreadyCompleted: true,
                        isRecurring: isRecurring,
                        nextOccurrenceId: nil,
                        reminder: mapped
                    ),
                    listId,
                    title,
                    isRecurring
                )
            }

            reminder.isCompleted = true
            reminder.completionDate = Date()
            try store.save(reminder, commit: true)

            if !isRecurring {
                let mapped = Self.mapReminder(reminder, timeZone: TimeZone.current)
                return (
                    CompleteReminderResult(
                        dryRun: false,
                        action: "complete_reminder",
                        completedId: id,
                        title: title,
                        alreadyCompleted: false,
                        isRecurring: false,
                        nextOccurrenceId: nil,
                        reminder: mapped
                    ),
                    listId,
                    title,
                    false
                )
            }
            return (nil, listId, title, true)
        }

        if let ready = initial.result {
            return ready
        }

        let openInList = try await listReminders(listIDs: [initial.listId], filter: .open)
        let nextCandidate = openInList
            .filter { $0.id != id && $0.title == initial.title }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            .first
        let completedRecord = try await findReminder(id: id)

        return CompleteReminderResult(
            dryRun: false,
            action: "complete_reminder",
            completedId: id,
            title: initial.title,
            alreadyCompleted: false,
            isRecurring: initial.isRecurring,
            nextOccurrenceId: nextCandidate?.id,
            reminder: completedRecord
        )
    }

    public func deleteReminder(id: String) async throws -> ReminderRecord {
        try await runOnQueue { store in
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                throw DaykitError(code: "REMINDER_NOT_FOUND", exitCode: .notFound, message: "Reminder '\(id)' not found.")
            }
            guard reminder.calendar?.allowsContentModifications == true else {
                throw DaykitError(code: "LIST_READ_ONLY", exitCode: .permissionOrPolicyDenied, message: "Reminder list is read-only.")
            }
            let snapshot = Self.mapReminder(reminder, timeZone: TimeZone.current)
            try store.remove(reminder, commit: true)
            return snapshot
        }
    }

    public func listSources(eventsAuthorized: Bool, remindersAuthorized: Bool) async throws -> [String] {
        guard eventsAuthorized || remindersAuthorized else { return [] }
        return try await runOnQueue { store in
            var seen = Set<String>()
            if eventsAuthorized {
                for cal in store.calendars(for: .event) {
                    if let title = cal.source?.title, !title.isEmpty {
                        seen.insert(title)
                    }
                }
            }
            if remindersAuthorized {
                for list in store.calendars(for: .reminder) {
                    if let title = list.source?.title, !title.isEmpty {
                        seen.insert(title)
                    }
                }
            }
            return seen.sorted()
        }
    }

    private func storeOnQueue() -> EKEventStore {
        if let cachedStore { return cachedStore }
        let store = EKEventStore()
        cachedStore = store
        return store
    }

    private func runOnQueue<T: Sendable>(_ work: @escaping @Sendable (EKEventStore) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let store = self.storeOnQueue()
                    let value = try work(store)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runWithTimeout<T: Sendable>(
        seconds: Int,
        code: String,
        message: String,
        start: @escaping @Sendable (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = OnceContinuation(continuation)
            let timer = DispatchWorkItem {
                gate.finish(with: .failure(DaykitError(code: code, exitCode: .runtimeError, message: message)))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds), execute: timer)

            start { result in
                timer.cancel()
                gate.finish(with: result)
            }
        }
    }

    private static func resolveEKEventOnQueue(store: EKEventStore, instanceId: String) throws -> EKEvent? {
        let ref = EventInstanceRef.parse(instanceId)
        if let occDate = ref.occurrenceDate {
            for windowSeconds: TimeInterval in [86400, 604800] {
                let start = occDate.addingTimeInterval(-windowSeconds)
                let end = occDate.addingTimeInterval(windowSeconds)
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
                let candidates = store.events(matching: predicate)
                if let matched = candidates.first(where: { event in
                    let sameSeries = (event.eventIdentifier == ref.seriesId) || (event.calendarItemIdentifier == ref.seriesId)
                    guard sameSeries else { return false }
                    guard let anchor = event.occurrenceDate ?? event.startDate else { return false }
                    return abs(anchor.timeIntervalSince(occDate)) <= 1.0
                }) {
                    return matched
                }
            }
            return nil
        }

        let found = store.event(withIdentifier: ref.seriesId) ?? (store.calendarItem(withIdentifier: ref.seriesId) as? EKEvent)
        guard let event = found else { return nil }
        if event.hasRecurrenceRules || event.isDetached {
            throw DaykitError(
                code: "AMBIGUOUS_RECURRING_ID",
                exitCode: .usageError,
                message: "Event '\(ref.seriesId)' is recurring/detached; use the full instance_id (<series_id>@<occurrence_utc>) from 'cal list/today/week'."
            )
        }
        return event
    }

    private static func removeAbsoluteAlarms(from reminder: EKReminder) {
        for alarm in (reminder.alarms ?? []) where alarm.absoluteDate != nil {
            reminder.removeAlarm(alarm)
        }
    }

    private static func mapAuthStatus(_ status: EKAuthorizationStatus) -> AccessStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }

    private static func mapSourceType(_ type: EKSourceType?) -> String {
        switch type {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "caldav"
        case .mobileMe: return "icloud"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        default: return "unknown"
        }
    }

    private static func hexColor(from cgColor: CGColor?) -> String? {
        guard let cgColor,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let comps = converted.components,
              comps.count >= 3
        else { return nil }
        let r = Int((min(max(comps[0], 0), 1) * 255.0).rounded())
        let g = Int((min(max(comps[1], 0), 1) * 255.0).rounded())
        let b = Int((min(max(comps[2], 0), 1) * 255.0).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func mapEvent(_ event: EKEvent, calendar: Calendar, defaultTimeZone: TimeZone) -> EventRecord {
        let seriesId = event.eventIdentifier ?? event.calendarItemIdentifier
        let isRecurring = event.hasRecurrenceRules || event.isDetached
        let occurrenceAnchor = event.occurrenceDate ?? event.startDate ?? Date()
        let occurrenceUTC = isRecurring ? DateParsing.formatUTCISO8601(occurrenceAnchor) : nil
        let instanceId = isRecurring ? "\(seriesId)@\(occurrenceUTC!)" : seriesId

        let startAt: String
        let endAt: String
        if event.isAllDay {
            startAt = DateParsing.formatDateOnly(event.startDate, calendar: calendar)
            let rawEnd = event.endDate ?? event.startDate!
            let comps = calendar.dateComponents([.hour, .minute, .second], from: rawEnd)
            let normalizedEnd: Date
            if rawEnd > event.startDate && comps.hour == 0 && comps.minute == 0 && comps.second == 0 {
                normalizedEnd = rawEnd.addingTimeInterval(-1)
            } else {
                normalizedEnd = rawEnd
            }
            endAt = DateParsing.formatDateOnly(normalizedEnd, calendar: calendar)
        } else {
            let tz = event.timeZone ?? defaultTimeZone
            startAt = DateParsing.formatRFC3339(event.startDate, timeZone: tz)
            endAt = DateParsing.formatRFC3339(event.endDate, timeZone: tz)
        }

        let alarms = (event.alarms ?? []).map { Int((-$0.relativeOffset / 60.0).rounded()) }
        let attendees = (event.attendees ?? []).map { participant in
            let urlStr = participant.url.absoluteString
            let email = urlStr.lowercased().hasPrefix("mailto:") ? String(urlStr.dropFirst(7)) : nil
            return AttendeeSummary(
                name: participant.name,
                email: email,
                status: mapParticipantStatus(participant.participantStatus),
                role: mapParticipantRole(participant.participantRole)
            )
        }

        let rawNotes = event.notes
        return EventRecord(
            instanceId: instanceId,
            seriesId: seriesId,
            title: event.title ?? "",
            startAt: startAt,
            endAt: endAt,
            allDay: event.isAllDay,
            timezone: event.isAllDay ? nil : (event.timeZone ?? defaultTimeZone).identifier,
            calendarId: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            location: event.location?.isEmpty == true ? nil : event.location,
            notes: rawNotes?.isEmpty == true ? nil : rawNotes,
            hasNotes: !(rawNotes?.isEmpty ?? true),
            notesTruncated: false,
            url: event.url?.absoluteString,
            availability: mapAvailability(event.availability),
            status: mapEventStatus(event.status),
            isRecurring: isRecurring,
            isDetached: event.isDetached,
            occurrenceDate: occurrenceUTC,
            alarmsMinutesBefore: alarms,
            attendees: attendees
        )
    }

    private static func mapReminder(_ reminder: EKReminder, timeZone: TimeZone) -> ReminderRecord {
        var dueAt: String?
        var hasDueTime = false
        if let comps = reminder.dueDateComponents {
            let formatted = DateParsing.formatDateComponents(comps, timeZone: timeZone)
            if !formatted.string.isEmpty {
                dueAt = formatted.string
                hasDueTime = formatted.hasDueTime
            }
        }

        let rawNotes = reminder.notes
        return ReminderRecord(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            listId: reminder.calendar?.calendarIdentifier ?? "",
            listTitle: reminder.calendar?.title ?? "",
            dueAt: dueAt,
            hasDueTime: hasDueTime,
            completed: reminder.isCompleted,
            completionDate: reminder.completionDate.map { DateParsing.formatRFC3339($0, timeZone: timeZone) },
            priority: PriorityLevel(eventKitPriority: reminder.priority),
            notes: rawNotes?.isEmpty == true ? nil : rawNotes,
            hasNotes: !(rawNotes?.isEmpty ?? true),
            notesTruncated: false,
            url: reminder.url?.absoluteString,
            isRecurring: reminder.hasRecurrenceRules,
            createdAt: reminder.creationDate.map { DateParsing.formatRFC3339($0, timeZone: timeZone) },
            modifiedAt: reminder.lastModifiedDate.map { DateParsing.formatRFC3339($0, timeZone: timeZone) }
        )
    }

    private static func mapAvailability(_ availability: EKEventAvailability) -> String {
        switch availability {
        case .notSupported: return "not_supported"
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        @unknown default: return "unknown"
        }
    }

    private static func mapEventStatus(_ status: EKEventStatus) -> String {
        switch status {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }

    private static func mapParticipantStatus(_ status: EKParticipantStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in_progress"
        @unknown default: return "unknown"
        }
    }

    private static func mapParticipantRole(_ role: EKParticipantRole) -> String {
        switch role {
        case .unknown: return "unknown"
        case .required: return "required"
        case .optional: return "optional"
        case .chair: return "chair"
        case .nonParticipant: return "non_participant"
        @unknown default: return "unknown"
        }
    }
}
