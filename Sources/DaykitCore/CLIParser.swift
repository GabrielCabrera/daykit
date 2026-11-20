import Foundation

public enum OutputMode: String, Sendable, Equatable {
    case auto
    case json
    case plain
}

public enum ParsedCommand: Sendable, Equatable {
    case version
    case help(topic: String?)
    case doctor(requestAccess: DoctorAccessRequest?)
    case calCalendars
    case calToday(calendarRefs: [String], maxNotesBytes: Int)
    case calWeek(calendarRefs: [String], maxNotesBytes: Int)
    case calList(from: String?, to: String?, calendarRefs: [String], maxNotesBytes: Int)
    case calAdd(
        title: String,
        start: String,
        end: String?,
        duration: String?,
        allDay: Bool,
        calendarRef: String?,
        location: String?,
        notes: String?,
        url: String?,
        alarms: [String],
        dryRun: Bool
    )
    case calUpdate(
        id: String,
        title: String?,
        start: String?,
        end: String?,
        duration: String?,
        allDay: Bool?,
        calendarRef: String?,
        location: FieldPatch<String>,
        notes: FieldPatch<String>,
        url: FieldPatch<String>,
        alarms: FieldPatch<[String]>,
        span: EventSpan?,
        dryRun: Bool,
        yes: Bool
    )
    case calDelete(id: String, span: EventSpan?, dryRun: Bool, yes: Bool)
    case remLists
    case remList(listRefs: [String], filter: ReminderCompletionFilter, maxNotesBytes: Int)
    case remOverdue(listRefs: [String], maxNotesBytes: Int)
    case remToday(listRefs: [String], maxNotesBytes: Int)
    case remAdd(
        title: String,
        listRef: String?,
        due: String?,
        priority: PriorityLevel,
        notes: String?,
        url: String?,
        dryRun: Bool
    )
    case remUpdate(
        id: String,
        title: String?,
        listRef: String?,
        due: FieldPatch<String>,
        priority: PriorityLevel?,
        notes: FieldPatch<String>,
        url: FieldPatch<String>,
        dryRun: Bool
    )
    case remDone(id: String, dryRun: Bool)
    case remDelete(id: String, dryRun: Bool, yes: Bool)
    case briefing(
        days: Int,
        maxOverdue: Int,
        calendarRefs: [String],
        listRefs: [String],
        includeNotes: Bool,
        maxNotesBytes: Int
    )
}

public struct CLIInvocation: Sendable, Equatable {
    public let command: ParsedCommand
    public let outputMode: OutputMode

    public init(command: ParsedCommand, outputMode: OutputMode) {
        self.command = command
        self.outputMode = outputMode
    }
}

