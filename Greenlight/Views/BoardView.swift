import SwiftUI

struct BoardView: View {
    let board: Board
    @AppStorage("showFinished") private var showFinished = false

    var body: some View {
        let groups = board.groups(showingFinished: showFinished)
        Group {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label(showFinished ? "No changes yet" : "Nothing open", systemImage: "checklist")
                } description: {
                    Text("Type /greenlight and your tasks in Claude Code. Each task shows up here for your call.")
                }
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.changes) { change in
                                ChangeRow(change: change, batch: group.batch, board: board)
                            }
                        } header: {
                            BatchHeader(batch: group.batch, board: board, hasOpen: group.changes.contains { !$0.stage.isFinished })
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem = board.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $showFinished) {
                    Text("Open").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Show finished and dropped changes too")
            }
        }
    }

    private var subtitle: String {
        switch board.waitingOnUser {
        case 0: return ""
        case 1: return "1 needs your call"
        case let count: return "\(count) need your call"
        }
    }
}

struct BatchHeader: View {
    let batch: Batch
    let board: Board
    let hasOpen: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(batch.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(CLI.tilde(batch.project))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if hasOpen {
                if board.isListening(to: batch.project) {
                    Label("Claude is listening", systemImage: "ear")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Claude isn't listening", systemImage: "ear.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Run /greenlight in \(CLI.tilde(batch.project)) so Claude picks up your calls.")
                }
            }
            if let link = batch.planURL, let url = URL(string: link) {
                Link("Plan", destination: url)
                    .font(.callout)
            }
        }
        .padding(.vertical, 4)
    }
}
