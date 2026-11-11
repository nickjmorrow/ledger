import LedgerUI
import SwiftUI

@main
struct LedgerMacApp: App {
    @State private var model: LedgerModel

    init() {
        do { _model = State(initialValue: try LedgerModel.openDefault()) } catch { fatalError("Can't open the Ledger database: \(error)") }
    }

    var body: some Scene {
        WindowGroup {
            MacRootView().environment(model).frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 800)
        .commands { LedgerCommands(model: model) }
        Settings { SettingsView().environment(model).preferredColorScheme(.dark) }
    }
}
