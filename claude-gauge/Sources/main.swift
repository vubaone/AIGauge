import Foundation

let semaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var exitCode: Int32 = 0

Task {
    exitCode = await CLI.run(args: Array(CommandLine.arguments.dropFirst()))
    semaphore.signal()
}

semaphore.wait()
exit(exitCode)
