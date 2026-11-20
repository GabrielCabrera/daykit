import Foundation

public enum DaykitVersion {
    public static let current = "0.1.0"
    public static let schemaVersion = 1
}

public enum ExitCode: Int32, Sendable, Equatable {
    case success = 0
    case runtimeError = 1
    case usageError = 2
    case permissionOrPolicyDenied = 3
    case notFound = 4
}

public enum JSONValue: Sendable, Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct DaykitError: Error, Sendable, Equatable {
    public let code: String
    public let exitCode: ExitCode
    public let message: String
    public let hint: String?
    public let details: [String: JSONValue]?

    public init(
        code: String,
        exitCode: ExitCode,
        message: String,
        hint: String? = nil,
        details: [String: JSONValue]? = nil
    ) {
        self.code = code
        self.exitCode = exitCode
        self.message = message
        self.hint = hint
        self.details = details
    }
}

public enum AccessDomain: String, Sendable, Codable, Equatable {
    case calendars
    case reminders
}

public enum AccessStatus: String, Sendable, Codable, Equatable {
    case notDetermined = "not_determined"
    case restricted = "restricted"
    case denied = "denied"
    case fullAccess = "full_access"
    case writeOnly = "write_only"

    public var isReadable: Bool {
        self == .fullAccess
    }
}

public enum DoctorAccessRequest: String, Sendable, Equatable {
    case cal
    case rem
    case all
}

public struct SessionInfo: Sendable, Codable, Equatable {
    public let isSSH: Bool
    public let hasAquaGUI: Bool

    enum CodingKeys: String, CodingKey {
        case isSSH = "is_ssh"
        case hasAquaGUI = "has_aqua_gui"
    }

    public init(isSSH: Bool, hasAquaGUI: Bool) {
        self.isSSH = isSSH
        self.hasAquaGUI = hasAquaGUI
    }
}

public struct RuntimePolicy: Sendable, Codable, Equatable {
    public let readOnly: Bool
    public let writableCalendars: [String]
    public let writableLists: [String]

    enum CodingKeys: String, CodingKey {
        case readOnly = "read_only"
        case writableCalendars = "writable_calendars"
        case writableLists = "writable_lists"
    }

    public init(readOnly: Bool = false, writableCalendars: [String] = [], writableLists: [String] = []) {
        self.readOnly = readOnly
        self.writableCalendars = writableCalendars
        self.writableLists = writableLists
    }

