import AppKit

func refuse(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4,
      let pid = Int32(CommandLine.arguments[1]), pid > 0 else {
    refuse("Usage: terminate-local.swift PID EXECUTABLE START")
}
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
guard let application = NSRunningApplication(processIdentifier: pid),
      application.executableURL?.resolvingSymlinksInPath() == expectedExecutable else {
    refuse("Application identity changed; no termination requested.")
}
let query = Process()
let output = Pipe()
query.executableURL = URL(fileURLWithPath: "/bin/ps")
query.arguments = ["-p", String(pid), "-o", "lstart="]
query.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
query.standardOutput = output
query.standardError = FileHandle.nullDevice
do { try query.run() } catch { refuse("Cannot verify application start time.") }
let captured = output.fileHandleForReading.readDataToEndOfFile()
query.waitUntilExit()
guard query.terminationStatus == 0,
      String(decoding: captured, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == CommandLine.arguments[3] else {
    refuse("Application start time changed; no termination requested.")
}
// Ask the application to quit normally. Its delegate can save drafts, close
// private clients, defer termination, or refuse it. Never force termination.
guard application.terminate() else { refuse("Application refused the native quit request.") }