public enum CLIParser {
    public static func parse(_ arguments: [String]) throws -> CLIInvocation {
        var jsonFlag = false
        var plainFlag = false
        var helpFlag = false
        var versionFlag = false

        var positionals: [String] = []
        var flagPairs: [(name: String, value: String?)] = []

        var i = 0
        var afterTerminator = false
        while i < arguments.count {
            let arg = arguments[i]
            if !afterTerminator && arg == "--" {
                afterTerminator = true
                i += 1
                continue
            }

            if !afterTerminator && (arg == "-h" || arg == "--help") {
                helpFlag = true
                i += 1
                continue
            }
            if !afterTerminator && (arg == "-V" || arg == "--version") {
                versionFlag = true
                i += 1
                continue
            }
            if !afterTerminator && arg == "--json" {
                jsonFlag = true
                i += 1
                continue
            }
            if !afterTerminator && arg == "--plain" {
                plainFlag = true
                i += 1
                continue
            }

            if !afterTerminator && arg.hasPrefix("--") {
                let rawFlag = String(arg.dropFirst(2))
                if let eqIndex = rawFlag.firstIndex(of: "=") {
                    let name = String(rawFlag[..<eqIndex])
                    let value = String(rawFlag[rawFlag.index(after: eqIndex)...])
                    flagPairs.append((name, value))
                    i += 1
                    continue
                }
                if isBooleanFlag(rawFlag) {
                    flagPairs.append((rawFlag, nil))
                    i += 1
                    continue
                }
                guard i + 1 < arguments.count else {
                    throw DaykitError(
                        code: "MISSING_FLAG_VALUE",
                        exitCode: .usageError,
                        message: "Flag --\(rawFlag) requires a value."
                    )
                }
                let nextVal = arguments[i + 1]
                flagPairs.append((rawFlag, nextVal))
                i += 2
                continue
            }

            if !afterTerminator && arg.hasPrefix("-") && arg != "-" {
                throw DaykitError(
                    code: "UNKNOWN_FLAG",
                    exitCode: .usageError,
                    message: "Unknown flag '\(arg)'."
                )
            }

            positionals.append(arg)
            i += 1
        }

        if jsonFlag && plainFlag {
            throw DaykitError(
                code: "CONFLICTING_FLAGS",
                exitCode: .usageError,
                message: "Cannot combine --json and --plain."
            )
        }
        let outputMode: OutputMode = jsonFlag ? .json : (plainFlag ? .plain : .auto)

        if versionFlag {
            guard positionals.isEmpty && flagPairs.isEmpty else {
                throw DaykitError(code: "USAGE_ERROR", exitCode: .usageError, message: "--version cannot be combined with subcommands or flags.")
            }
            return CLIInvocation(command: .version, outputMode: outputMode)
        }

        if helpFlag {
            let topic = positionals.isEmpty ? nil : positionals.joined(separator: " ")
            return CLIInvocation(command: .help(topic: topic), outputMode: outputMode)
        }

        guard !positionals.isEmpty else {
            return CLIInvocation(command: .help(topic: nil), outputMode: outputMode)
        }

        let command = try parseCommand(positionals: positionals, flagPairs: flagPairs)
        return CLIInvocation(command: command, outputMode: outputMode)
    }

    private static func isBooleanFlag(_ name: String) -> Bool {
        [
            "all-day", "no-all-day", "dry-run", "completed", "all", "include-notes",
            "clear-location", "clear-notes", "clear-url", "clear-alarms", "clear-due", "yes"
        ].contains(name)
    }

