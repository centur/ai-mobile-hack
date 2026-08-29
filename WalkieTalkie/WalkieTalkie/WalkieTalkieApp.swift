import SwiftUI
import UIKit

@main
final class WalkieTalkieAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = WalkieTalkieSceneDelegate.self
        return configuration
    }
}

final class WalkieTalkieSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = LandscapeHostingController(rootView: ContentView())
        self.window = window
        window.makeKeyAndVisible()
    }
}

/// Uses the iOS 26 scene-orientation preference instead of the deprecated
/// `UIRequiresFullScreen` compatibility mode.
final class LandscapeHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .landscape
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .landscapeRight
    }

    override var prefersInterfaceOrientationLocked: Bool {
        true
    }
}
