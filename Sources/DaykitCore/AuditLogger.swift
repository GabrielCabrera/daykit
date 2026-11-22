import Darwin
import Foundation

public struct AuditEntry: Sendable, Codable, Equatable {
    public let timestamp: String
    public let action: String
    public let targetId: String
    public let span: String?
    public let beforeEvent: EventRecord?
    public let beforeReminder: ReminderRecord?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case action
        case targetId = "target_id"
        case span
        case beforeEvent = "before_event"
        case beforeReminder = "before_reminder"
    }

    public init(
        timestamp: String,
        action: String,
        targetId: String,
        span: String? = nil,
        beforeEvent: EventRecord? = nil,
        beforeReminder: ReminderRecord? = nil
    ) {
        self.timestamp = timestamp
        self.action = action
        self.targetId = targetId
        self.span = span
        self.beforeEvent = beforeEvent
        self.beforeReminder = beforeReminder
    }
}

public protocol AuditLogWriter: Sendable {
    func record(_ entry: AuditEntry) throws
}

public struct NoopAuditLogWriter: AuditLogWriter {
    public init() {}

    public func record(_ entry: AuditEntry) throws {}
}

public final class FileAuditLogWriter: AuditLogWriter, @unchecked Sendable {
    public let path: String
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
    }

    public func record(_ entry: AuditEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(entry) + Data("\n".utf8)

        let fileURL = URL(fileURLWithPath: path)
        let parentURL = fileURL.deletingLastPathComponent()

        try lock.withLock {
            try FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var parentStat = Darwin.stat()
            guard Darwin.lstat(parentURL.path, &parentStat) == 0 else {
                let errText = String(cString: strerror(errno))
                throw DaykitError(
                    code: "AUDIT_LOG_ERROR",
                    exitCode: .runtimeError,
                    message: "Cannot inspect audit log directory '\(parentURL.path)': \(errText)"
                )
            }
            guard (parentStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw DaykitError(
                    code: "AUDIT_LOG_ERROR",
                    exitCode: .runtimeError,
                    message: "Audit log parent '\(parentURL.path)' is not a regular directory."
                )
            }
            if parentURL.lastPathComponent == "daykit" && parentStat.st_uid == Darwin.getuid() {
                _ = Darwin.chmod(parentURL.path, 0o700)
            }

            let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard fd >= 0 else {
                let errText = String(cString: strerror(errno))
                throw DaykitError(
                    code: "AUDIT_LOG_ERROR",
                    exitCode: .runtimeError,
                    message: "Cannot open audit log '\(path)': \(errText)"
                )
            }
            defer { _ = Darwin.close(fd) }

            var fileStat = Darwin.stat()
            guard Darwin.fstat(fd, &fileStat) == 0 else {
                let errText = String(cString: strerror(errno))
                throw DaykitError(
                    code: "AUDIT_LOG_ERROR",
                    exitCode: .runtimeError,
                    message: "Cannot inspect audit log '\(path)': \(errText)"
                )
            }
            guard (fileStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  fileStat.st_uid == Darwin.getuid()
            else {
                throw DaykitError(
                    code: "AUDIT_LOG_ERROR",
                    exitCode: .runtimeError,
                    message: "Audit log '\(path)' must be a regular file owned by the current user."
                )
            }

            if Darwin.fchmod(fd, 0o600) != 0 {
                let errText = String(cString: strerror(errno))
                throw DaykitError(
                    code: "AUDIT_LOG_ERROR",
                    exitCode: .runtimeError,
                    message: "Cannot enforce 0600 permissions on audit log '\(path)': \(errText)"
                )
            }

            try payload.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var bytesWritten = 0
                while bytesWritten < payload.count {
                    let written = Darwin.write(fd, base.advanced(by: bytesWritten), payload.count - bytesWritten)
                    if written < 0 {
                        if errno == EINTR { continue }
                        let errText = String(cString: strerror(errno))
                        throw DaykitError(
                            code: "AUDIT_LOG_ERROR",
                            exitCode: .runtimeError,
                            message: "Failed writing audit log '\(path)': \(errText)"
                        )
                    }
                    bytesWritten += written
                }
            }
        }
    }
}
