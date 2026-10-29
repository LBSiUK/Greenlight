import Foundation

/// Where a change is in the workflow. The user moves it at two gates (the plan, then the build on
/// localhost); Claude moves it everywhere else.
enum Stage: String, Codable, CaseIterable {
    case planning     // Claude: subagents are writing the plan
    case review       // user: greenlight or redlight the plan
    case redlit       // Claude: pick up, then ask the user what to change
    case replanning   // Claude: revising the plan
    case greenlit     // Claude: pick up and build
    case building     // Claude: building
    case qa           // user: try it on localhost, then accept or deny
    case denied       // Claude: pick up, then ask the user what is wrong
    case fixing       // Claude: fixing the build
    case accepted     // Claude: pick up and open the pull request
    case shipping     // Claude: pushing and opening the pull request
    case done         // pull request open
    case dropped      // abandoned

    /// The user has made a call that Claude has not picked up yet.
    var waitsForClaude: Bool { [.redlit, .greenlit, .denied, .accepted].contains(self) }

    /// Nothing happens until the user decides in the app.
    var waitsForUser: Bool { self == .review || self == .qa }

    var isFinished: Bool { self == .done || self == .dropped }

    /// What Claude does next when `greenlight wait` hands it a change in this stage.
    var nextStep: String? {
        switch self {
        case .redlit: return "set it to replanning, then ask the user what to change"
        case .greenlit: return "set it to building, then build it"
        case .denied: return "set it to fixing, then ask the user what is wrong"
        case .accepted: return "set it to shipping, then open the pull request"
        default: return nil
        }
    }
}

struct Batch: Codable, Identifiable, Equatable {
    var id: Int
    var title: String
    /// Root folder of the git repository the changes go into.
    var project: String
    /// The plan Artifact for the whole batch.
    var planURL: String?
    var created: Date
}

struct Change: Codable, Identifiable, Equatable {
    struct Event: Codable, Equatable {
        var at: Date
        var stage: Stage
        /// "user" for a click in the app, "claude" for the command.
        var by: String
    }

    var id: Int
    var batch: Int
    var title: String
    var summary: String
    /// The plan includes before and after pictures.
    var visual: Bool
    var stage: Stage
    var branch: String?
    var qaURL: String?
    var prURL: String?
    var updated: Date
    var history: [Event]

    /// This change's section of the batch plan.
    func planURL(in batch: Batch?) -> URL? {
        guard let link = batch?.planURL, !link.isEmpty else { return nil }
        let base = link.split(separator: "#", maxSplits: 1).first.map(String.init) ?? link
        return URL(string: base + "#change-\(id)")
    }
}

/// A running `greenlight wait`, so the app can tell whether a Claude session will hear a click.
struct Waiter: Codable, Equatable {
    var pid: Int32
    /// nil when the waiter watches every project.
    var project: String?
    var started: Date
}