    private static func parseCommand(positionals: [String], flagPairs: [(name: String, value: String?)]) throws -> ParsedCommand {
        let root = positionals[0]
        switch root {
        case "doctor":
            guard positionals.count == 1 else {
                throw DaykitError(code: "UNEXPECTED_ARGUMENT", exitCode: .usageError, message: "Unexpected argument for 'doctor': \(positionals[1]).")
            }
            let opts = try OptionBag(flagPairs, allowed: ["request-access"])
            let reqStr = try opts.singleOptional("request-access")
            let req: DoctorAccessRequest?
            if let reqStr {
                guard let parsed = DoctorAccessRequest(rawValue: reqStr.lowercased()) else {
                    throw DaykitError(code: "INVALID_ARGUMENT", exitCode: .usageError, message: "Invalid --request-access '\(reqStr)'. Use cal, rem, or all.")
                }
                req = parsed
            } else {
                req = nil
            }
            return .doctor(requestAccess: req)

        case "briefing":
            guard positionals.count == 1 else {
                throw DaykitError(code: "UNEXPECTED_ARGUMENT", exitCode: .usageError, message: "Unexpected argument for 'briefing': \(positionals[1]).")
            }
            let opts = try OptionBag(flagPairs, allowed: ["days", "max-overdue", "calendar", "list", "include-notes", "max-notes-bytes"])
            let days = try opts.intOptional("days", default: 1)
            guard (1...14).contains(days) else {
                throw DaykitError(code: "INVALID_ARGUMENT", exitCode: .usageError, message: "--days must be between 1 and 14.")
            }
            let maxOverdue = try opts.intOptional("max-overdue", default: 25)
            guard maxOverdue >= 0 else {
                throw DaykitError(code: "INVALID_ARGUMENT", exitCode: .usageError, message: "--max-overdue must be >= 0.")
            }
            let maxNotesBytes = try opts.intOptional("max-notes-bytes", default: 2048)
            guard maxNotesBytes >= 0 else {
                throw DaykitError(code: "INVALID_ARGUMENT", exitCode: .usageError, message: "--max-notes-bytes must be >= 0.")
            }
            return .briefing(
                days: days,
                maxOverdue: maxOverdue,
                calendarRefs: opts.many("calendar"),
                listRefs: opts.many("list"),
                includeNotes: opts.bool("include-notes"),
                maxNotesBytes: maxNotesBytes
            )

        case "cal":
            guard positionals.count >= 2 else {
                throw DaykitError(code: "MISSING_SUBCOMMAND", exitCode: .usageError, message: "Missing subcommand for 'cal'. Use calendars, today, week, list, add, update, or delete.")
            }
            return try parseCalCommand(sub: positionals[1], extraPositionals: Array(positionals.dropFirst(2)), flagPairs: flagPairs)

        case "rem":
            guard positionals.count >= 2 else {
                throw DaykitError(code: "MISSING_SUBCOMMAND", exitCode: .usageError, message: "Missing subcommand for 'rem'. Use lists, list, overdue, today, add, update, done, or delete.")
            }
            return try parseRemCommand(sub: positionals[1], extraPositionals: Array(positionals.dropFirst(2)), flagPairs: flagPairs)

        default:
            throw DaykitError(
                code: "UNKNOWN_COMMAND",
                exitCode: .usageError,
                message: "Unknown command '\(root)'. Run 'daykit --help' for usage."
            )
        }
    }

