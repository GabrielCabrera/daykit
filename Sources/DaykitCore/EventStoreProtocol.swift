import Foundation

public protocol EventStoreProtocol: Sendable {
    func authorizationStatus(for domain: AccessDomain) -> AccessStatus
    func sessionInfo() -> SessionInfo
    func requestAccess(for domain: AccessDomain) async throws -> AccessStatus
    func listCalendars() async throws -> [CalendarSummary]
    func listEvents(from: Date, to: Date, calendarIDs: [String]?) async throws -> [EventRecord]
    func findEvent(instanceId: String) async throws -> EventRecord?
    func createEvent(_ input: EventCreateInput) async throws -> EventRecord
    func updateEvent(_ input: EventUpdateInput) async throws -> EventRecord
    func deleteEvent(instanceId: String, span: EventSpan) async throws -> EventRecord
    func listReminderLists() async throws -> [ReminderListSummary]
    func listReminders(listIDs: [String]?, filter: ReminderCompletionFilter) async throws -> [ReminderRecord]
    func createReminder(_ input: ReminderCreateInput) async throws -> ReminderRecord
    func findReminder(id: String) async throws -> ReminderRecord?
    func updateReminder(_ input: ReminderUpdateInput) async throws -> ReminderRecord
    func completeReminder(id: String) async throws -> CompleteReminderResult
    func deleteReminder(id: String) async throws -> ReminderRecord
    func listSources(eventsAuthorized: Bool, remindersAuthorized: Bool) async throws -> [String]
}
