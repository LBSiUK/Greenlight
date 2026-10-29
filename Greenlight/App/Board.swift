import Foundation
import Observation

/// What the window shows: the ledger's batches and changes, reloaded whenever a file in it changes.
@MainActor
@Observable
final class Board {
    struct Group: Identifiable {
        let batch: Batch
        let changes: [Change]
        var id: Int { batch.id }
    }

    private(set) var batches: [Batch] = []
    private(set) var changes: [Change] = []
    private(set) var waiters: [Waiter] = []
    /// The last click that could not be saved, shown under the toolbar until the next reload.
    private(set) var problem: String?

    @ObservationIgnored private let ledger: Ledger
    @ObservationIgnored private var sources: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var timer: Timer?

    init(ledger: Ledger = Ledger()) {
        self.ledger = ledger
    }

    func start() {
        reload()
        for folder in [ledger.batchesFolder, ledger.changesFolder, ledger.waitersFolder] {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reload() } }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
        // A `greenlight wait` that is killed can't always remove its file, so check now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.waiters = self?.ledger.liveWaiters() ?? [] }
        }
    }

    func reload() {
        batches = ledger.batches()
        changes = ledger.changes()
        waiters = ledger.liveWaiters()
    }

    func groups(showingFinished: Bool) -> [Group] {
        batches.reversed().compactMap { batch in
            let mine = changes.filter { $0.batch == batch.id && (showingFinished || !$0.stage.isFinished) }
            return mine.isEmpty ? nil : Group(batch: batch, changes: mine)
        }
    }

    var waitingOnUser: Int { changes.filter(\.stage.waitsForUser).count }

    func isListening(to project: String) -> Bool {
        waiters.contains { $0.project == nil || $0.project == project }
    }

    func decide(_ change: Change, _ stage: Stage) {
        do {
            try ledger.decide(change.id, from: change.stage, to: stage)
            problem = nil
        } catch {
            problem = "\(error)"
        }
        reload()
    }
}
