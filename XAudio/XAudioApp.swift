import SwiftUI

@main
struct XAudioApp: App {
    @State private var model = AudioLibraryModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}

