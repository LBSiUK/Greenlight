#if DEBUG
import AppKit

/// Made-up batches for screenshots, so no real projects show up in them. They live in a fresh
/// folder under the temporary directory, never in the real records.
/// Debug builds only: `Greenlight -demo YES`, plus any of
///   -demoScreen NAME        put the window on the display whose name contains NAME
///   -demoAppearance light   or dark
///   -demoSize 700x660       window size in points
///   -showFinished YES       show finished changes too (the "All" view)
///   -demoActive YES         draw the window as active even when it isn't
enum Demo {
    private static let defaults = UserDefaults.standard

    static var isOn: Bool { defaults.bool(forKey: "demo") }

    static func makeLedger() -> Ledger {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("greenlight-demo-\(UUID().uuidString)")
        let ledger = Ledger(root: root)
        let code = NSHomeDirectory() + "/code/"
        let hour: TimeInterval = 3600
        let start = Date().addingTimeInterval(-30 * hour)
        do {
            let recipes = try ledger.newBatch(title: "Recipes API", project: code + "recipes", now: start)
            try add(ledger, recipes, "Paginate the recipe list", "Return 20 recipes a page, with next and previous links.",
                    stage: .done) { $0.prURL = "https://github.com/example/recipes/pull/42" }
            try add(ledger, recipes, "Search by ingredient", "A ?ingredient= filter that matches any of several ingredients.",
                    stage: .replanning)
            try ledger.publishPlan(batch: recipes.id, url: "https://claude.ai/code/artifact/demo-recipes", now: start)

            let portfolio = try ledger.newBatch(title: "Portfolio polish", project: code + "portfolio", now: start.addingTimeInterval(20 * hour))
            try add(ledger, portfolio, "Darker footer", "Move the footer onto the deep green brand colour so it stands apart from the page.",
                    visual: true, stage: .review)
            try add(ledger, portfolio, "Fix the pricing typo", "\"Anual\" becomes \"Annual\" in the pricing table.", stage: .review)
            try add(ledger, portfolio, "Validate the contact form", "Check the email and message before sending, with an error under each field.",
                    visual: true, stage: .qa) { $0.qaURL = "http://localhost:5173/contact" }
            try add(ledger, portfolio, "Lazy-load the gallery", "Load gallery images as they scroll into view.", stage: .building)
            try ledger.publishPlan(batch: portfolio.id, url: "https://claude.ai/code/artifact/demo-portfolio")
            // The app's own process stands in for a Claude session running `greenlight wait`.
            try ledger.addWaiter(Waiter(pid: getpid(), project: nil, started: Date()))
        } catch {
            NSLog("Greenlight demo: \(error)")
        }
        return ledger
    }

    private static func add(_ ledger: Ledger, _ batch: Batch, _ title: String, _ summary: String, visual: Bool = false,
                            stage: Stage, _ edit: (inout Change) -> Void = { _ in }) throws {
        let change = try ledger.addChange(batch: batch.id, title: title, summary: summary, visual: visual)
        if stage == .review { return }  // publishPlan moves it there
        try ledger.update(change.id, by: "claude") { change in
            change.stage = stage
            edit(&change)
        }
    }

    @MainActor
    static func start() {
        if defaults.bool(forKey: "demoActive") { drawAsActive() }
        switch defaults.string(forKey: "demoAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let window = NSApp.windows.first(where: { $0.title == "Greenlight" }) else { return }
            let parts = (defaults.string(forKey: "demoSize") ?? "700x660").split(separator: "x").compactMap { Double($0) }
            let size = parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : NSSize(width: 700, height: 660)
            let frame = screen.visibleFrame
            window.setFrame(NSRect(x: frame.minX + 60, y: frame.maxY - 60 - size.height, width: size.width, height: size.height),
                            display: true)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Makes windows draw as the active window even when another app (or the lock screen) is in
    /// front, so screenshots can be taken while the Mac is busy or locked.
    private static func drawAsActive() {
        func swap(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
            guard let a = class_getInstanceMethod(type, original), let b = class_getInstanceMethod(type, replacement) else { return }
            method_exchangeImplementations(a, b)
        }
        swap(NSWindow.self, #selector(getter: NSWindow.isKeyWindow), #selector(getter: NSWindow.demoAlwaysTrue))
        swap(NSWindow.self, #selector(getter: NSWindow.isMainWindow), #selector(getter: NSWindow.demoAlwaysTrueToo))
        swap(NSApplication.self, #selector(getter: NSApplication.isActive), #selector(getter: NSApplication.demoAlwaysActive))
    }

    private static var screen: NSScreen {
        let name = defaults.string(forKey: "demoScreen") ?? ""
        return NSScreen.screens.first { !name.isEmpty && $0.localizedName.localizedCaseInsensitiveContains(name) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
#endif

#if DEBUG
extension NSWindow {
    @objc var demoAlwaysTrue: Bool { true }
    @objc var demoAlwaysTrueToo: Bool { true }
}

extension NSApplication {
    @objc var demoAlwaysActive: Bool { true }
}
#endif
