import SwiftUI
import UIKit

final class XAudioAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .allButUpsideDown
    }
}

@main
struct XAudioApp: App {
    @UIApplicationDelegateAdaptor(XAudioAppDelegate.self)
    private var appDelegate

    @State private var model = AudioLibraryModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