    private static func parseCalCommand(sub: String, extraPositionals: [String], flagPairs: [(name: String, value: String?)]) throws -> ParsedCommand {
        guard extraPositionals.isEmpty else {
            throw DaykitError(code: "UNEXPECTED_ARGUMENT", exitCode: .usageError, message: "Unexpected argument for 'cal \(sub)': \(extraPositionals[0]).")
        }
        switch sub {
        case "calendars":
            _ = try OptionBag(flagPairs, allowed: [])
            return .calCalendars

        case "today":
            let opts = try OptionBag(flagPairs, allowed: ["calendar", "max-notes-bytes"])
            let maxBytes = try opts.nonNegativeInt("max-notes-bytes", default: 2048)
            return .calToday(calendarRefs: opts.many("calendar"), maxNotesBytes: maxBytes)

        case "week":
            let opts = try OptionBag(flagPairs, allowed: ["calendar", "max-notes-bytes"])
            let maxBytes = try opts.nonNegativeInt("max-notes-bytes", default: 2048)
            return .calWeek(calendarRefs: opts.many("calendar"), maxNotesBytes: maxBytes)

        case "list":
            let opts = try OptionBag(flagPairs, allowed: ["from", "to", "calendar", "max-notes-bytes"])
            let from = try opts.singleOptional("from")
            let to = try opts.singleOptional("to")
            let maxBytes = try opts.nonNegativeInt("max-notes-bytes", default: 2048)
            return .calList(from: from, to: to, calendarRefs: opts.many("calendar"), maxNotesBytes: maxBytes)

        case "add":
            let opts = try OptionBag(
                flagPairs,
                allowed: ["title", "start", "end", "duration", "all-day", "calendar", "location", "notes", "url", "alarm", "dry-run"]
            )
            let title = try opts.singleRequired("title")
            let start = try opts.singleRequired("start")
            let end = try opts.singleOptional("end")
            let duration = try opts.singleOptional("duration")
            if end != nil && duration != nil {
                throw DaykitError(code: "CONFLICTING_FLAGS", exitCode: .usageError, message: "Cannot specify both --end and --duration.")
            }
            return .calAdd(
                title: title,
                start: start,
                end: end,
                duration: duration,
                allDay: opts.bool("all-day"),
                calendarRef: try opts.singleOptional("calendar"),
                location: try opts.singleOptional("location"),
                notes: try opts.singleOptional("notes"),
                url: try opts.singleOptional("url"),
                alarms: opts.many("alarm"),
                dryRun: opts.bool("dry-run")
            )

        case "update":
            let opts = try OptionBag(
                flagPairs,
                allowed: [
                    "id", "title", "start", "end", "duration", "all-day", "no-all-day",
                    "calendar", "location", "clear-location", "notes", "clear-notes",
                    "url", "clear-url", "alarm", "clear-alarms", "span", "dry-run", "yes"
                ]
            )
            let id = try opts.singleRequired("id")
            let title = try opts.singleNonEmptyOptional("title")
            let start = try opts.singleOptional("start")
            let end = try opts.singleOptional("end")
            let duration = try opts.singleOptional("duration")
            if end != nil && duration != nil {
                throw DaykitError(code: "CONFLICTING_FLAGS", exitCode: .usageError, message: "Cannot specify both --end and --duration.")
            }
            let setAllDay = opts.bool("all-day")
            let clearAllDay = opts.bool("no-all-day")
            if setAllDay && clearAllDay {
                throw DaykitError(code: "CONFLICTING_FLAGS", exitCode: .usageError, message: "Cannot specify both --all-day and --no-all-day.")
            }
            let allDay: Bool? = setAllDay ? true : (clearAllDay ? false : nil)
            let calendarRef = try opts.singleOptional("calendar")
            let locationPatch = try opts.singlePatch("location", clearFlag: "clear-location")
            let notesPatch = try opts.singlePatch("notes", clearFlag: "clear-notes")
            let urlPatch = try opts.singlePatch("url", clearFlag: "clear-url")
            let alarmsPatch = try opts.manyPatch("alarm", clearFlag: "clear-alarms")
            let span = try parseSpan(opts)

            let hasAnyChange = title != nil || start != nil || end != nil || duration != nil || allDay != nil ||
                calendarRef != nil || locationPatch.isMutating || notesPatch.isMutating ||
                urlPatch.isMutating || alarmsPatch.isMutating
            guard hasAnyChange else {
                throw DaykitError(code: "NO_CHANGES", exitCode: .usageError, message: "No update fields specified for 'cal update'.")
            }

            return .calUpdate(
                id: id,
                title: title,
                start: start,
                end: end,
                duration: duration,
                allDay: allDay,
                calendarRef: calendarRef,
                location: locationPatch,
                notes: notesPatch,
                url: urlPatch,
                alarms: alarmsPatch,
                span: span,
                dryRun: opts.bool("dry-run"),
                yes: opts.bool("yes")
            )

        case "delete":
            let opts = try OptionBag(flagPairs, allowed: ["id", "span", "dry-run", "yes"])
            let id = try opts.singleRequired("id")
            let span = try parseSpan(opts)
            return .calDelete(id: id, span: span, dryRun: opts.bool("dry-run"), yes: opts.bool("yes"))

        default:
            throw DaykitError(code: "UNKNOWN_SUBCOMMAND", exitCode: .usageError, message: "Unknown 'cal' subcommand '\(sub)'.")
        }
    }

