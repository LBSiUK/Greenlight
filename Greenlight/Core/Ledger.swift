import Foundation

enum LedgerError: Error, CustomStringConvertible {
    case noBatch(Int)
    case noChange(Int)
    case stageMoved(id: Int, expected: Stage, actual: Stage)

    var description: String {
        switch self {
        case .noBatch(let id): return "There is no batch \(id)."
        case .noChange(let id): return "There is no change #\(id)."
        case .stageMoved(let id, let expected, let actual):
            return "Change #\(id) is in \(actual.rawValue), not \(expected.rawValue)."
        }
    }
}

/// The records the app and the command share: one JSON file per batch, change and waiter, under
/// ~/Library/Application Support/Greenlight (or $GREENLIGHT_HOME). Writes hold a file lock and
/// replace files atomically, so a click in the app and a command run at the same moment don't lose
/// each other's edits.
struct Ledger {
    let root: URL

    static var defaultRoot: URL {
        if let home = ProcessInfo.processInfo.environment["GREENLIGHT_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Greenlight", isDirectory: true)
    }

    init(root: URL = Ledger.defaultRoot) {
        self.root = root
        for folder in [batchesFolder, changesFolder, waitersFolder] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    var batchesFolder: URL { root.appendingPathComponent("batches", isDirectory: true) }
    var changesFolder: URL { root.appendingPathComponent("changes", isDirectory: true) }
    var waitersFolder: URL { root.appendingPathComponent("waiters", isDirectory: true) }

    /// Where Claude keeps a batch's plan page, pictures and QA pages: .greenlight/<batch> in the
    /// repository, which git is told to ignore. It sits inside the project so the Artifact tool can
    /// publish from it and a later session finds it again.
    func planFolder(for batch: Batch) -> URL {
        let project = URL(fileURLWithPath: batch.project, isDirectory: true)
        let folder = project.appendingPathComponent(".greenlight/\(batch.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Ledger.ignoreInGit(project: project)
        return folder
    }

    /// Adds .greenlight/ to the repository's .git/info/exclude, once.
    static func ignoreInGit(project: URL) {
        var isFolder: ObjCBool = false
        let git = project.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isFolder), isFolder.boolValue else { return }
        let exclude = git.appendingPathComponent("info/exclude")
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(".greenlight/") else { return }
        try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try? (current + separator + ".greenlight/\n").write(to: exclude, atomically: true, encoding: .utf8)
    }

    // MARK: Reading

    func batches() -> [Batch] { readAll(Batch.self, in: batchesFolder).sorted { $0.id < $1.id } }
    func changes() -> [Change] { readAll(Change.self, in: changesFolder).sorted { $0.id < $1.id } }
    func batch(_ id: Int) -> Batch? { read(Batch.self, at: file(batchesFolder, id)) }
    func change(_ id: Int) -> Change? { read(Change.self, at: file(changesFolder, id)) }

    func changes(inProject project: String?) -> [Change] {
        guard let project else { return changes() }
        let ids = Set(batches().filter { $0.project == project }.map(\.id))
        return changes().filter { ids.contains($0.batch) }
    }

    // MARK: Writing

    func newBatch(title: String, project: String, now: Date = Date()) throws -> Batch {
        try locked {
            let batch = Batch(id: nextID(in: batchesFolder), title: title, project: project, planURL: nil, created: now)
            try write(batch, to: file(batchesFolder, batch.id))
            return batch
        }
    }

    func addChange(batch: Int, title: String, summary: String, visual: Bool, now: Date = Date()) throws -> Change {
        try locked {
            guard self.batch(batch) != nil else { throw LedgerError.noBatch(batch) }
            let change = Change(id: nextID(in: changesFolder), batch: batch, title: title, summary: summary,
                                visual: visual, stage: .planning, branch: nil, qaURL: nil, prURL: nil,
                                updated: now, history: [.init(at: now, stage: .planning, by: "claude")])
            try write(change, to: file(changesFolder, change.id))
            return change
        }
    }

    /// Records the plan link and puts the batch's changes that are still being planned up for review.
    @discardableResult
    func publishPlan(batch id: Int, url: String, now: Date = Date()) throws -> [Change] {
        try locked {
            guard var batch = batch(id) else { throw LedgerError.noBatch(id) }
            batch.planURL = url
            try write(batch, to: file(batchesFolder, id))
            var moved: [Change] = []
            for var change in changes() where change.batch == id && change.stage == .planning {
                change.move(to: .review, by: "claude", at: now)
                try write(change, to: file(changesFolder, change.id))
                moved.append(change)
            }
            return moved
        }
    }

    /// Edits a change. A new stage is added to its history.
    @discardableResult
    func update(_ id: Int, by actor: String, now: Date = Date(), _ edit: (inout Change) throws -> Void) throws -> Change {
        try locked {
            guard var change = change(id) else { throw LedgerError.noChange(id) }
            let before = change.stage
            try edit(&change)
            let after = change.stage
            change.stage = before
            change.move(to: after, by: actor, at: now)
            change.updated = now
            try write(change, to: file(changesFolder, id))
            return change
        }
    }

    /// The user's call from the app. Refuses if the change has moved on since the app last looked,
    /// so a stale button can't undo Claude's work.
    @discardableResult
    func decide(_ id: Int, from expected: Stage, to stage: Stage, now: Date = Date()) throws -> Change {
        try locked {
            guard var change = change(id) else { throw LedgerError.noChange(id) }
            guard change.stage == expected else {
                throw LedgerError.stageMoved(id: id, expected: expected, actual: change.stage)
            }
            change.move(to: stage, by: "user", at: now)
            try write(change, to: file(changesFolder, id))
            return change
        }
    }

    // MARK: Waiters

    func addWaiter(_ waiter: Waiter) throws {
        try write(waiter, to: waitersFolder.appendingPathComponent("\(waiter.pid).json"))
    }

    func removeWaiter(pid: Int32) {
        try? FileManager.default.removeItem(at: waitersFolder.appendingPathComponent("\(pid).json"))
    }

    /// Waiters whose process is still running. Files left by ones that died are removed.
    func liveWaiters() -> [Waiter] {
        readAll(Waiter.self, in: waitersFolder).filter { waiter in
            if kill(waiter.pid, 0) == 0 || errno == EPERM { return true }
            removeWaiter(pid: waiter.pid)
            return false
        }
    }

    func isListening(to project: String) -> Bool {
        liveWaiters().contains { $0.project == nil || $0.project == project }
    }

    // MARK: Files

    private func file(_ folder: URL, _ id: Int) -> URL { folder.appendingPathComponent("\(id).json") }

    private func nextID(in folder: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return (names.compactMap { Int(($0 as NSString).deletingPathExtension) }.max() ?? 0) + 1
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(root.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return try body() }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        return try body()
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Ledger.decoder.decode(type, from: data)
    }

    private func readAll<T: Decodable>(_ type: T.Type, in folder: URL) -> [T] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { read(type, at: folder.appendingPathComponent($0)) }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try Ledger.encoder.encode(value).write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension Change {
    mutating func move(to stage: Stage, by actor: String, at now: Date) {
        guard stage != self.stage else { return }
        self.stage = stage
        updated = now
        history.append(.init(at: now, stage: stage, by: actor))
    }
}