    public static func fromEnvironment(_ environment: [String: String]) -> RuntimePolicy {
        let rawReadOnly = environment["DAYKIT_READ_ONLY"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let readOnly = ["1", "true", "yes", "on"].contains(rawReadOnly)
        let calendars = parseAllowlist(environment["DAYKIT_WRITABLE_CALENDARS"])
        let lists = parseAllowlist(environment["DAYKIT_WRITABLE_LISTS"])
        return RuntimePolicy(readOnly: readOnly, writableCalendars: calendars, writableLists: lists)
    }

    private static func parseAllowlist(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public enum PriorityLevel: String, Sendable, Codable, Equatable {
    case none
    case low
    case medium
    case high

    public init(eventKitPriority: Int) {
        switch eventKitPriority {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }

    public var eventKitValue: Int {
        switch self {
        case .none: return 0
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        }
    }
}

public enum ReminderCompletionFilter: String, Sendable, Codable, Equatable {
    case open
    case completed
    case all
}

public struct CalendarSummary: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let sourceName: String
    public let sourceType: String
    public let colorHex: String?
    public let writable: Bool
    public let isDefault: Bool
    public let isSubscribed: Bool
    public let isImmutable: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourceName = "source_name"
        case sourceType = "source_type"
        case colorHex = "color_hex"
        case writable
        case isDefault = "is_default"
        case isSubscribed = "is_subscribed"
        case isImmutable = "is_immutable"
    }

    public init(
        id: String,
        title: String,
        sourceName: String,
        sourceType: String,
        colorHex: String?,
        writable: Bool,
        isDefault: Bool,
        isSubscribed: Bool,
        isImmutable: Bool
    ) {
        self.id = id
        self.title = title
        self.sourceName = sourceName
        self.sourceType = sourceType
        self.colorHex = colorHex
        self.writable = writable
        self.isDefault = isDefault
        self.isSubscribed = isSubscribed
        self.isImmutable = isImmutable
    }
}

public struct AttendeeSummary: Sendable, Codable, Equatable {
    public let name: String?
    public let email: String?
    public let status: String
    public let role: String

    public init(name: String?, email: String?, status: String, role: String) {
        self.name = name
        self.email = email
        self.status = status
        self.role = role
    }
}

public struct EventRecord: Sendable, Codable, Equatable {
    public let instanceId: String
    public let seriesId: String
    public let title: String
    public let startAt: String
    public let endAt: String
    public let allDay: Bool
    public let timezone: String?
    public let calendarId: String
    public let calendarTitle: String
    public let location: String?
    public let notes: String?
    public let hasNotes: Bool
    public let notesTruncated: Bool
    public let url: String?
    public let availability: String
    public let status: String
    public let isRecurring: Bool
    public let isDetached: Bool
    public let occurrenceDate: String?
    public let alarmsMinutesBefore: [Int]
    public let attendees: [AttendeeSummary]

    enum CodingKeys: String, CodingKey {
        case instanceId = "instance_id"
        case seriesId = "series_id"
        case title
        case startAt = "start_at"
        case endAt = "end_at"
        case allDay = "all_day"
        case timezone
        case calendarId = "calendar_id"
        case calendarTitle = "calendar_title"
        case location
        case notes
        case hasNotes = "has_notes"
        case notesTruncated = "notes_truncated"
        case url
        case availability
        case status
        case isRecurring = "is_recurring"
        case isDetached = "is_detached"
        case occurrenceDate = "occurrence_date"
        case alarmsMinutesBefore = "alarms_minutes_before"
        case attendees
    }

    public init(
        instanceId: String,
        seriesId: String,
        title: String,
        startAt: String,
        endAt: String,
        allDay: Bool,
        timezone: String?,
        calendarId: String,
        calendarTitle: String,
        location: String?,
        notes: String?,
        hasNotes: Bool,
        notesTruncated: Bool,
        url: String?,
        availability: String,
        status: String,
        isRecurring: Bool,
        isDetached: Bool,
        occurrenceDate: String?,
        alarmsMinutesBefore: [Int],
        attendees: [AttendeeSummary]
    ) {
        self.instanceId = instanceId
        self.seriesId = seriesId
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.timezone = timezone
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.location = location
        self.notes = notes
        self.hasNotes = hasNotes
        self.notesTruncated = notesTruncated
        self.url = url
        self.availability = availability
        self.status = status
        self.isRecurring = isRecurring
        self.isDetached = isDetached
        self.occurrenceDate = occurrenceDate
        self.alarmsMinutesBefore = alarmsMinutesBefore
        self.attendees = attendees
    }

    public func withProcessedNotes(maxBytes: Int, include: Bool) -> EventRecord {
        let processed = OutputFormatting.processNotes(notes, maxBytes: maxBytes, include: include)
        return EventRecord(
            instanceId: instanceId,
            seriesId: seriesId,
            title: title,
            startAt: startAt,
            endAt: endAt,
            allDay: allDay,
            timezone: timezone,
            calendarId: calendarId,
            calendarTitle: calendarTitle,
            location: location,
            notes: processed.value,
            hasNotes: processed.hasNotes,
            notesTruncated: processed.truncated,
            url: url,
            availability: availability,
            status: status,
            isRecurring: isRecurring,
            isDetached: isDetached,
            occurrenceDate: occurrenceDate,
            alarmsMinutesBefore: alarmsMinutesBefore,
            attendees: attendees
        )
    }
}

public struct ReminderListSummary: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let sourceName: String
    public let sourceType: String
    public let colorHex: String?
    public let writable: Bool
    public let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourceName = "source_name"
        case sourceType = "source_type"
        case colorHex = "color_hex"
        case writable
        case isDefault = "is_default"
    }

