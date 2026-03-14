import SwiftUI
import FirebaseCore

// MARK: - kyberchatApp
//
// App entry point. Responsibilities:
//   • Configure Firebase (must happen before any Firebase SDK call)
//   • Register session-scoped service teardown on logout
//
// SPM dependencies required (File → Add Package Dependencies in Xcode):
//   • https://github.com/firebase/firebase-ios-sdk  (latest)
//     Products: FirebaseAuth, FirebaseFirestore, FirebaseMessaging
//   • https://github.com/apple/swift-crypto  (≥ 3.3.0)
//     Product: Crypto
//
// Xcode Signing & Capabilities:
//   • Push Notifications
//   • Background Modes → Remote notifications

@main
struct kyberchatApp: App {

    init() {
        // Firebase must be configured before any Auth / Firestore / Messaging call.
        // Reads GoogleService-Info.plist — add this file to the Xcode target if missing.
        FirebaseApp.configure()

        // When the PASETO session ends (explicit logout OR 401 auto-logout),
        // sign out of Firebase so Firestore security rules reject stale writes.
        SessionManager.shared.onLogout = {
            FirebaseAuthService.shared.signOut()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
