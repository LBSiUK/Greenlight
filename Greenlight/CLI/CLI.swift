import Foundation

/// `greenlight`: the command Claude runs. Lives in the app binary; ~/.local/bin/greenlight links to it.
enum CLI {
    static let commands: Set<String> = ["new", "add", "plan", "set", "list", "show", "folder", "wait", "help", "--help", "-h"]

    /// True when the binary was started as the command rather than as the app.
    static func wanted(_ arguments: [String]) -> Bool {
        let invokedAs = ((arguments.first ?? "") as NSString).lastPathComponent
        if invokedAs == "greenlight" { return true }
        return arguments.count > 1 && commands.contains(arguments[1])
    }

    static func run(_ arguments: [String], ledger: Ledger = Ledger()) -> Int32 {
        var args = Array(arguments.dropFirst())
        let command = args.isEmpty ? "list" : args.removeFirst()
        do {
            let options = try Options(args)
            switch command {
            case "new": return try new(options, ledger)
            case "add": return try add(options, ledger)
            case "plan": return try plan(options, ledger)
            case "set": return try set(options, ledger)
            case "list": return list(options, ledger)
            case "show": return try show(options, ledger)
            case "folder": return try folder(options, ledger)
            case "wait": return wait(options, ledger)
            case "help", "--help", "-h": print(usage); return 0
            default: throw Problem("Unknown command '\(command)'.\n\n\(usage)")
            }
        } catch {
            FileHandle.standardError.write(Data("greenlight: \(error)\n".utf8))
            return 2
        }
    }

    static let usage = """
    greenlight: the changes listed in the Greenlight app

      greenlight new "<batch title>" [--project PATH]   start a batch of changes for a git repo
      greenlight add <batch> "<title>" [--summary TEXT] [--visual]
                                                       add a change to a batch (stage: planning)
      greenlight plan <batch> <artifact url>           record the plan link; put the batch up for review
      greenlight set <id> [--stage STAGE] [--qa URL] [--pr URL] [--branch NAME]
                          [--title TEXT] [--summary TEXT]
      greenlight list [--done] [--all-projects] [--json] open changes in this repo
      greenlight show <id>                             one change as JSON, with its plan link
      greenlight folder <batch>                        where the batch's plan page and pictures go
                                                       (.greenlight/<batch> in the repo, ignored by git)
      greenlight wait [--all-projects] [--timeout SECONDS]
                                                       block until the user makes a call in the app,
                                                       then print what to do. Run it in the background.
                                                       Exit 0: calls to pick up. 3: nothing open.
                                                       4: --timeout passed. 5: already listening.

    Stages: planning review redlit replanning greenlit building qa denied fixing accepted shipping done dropped
    The user moves review -> greenlit/redlit and qa -> accepted/denied in the app; Claude moves the rest.
    --project defaults to the git repository of the current folder.
    """

    // MARK: Commands

    private static func new(_ options: Options, _ ledger: Ledger) throws -> Int32 {
        let title = try options.positional(0, "Give the batch a title: greenlight new \"Header tweaks\"")
        let project = try projectRoot(options.value("--project"))
        let batch = try ledger.newBatch(title: title, project: project)
        print("Batch \(batch.id): \(batch.title)")
        print("Project: \(tilde(project))")
        print("Plan folder: \(ledger.planFolder(for: batch).path)")
        return 0
    }

    private static func add(_ options: Options, _ ledger: Ledger) throws -> Int32 {
        let batch = try options.number(0, "Say which batch: greenlight add 3 \"Darker footer\"")
        let title = try options.positional(1, "Give the change a title: greenlight add \(batch) \"Darker footer\"")
        let change = try ledger.addChange(batch: batch, title: title, summary: options.value("--summary") ?? "",
                                          visual: options.flag("--visual"))
        print("#\(change.id) \(change.title) (planning)")
        return 0
    }

    private static func plan(_ options: Options, _ ledger: Ledger) throws -> Int32 {
        let batch = try options.number(0, "Say which batch: greenlight plan 3 https://claude.ai/…")
        let url = try options.positional(1, "Give the plan link: greenlight plan \(batch) https://claude.ai/…")
        let moved = try ledger.publishPlan(batch: batch, url: url)
        print("Batch \(batch) plan: \(url)")
        print(moved.isEmpty ? "No changes were waiting on the plan." : "Up for review: " + moved.map { "#\($0.id)" }.joined(separator: ", "))
        return 0
    }

