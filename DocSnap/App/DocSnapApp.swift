import SwiftUI

@main
struct DocSnapApp: App {
    @State private var store: DocumentStore
    @AppStorage(Settings.appearanceKey) private var appearance: AppearanceMode = .system

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
                // Applied to the UIWindow: .preferredColorScheme(nil) doesn't reliably return to System.
                .onAppear { appearance.apply() }
                .onChange(of: appearance) { _, newValue in newValue.apply() }
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
