import Darwin
import DaykitCore
import Foundation

@main
enum DaykitMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let isTTY = isatty(STDOUT_FILENO) == 1
        let policy = RuntimePolicy.fromEnvironment(ProcessInfo.processInfo.environment)
        let auditWriter: AuditLogWriter
        if policy.auditLogEnabled, let path = policy.auditLogPath, !path.isEmpty {
            auditWriter = FileAuditLogWriter(path: path)
        } else {
            auditWriter = NoopAuditLogWriter()
        }
        let store = LiveEventKitStore()
        let app = DaykitApp(store: store, policy: policy, auditWriter: auditWriter, isTTY: isTTY)
        let output = await app.run(arguments: args)

        if !output.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(output.stdout.utf8))
        }
        if !output.stderr.isEmpty {
            FileHandle.standardError.write(Data(output.stderr.utf8))
        }
        Darwin.exit(output.exitCode.rawValue)
    }
}
