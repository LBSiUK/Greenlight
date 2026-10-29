import Foundation
import Testing

private func freshLedger() -> Ledger {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("greenlight-tests-\(UUID().uuidString)")
    return Ledger(root: root)
}

@Suite struct LedgerTests {
    @Test func numbersBatchesAndChangesInOrder() throws {
        let ledger = freshLedger()
        let first = try ledger.newBatch(title: "One", project: "/repo")
        let second = try ledger.newBatch(title: "Two", project: "/repo")
        #expect(first.id == 1 && second.id == 2)
        let a = try ledger.addChange(batch: 1, title: "A", summary: "", visual: false)
        let b = try ledger.addChange(batch: 2, title: "B", summary: "", visual: true)
        #expect(a.id == 1 && b.id == 2)
        #expect(a.stage == .planning)
        #expect(ledger.changes().map(\.title) == ["A", "B"])
    }

    @Test func refusesAChangeForAMissingBatch() {
        let ledger = freshLedger()
        #expect(throws: LedgerError.self) { try ledger.addChange(batch: 9, title: "A", summary: "", visual: false) }
    }

    @Test func publishingThePlanPutsPlanningChangesUpForReview() throws {
        let ledger = freshLedger()
        _ = try ledger.newBatch(title: "One", project: "/repo")
        _ = try ledger.addChange(batch: 1, title: "A", summary: "", visual: false)
        _ = try ledger.addChange(batch: 1, title: "B", summary: "", visual: false)
        try ledger.update(2, by: "claude") { $0.stage = .dropped }
        let moved = try ledger.publishPlan(batch: 1, url: "https://claude.ai/code/artifact/abc")
        #expect(moved.map(\.id) == [1])
        #expect(ledger.change(1)?.stage == .review)
        #expect(ledger.change(2)?.stage == .dropped)
        let link = ledger.change(1)?.planURL(in: ledger.batch(1))
        #expect(link?.absoluteString == "https://claude.ai/code/artifact/abc#change-1")
    }

    @Test func updateRecordsEachNewStageOnce() throws {
        let ledger = freshLedger()
        _ = try ledger.newBatch(title: "One", project: "/repo")
        _ = try ledger.addChange(batch: 1, title: "A", summary: "", visual: false)
        try ledger.update(1, by: "claude") { $0.stage = .review }
        try ledger.update(1, by: "claude") { $0.qaURL = "http://localhost:5173/" }
        let change = try #require(ledger.change(1))
        #expect(change.history.map(\.stage) == [.planning, .review])
        #expect(change.qaURL == "http://localhost:5173/")
    }

    @Test func aClickOnAStaleButtonIsRefused() throws {
        let ledger = freshLedger()
        _ = try ledger.newBatch(title: "One", project: "/repo")
        _ = try ledger.addChange(batch: 1, title: "A", summary: "", visual: false)
        try ledger.publishPlan(batch: 1, url: "https://example.com")
        try ledger.decide(1, from: .review, to: .greenlit)
        #expect(ledger.change(1)?.history.last?.by == "user")
        // The app still shows "review"; Claude has already moved on to building.
        try ledger.update(1, by: "claude") { $0.stage = .building }
        #expect(throws: LedgerError.self) { try ledger.decide(1, from: .review, to: .redlit) }
        #expect(ledger.change(1)?.stage == .building)
    }

    @Test func filtersChangesByProject() throws {
        let ledger = freshLedger()
        _ = try ledger.newBatch(title: "One", project: "/a")
        _ = try ledger.newBatch(title: "Two", project: "/b")
        _ = try ledger.addChange(batch: 1, title: "A", summary: "", visual: false)
        _ = try ledger.addChange(batch: 2, title: "B", summary: "", visual: false)
        #expect(ledger.changes(inProject: "/b").map(\.title) == ["B"])
        #expect(ledger.changes(inProject: nil).count == 2)
    }

    @Test func keepsPlansInAGitIgnoredFolderInTheRepo() throws {
        let ledger = freshLedger()
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("gl-plan-\(UUID().uuidString)")
        let exclude = repo.appendingPathComponent(".git/info/exclude")
        try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "*.log".write(to: exclude, atomically: true, encoding: .utf8)
        let batch = try ledger.newBatch(title: "One", project: repo.path)
        let folder = ledger.planFolder(for: batch)
        _ = ledger.planFolder(for: batch)
        #expect(folder.path == repo.appendingPathComponent(".greenlight/1").path)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(try String(contentsOf: exclude, encoding: .utf8) == "*.log\n.greenlight/\n")
    }