    private static func set(_ options: Options, _ ledger: Ledger) throws -> Int32 {
        let id = try options.number(0, "Say which change: greenlight set 14 --stage building")
        var stage: Stage?
        if let name = options.value("--stage") {
            guard let parsed = Stage(rawValue: name) else {
                throw Problem("Unknown stage '\(name)'. Stages: " + Stage.allCases.map(\.rawValue).joined(separator: " "))
            }
            stage = parsed
        }
        let change = try ledger.update(id, by: "claude") { change in
            if let stage { change.stage = stage }
            if let value = options.value("--qa") { change.qaURL = value.isEmpty ? nil : value }
            if let value = options.value("--pr") { change.prURL = value.isEmpty ? nil : value }
            if let value = options.value("--branch") { change.branch = value.isEmpty ? nil : value }
            if let value = options.value("--title") { change.title = value }
            if let value = options.value("--summary") { change.summary = value }
        }
        print(line(change))
        return 0
    }

    private static func list(_ options: Options, _ ledger: Ledger) -> Int32 {
        let project = options.flag("--all-projects") ? nil : try? projectRoot(options.value("--project"))
        let batches = Dictionary(uniqueKeysWithValues: ledger.batches().map { ($0.id, $0) })
        let changes = ledger.changes(inProject: project).filter { options.flag("--done") || !$0.stage.isFinished }
        if options.flag("--json") {
            print(json(changes.map { Shown(change: $0, batch: batches[$0.batch]) }))
            return 0
        }
        if changes.isEmpty {
            print(project.map { "Nothing open in \(tilde($0))." } ?? "Nothing open.")
            return 0
        }
        for change in changes {
            var row = line(change)
            if let batch = batches[change.batch] { row += "  [batch \(batch.id): \(batch.title)]" }
            print(row)
        }
        return 0
    }

    private static func show(_ options: Options, _ ledger: Ledger) throws -> Int32 {
        let id = try options.number(0, "Say which change: greenlight show 14")
        guard let change = ledger.change(id) else { throw LedgerError.noChange(id) }
        print(json(Shown(change: change, batch: ledger.batch(change.batch))))
        return 0
    }

    private static func folder(_ options: Options, _ ledger: Ledger) throws -> Int32 {
        let id = try options.number(0, "Say which batch: greenlight folder 3")
        guard let batch = ledger.batch(id) else { throw LedgerError.noBatch(id) }
        print(ledger.planFolder(for: batch).path)
        return 0
    }