    public init(
        id: String,
        title: String,
        sourceName: String,
        sourceType: String,
        colorHex: String?,
        writable: Bool,
        isDefault: Bool
    ) {
        self.id = id
        self.title = title
        self.sourceName = sourceName
        self.sourceType = sourceType
        self.colorHex = colorHex
        self.writable = writable
        self.isDefault = isDefault
    }
}

public struct ReminderRecord: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let listId: String
    public let listTitle: String
    public let dueAt: String?
    public let hasDueTime: Bool
    public let completed: Bool
    public let completionDate: String?
    public let priority: PriorityLevel
    public let notes: String?
    public let hasNotes: Bool
    public let notesTruncated: Bool
    public let url: String?
    public let isRecurring: Bool
    public let createdAt: String?
    public let modifiedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case listId = "list_id"
        case listTitle = "list_title"
        case dueAt = "due_at"
        case hasDueTime = "has_due_time"
        case completed
        case completionDate = "completion_date"
        case priority
        case notes
        case hasNotes = "has_notes"
        case notesTruncated = "notes_truncated"
        case url
        case isRecurring = "is_recurring"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }

    public init(
        id: String,
        title: String,
        listId: String,
        listTitle: String,
        dueAt: String?,
        hasDueTime: Bool,
        completed: Bool,
        completionDate: String?,
        priority: PriorityLevel,
        notes: String?,
        hasNotes: Bool,
        notesTruncated: Bool,
        url: String?,
        isRecurring: Bool,
        createdAt: String?,
        modifiedAt: String?
    ) {
        self.id = id
        self.title = title
        self.listId = listId
        self.listTitle = listTitle
        self.dueAt = dueAt
        self.hasDueTime = hasDueTime
        self.completed = completed
        self.completionDate = completionDate
        self.priority = priority
        self.notes = notes
        self.hasNotes = hasNotes
        self.notesTruncated = notesTruncated
        self.url = url
        self.isRecurring = isRecurring
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public func withProcessedNotes(maxBytes: Int, include: Bool) -> ReminderRecord {
        let processed = OutputFormatting.processNotes(notes, maxBytes: maxBytes, include: include)
        return ReminderRecord(
            id: id,
            title: title,
            listId: listId,
            listTitle: listTitle,
            dueAt: dueAt,
            hasDueTime: hasDueTime,
            completed: completed,
            completionDate: completionDate,
            priority: priority,
            notes: processed.value,
            hasNotes: processed.hasNotes,
            notesTruncated: processed.truncated,
            url: url,
            isRecurring: isRecurring,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }
}

public struct BriefingPayload: Sendable, Codable, Equatable {
    public let windowFrom: String
    public let windowTo: String
    public let days: Int
    public let overdueTotal: Int
    public let overdueTruncated: Bool
    public let overdueReminders: [ReminderRecord]
    public let todayReminders: [ReminderRecord]
    public let todayEvents: [EventRecord]
    public let upcomingEvents: [EventRecord]
    public let warnings: [String]
    public let untrustedContentNotice: String

    enum CodingKeys: String, CodingKey {
        case windowFrom = "window_from"
        case windowTo = "window_to"
        case days
        case overdueTotal = "overdue_total"
        case overdueTruncated = "overdue_truncated"
        case overdueReminders = "overdue_reminders"
        case todayReminders = "today_reminders"
        case todayEvents = "today_events"
        case upcomingEvents = "upcoming_events"
        case warnings
        case untrustedContentNotice = "untrusted_content_notice"
    }

    public init(
        windowFrom: String,
        windowTo: String,
        days: Int,
        overdueTotal: Int,
        overdueTruncated: Bool,
        overdueReminders: [ReminderRecord],
        todayReminders: [ReminderRecord],
        todayEvents: [EventRecord],
        upcomingEvents: [EventRecord],
        warnings: [String],
        untrustedContentNotice: String
    ) {
        self.windowFrom = windowFrom
        self.windowTo = windowTo
        self.days = days
        self.overdueTotal = overdueTotal
        self.overdueTruncated = overdueTruncated
        self.overdueReminders = overdueReminders
        self.todayReminders = todayReminders
        self.todayEvents = todayEvents
        self.upcomingEvents = upcomingEvents
        self.warnings = warnings
        self.untrustedContentNotice = untrustedContentNotice
    }
}

public struct DoctorPermissions: Sendable, Codable, Equatable {
    public let calendars: AccessStatus
    public let reminders: AccessStatus

    public init(calendars: AccessStatus, reminders: AccessStatus) {
        self.calendars = calendars
        self.reminders = reminders
    }
}

public struct DoctorTargetRef: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let sourceName: String

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourceName = "source_name"
    }

    public init(id: String, title: String, sourceName: String) {
        self.id = id
        self.title = title
        self.sourceName = sourceName
    }
}

