import SwiftUI

struct ChangeRow: View {
    let change: Change
    let batch: Batch
    let board: Board

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(change.id)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(change.title)
                    .fontWeight(.semibold)
                if change.visual {
                    Image(systemName: "photo.on.rectangle")
                        .foregroundStyle(.secondary)
                        .help("The plan shows before and after pictures")
                }
                Spacer(minLength: 12)
                Label(change.stage.title, systemImage: change.stage.symbol)
                    .font(.callout)
                    .foregroundStyle(change.stage.tint)
            }
            if !change.summary.isEmpty {
                Text(change.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let detail = change.stage.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            actions
        }
        .padding(.vertical, 6)
        // Run the separator under the whole row, not from whichever text SwiftUI picks.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    @ViewBuilder private var actions: some View {
        let plan = change.planURL(in: batch)
        switch change.stage {
        case .review:
            HStack {
                if let plan { Link("Open plan", destination: plan) }
                Spacer()
                Button("Redlight") { board.decide(change, .redlit) }
                    .tint(.red)
                Button("Greenlight") { board.decide(change, .greenlit) }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
            .controlSize(.regular)
        case .qa:
            HStack {
                if let link = change.qaURL, let url = URL(string: link) {
                    Button("Open \(url.host() ?? "localhost")\(url.port.map { ":\($0)" } ?? "")", systemImage: "safari") {
                        NSWorkspace.shared.open(url)
                    }
                }
                if let plan { Link("Plan", destination: plan) }
                Spacer()
                Button("Deny") { board.decide(change, .denied) }
                    .tint(.red)
                Button("Accept") { board.decide(change, .accepted) }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        case .done:
            HStack {
                if let link = change.prURL, let url = URL(string: link) {
                    Link("Open pull request", destination: url)
                }
                if let plan { Link("Plan", destination: plan) }
            }
        default:
            if let plan { Link("Open plan", destination: plan) }
        }
    }
}

extension Stage {
    var title: String {
        switch self {
        case .planning: return "Planning"
        case .review: return "Needs your call"
        case .redlit: return "Red-lit"
        case .replanning: return "Replanning"
        case .greenlit: return "Green-lit"
        case .building: return "Building"
        case .qa: return "Ready to test"
        case .denied: return "Denied"
        case .fixing: return "Fixing"
        case .accepted: return "Accepted"
        case .shipping: return "Opening PR"
        case .done: return "PR open"
        case .dropped: return "Dropped"
        }
    }

    var detail: String? {
        switch self {
        case .planning: return "Claude is planning this change."
        case .redlit: return "Claude will ask you what to change."
        case .replanning: return "Claude is revising the plan."
        case .greenlit: return "Claude will build it."
        case .building: return "Claude is building it and will put it on localhost."
        case .denied: return "Claude will ask you what is wrong."
        case .fixing: return "Claude is fixing it."
        case .accepted: return "Claude will open a pull request."
        case .shipping: return "Claude is opening the pull request."
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .planning, .replanning: return "pencil.and.list.clipboard"
        case .review: return "hand.raised.fill"
        case .redlit, .denied: return "xmark.circle.fill"
        case .greenlit, .accepted: return "checkmark.circle.fill"
        case .building, .fixing: return "hammer.fill"
        case .shipping: return "arrow.up.circle"
        case .qa: return "safari.fill"
        case .done: return "arrow.triangle.pull"
        case .dropped: return "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .review: return .orange
        case .qa: return .blue
        case .redlit, .denied: return .red
        case .greenlit, .accepted: return .green
        case .done: return .purple
        default: return .secondary
        }
    }
}
