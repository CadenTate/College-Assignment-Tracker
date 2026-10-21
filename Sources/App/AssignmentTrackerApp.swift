import SwiftUI

@main
struct AssignmentTrackerApp: App {
    @StateObject private var pro = Pro()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(pro) }
        #if os(macOS)
            .defaultSize(width: 1080, height: 780)
        #endif
    }
}
