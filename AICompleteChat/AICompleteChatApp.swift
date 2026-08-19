import SwiftUI
import DesignFoundation

@main
struct AICompleteChatApp: App {
    @State private var appEnvironment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            // Passed explicitly (not just via `.environment`) so ContentView.init() can seed its
            // @ObservedObject voiceEngine/session properties with the real shared instances up
            // front — see ContentView's doc comment for why the environment-only + placeholder-
            // then-swap approach doesn't compile. `.environment` is kept too in case other views
            // added later prefer implicit @Environment access.
            ContentView(appEnvironment: appEnvironment)
                .environment(appEnvironment)
                .dfThemePreset(.slate)
        }
    }
}
