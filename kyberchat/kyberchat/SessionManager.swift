import Foundation
import Observation

/// The single source of truth for authentication state.
///
/// Persists the PASETO token to Keychain and user identity to UserDefaults.
/// Views observe `isLoggedIn` to drive navigation. Any `401` response from
/// the API should call `SessionManager.shared.logout()` to clear state and
/// route back to the login screen.
@Observable
final class SessionManager {

    static let shared = SessionManager()

    // MARK: - Published state

    /// `true` when a valid token exists in Keychain. Drives root navigation.
    private(set) var isLoggedIn: Bool = false

    /// The authenticated user's UUID. Available after login or auto-login.
    private(set) var userUUID: String = ""

    /// The authenticated user's username.
    private(set) var username: String = ""

    // MARK: - UserDefaults keys

    private enum UDKey {
        static let userUUID  = "kyberchat_user_uuid"
        static let username  = "kyberchat_username"
    }

    // MARK: - Init

    private init() {
        // Restore non-sensitive identity from UserDefaults immediately so
        // userUUID / username are available before the Keychain check completes.
        userUUID = UserDefaults.standard.string(forKey: UDKey.userUUID) ?? ""
        username = UserDefaults.standard.string(forKey: UDKey.username) ?? ""
    }

    // MARK: - Token accessors

    /// The stored PASETO token, or `nil` if the user is not authenticated.
    var token: String? {
        KeychainHelper.read(account: KeychainAccount.authToken.rawValue)
    }

    // MARK: - Logout hook

    /// Optional callback invoked on every logout, whether triggered explicitly
    /// (user taps Log Out) or automatically (401 response from the API).
    ///
    /// Register at app startup to tear down session-scoped services:
    /// ```swift
    /// SessionManager.shared.onLogout = {
    ///     FirebaseAuthService.shared.signOut()
    /// }
    /// ```
    var onLogout: (() -> Void)?

    // MARK: - Login / Logout

    /// Called after a successful `POST /validate_login` or `POST /create_user`.
    /// Persists credentials and updates observable state.
    func login(token: String, userUUID: String, username: String) {
        KeychainHelper.save(token, account: KeychainAccount.authToken.rawValue)
        UserDefaults.standard.set(userUUID, forKey: UDKey.userUUID)
        UserDefaults.standard.set(username, forKey: UDKey.username)
        self.userUUID = userUUID
        self.username = username
        self.isLoggedIn = true
    }

    /// Clears all session state and navigates back to the login screen.
    /// Call on explicit logout or when any API call returns 401.
    func logout() {
        KeychainHelper.delete(account: KeychainAccount.authToken.rawValue)
        UserDefaults.standard.removeObject(forKey: UDKey.userUUID)
        UserDefaults.standard.removeObject(forKey: UDKey.username)
        userUUID = ""
        username = ""
        isLoggedIn = false
        // Notify session-scoped services (e.g. FirebaseAuthService) to clean up.
        onLogout?()
    }

    /// Attempts to restore a session from Keychain on cold launch.
    /// Call from `ContentView.onAppear` or the app entry point.
    func restoreSession() {
        guard let _ = token, !userUUID.isEmpty else {
            isLoggedIn = false
            return
        }
        // Token exists and identity is present — treat as logged in.
        // The token expiry is validated server-side on the first authenticated
        // request; if it has expired the API returns 401 which triggers logout().
        isLoggedIn = true
    }
}
