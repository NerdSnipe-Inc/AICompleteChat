import SwiftUI
import DesignFoundation

@main
struct AICompleteChatApp: App {
    @State private var appEnvironment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appEnvironment)
                .dfThemePreset(.slate)
        }
    }
}