    private static func parseRemCommand(sub: String, extraPositionals: [String], flagPairs: [(name: String, value: String?)]) throws -> ParsedCommand {
        guard extraPositionals.isEmpty else {
            throw DaykitError(code: "UNEXPECTED_ARGUMENT", exitCode: .usageError, message: "Unexpected argument for 'rem \(sub)': \(extraPositionals[0]).")
        }
        switch sub {
        case "lists":
            _ = try OptionBag(flagPairs, allowed: [])
            return .remLists

        case "list":
            let opts = try OptionBag(flagPairs, allowed: ["list", "completed", "all", "max-notes-bytes"])
            let completed = opts.bool("completed")
            let all = opts.bool("all")
            if completed && all {
                throw DaykitError(code: "CONFLICTING_FLAGS", exitCode: .usageError, message: "Cannot combine --completed and --all.")
            }
            let filter: ReminderCompletionFilter = all ? .all : (completed ? .completed : .open)
            let maxBytes = try opts.nonNegativeInt("max-notes-bytes", default: 2048)
            return .remList(listRefs: opts.many("list"), filter: filter, maxNotesBytes: maxBytes)

        case "overdue":
            let opts = try OptionBag(flagPairs, allowed: ["list", "max-notes-bytes"])
            let maxBytes = try opts.nonNegativeInt("max-notes-bytes", default: 2048)
            return .remOverdue(listRefs: opts.many("list"), maxNotesBytes: maxBytes)

        case "today":
            let opts = try OptionBag(flagPairs, allowed: ["list", "max-notes-bytes"])
            let maxBytes = try opts.nonNegativeInt("max-notes-bytes", default: 2048)
            return .remToday(listRefs: opts.many("list"), maxNotesBytes: maxBytes)

        case "add":
            let opts = try OptionBag(flagPairs, allowed: ["title", "list", "due", "priority", "notes", "url", "dry-run"])
            let title = try opts.singleRequired("title")
            let priorityStr = try opts.singleOptional("priority") ?? "none"
            guard let priority = PriorityLevel(rawValue: priorityStr.lowercased()) else {
                throw DaykitError(code: "INVALID_ARGUMENT", exitCode: .usageError, message: "Invalid --priority '\(priorityStr)'. Use none, low, medium, or high.")
            }
            return .remAdd(
                title: title,
                listRef: try opts.singleOptional("list"),
                due: try opts.singleOptional("due"),
                priority: priority,
                notes: try opts.singleOptional("notes"),
                url: try opts.singleOptional("url"),
                dryRun: opts.bool("dry-run")
            )

        case "update":
            let opts = try OptionBag(
                flagPairs,
                allowed: [
                    "id", "title", "list", "due", "clear-due", "priority",
                    "notes", "clear-notes", "url", "clear-url", "dry-run"
                ]
            )
            let id = try opts.singleRequired("id")
            let title = try opts.singleNonEmptyOptional("title")
            let listRef = try opts.singleOptional("list")
            let duePatch = try opts.singlePatch("due", clearFlag: "clear-due")
            let priority: PriorityLevel?
            if let priorityStr = try opts.singleOptional("priority") {
                guard let parsed = PriorityLevel(rawValue: priorityStr.lowercased()) else {
                    throw DaykitError(code: "INVALID_ARGUMENT", exitCode: .usageError, message: "Invalid --priority '\(priorityStr)'. Use none, low, medium, or high.")
                }
                priority = parsed
            } else {
                priority = nil
            }
            let notesPatch = try opts.singlePatch("notes", clearFlag: "clear-notes")
            let urlPatch = try opts.singlePatch("url", clearFlag: "clear-url")

            let hasAnyChange = title != nil || listRef != nil || duePatch.isMutating ||
                priority != nil || notesPatch.isMutating || urlPatch.isMutating
            guard hasAnyChange else {
                throw DaykitError(code: "NO_CHANGES", exitCode: .usageError, message: "No update fields specified for 'rem update'.")
            }

            return .remUpdate(
                id: id,
                title: title,
                listRef: listRef,
                due: duePatch,
                priority: priority,
                notes: notesPatch,
                url: urlPatch,
                dryRun: opts.bool("dry-run")
            )

        case "done":
            let opts = try OptionBag(flagPairs, allowed: ["id", "dry-run"])
            let id = try opts.singleRequired("id")
            return .remDone(id: id, dryRun: opts.bool("dry-run"))

        case "delete":
            let opts = try OptionBag(flagPairs, allowed: ["id", "dry-run", "yes"])
            let id = try opts.singleRequired("id")
            return .remDelete(id: id, dryRun: opts.bool("dry-run"), yes: opts.bool("yes"))

        default:
            throw DaykitError(code: "UNKNOWN_SUBCOMMAND", exitCode: .usageError, message: "Unknown 'rem' subcommand '\(sub)'.")
        }
    }

