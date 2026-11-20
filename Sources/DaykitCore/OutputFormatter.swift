import Foundation

public struct SuccessEnvelope<T: Encodable>: Encodable {
    public let schemaVersion: Int
    public let ok: Bool
    public let command: String
    public let timezone: String
    public let generatedAt: String
    public let data: T

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ok
        case command
        case timezone
        case generatedAt = "generated_at"
        case data
    }
}

public struct ErrorBody: Encodable {
    public let code: String
    public let exitCode: Int32
    public let message: String
    public let hint: String?
    public let details: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case code
        case exitCode = "exit_code"
        case message
        case hint
        case details
    }
}

public struct ErrorEnvelope: Encodable {
    public let schemaVersion: Int
    public let ok: Bool
    public let error: ErrorBody

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ok
        case error
    }
}

public enum OutputFormatting {
    public static func stripControlAndANSI(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar.value == 0x1B {
                i += 1
                if i < scalars.count {
                    let next = scalars[i].value
                    if next == 0x5B { // CSI: ESC [ ... final byte 0x40..0x7E
                        i += 1
                        while i < scalars.count {
                            let code = scalars[i].value
                            i += 1
                            if (0x40...0x7E).contains(code) { break }
                        }
                        continue
                    } else if next == 0x5D { // OSC: ESC ] ... BEL or ST (ESC \)
                        i += 1
                        while i < scalars.count {
                            let code = scalars[i].value
                            if code == 0x07 {
                                i += 1
                                break
                            }
                            if code == 0x1B && i + 1 < scalars.count && scalars[i + 1].value == 0x5C {
                                i += 2
                                break
                            }
                            i += 1
                        }
                        continue
                    }
                }
                continue
            }

            let val = scalar.value
            // Preserve \n (0x0A) and \t (0x09); strip other C0 (0x00..0x1F, 0x7F) and C1 (0x80..0x9F) control characters.
            if val == 0x09 || val == 0x0A || (val >= 0x20 && val != 0x7F && !(0x80...0x9F).contains(val)) {
                result.unicodeScalars.append(scalar)
            }
            i += 1
        }
        return result
    }

    public static func processNotes(_ notes: String?, maxBytes: Int, include: Bool) -> (value: String?, hasNotes: Bool, truncated: Bool) {
        guard let notes, !notes.isEmpty else {
            return (nil, false, false)
        }
        guard include else {
            return (nil, true, false)
        }
        if maxBytes == 0 {
            return (notes, true, false)
        }
        let utf8 = Array(notes.utf8)
        if utf8.count <= maxBytes {
            return (notes, true, false)
        }
        var currentBytes = 0
        var prefix = ""
        for scalar in notes.unicodeScalars {
            let scalarLen = scalar.utf8.count
            if currentBytes + scalarLen > maxBytes {
                break
            }
            prefix.unicodeScalars.append(scalar)
            currentBytes += scalarLen
        }
        return (prefix, true, true)
    }

    public static func encodeSuccess<T: Encodable>(
        command: String,
        data: T,
        now: Date,
        timeZone: TimeZone,
        pretty: Bool = false
    ) throws -> String {
        let envelope = SuccessEnvelope(
            schemaVersion: DaykitVersion.schemaVersion,
            ok: true,
            command: command,
            timezone: timeZone.identifier,
            generatedAt: DateParsing.formatRFC3339(now, timeZone: timeZone),
            data: data
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(envelope)
        return String(decoding: encoded, as: UTF8.self) + "\n"
    }

    public static func encodeError(_ error: DaykitError, pretty: Bool = false) -> String {
        let envelope = ErrorEnvelope(
            schemaVersion: DaykitVersion.schemaVersion,
            ok: false,
            error: ErrorBody(
                code: error.code,
                exitCode: error.exitCode.rawValue,
                message: error.message,
                hint: error.hint,
                details: error.details
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        if let encoded = try? encoder.encode(envelope) {
            return String(decoding: encoded, as: UTF8.self) + "\n"
        }
        return "{\"schema_version\":1,\"ok\":false,\"error\":{\"code\":\"INTERNAL_ERROR\",\"exit_code\":1,\"message\":\"Failed to serialize error.\"}}\n"
    }

    public static func renderPlainCalendars(_ calendars: [CalendarSummary]) -> String {
        if calendars.isEmpty { return "No calendars found.\n" }
        return calendars.map { cal in
            let flags = [
                cal.isDefault ? "default" : nil,
                cal.writable ? "writable" : "read-only"
            ].compactMap { $0 }.joined(separator: ", ")
            return "\(stripControlAndANSI(cal.title)) [\(stripControlAndANSI(cal.sourceName))] (\(flags))  id=\(cal.id)"
        }.joined(separator: "\n") + "\n"
    }

    public static func renderPlainEvents(_ events: [EventRecord]) -> String {
        if events.isEmpty { return "No events found.\n" }
        return events.map { event in
            let span = event.allDay ? "\(event.startAt) .. \(event.endAt) [all-day]" : "\(event.startAt) -> \(event.endAt)"
            var line = "\(span) | \(stripControlAndANSI(event.title)) [\(stripControlAndANSI(event.calendarTitle))]  id=\(event.instanceId)"
            if let loc = event.location, !loc.isEmpty {
                line += " @ \(stripControlAndANSI(loc))"
            }
            return line
        }.joined(separator: "\n") + "\n"
    }

    public static func renderPlainReminderLists(_ lists: [ReminderListSummary]) -> String {
        if lists.isEmpty { return "No reminder lists found.\n" }
        return lists.map { list in
            let flags = [
                list.isDefault ? "default" : nil,
                list.writable ? "writable" : "read-only"
            ].compactMap { $0 }.joined(separator: ", ")
            return "\(stripControlAndANSI(list.title)) [\(stripControlAndANSI(list.sourceName))] (\(flags))  id=\(list.id)"
        }.joined(separator: "\n") + "\n"
    }

    public static func renderPlainReminders(_ reminders: [ReminderRecord]) -> String {
        if reminders.isEmpty { return "No reminders found.\n" }
        return reminders.map { rem in
            let mark = rem.completed ? "[x]" : "[ ]"
            let due = rem.dueAt ?? "no-due"
            let prio = rem.priority == .none ? "" : " !\(rem.priority.rawValue)"
            return "\(mark) \(stripControlAndANSI(rem.title)) (\(due)\(prio)) [\(stripControlAndANSI(rem.listTitle))]  id=\(rem.id)"
        }.joined(separator: "\n") + "\n"
    }

    public static func renderPlainBriefing(_ payload: BriefingPayload) -> String {
        var lines: [String] = []
        lines.append("Briefing (\(payload.windowFrom) -> \(payload.windowTo))")
        if !payload.warnings.isEmpty {
            lines.append("Warnings: " + payload.warnings.map(stripControlAndANSI).joined(separator: "; "))
        }
        lines.append("\nOverdue reminders (\(payload.overdueReminders.count)/\(payload.overdueTotal)):")
        lines.append(contentsOf: payload.overdueReminders.isEmpty ? ["  (none)"] : payload.overdueReminders.map { "  - \(stripControlAndANSI($0.title)) (\($0.dueAt ?? ""))  id=\($0.id)" })
        lines.append("\nToday reminders (\(payload.todayReminders.count)):")
        lines.append(contentsOf: payload.todayReminders.isEmpty ? ["  (none)"] : payload.todayReminders.map { "  - \(stripControlAndANSI($0.title)) (\($0.dueAt ?? ""))  id=\($0.id)" })
        lines.append("\nToday events (\(payload.todayEvents.count)):")
        lines.append(contentsOf: payload.todayEvents.isEmpty ? ["  (none)"] : payload.todayEvents.map { "  - \($0.startAt) \(stripControlAndANSI($0.title)) [\($0.calendarTitle)]" })
        if payload.days > 1 {
            lines.append("\nUpcoming events (\(payload.upcomingEvents.count)):")
            lines.append(contentsOf: payload.upcomingEvents.isEmpty ? ["  (none)"] : payload.upcomingEvents.map { "  - \($0.startAt) \(stripControlAndANSI($0.title)) [\($0.calendarTitle)]" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func renderPlainDoctor(_ doctor: DoctorPayload) -> String {
        var lines: [String] = [
            "daykit \(doctor.daykitVersion) (\(doctor.arch), macOS \(doctor.macosVersion))",
            "Session: ssh=\(doctor.session.isSSH), aqua_gui=\(doctor.session.hasAquaGUI)",
            "Permissions: calendars=\(doctor.permissions.calendars.rawValue), reminders=\(doctor.permissions.reminders.rawValue)",
            "Policy: read_only=\(doctor.policy.readOnly), writable_calendars=\(doctor.policy.writableCalendars.joined(separator: ",")), writable_lists=\(doctor.policy.writableLists.joined(separator: ","))"
        ]
        if let defCal = doctor.defaultCalendar {
            lines.append("Default calendar: \(stripControlAndANSI(defCal.title)) [\(defCal.sourceName)] (\(defCal.id))")
        }
        if let defList = doctor.defaultReminderList {
            lines.append("Default reminder list: \(stripControlAndANSI(defList.title)) [\(defList.sourceName)] (\(defList.id))")
        }
        if !doctor.sources.isEmpty {
            lines.append("Sources: " + doctor.sources.map(stripControlAndANSI).joined(separator: ", "))
        }
        if !doctor.notes.isEmpty {
            lines.append("Notes:")
            for note in doctor.notes {
                lines.append("  - \(note)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