public struct DoctorPayload: Sendable, Codable, Equatable {
    public let daykitVersion: String
    public let macosVersion: String
    public let arch: String
    public let session: SessionInfo
    public let policy: RuntimePolicy
    public let permissions: DoctorPermissions
    public let defaultCalendar: DoctorTargetRef?
    public let defaultReminderList: DoctorTargetRef?
    public let sources: [String]
    public let notes: [String]

    enum CodingKeys: String, CodingKey {
        case daykitVersion = "daykit_version"
        case macosVersion = "macos_version"
        case arch
        case session
        case policy
        case permissions
        case defaultCalendar = "default_calendar"
        case defaultReminderList = "default_reminder_list"
        case sources
        case notes
    }

    public init(
        daykitVersion: String,
        macosVersion: String,
        arch: String,
        session: SessionInfo,
        policy: RuntimePolicy,
        permissions: DoctorPermissions,
        defaultCalendar: DoctorTargetRef?,
        defaultReminderList: DoctorTargetRef?,
        sources: [String],
        notes: [String]
    ) {
        self.daykitVersion = daykitVersion
        self.macosVersion = macosVersion
        self.arch = arch
        self.session = session
        self.policy = policy
        self.permissions = permissions
        self.defaultCalendar = defaultCalendar
        self.defaultReminderList = defaultReminderList
        self.sources = sources
        self.notes = notes
    }
}

public struct EventCreateInput: Sendable, Equatable {
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let allDay: Bool
    public let calendarId: String
    public let location: String?
    public let notes: String?
    public let url: String?
    public let alarmsMinutesBefore: [Int]

    public init(
        title: String,
        startDate: Date,
        endDate: Date,
        allDay: Bool,
        calendarId: String,
        location: String?,
        notes: String?,
        url: String?,
        alarmsMinutesBefore: [Int]
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.allDay = allDay
        self.calendarId = calendarId
        self.location = location
        self.notes = notes
        self.url = url
        self.alarmsMinutesBefore = alarmsMinutesBefore
    }
}

public struct ReminderCreateInput: Sendable, Equatable {
    public let title: String
    public let listId: String
    public let dueComponents: DateComponents?
    public let hasDueTime: Bool
    public let dueAlarmDate: Date?
    public let priority: PriorityLevel
    public let notes: String?
    public let url: String?

    public init(
        title: String,
        listId: String,
        dueComponents: DateComponents?,
        hasDueTime: Bool,
        dueAlarmDate: Date?,
        priority: PriorityLevel,
        notes: String?,
        url: String?
    ) {
        self.title = title
        self.listId = listId
        self.dueComponents = dueComponents
        self.hasDueTime = hasDueTime
        self.dueAlarmDate = dueAlarmDate
        self.priority = priority
        self.notes = notes
        self.url = url
    }
}