    /// Blocks until a change in scope waits for Claude, prints those changes and exits 0. Exits 3
    /// when nothing is open (so there is nothing to wait for), 4 on --timeout, and 5 when another
    /// `greenlight wait` already listens to the same scope, so one call is never handled twice.
    private static func wait(_ options: Options, _ ledger: Ledger) -> Int32 {
        let project = options.flag("--all-projects") ? nil : try? projectRoot(options.value("--project"))
        let deadline = options.value("--timeout").flatMap(Double.init).map { Date().addingTimeInterval($0) }
        let pid = getpid()
        if let other = ledger.liveWaiters().first(where: { $0.project == project && $0.pid != pid }) {
            print("Already listening" + (project.map { " to \(tilde($0))" } ?? "") + " (greenlight wait, pid \(other.pid)). Nothing to do.")
            return 5
        }
        try? ledger.addWaiter(Waiter(pid: pid, project: project, started: Date()))
        WaiterCleanup.arm(file: ledger.waitersFolder.appendingPathComponent("\(pid).json").path)
        defer { ledger.removeWaiter(pid: pid) }

        while true {
            let open = ledger.changes(inProject: project).filter { !$0.stage.isFinished }
            if open.isEmpty {
                print(project.map { "Nothing open in \(tilde($0)), so nothing to wait for." } ?? "Nothing open.")
                return 3
            }
            let decided = open.filter(\.stage.waitsForClaude)
            if !decided.isEmpty {
                print("The user made a call in Greenlight" + (project.map { " (\(tilde($0)))" } ?? "") + ":")
                for change in decided {
                    print("#\(change.id) \(change.stage.rawValue): \(change.title). Next: \(change.stage.nextStep ?? "")")
                }
                print("Pick each one up (move it to its working stage) before running greenlight wait again.")
                return 0
            }
            if let deadline, Date() >= deadline {
                print("Still waiting on the user: " + open.filter(\.stage.waitsForUser).map { "#\($0.id)" }.joined(separator: ", "))
                return 4
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    // MARK: Helpers

    struct Problem: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Splits arguments into positionals, `--name value` options and bare flags.
    struct Options {
        static let takesValue: Set<String> = ["--project", "--summary", "--stage", "--qa", "--pr", "--branch", "--title", "--timeout"]
        static let flags: Set<String> = ["--visual", "--done", "--all-projects", "--json"]

        private(set) var positionals: [String] = []
        private(set) var values: [String: String] = [:]
        private(set) var set: Set<String> = []

        init(_ args: [String]) throws {
            var index = 0
            while index < args.count {
                let arg = args[index]
                if Options.takesValue.contains(arg) {
                    guard index + 1 < args.count else { throw Problem("\(arg) needs a value.") }
                    values[arg] = args[index + 1]
                    index += 2
                    continue
                }
                if Options.flags.contains(arg) { set.insert(arg) }
                else if arg.hasPrefix("--") { throw Problem("Unknown option \(arg). Run greenlight help.") }
                else { positionals.append(arg) }
                index += 1
            }
        }

        func value(_ name: String) -> String? { values[name] }
        func flag(_ name: String) -> Bool { set.contains(name) }

        func positional(_ index: Int, _ hint: String) throws -> String {
            guard index < positionals.count, !positionals[index].isEmpty else { throw Problem(hint) }
            return positionals[index]
        }

        func number(_ index: Int, _ hint: String) throws -> Int {
            let text = try positional(index, hint)
            guard let number = Int(text.hasPrefix("#") ? String(text.dropFirst()) : text) else { throw Problem(hint) }
            return number
        }
    }

    private struct Shown: Encodable {
        let change: Change
        let batch: Batch?
        enum CodingKeys: String, CodingKey { case change, batch, planURL, waitsFor }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(change, forKey: .change)
            try container.encodeIfPresent(batch, forKey: .batch)
            try container.encodeIfPresent(change.planURL(in: batch)?.absoluteString, forKey: .planURL)
            let waitsFor = change.stage.waitsForUser ? "user" : change.stage.isFinished ? "nobody" : "claude"
            try container.encode(waitsFor, forKey: .waitsFor)
        }
    }

    /// The main repository's root for a folder, so a worktree counts as the repo it came from.
    static func projectRoot(_ explicit: String?) throws -> String {
        let start = explicit.map { ($0 as NSString).expandingTildeInPath } ?? FileManager.default.currentDirectoryPath
        guard let common = git(["-C", start, "rev-parse", "--path-format=absolute", "--git-common-dir"]) else {
            throw Problem("\(tilde(start)) is not in a git repository. Pass --project PATH.")
        }
        var root = common
        if (root as NSString).lastPathComponent == ".git" {
            root = (root as NSString).deletingLastPathComponent
        } else if let top = git(["-C", start, "rev-parse", "--show-toplevel"]) {
            root = top
        }
        return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    }

    private static func git(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func line(_ change: Change) -> String {
        let who = change.stage.waitsForUser ? "waits for the user" : change.stage.isFinished ? "finished" : "waits for Claude"
        var row = pad("#\(change.id)", 6) + pad(change.stage.rawValue, 12) + pad(who, 20) + change.title
        if let qa = change.qaURL, change.stage == .qa { row += "  " + qa }
        if let pr = change.prURL { row += "  " + pr }
        return row
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        String(decoding: (try? Ledger.encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Removes the waiter file when `greenlight wait` is stopped, so the app stops showing it as listening.
enum WaiterCleanup {
    nonisolated(unsafe) private static var file: UnsafeMutablePointer<CChar>?

    static func arm(file path: String) {
        file = strdup(path)
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber) { received in
                if let file = WaiterCleanup.file { unlink(file) }
                _exit(128 + received)
            }
        }
    }
}
