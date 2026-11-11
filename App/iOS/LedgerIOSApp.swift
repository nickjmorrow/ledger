import LedgerUI
import SwiftUI

@main
struct LedgerIOSApp: App {
    @State private var model: LedgerModel

    init() {
        do { _model = State(initialValue: try LedgerModel.openDefault()) } catch { fatalError("Can't open the Ledger database: \(error)") }
    }

    var body: some Scene {
        WindowGroup { PhoneRootView().environment(model) }
    }
}
