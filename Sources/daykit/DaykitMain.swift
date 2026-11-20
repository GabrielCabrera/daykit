import Darwin
import DaykitCore
import Foundation

@main
enum DaykitMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let isTTY = isatty(STDOUT_FILENO) == 1
        let policy = RuntimePolicy.fromEnvironment(ProcessInfo.processInfo.environment)
        let store = LiveEventKitStore()
        let app = DaykitApp(store: store, policy: policy, isTTY: isTTY)
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
