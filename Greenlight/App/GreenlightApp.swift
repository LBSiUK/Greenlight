import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CLI.wanted(CommandLine.arguments) {
            exit(CLI.run(CommandLine.arguments))
        }
        GreenlightApp.main()
    }
}

struct GreenlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Greenlight", id: "main") {
            BoardView(board: delegate.board)
                .frame(minWidth: 480, minHeight: 360)
        }
        .defaultSize(width: 680, height: 600)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    let board = Board(ledger: Demo.isOn ? Demo.makeLedger() : Ledger())
    #else
    let board = Board()
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        board.start()
        #if DEBUG
        if Demo.isOn { return Demo.start() }
        #endif
        Installer.run()
    }
}
