import SwiftUI

@main
struct DocSnapApp: App {
    @State private var store: DocumentStore

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(SampleData.launchArgument) {
            _store = State(initialValue: SampleData.makeStore())
            return
        }
        #endif
        _store = State(initialValue: DocumentStore())
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
                .task {
                    store.cleanExports()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains(SampleData.launchArgument) {
                        await SampleData.seed(store)
                    }
                    #endif
                }
        }
    }
}
