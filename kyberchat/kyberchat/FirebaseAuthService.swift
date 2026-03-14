// FirebaseAuthService.swift
//
// Manages the Firebase Auth session that grants the iOS client permission to
// write directly to Firestore. The KyberChat server issues a signed Firebase
// custom token (via POST /firebase_token) in exchange for a valid PASETO session
// token. This file handles the exchange, caching, and teardown lifecycle.
//
// Architecture (Option A — Custom Token Bridge):
//
//   PASETO session (KyberChat API)
//       │
//       ▼
//   POST /firebase_token  ──►  firebase_admin.auth.create_custom_token(user_uuid)
//       │
//       ▼  firebase_token (JWT, 1-hour TTL)
//   Auth.auth().signIn(withCustomToken:)
//       │
//       ▼  Firebase ID token (auto-refreshed by SDK)
//   Firestore security rules: request.auth.uid == user_uuid
//
// Usage:
//   • Call `refreshIfNeeded(pasteToken:)` in FriendsListView.task — covers both
//     cold launch (restoreSession) and fresh login paths.
//   • `SessionManager.shared.onLogout` calls `FirebaseAuthService.shared.signOut()`
//     to clear the Firebase session alongside the PASETO session.
//
// SPM dependency required:
//   https://github.com/firebase/firebase-ios-sdk  (latest)
//   Products: FirebaseAuth, FirebaseFirestore
//
// Xcode setup:
//   1. Add GoogleService-Info.plist to the Xcode project target.
//   2. Call FirebaseApp.configure() in kyberchatApp.init() — already done.
//   3. Enable Push Notifications + Background Modes (Remote notifications) in
//      Signing & Capabilities.

import Foundation
import FirebaseAuth

@Observable
final class FirebaseAuthService {

    static let shared = FirebaseAuthService()

    // MARK: - Observable state

    /// `true` once signIn(withCustomToken:) has succeeded in this session.
    /// Does NOT track internal Firebase token refresh — the SDK handles that.
    private(set) var isSignedIn: Bool = false

    // MARK: - Init

    private init() {
        // Sync initial state with Firebase SDK on cold launch.
        // Firebase may already have a valid session from a previous run if the
        // ID token hasn't expired and the user hasn't signed out.
        isSignedIn = Auth.auth().currentUser != nil
    }

    // MARK: - Public API

    /// Signs in with a Firebase custom token received from POST /firebase_token.
    /// After this call the Firebase SDK automatically refreshes the derived ID
    /// token — no further calls to this method are needed unless the user logs out.
    func signIn(with customToken: String) async throws {
        let _ = try await Auth.auth().signIn(withCustomToken: customToken)
        isSignedIn = true
    }

    /// Signs out of Firebase. Called by the SessionManager logout hook so the
    /// Firebase UID is invalidated when the PASETO session ends.
    func signOut() {
        try? Auth.auth().signOut()
        isSignedIn = false
    }

    /// Ensures a Firebase session exists. No-ops if Firebase already has a
    /// current user (the SDK auto-refreshes the underlying ID token).
    ///
    /// Call from `FriendsListView.task` to cover both cold launches (where
    /// Firebase may still have a valid user) and fresh logins.
    ///
    /// This method is intentionally non-throwing — a Firebase auth failure is
    /// non-fatal. PASETO-authenticated server calls still work; only direct
    /// Firestore writes will be rejected until the next successful refresh.
    func refreshIfNeeded(pasteToken: String) async {
        // Firebase SDK holds a current user and auto-refreshes its ID token.
        // No server round-trip needed.
        if Auth.auth().currentUser != nil {
            isSignedIn = true
            return
        }

        do {
            let response = try await APIService.shared.getFirebaseToken(token: pasteToken)
            try await signIn(with: response.firebase_token)
        } catch APIError.unauthorized {
            // PASETO token itself has expired — SessionManager.logout() will
            // be triggered by the 401 handler in APIService. Nothing to do here.
        } catch {
            // Firebase unavailable, network error, etc. Non-fatal.
            // Firestore writes will fail with PERMISSION_DENIED until the next
            // refreshIfNeeded call (e.g. next app foreground).
        }
    }
}
