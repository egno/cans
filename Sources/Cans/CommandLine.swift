import AppKit
import Foundation

/// Started with a command (`Cans status`), the binary is the command line tool: it hands
/// the command to the running app and prints the answer. Started any other way, it's the app.
@main @MainActor
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ScriptParser.isCommandLine(arguments) {
            exit(CommandLineClient.run(arguments))
        }
        CansApp.main()
    }
}

/// How the command line tool and the app talk: distributed notifications, which need no
/// bundle, entitlement or open port. The command's ID is the notification's object, so a
/// tool only hears its own answers.
enum ScriptChannel {
    static let command = Notification.Name("io.github.egno.cans.command")
    static let reply = Notification.Name("io.github.egno.cans.reply")

    enum Key {
        static let arguments = "arguments"
        /// "received" at once, so the tool knows Cans is running; then "done".
        static let phase = "phase"
        static let ok = "ok"
        static let output = "output"
    }
}

/// The app's end: runs each command it hears and posts the result back.
@MainActor
final class ScriptServer: NSObject {
    private let runner: ScriptRunner

    init(manager: HeadphonesManager) {
        runner = ScriptRunner(manager: manager)
        super.init()
        // A menu bar app is rarely active, and AppKit holds distributed notifications
        // back from inactive apps unless asked not to.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: ScriptChannel.command, object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    func open(_ url: URL) {
        runner.open(url)
    }

    @objc private nonisolated func received(_ note: Notification) {
        guard let id = note.object as? String,
              let arguments = note.userInfo?[ScriptChannel.Key.arguments] as? [String] else { return }
        MainActor.assumeIsolated {
            post(id, [ScriptChannel.Key.phase: "received"])
            Task {
                let result = await runner.run(arguments)
                post(id, [ScriptChannel.Key.phase: "done", ScriptChannel.Key.ok: result.ok,
                          ScriptChannel.Key.output: result.output])
            }
        }
    }

    private func post(_ id: String, _ info: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(
            ScriptChannel.reply, object: id, userInfo: info, deliverImmediately: true)
    }
}

/// The tool's end.
@MainActor
enum CommandLineClient {
    private final class Inbox: NSObject {
        var received = false
        var result: ScriptResult?

        @objc func reply(_ note: Notification) {
            received = true
            guard note.userInfo?[ScriptChannel.Key.phase] as? String == "done" else { return }
            result = ScriptResult(ok: note.userInfo?[ScriptChannel.Key.ok] as? Bool ?? false,
                                  output: note.userInfo?[ScriptChannel.Key.output] as? String ?? "")
        }
    }

    /// Returns the exit status: 0 done, 1 failed, 64 for a command that makes no sense,
    /// 69 when Cans isn't there to ask.
    static func run(_ arguments: [String]) -> Int32 {
        // Mistakes and help don't need the app.
        do {
            if try ScriptParser.parse(arguments).command == .help {
                print(ScriptParser.usage)
                return 0
            }
        } catch {
            printError("\(error.message)\n\n\(ScriptParser.usage)")
            return 64
        }

        let id = UUID().uuidString
        let inbox = Inbox()
        let center = DistributedNotificationCenter.default()
        center.addObserver(inbox, selector: #selector(Inbox.reply(_:)), name: ScriptChannel.reply, object: id,
                           suspensionBehavior: .deliverImmediately)
        center.postNotificationName(ScriptChannel.command, object: id,
                                    userInfo: [ScriptChannel.Key.arguments: arguments], deliverImmediately: true)

        let start = ContinuousClock.now
        // A connect can take the headphones 20 s to give up on; the app answers before this.
        while inbox.result == nil {
            let waited = ContinuousClock.now - start
            if !inbox.received, waited > .seconds(2) {
                printError("Cans isn't running, or is a version without scripting. Open Cans.app and try again.")
                return 69
            }
            if waited > .seconds(60) {
                printError("Cans didn't answer")
                return 1
            }
            if CFRunLoopRunInMode(.defaultMode, 0.05, true) == .finished { Thread.sleep(forTimeInterval: 0.02) }
        }
        guard let result = inbox.result, result.ok else {
            printError(inbox.result?.output ?? "")
            return 1
        }
        if !result.output.isEmpty { print(result.output) }
        return 0
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