public struct CreateEventPreview: Sendable, Codable, Equatable {
    public let calendarId: String
    public let calendarTitle: String
    public let title: String
    public let startAt: String
    public let endAt: String
    public let allDay: Bool
    public let location: String?
    public let notes: String?
    public let url: String?
    public let alarmsMinutesBefore: [Int]

    enum CodingKeys: String, CodingKey {
        case calendarId = "calendar_id"
        case calendarTitle = "calendar_title"
        case title
        case startAt = "start_at"
        case endAt = "end_at"
        case allDay = "all_day"
        case location
        case notes
        case url
        case alarmsMinutesBefore = "alarms_minutes_before"
    }

    public init(
        calendarId: String,
        calendarTitle: String,
        title: String,
        startAt: String,
        endAt: String,
        allDay: Bool,
        location: String?,
        notes: String?,
        url: String?,
        alarmsMinutesBefore: [Int]
    ) {
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.location = location
        self.notes = notes
        self.url = url
        self.alarmsMinutesBefore = alarmsMinutesBefore
    }
}

public struct CreateEventResult: Sendable, Codable, Equatable {
    public let dryRun: Bool
    public let action: String
    public let preview: CreateEventPreview?
    public let event: EventRecord?

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case action
        case preview
        case event
    }

    public init(dryRun: Bool, action: String, preview: CreateEventPreview?, event: EventRecord?) {
        self.dryRun = dryRun
        self.action = action
        self.preview = preview
        self.event = event
    }
}

public struct CreateReminderPreview: Sendable, Codable, Equatable {
    public let listId: String
    public let listTitle: String
    public let title: String
    public let dueAt: String?
    public let hasDueTime: Bool
    public let priority: PriorityLevel
    public let notes: String?
    public let url: String?

    enum CodingKeys: String, CodingKey {
        case listId = "list_id"
        case listTitle = "list_title"
        case title
        case dueAt = "due_at"
        case hasDueTime = "has_due_time"
        case priority
        case notes
        case url
    }

    public init(
        listId: String,
        listTitle: String,
        title: String,
        dueAt: String?,
        hasDueTime: Bool,
        priority: PriorityLevel,
        notes: String?,
        url: String?
    ) {
        self.listId = listId
        self.listTitle = listTitle
        self.title = title
        self.dueAt = dueAt
        self.hasDueTime = hasDueTime
        self.priority = priority
        self.notes = notes
        self.url = url
    }
}

public struct CreateReminderResult: Sendable, Codable, Equatable {
    public let dryRun: Bool
    public let action: String
    public let preview: CreateReminderPreview?
    public let reminder: ReminderRecord?

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case action
        case preview
        case reminder
    }

    public init(dryRun: Bool, action: String, preview: CreateReminderPreview?, reminder: ReminderRecord?) {
        self.dryRun = dryRun
        self.action = action
        self.preview = preview
        self.reminder = reminder
    }
}

public struct CompleteReminderResult: Sendable, Codable, Equatable {
    public let dryRun: Bool
    public let action: String
    public let completedId: String
    public let title: String
    public let alreadyCompleted: Bool
    public let isRecurring: Bool
    public let nextOccurrenceId: String?
    public let reminder: ReminderRecord?

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case action
        case completedId = "completed_id"
        case title
        case alreadyCompleted = "already_completed"
        case isRecurring = "is_recurring"
        case nextOccurrenceId = "next_occurrence_id"
        case reminder
    }

    public init(
        dryRun: Bool,
        action: String,
        completedId: String,
        title: String,
        alreadyCompleted: Bool,
        isRecurring: Bool,
        nextOccurrenceId: String?,
        reminder: ReminderRecord?
    ) {
        self.dryRun = dryRun
        self.action = action
        self.completedId = completedId
        self.title = title
        self.alreadyCompleted = alreadyCompleted
        self.isRecurring = isRecurring
        self.nextOccurrenceId = nextOccurrenceId
        self.reminder = reminder
    }
}

public struct ExecutionOutput: Sendable, Equatable {
    public let exitCode: ExitCode
    public let stdout: String
    public let stderr: String

    public init(exitCode: ExitCode, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}