    @Test func forgetsWaitersWhoseProcessHasEnded() throws {
        let ledger = freshLedger()
        try ledger.addWaiter(Waiter(pid: getpid(), project: "/a", started: Date()))
        try ledger.addWaiter(Waiter(pid: 999_999, project: "/b", started: Date()))
        #expect(ledger.liveWaiters().map(\.project) == ["/a"])
        #expect(ledger.isListening(to: "/a"))
        #expect(!ledger.isListening(to: "/b"))
    }
}

@Suite struct CLITests {
    @Test func recognisesTheCommandForm() {
        #expect(CLI.wanted(["/Users/me/.local/bin/greenlight"]))
        #expect(CLI.wanted(["/Applications/Greenlight.app/Contents/MacOS/Greenlight", "wait"]))
        #expect(!CLI.wanted(["/Applications/Greenlight.app/Contents/MacOS/Greenlight"]))
        #expect(!CLI.wanted(["/Applications/Greenlight.app/Contents/MacOS/Greenlight", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    @Test func parsesOptionsAndFlags() throws {
        let options = try CLI.Options(["3", "Darker footer", "--summary", "Use the dark tone", "--visual"])
        #expect(try options.number(0, "") == 3)
        #expect(try options.positional(1, "") == "Darker footer")
        #expect(options.value("--summary") == "Use the dark tone")
        #expect(options.flag("--visual"))
        #expect(try CLI.Options(["#14"]).number(0, "") == 14)
        #expect(throws: CLI.Problem.self) { try CLI.Options(["--stage"]) }
        #expect(throws: CLI.Problem.self) { try CLI.Options(["--nope"]) }
    }

    @Test func waitReturnsAtOnceWhenACallIsWaiting() throws {
        let ledger = freshLedger()
        _ = try ledger.newBatch(title: "One", project: "/a")
        _ = try ledger.addChange(batch: 1, title: "A", summary: "", visual: false)
        try ledger.publishPlan(batch: 1, url: "https://example.com")
        try ledger.decide(1, from: .review, to: .greenlit)
        #expect(CLI.run(["greenlight", "wait", "--all-projects", "--timeout", "5"], ledger: ledger) == 0)
        #expect(ledger.liveWaiters().isEmpty)
    }

    @Test func waitTimesOutWhileTheUserIsStillDeciding() throws {
        let ledger = freshLedger()
        _ = try ledger.newBatch(title: "One", project: "/a")
        _ = try ledger.addChange(batch: 1, title: "A", summary: "", visual: false)
        try ledger.publishPlan(batch: 1, url: "https://example.com")
        #expect(CLI.run(["greenlight", "wait", "--all-projects", "--timeout", "0"], ledger: ledger) == 4)
    }

    @Test func waitStopsWhenNothingIsOpen() throws {
        let ledger = freshLedger()
        #expect(CLI.run(["greenlight", "wait", "--all-projects"], ledger: ledger) == 3)
    }

    @Test func waitWakesWhenTheUserDecidesLater() async throws {
        let ledger = freshLedger()
        _ = try ledger.newBatch(title: "One", project: "/a")
        _ = try ledger.addChange(batch: 1, title: "A", summary: "", visual: false)
        try ledger.publishPlan(batch: 1, url: "https://example.com")
        let waiting = Task.detached { CLI.run(["greenlight", "wait", "--all-projects", "--timeout", "10"], ledger: ledger) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(ledger.liveWaiters().count == 1)
        try ledger.decide(1, from: .review, to: .redlit)
        #expect(await waiting.value == 0)
    }

    @Test func waitWontStartASecondListenerForTheSameProject() throws {
        let ledger = freshLedger()
        _ = try ledger.newBatch(title: "One", project: "/a")
        _ = try ledger.addChange(batch: 1, title: "A", summary: "", visual: false)
        try ledger.publishPlan(batch: 1, url: "https://example.com")
        try ledger.addWaiter(Waiter(pid: getppid(), project: nil, started: Date()))
        #expect(CLI.run(["greenlight", "wait", "--all-projects", "--timeout", "0"], ledger: ledger) == 5)
        #expect(ledger.liveWaiters().count == 1)
    }

    @Test func findsTheMainRepositoryFromAWorktree() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gl-repo-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo").path
        let worktree = base.appendingPathComponent("wt").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t"] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        try git("init", "-q")
        try git("commit", "-q", "--allow-empty", "-m", "start")
        try git("worktree", "add", "-q", worktree, "-b", "side")
        let expected = URL(fileURLWithPath: repo).resolvingSymlinksInPath().path
        #expect(try CLI.projectRoot(repo) == expected)
        #expect(try CLI.projectRoot(worktree) == expected)
        #expect(throws: CLI.Problem.self) { try CLI.projectRoot(base.path) }
    }
}