    private static func parseSpan(_ opts: OptionBag) throws -> EventSpan? {
        guard let raw = try opts.singleOptional("span") else { return nil }
        guard let span = EventSpan(rawValue: raw.lowercased()) else {
            throw DaykitError(code: "INVALID_ARGUMENT", exitCode: .usageError, message: "Invalid --span '\(raw)'. Use this or future.")
        }
        return span
    }
}

private struct OptionBag {
    private var values: [String: [String]] = [:]
    private var bools: Set<String> = []

    init(_ pairs: [(name: String, value: String?)], allowed: Set<String>) throws {
        for (name, value) in pairs {
            guard allowed.contains(name) else {
                throw DaykitError(
                    code: "UNKNOWN_FLAG",
                    exitCode: .usageError,
                    message: "Unknown or unsupported flag --\(name) for this subcommand."
                )
            }
            if let value {
                values[name, default: []].append(value)
            } else {
                bools.insert(name)
            }
        }
    }

    func bool(_ name: String) -> Bool {
        bools.contains(name)
    }

    func many(_ name: String) -> [String] {
        values[name] ?? []
    }

    func singleOptional(_ name: String) throws -> String? {
        let list = values[name] ?? []
        if list.count > 1 {
            throw DaykitError(code: "DUPLICATE_FLAG", exitCode: .usageError, message: "Flag --\(name) cannot be provided multiple times.")
        }
        return list.first
    }

    func singleNonEmptyOptional(_ name: String) throws -> String? {
        guard let value = try singleOptional(name) else { return nil }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DaykitError(code: "INVALID_ARGUMENT", exitCode: .usageError, message: "Flag --\(name) cannot be empty.")
        }
        return value
    }

    func singleRequired(_ name: String) throws -> String {
        guard let value = try singleOptional(name), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DaykitError(code: "MISSING_FLAG", exitCode: .usageError, message: "Missing required flag --\(name).")
        }
        return value
    }

    func singlePatch(_ name: String, clearFlag: String) throws -> FieldPatch<String> {
        let val = try singleOptional(name)
        let shouldClear = bool(clearFlag)
        if val != nil && shouldClear {
            throw DaykitError(code: "CONFLICTING_FLAGS", exitCode: .usageError, message: "Cannot specify both --\(name) and --\(clearFlag).")
        }
        if shouldClear { return .clear }
        if let val { return .set(val) }
        return .unchanged
    }

    func manyPatch(_ name: String, clearFlag: String) throws -> FieldPatch<[String]> {
        let vals = many(name)
        let shouldClear = bool(clearFlag)
        if !vals.isEmpty && shouldClear {
            throw DaykitError(code: "CONFLICTING_FLAGS", exitCode: .usageError, message: "Cannot specify both --\(name) and --\(clearFlag).")
        }
        if shouldClear { return .clear }
        if !vals.isEmpty { return .set(vals) }
        return .unchanged
    }

    func intOptional(_ name: String, default defaultValue: Int) throws -> Int {
        guard let raw = try singleOptional(name) else { return defaultValue }
        guard let intVal = Int(raw) else {
            throw DaykitError(code: "INVALID_INTEGER", exitCode: .usageError, message: "Flag --\(name) expects an integer, got '\(raw)'.")
        }
        return intVal
    }

    func nonNegativeInt(_ name: String, default defaultValue: Int) throws -> Int {
        let value = try intOptional(name, default: defaultValue)
        guard value >= 0 else {
            throw DaykitError(code: "INVALID_ARGUMENT", exitCode: .usageError, message: "--\(name) must be >= 0.")
        }
        return value
    }
}
